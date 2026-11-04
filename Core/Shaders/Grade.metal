// Portions of this file (ailut_eval / lower_bound_clamped / lut_apply) port the
// CPU kernels of AdaInt, https://github.com/ImCharlesY/AdaInt at commit
// 5678851339dff90becb09c3dec41e7214207ccbc (adaint/ailut_transform/ailut/csrc/
// ailut_transform_cpu.cpp), Copyright (c) MMEditing Authors, licensed under
// Apache-2.0 (Resources/Models/AdaInt-LICENSE.txt). Changed by AutoGrade: ported
// from C++ to Metal compute kernels. Those portions remain under Apache-2.0;
// the rest is PolyForm Noncommercial 1.0.0 (LICENSE).
// AutoGrade kernels. Every kernel here has a golden counterpart in fixtures/
// and an XCTest; the comments say which upstream line each one mirrors.
//
// Layouts (identical to the PyTorch/upstream side, see research/fixture_io.py):
//   planar image  float[3][h][w]             channel c at offset c*w*h
//   LUT           float[3][n][n][n]          lut[c][b][g][r], r fastest
//   vertices      float[3][d]                per-channel AdaInt sampling points
#include <metal_stdlib>
using namespace metal;

// ------------------------------------------------------------------ decode --
// BT.709 limited range, 8-bit 4:2:0 -> planar RGB in [0,1]. The convention is
// CLAUDE.md 架构原则 4 and research/make_fixtures.py::yuv709_to_rgb. Textures
// are the decoder's planes (r8Unorm luma, rg8Unorm interleaved CbCr); rint
// recovers the exact integer code from the unorm read.
kernel void yuv420_to_rgb(texture2d<float, access::read> lumaTex   [[texture(0)]],
                          texture2d<float, access::read> chromaTex [[texture(1)]],
                          device float *rgb                        [[buffer(0)]],
                          uint2 g                                  [[thread_position_in_grid]])
{
    const uint w = lumaTex.get_width(), h = lumaTex.get_height();
    if (g.x >= w || g.y >= h) return;
    const uint wc = chromaTex.get_width(), hc = chromaTex.get_height();

    const float y = (rint(lumaTex.read(g).r * 255.0f) - 16.0f) / 219.0f;

    // chroma sample (i, j) sits at luma (2i, 2j + 0.5)
    const float cx = clamp(float(g.x) * 0.5f, 0.0f, float(wc - 1));
    const float cy = clamp((float(g.y) - 0.5f) * 0.5f, 0.0f, float(hc - 1));
    const uint x0 = uint(floor(cx)), y0 = uint(floor(cy));
    const uint x1 = min(x0 + 1, wc - 1), y1 = min(y0 + 1, hc - 1);
    const float fx = cx - float(x0), fy = cy - float(y0);
    const float2 c00 = rint(chromaTex.read(uint2(x0, y0)).rg * 255.0f);
    const float2 c10 = rint(chromaTex.read(uint2(x1, y0)).rg * 255.0f);
    const float2 c01 = rint(chromaTex.read(uint2(x0, y1)).rg * 255.0f);
    const float2 c11 = rint(chromaTex.read(uint2(x1, y1)).rg * 255.0f);
    const float2 top = c00 * (1.0f - fx) + c10 * fx;
    const float2 bot = c01 * (1.0f - fx) + c11 * fx;
    const float2 c = top * (1.0f - fy) + bot * fy;
    const float u = (c.x - 128.0f) / 224.0f;
    const float v = (c.y - 128.0f) / 224.0f;

    const uint i = g.y * w + g.x, n = w * h;
    rgb[i]         = clamp(y + 1.5748f * v, 0.0f, 1.0f);
    rgb[i + n]     = clamp(y - 0.187324f * u - 0.468124f * v, 0.0f, 1.0f);
    rgb[i + 2 * n] = clamp(y + 1.8556f * u, 0.0f, 1.0f);
}

// ------------------------------------------------------------------ resize --
// F.interpolate(mode="bilinear", align_corners=False), no antialias: PyTorch's
// area_pixel_compute_source_index (clamped at 0) and its h1p/w1p edge rule.
struct ResizeParams { uint sw, sh, dw, dh; };

