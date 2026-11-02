// App preview: build the one picture the display layer shows, in the same
// format the decoder hands QuickTime — 8-bit 4:2:0 BT.709 limited ('420v') —
// so the system colour-manages both the same way (CLAUDE.md 架构原则 5).
// Per pixel the source is chosen by the split (no resampling); the RGB codes
// are the BGRA8 bytes GradeKernels wrote, converted with the inverse of the
// decode convention (架构原则 4).
#include <metal_stdlib>
using namespace metal;

struct CompositeParams {
    uint splitColumn;   // first column taken from `graded` (mode 0)
    uint mode;          // 0 split, 1 original only, 2 graded only
};

static inline float3 pick(texture2d<float, access::read> original, texture2d<float, access::read> graded,
                          constant CompositeParams &p, uint2 g)
{
    const bool left = p.mode == 1 || (p.mode == 0 && g.x < p.splitColumn);
    return (left ? original.read(g) : graded.read(g)).rgb;
}

static inline float luma709(float3 c) { return 0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b; }

// One thread per 2x2 block: four luma codes, one CbCr pair. Chroma is the
// even column (co-sited, chroma location Left) averaged over the two rows —
// the sample the decode convention reads at (x/2, (y-0.5)/2).
kernel void display_composite_nv12(texture2d<float, access::read> original   [[texture(0)]],
                                   texture2d<float, access::read> graded     [[texture(1)]],
                                   texture2d<float, access::write> lumaOut   [[texture(2)]],
                                   texture2d<float, access::write> chromaOut [[texture(3)]],
                                   constant CompositeParams &p               [[buffer(0)]],
                                   uint2 b                                   [[thread_position_in_grid]])
{
    if (b.x >= chromaOut.get_width() || b.y >= chromaOut.get_height()) return;
    float3 chromaSource = 0;
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            const uint2 g = uint2(2 * b.x + dx, 2 * b.y + dy);
            const float3 c = pick(original, graded, p, g);
            lumaOut.write(float4(rint(16.0f + 219.0f * luma709(c)) / 255.0f, 0, 0, 1), g);
            if (dx == 0) chromaSource += 0.5f * c;
        }
    }
    const float y = luma709(chromaSource);
    const float cb = rint(128.0f + 224.0f * (chromaSource.b - y) / 1.8556f);
    const float cr = rint(128.0f + 224.0f * (chromaSource.r - y) / 1.5748f);
    chromaOut.write(float4(clamp(cb, 16.0f, 240.0f) / 255.0f, clamp(cr, 16.0f, 240.0f) / 255.0f, 0, 1), b);
}