kernel void resize_bilinear(device const float *src       [[buffer(0)]],
                            device float *dst             [[buffer(1)]],
                            constant ResizeParams &p      [[buffer(2)]],
                            uint3 g                       [[thread_position_in_grid]])
{
    if (g.x >= p.dw || g.y >= p.dh || g.z >= 3) return;
    const float sx = float(p.sw) / float(p.dw), sy = float(p.sh) / float(p.dh);
    const float xr = max(sx * (float(g.x) + 0.5f) - 0.5f, 0.0f);
    const float yr = max(sy * (float(g.y) + 0.5f) - 0.5f, 0.0f);
    const uint x0 = uint(xr), y0 = uint(yr);
    const uint xp = x0 < p.sw - 1 ? 1 : 0, yp = y0 < p.sh - 1 ? 1 : 0;
    const float l1 = xr - float(x0), l0 = 1.0f - l1;
    const float h1 = yr - float(y0), h0 = 1.0f - h1;
    device const float *s = src + g.z * p.sw * p.sh;
    const float v = h0 * (l0 * s[y0 * p.sw + x0] + l1 * s[y0 * p.sw + x0 + xp])
                  + h1 * (l0 * s[(y0 + yp) * p.sw + x0] + l1 * s[(y0 + yp) * p.sw + x0 + xp]);
    dst[g.z * p.dw * p.dh + g.y * p.dw + g.x] = v;
}

// ------------------------------------------------------------- crop resize --
// Reframe crop-and-resize (CLAUDE.md 架构原则 4, 重构图的裁切缩放): bilinear,
// align_corners=False, antialiased like F.interpolate(antialias=True), but read
// from the whole frame starting at a fractional origin. Each axis: scale s =
// length / output, support max(s,1), triangle weights normalised over the frame.
struct CropParams { uint sw, sh, dw, dh; float ox, oy, lx, ly; };
constant int maxTaps = 64;   // support <= 31 px per side; Kernels.swift refuses more

static inline int aa_weights(float c, float s, int n, thread float *w, thread int &lo, thread float &sum)
{
    const float support = max(s, 1.0f), inv = s >= 1.0f ? 1.0f / s : 1.0f;
    lo = max(int(c - support + 0.5f), 0);
    const int hi = min(int(c + support + 0.5f), n);
    sum = 0.0f;
    for (int j = lo; j < hi; ++j) {
        const float v = max(0.0f, 1.0f - fabs((float(j) - c + 0.5f) * inv));
        w[j - lo] = v;
        sum += v;
    }
    return hi - lo;
}

kernel void crop_resize_aa(device const float *src  [[buffer(0)]],
                           device float *dst        [[buffer(1)]],
                           constant CropParams &p   [[buffer(2)]],
                           uint3 g                  [[thread_position_in_grid]])
{
    if (g.x >= p.dw || g.y >= p.dh || g.z >= 3) return;
    const float sx = p.lx / float(p.dw), sy = p.ly / float(p.dh);
    float wx[maxTaps], wy[maxTaps], sumx, sumy;
    int x0, y0;
    const int nx = aa_weights(p.ox + sx * (float(g.x) + 0.5f), sx, int(p.sw), wx, x0, sumx);
    const int ny = aa_weights(p.oy + sy * (float(g.y) + 0.5f), sy, int(p.sh), wy, y0, sumy);
    device const float *s = src + g.z * p.sw * p.sh;
    float acc = 0.0f;
    for (int y = 0; y < ny; ++y) {
        device const float *row = s + (y0 + y) * p.sw + x0;
        float r = 0.0f;
        for (int x = 0; x < nx; ++x) r += wx[x] * row[x];
        acc += wy[y] * r;
    }
    dst[g.z * p.dw * p.dh + g.y * p.dw + g.x] = acc / (sumx * sumy);
}

// ------------------------------------------------------------------- AiLUT --
// Mirrors upstream ailut_transform_cpu.cpp: lower_bound + trilinear, same eps,
// same operation order.
static inline int lower_bound_clamped(device const float *v, int d, float val)
{
    int start = 0, end = d;
    while (start < end) {
        const int mid = start + ((end - start) >> 1);
        if (!(v[mid] >= val)) start = mid + 1; else end = mid;
    }
    return clamp(start - 1, 0, d - 2);
}

static inline float3 ailut_eval(float r, float g, float b,
                                device const float *lut, device const float *ver, int d)
{
    const float eps = 1e-10f;
    const int rid = lower_bound_clamped(ver, d, r);
    const int gid = lower_bound_clamped(ver + d, d, g);
    const int bid = lower_bound_clamped(ver + 2 * d, d, b);
    const int s2 = d * d, s3 = s2 * d;
    const int id000 = rid + d * gid + s2 * bid;
    const int id100 = id000 + 1, id010 = id000 + d, id110 = id000 + d + 1;
    const int id001 = id000 + s2, id101 = id001 + 1, id011 = id001 + d, id111 = id001 + d + 1;

    const float r0 = ver[rid], r1 = ver[rid + 1];
    const float g0 = ver[d + gid], g1 = ver[d + gid + 1];
    const float b0 = ver[2 * d + bid], b1 = ver[2 * d + bid + 1];
    const float rd = (r - r0) / (r1 - r0 + eps);
    const float gd = (g - g0) / (g1 - g0 + eps);
    const float bd = (b - b0) / (b1 - b0 + eps);

    const float w000 = (1 - rd) * (1 - gd) * (1 - bd);
    const float w100 = (    rd) * (1 - gd) * (1 - bd);
    const float w010 = (1 - rd) * (    gd) * (1 - bd);
    const float w110 = (    rd) * (    gd) * (1 - bd);
    const float w001 = (1 - rd) * (1 - gd) * (    bd);
    const float w101 = (    rd) * (1 - gd) * (    bd);
    const float w011 = (1 - rd) * (    gd) * (    bd);
    const float w111 = (    rd) * (    gd) * (    bd);

    float out[3];
    for (int c = 0; c < 3; ++c) {
        device const float *l = lut + c * s3;
        out[c] = w000 * l[id000] + w100 * l[id100] + w010 * l[id010] + w110 * l[id110]
               + w001 * l[id001] + w101 * l[id101] + w011 * l[id011] + w111 * l[id111];
    }
    return float3(out[0], out[1], out[2]);
}

kernel void ailut_apply(device const float *img  [[buffer(0)]],
                        device const float *lut  [[buffer(1)]],
                        device const float *ver  [[buffer(2)]],
                        device float *out        [[buffer(3)]],
                        constant uint2 &p        [[buffer(4)]],   // (pixels, d)
                        uint i                   [[thread_position_in_grid]])
{
    const uint n = p.x;
    if (i >= n) return;
    const float3 o = ailut_eval(img[i], img[i + n], img[i + 2 * n], lut, ver, int(p.y));
    out[i] = o.x; out[i + n] = o.y; out[i + 2 * n] = o.z;
}

// AiLUT sampled on a uniform n^3 lattice -> float[3][n][n][n]. Lattice values
// follow torch.linspace(0, 1, n) exactly (it is symmetric about the midpoint).
static inline float linspace01(uint i, uint n)
{
    const float step = 1.0f / float(n - 1);
    return i < n / 2 ? float(i) * step : 1.0f - float(n - 1 - i) * step;
}

kernel void ailut_bake(device const float *lut  [[buffer(0)]],
                       device const float *ver  [[buffer(1)]],
                       device float *out        [[buffer(2)]],
                       constant uint2 &p        [[buffer(3)]],    // (n, d)
                       uint3 g                  [[thread_position_in_grid]])  // (r, g, b)
{
    const uint n = p.x;
    if (g.x >= n || g.y >= n || g.z >= n) return;
    const float3 o = ailut_eval(linspace01(g.x, n), linspace01(g.y, n), linspace01(g.z, n),
                                lut, ver, int(p.y));
    const uint i = (g.z * n + g.y) * n + g.x, n3 = n * n * n;
    out[i] = o.x; out[i + n3] = o.y; out[i + 2 * n3] = o.z;
}

// --------------------------------------------------------- shot averaging --
kernel void lut_accumulate(device float *acc        [[buffer(0)]],
                           device const float *src  [[buffer(1)]],
                           constant uint &count     [[buffer(2)]],
                           uint i                   [[thread_position_in_grid]])
{
    if (i < count) acc[i] += src[i];
}

// ------------------------------------------------------------- uniform LUT --
// Mirrors upstream lut_transform_3d_cpu_forward_impl (input clamped to [0,1]).
kernel void lut_apply(device const float *img  [[buffer(0)]],
                      device const float *lut  [[buffer(1)]],
                      device float *out        [[buffer(2)]],
                      constant uint2 &p        [[buffer(3)]],     // (pixels, n)
                      uint i                   [[thread_position_in_grid]])
{
    const uint npx = p.x;
    if (i >= npx) return;
    const int d = int(p.y);
    const float size_bin = 1.0f / float(d - 1);
    const float r = clamp(img[i], 0.0f, 1.0f);
    const float g = clamp(img[i + npx], 0.0f, 1.0f);
    const float b = clamp(img[i + 2 * npx], 0.0f, 1.0f);
    const int rid = clamp(int(floor(r * float(d - 1))), 0, d - 2);
    const int gid = clamp(int(floor(g * float(d - 1))), 0, d - 2);
    const int bid = clamp(int(floor(b * float(d - 1))), 0, d - 2);
    const int s2 = d * d, s3 = s2 * d;
    const int id000 = rid + d * gid + s2 * bid;
    const int id100 = id000 + 1, id010 = id000 + d, id110 = id000 + d + 1;
    const int id001 = id000 + s2, id101 = id001 + 1, id011 = id001 + d, id111 = id001 + d + 1;
    const float rd = (r - size_bin * float(rid)) / size_bin;
    const float gd = (g - size_bin * float(gid)) / size_bin;
    const float bd = (b - size_bin * float(bid)) / size_bin;
    const float w000 = (1 - rd) * (1 - gd) * (1 - bd);
    const float w100 = (    rd) * (1 - gd) * (1 - bd);
    const float w010 = (1 - rd) * (    gd) * (1 - bd);
    const float w110 = (    rd) * (    gd) * (1 - bd);
    const float w001 = (1 - rd) * (1 - gd) * (    bd);
    const float w101 = (    rd) * (1 - gd) * (    bd);
    const float w011 = (1 - rd) * (    gd) * (    bd);
    const float w111 = (    rd) * (    gd) * (    bd);
    for (int c = 0; c < 3; ++c) {
        device const float *l = lut + c * s3;
        out[i + c * npx] = w000 * l[id000] + w100 * l[id100] + w010 * l[id010] + w110 * l[id110]
                         + w001 * l[id001] + w101 * l[id101] + w011 * l[id011] + w111 * l[id111];
    }
}

// ------------------------------------------------------------------ encode --
// planar float -> BGRA8 texture for the encoder. Quantize explicitly
// (clamp * 255, round half to even) so the texture's own unorm conversion only
// ever sees exact codes.
kernel void planar_to_bgra8(device const float *img                 [[buffer(0)]],
                            texture2d<float, access::write> outTex  [[texture(0)]],
                            uint2 g                                 [[thread_position_in_grid]])
{
    const uint w = outTex.get_width(), h = outTex.get_height();
    if (g.x >= w || g.y >= h) return;
    const uint i = g.y * w + g.x, n = w * h;
    const float3 q = rint(clamp(float3(img[i], img[i + n], img[i + 2 * n]), 0.0f, 1.0f) * 255.0f) / 255.0f;
    outTex.write(float4(q, 1.0f), g);   // a bgra8Unorm view takes (r, g, b, a) and stores BGRA
}

// ---------------------------------------------------------------- strength --
// final = s * shot + (1 - s) * identity  (CLAUDE.md, 强度). Written this way so
// s = 1 and s = 0 reproduce the two ends exactly in float.
kernel void lut_blend(device const float *lut  [[buffer(0)]],
                      device float *out        [[buffer(1)]],
                      constant float &s        [[buffer(2)]],
                      constant uint &n         [[buffer(3)]],
                      uint3 g                  [[thread_position_in_grid]])   // (r, g, b)
{
    if (g.x >= n || g.y >= n || g.z >= n) return;
    const uint i = (g.z * n + g.y) * n + g.x, n3 = n * n * n;
    const float id[3] = { linspace01(g.x, n), linspace01(g.y, n), linspace01(g.z, n) };
    for (uint c = 0; c < 3; ++c) out[i + c * n3] = s * lut[i + c * n3] + (1.0f - s) * id[c];
}

// shot LUT = clamp(sum / frames, 0, 1), written to a separate buffer so the
// unclamped sum survives for cut editing (CLAUDE.md, 切点编辑).
kernel void lut_mean(device const float *sum  [[buffer(0)]],
                     device float *out        [[buffer(1)]],
                     constant uint2 &p        [[buffer(2)]],      // (values, frames)
                     uint i                   [[thread_position_in_grid]])
{
    if (i < p.x) out[i] = clamp(sum[i] / float(p.y), 0.0f, 1.0f);
}
