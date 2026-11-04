"""Generate fixtures/: the golden data every Swift parity test reads.

All numbers come from the upstream C++ CPU kernels (oracle.ailut_reference /
lut_reference) and the conventions in fixture_io.py, on CPU, one thread.
Running it twice must produce byte-identical files (checked by --verify).

Contents
  inputs        demo / gym_a / gym_b / comic: 8-bit PNG, 640 px wide
  per input     _resized256 (network input), _lut, _vertices (network output),
                _ailut_out (upstream AiLUT kernel applied to the input, 8-bit)
  bake          demo_bake33: demo's AiLUT sampled on a uniform 33^3 lattice
  shot          gym_shot33: clamp(mean(bake33(gym_a), bake33(gym_b)), 0, 1)
                gym_shot33.cube: the same LUT as written by the app's format
                gym_a_shot65_out: gym_a through clamp(mean(bake65 a, b)) via
                upstream's uniform LUT kernel — bake + average + apply at 65^3
  video         synthetic_shots.mp4: 3 synthetic shots (cuts at 30, 60), bt709
                synthetic_vfr.mp4: variable frame rate (every 7th frame dropped)
                synthetic_av.mp4: 3 s testsrc2 + 10 s 440 Hz AAC (audio passthrough)
                synthetic_av_880.mp4: the same video + 10 s 880 Hz (audio that must not match)
                synthetic_subject.mp4: a disk moving left to right over noise (subject detection)
                synthetic_ntsc.mp4: 29.97 fps with a 1/30000 time scale (export time stamps)
                synthetic_fullrange.mp4 + fullrange_f15_{y,cb,cr,rgb}: full-range source, frame 15 planes and RGB
  crop        crop_*: crop-and-resize (reframe) cases, see CROP_CASES and the manifest
  overlay     overlay_rgba.u8 + overlay_*: subtitle compositing (premultiplied over)
  background  bg_image / bg_mask + bg_blur / bg_colour: person-mask compositing;
                bg_masks.u8 + bg_combined: mask average and feather (CPU)
                synthetic_clean.mp4 / synthetic_noisy.mp4: the same 20 frames, clean and with noise
                synthetic_person.mp4: a face (gym_b) panning, then a cut to comic
  cover       synthetic_cover.mp4: blurred / sharp / overexposed / dissolve / still / short pan (cover frames)
                cover_features, cover_scores, cover_resized: the cover scan and scores (CLAUDE.md 封面)
  subtitles   subtitles_sample.srt: a messy SRT for the lenient parser (BOM, CRLF, gaps)
                synthetic_f15_{y,cb,cr}: decoder planes of frame 15
                synthetic_f15_rgb: those planes through the YUV->RGB convention
  manifest.json shapes, dtypes, sha256, and the expected shot list

Usage:
  PATH="$PWD/research/.venv/bin:$PATH" research/.venv/bin/python -I research/make_fixtures.py [--verify]
"""
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I drops the script dir

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

from fixture_io import Manifest, load_rgb, resize256, to_u8
from oracle.ailut import UPSTREAM, ailut_reference, load_model, lut_reference

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "fixtures"
# Source clips live in the experiment, never in git (CLAUDE.md, 许可与素材).
CLIPS = Path.home() / "camera" / "experiments" / "adaint" / "data"
FRAMES = {"gym_a": ("gym_1080p.mp4", 60), "gym_b": ("gym_1080p.mp4", 70),
          "comic": ("comic_multishot.mp4", 180)}
WIDTH = 640
CUT = 0.25


# ------------------------------------------------------------- lattice ----
def identity_lattice(n):
    """Uniform lattice as a (1,3,n*n,n) image; reshape(1,3,n,n,n) of a transform
    of it gives lut[c][b][g][r], r fastest — the layout of the model's LUT."""
    ax = torch.linspace(0, 1, n, dtype=torch.float32)
    bb, gg, rr = torch.meshgrid(ax, ax, ax, indexing="ij")
    return torch.stack([rr, gg, bb])[None].reshape(1, 3, n * n, n).contiguous()


def bake(lut, vertices, n):
    return ailut_reference(identity_lattice(n), lut, vertices).reshape(1, 3, n, n, n)


def cube_text(lut, title):
    """The app's .cube format: LUT_3D_SIZE, then r-fastest rows, %.6f."""
    n = lut.shape[-1]
    rows = lut[0].clamp(0, 1).permute(1, 2, 3, 0).reshape(-1, 3).numpy()
    body = "\n".join(f"{r:.6f} {g:.6f} {b:.6f}" for r, g, b in rows)
    return f'TITLE "{title}"\nLUT_3D_SIZE {n}\n{body}\n'


# --------------------------------------------------------------- video ----
def ffmpeg(*args):
    return subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", *args],
                          check=True, capture_output=True).stdout


def frame_rgb(clip, index):
    """One frame as 8-bit RGB, explicit bt709 limited -> full; only used to make
    input PNGs, so swscale's own rounding is irrelevant to any tolerance."""
    raw = ffmpeg("-i", str(CLIPS / clip), "-fps_mode", "passthrough", "-vf",
                 f"select=eq(n\\,{index}),scale=in_color_matrix=bt709:in_range=tv:out_range=pc,format=rgb24",
                 "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-")
    w, h = probe_size(CLIPS / clip)
    return Image.fromarray(np.frombuffer(raw, np.uint8).reshape(h, w, 3), "RGB")


def probe_size(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "stream=width,height", "-of", "csv=p=0", str(path)]).decode()
    w, h = out.strip().split(",")
    return int(w), int(h)


def make_synthetic(path):
    """Three visually distinct 1 s shots, 320x180 @ 30 fps, H.264 4:2:0 tagged bt709."""
    sources = ["testsrc2=size=320x180:rate=30", "smptebars=size=320x180:rate=30",
               "mandelbrot=size=320x180:rate=30"]
    graph = ";".join(f"{s},trim=duration=1,setpts=PTS-STARTPTS[v{i}]" for i, s in enumerate(sources))
    graph += ";[v0][v1][v2]concat=n=3:v=1:a=0,format=yuv420p[out]"
    ffmpeg("-filter_complex", graph, "-map", "[out]",
           "-c:v", "libx264", "-preset", "veryslow", "-crf", "18", "-g", "30",
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-color_range", "tv", "-bitexact", "-threads", "1", "-x264-params", "threads=1",
           "-an", "-fflags", "+bitexact", str(path))


def make_fullrange(path):
    """1 s of testsrc2 encoded full range (yuvj420p, H.264 VUI full_range_flag), BT.709
    tags, as GoPro writes it: luma reaches below 16 and above 235."""
    ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30,trim=end_frame=30",
           "-vf", "scale=out_color_matrix=bt709:out_range=full,format=yuvj420p",
           "-c:v", "libx264", "-preset", "veryslow", "-crf", "18", "-g", "30",
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-color_range", "pc", "-bitexact", "-threads", "1", "-x264-params", "threads=1",
           "-an", "-fflags", "+bitexact", str(path))


def make_ntsc(path):
    """1 s of testsrc2 at 30000/1001 fps with a 1/30000 track time scale, as DJI and
    GoPro write it: 1001/30000 s is not a multiple of 1/600 (the writer's default)."""
    ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30000/1001,trim=end_frame=30",
           "-pix_fmt", "yuv420p", "-video_track_timescale", "30000",
           "-c:v", "libx264", "-preset", "veryslow", "-crf", "18", "-g", "30",
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-color_range", "tv", "-bitexact", "-threads", "1", "-x264-params", "threads=1",
           "-an", "-fflags", "+bitexact", str(path))


def make_vfr(path):
    """2 s of testsrc2 at 30 fps with every 7th frame dropped and timestamps kept,
    muxed variable-frame-rate: a frame count cannot be turned into a time."""
    ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30,trim=duration=2",
           "-vf", "select='not(eq(mod(n\\,7)\\,3))',format=yuv420p", "-fps_mode", "vfr",
           "-c:v", "libx264", "-preset", "veryslow", "-crf", "18", "-g", "30",
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-color_range", "tv", "-bitexact", "-threads", "1", "-x264-params", "threads=1",
           "-an", "-fflags", "+bitexact", str(path))


def make_subject(path):
    """A bright disk (radius 20) moving left to right over static grey noise,
    320x180, 3 s at 30 fps: centre x = 60 + 60 t px, y = 90 (subject detection)."""
    ffmpeg("-f", "lavfi", "-i", "color=c=0x808080:size=320x180:rate=30,noise=alls=24:all_seed=7,trim=duration=3",
           "-f", "lavfi", "-i", "color=c=0xffd040:size=40x40:rate=30,format=rgba,"
           "geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lte(hypot(X-19.5,Y-19.5),20),255,0)',trim=duration=3",
           "-filter_complex", "[0][1]overlay=x='40+60*t':y=70:eval=frame,format=yuv420p[out]", "-map", "[out]",
           "-c:v", "libx264", "-preset", "veryslow", "-crf", "18", "-g", "30",
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-color_range", "tv", "-bitexact", "-threads", "1", "-x264-params", "threads=1",
           "-an", "-fflags", "+bitexact", str(path))


def make_av(path, hz=440):
    """3 s of testsrc2 with a mono AAC sine 7 s longer than the video. The writer
    takes up to ~7 s of audio ahead of the video (measured 2026-11-03), so only a
    tail this long makes the drain after the last frame necessary (CLAUDE.md 导出:
    copied whole, not trimmed). Same video bytes for every `hz`."""
    ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30,trim=duration=3",
           "-f", "lavfi", "-i", f"sine=frequency={hz}:sample_rate=48000:duration=10",
           "-map", "0:v", "-map", "1:a", "-pix_fmt", "yuv420p",
           "-c:v", "libx264", "-preset", "veryslow", "-crf", "18", "-g", "30",
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-color_range", "tv", "-bitexact", "-threads", "1", "-x264-params", "threads=1",
           "-c:a", "aac", "-b:a", "96k", "-ac", "1", "-flags:a", "+bitexact", "-fflags", "+bitexact", str(path))


def make_noise_pair(clean, noisy):
    """20 frames 320x180: slow gradients with a moving disk, encoded nearly
    losslessly; the noisy one adds per-frame random noise (fixed seed) before
    encoding. Same picture underneath, so denoising is measurable."""
    base = ("color=c=black:size=320x180:rate=30,format=rgb24,"
            "geq=r='128+90*sin(X/45+T)':g='120+70*cos(Y/35)':b='170-X/4'[bg];"
            "color=c=0xffd040:size=40x40:rate=30,format=rgba,"
            "geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lte(hypot(X-19.5,Y-19.5),20),255,0)'[disk];"
            "[bg][disk]overlay=x='60+90*t':y=70:eval=frame")
    for path, extra in ((clean, ""), (noisy, ",noise=alls=14:allf=t:all_seed=11")):
        ffmpeg("-filter_complex", f"{base}{extra},format=yuv420p[out]", "-map", "[out]", "-frames:v", "20",
               "-c:v", "libx264", "-preset", "veryslow", "-crf", "6", "-g", "30",
               "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
               "-color_range", "tv", "-bitexact", "-threads", "1", "-x264-params", "threads=1",
               "-an", "-fflags", "+bitexact", str(path))


def make_person(path, face_png, other_png):
    """12 frames of a face (a 576x324 window panning 2 px a frame over the
    640x360 gym_b input), then a cut to 12 frames of comic (a 487x274 window); 320x180."""
    ffmpeg("-loop", "1", "-framerate", "30", "-i", str(face_png), "-loop", "1", "-framerate", "30", "-i", str(other_png),
           "-filter_complex", "[0]crop=576:324:x='2*n':y=18,scale=320:180,trim=end_frame=12,setpts=PTS-STARTPTS[a];"
           "[1]crop=487:274:x=76:y=0,scale=320:180,trim=end_frame=12,setpts=PTS-STARTPTS[b];"
           "[a][b]concat=n=2:v=1:a=0,format=yuv420p[out]", "-map", "[out]",
           "-c:v", "libx264", "-preset", "veryslow", "-crf", "18", "-g", "30",
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-color_range", "tv", "-bitexact", "-threads", "1", "-x264-params", "threads=1",
           "-an", "-fflags", "+bitexact", str(path))


def make_cover(path, face_png, other_png):
    """Cover frame selection (CLAUDE.md 封面), 320x180 @ 30 fps, 120 frames:
    0-59 gym_b still: 0-19 blurred, 20-39 sharp, 40-59 overexposed;
    60-74 a dissolve gym_b -> comic, 75-104 comic still; 105-119 comic panning
    (0.5 s, too short to compete). Shots are given explicitly (COVER_SHOTS)."""
    ffmpeg("-loop", "1", "-framerate", "30", "-i", str(face_png), "-loop", "1", "-framerate", "30", "-i", str(other_png),
           "-filter_complex",
           "[0]scale=320:180,setsar=1,split=4[g0][g1][g2][g3];"
           "[g0]gblur=sigma=4,trim=end_frame=20,setpts=PTS-STARTPTS[blur];"
           "[g1]trim=end_frame=20,setpts=PTS-STARTPTS[sharp];"
           "[g2]eq=brightness=0.5,trim=end_frame=20,setpts=PTS-STARTPTS[over];"
           "[g3]trim=end_frame=15,setpts=PTS-STARTPTS[from];"
           "[1]scale=640:360,setsar=1,split=3[c0][c1][c2];"
           "[c0]crop=320:180:160:90,trim=end_frame=15,setpts=PTS-STARTPTS[to];"
           "[from][to]blend=all_expr='A*(1-(N+1)/16)+B*(N+1)/16'[dissolve];"
           "[c1]crop=320:180:160:90,trim=end_frame=30,setpts=PTS-STARTPTS[still];"
           "[c2]crop=320:180:x='160+12*n':y=90,trim=end_frame=15,setpts=PTS-STARTPTS[pan];"
           "[blur][sharp][over][dissolve][still][pan]concat=n=6:v=1:a=0,format=yuv420p[out]", "-map", "[out]",
           "-c:v", "libx264", "-preset", "veryslow", "-crf", "18", "-g", "30",
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-color_range", "tv", "-bitexact", "-threads", "1", "-x264-params", "threads=1",
           "-an", "-fflags", "+bitexact", str(path))


# Cover scoring (CLAUDE.md 封面). The executable definition; Core/Cover.swift follows it.
COVER_SHOTS = [[0, 59], [60, 104], [105, 119]]
# Made-up face samples (frame, cx, cy, w, h; top-left origin) so the face term is
# checked without depending on Vision: frames 25-35 a large central face, 80-90 a small one at the edge.
COVER_FACES = [[i, 0.5, 0.4, 0.25, 0.3] for i in range(25, 36)] + [[i, 0.04, 0.5, 0.1, 0.1] for i in range(80, 91)]
COVER_WEIGHTS = (0.4, 0.3, 0.2, 0.1)
COVER_RESIZE = (150, 84)        # an extra resize case: (w, h) of frame 0's luma


def cover_luma(y):
    return np.clip((y.astype(np.float64) - 16) / 219, 0, 1)


def cover_size(w, h, target=360):
    return (w, h) if h <= target else (int(np.floor(w * target / h + 0.5)), target)


def cover_resize(y, w, h):
    """Bilinear, align_corners=False, no antialias: PyTorch's formula, float64."""
    t = torch.from_numpy(y)[None, None]
    return F.interpolate(t, size=(h, w), mode="bilinear", align_corners=False)[0, 0].numpy()


def cover_frame_features(y):
    lap = 4 * y[1:-1, 1:-1] - y[:-2, 1:-1] - y[2:, 1:-1] - y[1:-1, :-2] - y[1:-1, 2:]
    return [lap.var(), (y >= 0.98).mean(), (y <= 0.02).mean(), y.mean()]


def cover_features(path, n):
    """Per frame: sharpness, hi, lo, mean, diff to previous, diff to next (0 at the ends)."""
    w, h = probe_size(path)
    aw, ah = cover_size(w, h)
    lumas, feats = [], []
    for i in range(n):
        y = cover_luma(yuv_planes(path, i, w, h)[0])
        if (aw, ah) != (w, h):
            y = cover_resize(y, aw, ah)
        lumas.append(y)
        feats.append(cover_frame_features(y))
    diffs = [np.abs(lumas[i] - lumas[i - 1]).mean() for i in range(1, n)]
    out = np.zeros((n, 6))
    out[:, :4] = feats
    out[1:, 4] = diffs
    out[:-1, 5] = diffs
    return out


def cover_scores(feat, faces, shots, times, within_shot=True):
    """score = (0.4 S + 0.3 E + 0.2 F + 0.1 M) * T, float64. S is normalised by the
    95th percentile of its shot (`within_shot`, picking a frame) or of the whole
    video (ranking the shots' picks)."""
    n = len(feat)
    q = lambda x: float(np.quantile(x, 0.95))           # linear interpolation, like Reframe.quantile
    S = np.zeros(n)
    for a, b in (shots if within_shot else [[0, n - 1]]):
        p_sharp = q(feat[a:b + 1, 0])
        if p_sharp > 1e-12:
            S[a:b + 1] = np.clip(feat[a:b + 1, 0] / p_sharp, 0, 1)
    E = np.clip(1 - (feat[:, 1] + feat[:, 2]) / 0.10, 0, 1) * np.clip(1 - np.abs(feat[:, 3] - 0.45) / 0.55, 0, 1)
    Fc = np.zeros(n)
    for i, cx, cy, fw, fh in faces:
        edge = min(cx - fw / 2, cy - fh / 2, 1 - (cx + fw / 2), 1 - (cy + fh / 2)) < 0.05
        Fc[i] = min(1.0, fw * fh / 0.04) * (0.5 if edge else 1.0)
    D = np.zeros(n)
    for a, b in shots:
        for i in range(a, b + 1):
            sides = ([feat[i, 4]] if i > a else []) + ([feat[i, 5]] if i < b else [])
            D[i] = np.mean(sides) if sides else 0
    p_diff = q(D)
    M = np.ones(n) if p_diff <= 1e-12 else 1 - np.clip(D / p_diff, 0, 1)
    T = np.ones(n)
    for a, b in shots:
        dur = (b - a + 1) * frame_step(times, a, b)
        win = min(max(0.1 * dur, 0.2), 0.5)
        for i in range(a, b + 1):
            d = min(times[i] - times[a], times[b] - times[i])
            T[i] = 1.0 if d >= win else 0.5 + 0.5 * d / win
    ws, we, wf, wm = COVER_WEIGHTS
    return (ws * S + we * E + wf * Fc + wm * M) * T


def frame_step(times, a, b):
    """Reframe.frameDuration: mean frame spacing in the shot, 1/30 for one frame."""
    return 1 / 30 if b == a else max((times[b] - times[a]) / (b - a), 1e-3)


def cover_best(pick, rank, shots, times):
    """Each eligible shot's best frame by `pick` (first on ties), ordered by `rank` at that frame."""
    long = [s for s in shots if (s[1] - s[0] + 1) * frame_step(times, *s) >= 1.0] or shots
    best = [max(range(a, b + 1), key=lambda i: (pick[i], -i)) for a, b in long]
    return sorted(best, key=lambda i: (-rank[i], i))


def gaussian_taps(sigma):
    """Normalised taps for -r..r, r = ceil(3 sigma); [1] below 0.3 (CLAUDE.md 背景). float64."""
    if sigma < 0.3:
        return np.ones(1)
    r = int(np.ceil(3 * sigma))
    k = np.exp(-np.arange(-r, r + 1, dtype=np.float64) ** 2 / (2 * sigma * sigma))
    return k / k.sum()


def blur_axis(a, taps, axis):
    """a (..., H, W) float64, one axis, edge clamped, summed from -r to r."""
    r = len(taps) // 2
    n = a.shape[axis]
    out = np.zeros_like(a)
    for j in range(-r, r + 1):
        idx = np.clip(np.arange(n) + j, 0, n - 1)
        out += taps[j + r] * np.take(a, idx, axis=axis)
    return out


def combine_masks(masks, frame_w, frame_h, feather=0.005):
    """Mean of uint8 masks (n,h,w) in [0,1], then the feather blur per axis."""
    h, w = masks.shape[1:]
    mean = masks.astype(np.float64).sum(0) / (255 * len(masks))
    f = feather * frame_h
    out = blur_axis(mean, gaussian_taps(np.float32(f * w / frame_w)), 1)
    return blur_axis(out, gaussian_taps(np.float32(f * h / frame_h)), 0)


def sample_mask(mask, W, H):
    """Bilinear, align_corners=False, edge clamped: (mh,mw) -> (H,W), like resize_bilinear."""
    mh, mw = mask.shape
    def axis(n_out, n_in):
        r = np.maximum((n_in / n_out) * (np.arange(n_out) + 0.5) - 0.5, 0)
        i0 = np.minimum(r.astype(np.int64), n_in - 1)
        i1 = np.where(i0 < n_in - 1, i0 + 1, i0)
        return i0, i1, r - i0
    x0, x1, lx = axis(W, mw)
    y0, y1, ly = axis(H, mh)
    top = mask[y0][:, x0] * (1 - lx) + mask[y0][:, x1] * lx
    bot = mask[y1][:, x0] * (1 - lx) + mask[y1][:, x1] * lx
    return top * (1 - ly)[:, None] + bot * ly[:, None]


def background(img, mask, effect):
    """img (3,H,W) float64; mask (mh,mw); effect ("blur", sigma) or ("colour", rgb):
    out = img*m + bg*(1-m) (CLAUDE.md 背景合成)."""
    H, W = img.shape[1:]
    m = sample_mask(mask, W, H)
    if effect[0] == "blur":
        planes = np.concatenate([img * (1 - m), (1 - m)[None]])
        taps = gaussian_taps(effect[1])
        planes = blur_axis(blur_axis(planes, taps, 2), taps, 1)
        den = planes[3]
        bg = np.where(den > 1e-6, planes[:3] / np.where(den > 1e-6, den, 1), img)
    else:
        bg = np.asarray(effect[1], np.float64)[:, None, None] * np.ones_like(img)
    return img * m + bg * (1 - m)


BG_EFFECTS = [("bg_blur", ("blur", 4.5)), ("bg_colour", ("colour", (0.0, 177 / 255, 64 / 255)))]


def crop_weights(in_size, out_size, origin, length):
    """One axis of the reframe crop-and-resize (CLAUDE.md 架构原则 4, 重构图的裁切缩放):
    antialiased bilinear, align_corners=False, PyTorch's formula, but over the
    whole frame from a fractional origin. float64; rows sum to 1."""
    s = length / out_size
    support, inv = max(s, 1.0), (1.0 / s if s >= 1.0 else 1.0)
    w = np.zeros((out_size, in_size))
    for i in range(out_size):
        c = origin + s * (i + 0.5)
        lo, hi = max(int(c - support + 0.5), 0), min(int(c + support + 0.5), in_size)
        for j in range(lo, hi):
            w[i, j] = max(0.0, 1.0 - abs((j - c + 0.5) * inv))
        w[i] /= w[i].sum()
    return w


def crop_resize(img, origin, length, out):
    """img (1,3,H,W) -> (1,3,out_h,out_w); origin/length = (x, y), may be fractional."""
    a = img[0].double().numpy()
    wx = crop_weights(a.shape[2], out[0], origin[0], length[0])
    wy = crop_weights(a.shape[1], out[1], origin[1], length[1])
    return torch.from_numpy(np.stack([wy @ a[c] @ wx.T for c in range(3)])[None]).float()   # separable


# name, input fixture, transposed (portrait source), origin (x, y), length (x, y), output (w, h)
CROP_CASES = [
    ("crop_full_up", "demo_resized256", False, (0, 0), (256, 256), (320, 320)),
    ("crop_full_down", "demo_resized256", False, (0, 0), (256, 256), (100, 100)),
    ("crop_916_up", "gym_a_in", False, (151.25, 0), (202.5, 360), (270, 480)),
    ("crop_916_down", "gym_a_in", False, (300.75, 0), (202.5, 360), (90, 160)),
    ("crop_169", "gym_a_in", True, (0, 88.4), (360, 202.5), (320, 180)),
]


def overlay_rgba(w=120, h=80):
    """A synthetic premultiplied sRGB RGBA8 patch with fully clear, fully opaque
    and half-transparent areas (no text: text rasterisation is not a fixture)."""
    y, x = np.mgrid[0:h, 0:w]
    a = np.clip((x * 255) // (w - 1), 0, 255).astype(np.uint8)          # alpha ramps 0 -> 255 left to right
    a[:, : w // 6] = 0
    a[:, -(w // 6):] = 255
    colour = np.stack([(x * 7) % 256, (y * 11) % 256, ((x + y) * 5) % 256], -1).astype(np.uint16)
    rgb = (colour * a[..., None].astype(np.uint16) + 127) // 255           # premultiplied, rounded
    return np.dstack([rgb.astype(np.uint8), a])


def overlay(img, rgba, origin):
    """img (1,3,H,W) float; rgba (h,w,4) premultiplied uint8 at integer `origin`
    (may lie partly outside): out = src*(1-a) + premul (CLAUDE.md 字幕叠加)."""
    out = img.clone()
    H, W = img.shape[2:]
    h, w = rgba.shape[:2]
    ox, oy = origin
    x0, y0, x1, y1 = max(ox, 0), max(oy, 0), min(ox + w, W), min(oy + h, H)
    o = torch.from_numpy(rgba.astype(np.float32) / 255.0)[y0 - oy:y1 - oy, x0 - ox:x1 - ox]
    a = o[..., 3]
    for c in range(3):
        out[0, c, y0:y1, x0:x1] = img[0, c, y0:y1, x0:x1] * (1 - a) + o[..., c]
    return out


OVERLAY_CASES = [("overlay_inside", (60, 40)), ("overlay_clipped", (-20, 200))]

SUBTITLE_SAMPLE = ("\ufeff1\r\n00:00:01,000 --> 00:00:02,500\r\n你好\r\n\r\n"
                   "00:00:03.000 --> 00:00:04.000\nno number, dot separator\nsecond line\n\n"
                   "7\nnot a time line\nbroken\n\n"
                   "9\n00:00:03,500 --> 00:00:05,000\noverlaps\n")


def frame_times(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "frame=pts_time", "-of", "csv=p=0", str(path)]).decode()
    return [float(t.strip(",")) for t in out.split()]


def yuv_planes(path, index, w, h, pix_fmt="yuv420p"):
    """The decoder's planes as coded: `pix_fmt` must match the stream's range
    (yuvj420p for full range), or ffmpeg converts the range on the way out."""
    raw = ffmpeg("-i", str(path), "-fps_mode", "passthrough", "-vf", f"select=eq(n\\,{index})",
                 "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", pix_fmt, "-")
    a = np.frombuffer(raw, np.uint8)
    y = a[:w * h].reshape(h, w)
    cb = a[w * h:w * h + w * h // 4].reshape(h // 2, w // 2)
    cr = a[w * h + w * h // 4:].reshape(h // 2, w // 2)
    return y, cb, cr


def chroma_up(c, w, h):
    """4:2:0 -> 4:4:4, bilinear, clamp to edge, MPEG-2/H.264 default siting:
    chroma sample (i, j) sits at luma (2i, 2j + 0.5). So luma (x, y) reads the
    chroma plane at continuous (x / 2, (y - 0.5) / 2)."""
    c = c.astype(np.float64)
    hc, wc = c.shape
    cx = np.arange(w) / 2.0
    cy = (np.arange(h) - 0.5) / 2.0
    cx = np.clip(cx, 0, wc - 1); cy = np.clip(cy, 0, hc - 1)
    x0 = np.floor(cx).astype(int); y0 = np.floor(cy).astype(int)
    x1 = np.minimum(x0 + 1, wc - 1); y1 = np.minimum(y0 + 1, hc - 1)
    fx = (cx - x0)[None, :]; fy = (cy - y0)[:, None]
    top = c[y0][:, x0] * (1 - fx) + c[y0][:, x1] * fx
    bot = c[y1][:, x0] * (1 - fx) + c[y1][:, x1] * fx
    return top * (1 - fy) + bot * fy


def yuv709_to_rgb(y, cb, cr):
    """BT.709, 8-bit limited range -> RGB in [0,1] (display-referred, no transfer function)."""
    h, w = y.shape
    yy = (y.astype(np.float64) - 16) / 219
    u = (chroma_up(cb, w, h) - 128) / 224
    v = (chroma_up(cr, w, h) - 128) / 224
    r = yy + 1.5748 * v
    g = yy - 0.187324 * u - 0.468124 * v
    b = yy + 1.8556 * u
    return np.clip(np.stack([r, g, b]), 0, 1).astype(np.float32)[None]


def yuv709_full_to_rgb(y, cb, cr):
    """BT.709, 8-bit full range (H.273): Y' = Y/255, C' = (C-128)/255; same matrix and chroma rule."""
    h, w = y.shape
    yy = y.astype(np.float64) / 255
    u = (chroma_up(cb, w, h) - 128) / 255
    v = (chroma_up(cr, w, h) - 128) / 255
    r = yy + 1.5748 * v
    g = yy - 0.187324 * u - 0.468124 * v
    b = yy + 1.8556 * u
    return np.clip(np.stack([r, g, b]), 0, 1).astype(np.float32)[None]


def histogram(img):
    """Shot-detection histogram: 160x90 bilinear thumbnail, 8 bins per channel."""
    small = F.interpolate(img, size=(90, 160), mode="bilinear", align_corners=False)
    q = (small[0].clamp(0, 1) * 7.999).long()
    idx = (q[0] * 64 + q[1] * 8 + q[2]).flatten()
    h = torch.bincount(idx, minlength=512).float()
    return h / h.sum()


def shots(path, w, h, n):
    cuts, prev = [0], None
    for i in range(n):
        y, cb, cr = yuv_planes(path, i, w, h)
        hh = histogram(torch.from_numpy(yuv709_to_rgb(y, cb, cr)))
        if prev is not None and (hh - prev).abs().sum().item() > CUT:
            cuts.append(i)
        prev = hh
    return [[a, b - 1] for a, b in zip(cuts, cuts[1:] + [n])]


# ---------------------------------------------------------------- main ----
@torch.no_grad()
def generate(dest: Path):
    torch.set_num_threads(1)
    dest.mkdir(parents=True, exist_ok=True)
    m = Manifest(dest)
    model = load_model("fivek")

    inputs = {"demo": Image.open(UPSTREAM / "resources" / "a4739.jpg").convert("RGB")}
    for name, (clip, index) in FRAMES.items():
        inputs[name] = frame_rgb(clip, index)
    tensors = {}
    for name, im in inputs.items():
        im = im.resize((WIDTH, round(im.height * WIDTH / im.width)), Image.Resampling.LANCZOS)
        m.image(f"{name}_in", np.asarray(im), note="input, 8-bit sRGB-ish display-referred")
        x = load_rgb(dest / f"{name}_in.png")
        x256 = resize256(x)
        lut, ver = model.predict(x)          # predict resizes internally, same as resize256
        tensors[name] = (x, lut, ver)
        m.tensor(f"{name}_resized256", x256, "bilinear, align_corners=False")
        m.tensor(f"{name}_lut", lut, "lut[c][b][g][r]")
        m.tensor(f"{name}_vertices", ver, "per-channel AdaInt vertices")
        m.image(f"{name}_ailut_out", to_u8(ailut_reference(x, lut, ver)), "upstream AiLUT kernel")

    _, lut, ver = tensors["demo"]
    m.tensor("demo_bake33", bake(lut, ver, 33), "AiLUT on a uniform 33^3 lattice, unclamped")

    (xa, la, va), (_, lb, vb) = tensors["gym_a"], tensors["gym_b"]
    shot33 = ((bake(la, va, 33) + bake(lb, vb, 33)) / 2).clamp(0, 1)
    m.tensor("gym_shot33", shot33, "clamp(mean(bake33 a, b), 0, 1)")
    (dest / "gym_shot33.cube").write_text(cube_text(shot33, "AutoGrade gym shot"))
    m.record("gym_shot33.cube", dest / "gym_shot33.cube", file="gym_shot33.cube", dtype="text",
              shape=[33, 33, 33, 3], note="the app's .cube format")
    shot65 = ((bake(la, va, 65) + bake(lb, vb, 65)) / 2).clamp(0, 1)
    m.image("gym_a_shot65_out", to_u8(lut_reference(xa.clamp(0, 1), shot65)),
            "upstream uniform LUT kernel, 65^3 shot LUT")

    clip = dest / "synthetic_shots.mp4"
    make_synthetic(clip)
    m.record("synthetic_shots.mp4", clip, file=clip.name, dtype="h264", shape=[90, 180, 320],
              note="testsrc2 | smptebars | mandelbrot, 1 s each, bt709 limited")
    w, h = probe_size(clip)
    y, cb, cr = yuv_planes(clip, 15, w, h)
    for name, plane in (("y", y), ("cb", cb), ("cr", cr)):
        path = dest / f"synthetic_f15_{name}.u8"
        path.write_bytes(plane.tobytes())
        m.record(f"synthetic_f15_{name}", path, file=path.name, dtype="uint8", shape=list(plane.shape),
                  note="decoder output plane")
    m.tensor("synthetic_f15_rgb", torch.from_numpy(yuv709_to_rgb(y, cb, cr)),
             "bt709 limited, chroma bilinear at (x/2, (y-0.5)/2), clamp")
    expected = shots(clip, w, h, 90)
    vfr = dest / "synthetic_vfr.mp4"
    make_vfr(vfr)
    vfr_times = frame_times(vfr)
    m.record("synthetic_vfr.mp4", vfr, file=vfr.name, dtype="h264", shape=[len(vfr_times), 180, 320],
             note="testsrc2 2 s, every 7th frame dropped, variable frame rate")
    av = dest / "synthetic_av.mp4"
    make_av(av)
    m.record("synthetic_av.mp4", av, file=av.name, dtype="h264+aac", shape=[90, 180, 320],
             note="testsrc2 3 s + 440 Hz mono AAC 10 s")
    av880 = dest / "synthetic_av_880.mp4"
    make_av(av880, hz=880)
    m.record("synthetic_av_880.mp4", av880, file=av880.name, dtype="h264+aac", shape=[90, 180, 320],
             note="the same video as synthetic_av + 880 Hz mono AAC 10 s")
    subject = dest / "synthetic_subject.mp4"
    make_subject(subject)
    m.record("synthetic_subject.mp4", subject, file=subject.name, dtype="h264", shape=[90, 180, 320],
             note="disk r=20 at x = 60 + 60 t, y = 90, over grey noise")
    full = dest / "synthetic_fullrange.mp4"
    make_fullrange(full)
    m.record("synthetic_fullrange.mp4", full, file=full.name, dtype="h264", shape=[30, 180, 320],
             note="testsrc2, 30 frames, H.264 full range (yuvj420p), bt709 tags")
    fy, fcb, fcr = yuv_planes(full, 15, 320, 180, pix_fmt="yuvj420p")
    if not (fy.min() < 16 and fy.max() > 235):
        sys.exit(f"synthetic_fullrange: luma {fy.min()}..{fy.max()} does not leave 16..235, cannot tell the ranges apart")
    for name, plane in (("y", fy), ("cb", fcb), ("cr", fcr)):
        path = dest / f"fullrange_f15_{name}.u8"
        path.write_bytes(plane.tobytes())
        m.record(f"fullrange_f15_{name}", path, file=path.name, dtype="uint8", shape=list(plane.shape),
                 note="decoder output plane, full range as coded")
    m.tensor("fullrange_f15_rgb", torch.from_numpy(yuv709_full_to_rgb(fy, fcb, fcr)),
             "bt709 full range (H.273), chroma bilinear at (x/2, (y-0.5)/2), clamp")
    ntsc = dest / "synthetic_ntsc.mp4"
    make_ntsc(ntsc)
    m.record("synthetic_ntsc.mp4", ntsc, file=ntsc.name, dtype="h264", shape=[30, 180, 320],
             note="testsrc2, 30 frames at 30000/1001 fps, time scale 30000")

    # crop-and-resize: the numpy reference must equal PyTorch on whole frames first
    sources = {"demo_resized256": tensors["demo"][0], "gym_a_in": tensors["gym_a"][0]}
    sources["demo_resized256"] = resize256(sources["demo_resized256"])
    for whole in ((320, 320), (100, 100)):
        ref = crop_resize(sources["demo_resized256"], (0, 0), (256, 256), whole)
        # float64: PyTorch's float32 upscale itself rounds by up to 3.9e-6 (measured 2026-11-03)
        pt = F.interpolate(sources["demo_resized256"].double(), size=(whole[1], whole[0]), mode="bilinear",
                           align_corners=False, antialias=True).float()
        err = (ref - pt).abs().max().item()
        if err > 1e-6:
            sys.exit(f"crop reference differs from PyTorch antialias on a whole frame {whole}: {err}")
    crops = []
    for name, src, transposed, origin, length, out in CROP_CASES:
        img = sources[src].transpose(2, 3).contiguous() if transposed else sources[src]
        m.tensor(name, crop_resize(img, origin, length, out), f"crop {origin}+{length} -> {out} of {src}"
                 + (" transposed" if transposed else ""))
        crops.append({"name": name, "input": src, "transposed": transposed, "origin": list(origin),
                      "length": list(length), "output": list(out)})

    rgba = overlay_rgba()
    (dest / "overlay_rgba.u8").write_bytes(rgba.tobytes())
    m.record("overlay_rgba", dest / "overlay_rgba.u8", file="overlay_rgba.u8", dtype="uint8", shape=list(rgba.shape),
             note="premultiplied sRGB RGBA8: clear / ramp / opaque")
    for name, origin in OVERLAY_CASES:
        m.tensor(name, overlay(sources["demo_resized256"], rgba, origin), f"overlay_rgba over demo_resized256 at {origin}")
    # background: a 160x90 graded-like picture, a smooth 40x30 blob mask
    img = F.interpolate(tensors["gym_b"][0], size=(90, 160), mode="bilinear", align_corners=False)
    m.tensor("bg_image", img, "gym_b at 160x90")
    yy, xx = np.mgrid[0:30, 0:40]
    blob = np.sqrt(np.clip(1 - ((xx - 21) / 11.0) ** 2 - ((yy - 13) / 13.0) ** 2, 0, 1)).astype(np.float32)
    m.tensor("bg_mask", torch.from_numpy(blob), "40x30 person-like mask in [0, 1]")
    for name, effect in BG_EFFECTS:
        out = background(img[0].double().numpy(), blob.astype(np.float64), effect)
        m.tensor(name, torch.from_numpy(out)[None], f"bg_image with bg_mask, {effect}")
    rng = np.random.default_rng(3)
    masks = np.stack([np.clip(blob * 255 + rng.normal(0, 30, blob.shape), 0, 255)
                      for _ in range(5)]).astype(np.uint8)
    masks = np.repeat(np.repeat(masks, 3, 1), 3, 2)         # 120x90: a feather wide enough to have taps
    (dest / "bg_masks.u8").write_bytes(masks.tobytes())
    m.record("bg_masks", dest / "bg_masks.u8", file="bg_masks.u8", dtype="uint8", shape=list(masks.shape),
             note="5 noisy 120x90 person masks")
    m.tensor("bg_combined", torch.from_numpy(combine_masks(masks, 640, 360)), "mean + feather, frame 640x360")
    clean, noisy = dest / "synthetic_clean.mp4", dest / "synthetic_noisy.mp4"
    make_noise_pair(clean, noisy)
    m.record("synthetic_clean.mp4", clean, file=clean.name, dtype="h264", shape=[20, 180, 320],
             note="gradients + moving disk, crf 6")
    m.record("synthetic_noisy.mp4", noisy, file=noisy.name, dtype="h264", shape=[20, 180, 320],
             note="synthetic_clean + temporal noise alls=14 seed 11, crf 6")
    person = dest / "synthetic_person.mp4"
    make_person(person, dest / "gym_b_in.png", dest / "comic_in.png")
    m.record("synthetic_person.mp4", person, file=person.name, dtype="h264", shape=[24, 180, 320],
             note="gym_b face panning 12 frames | comic 12 frames")
    cover = dest / "synthetic_cover.mp4"
    make_cover(cover, dest / "gym_b_in.png", dest / "comic_in.png")
    cover_times = frame_times(cover)
    n_cover = len(cover_times)
    m.record("synthetic_cover.mp4", cover, file=cover.name, dtype="h264", shape=[n_cover, 180, 320],
             note="gym_b blurred | sharp | overexposed, dissolve to comic, comic still, comic panning 0.5 s")
    feat = cover_features(cover, n_cover)
    m.tensor("cover_features", torch.from_numpy(feat.astype(np.float32)),
             "per frame: laplacian variance, hi, lo, mean, diff prev, diff next (float64 -> float32)")
    scores = cover_scores(feat, COVER_FACES, COVER_SHOTS, cover_times)
    ranks = cover_scores(feat, COVER_FACES, COVER_SHOTS, cover_times, within_shot=False)
    plain = cover_scores(feat, [], COVER_SHOTS, cover_times)
    m.tensor("cover_scores", torch.from_numpy(np.stack([scores, ranks, plain]).astype(np.float32)),
             "pick / rank with COVER_FACES, pick without faces; COVER_SHOTS; float64 -> float32")
    w0, h0 = probe_size(cover)
    y0 = cover_luma(yuv_planes(cover, 0, w0, h0)[0])
    m.tensor("cover_resized", torch.from_numpy(cover_resize(y0, *COVER_RESIZE).astype(np.float32)),
             f"frame 0 luma resized to {COVER_RESIZE}, bilinear align_corners=False")
    best = cover_best(scores, ranks, COVER_SHOTS, cover_times)
    best_plain = cover_best(plain, cover_scores(feat, [], COVER_SHOTS, cover_times, within_shot=False),
                            COVER_SHOTS, cover_times)
    if not any(20 <= b <= 39 for b in best_plain):
        sys.exit(f"cover fixture: without faces the gym shot should pick a sharp frame (20-39), got {best_plain}")
    srt = dest / "subtitles_sample.srt"
    srt.write_bytes(SUBTITLE_SAMPLE.encode("utf-8"))
    m.record("subtitles_sample.srt", srt, file=srt.name, dtype="text", shape=[], note="BOM, CRLF and LF, missing number, bad block, overlap")

    m.write(generator="research/make_fixtures.py", crop_cases=crops,
            overlay_cases=[{"name": n, "origin": list(o)} for n, o in OVERLAY_CASES],
            background_cases=[{"name": n, "effect": e[0], "sigma": e[1] if e[0] == "blur" else 0,
                               "colour": list(e[1]) if e[0] == "colour" else [0, 0, 0]} for n, e in BG_EFFECTS],
            upstream="AdaInt@5678851339dff90becb09c3dec41e7214207ccbc",
            torch=torch.__version__, cut_threshold=CUT, synthetic_shots=expected, vfr_frame_times=vfr_times,
            cover={"shots": COVER_SHOTS, "faces": COVER_FACES, "best": best, "best_without_faces": best_plain,
                   "resize": list(COVER_RESIZE)})
    print(f"synthetic shots: {expected}")
    print(f"cover best frames: {best}, scores {[round(float(scores[i]), 4) for i in best]}")


def digest(folder: Path):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(folder.iterdir())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true", help="regenerate into a temp dir and compare bytes")
    args = ap.parse_args()
    if args.verify:
        with tempfile.TemporaryDirectory() as tmp:
            generate(Path(tmp))
            a, b = digest(FIXTURES), digest(Path(tmp))
            bad = sorted(k for k in a.keys() | b.keys() if a.get(k) != b.get(k))
            print("reproducible: byte-identical" if not bad else f"NOT reproducible: {bad}")
            sys.exit(1 if bad else 0)
    generate(FIXTURES)   # overwrites in place; deleting is a red line (CLAUDE.md)
    listed = {e["file"] for e in json.loads((FIXTURES / "manifest.json").read_text())["files"].values()}
    stale = sorted(p.name for p in FIXTURES.iterdir() if p.name not in listed | {"manifest.json"})
    if stale:
        print(f"stale files not in manifest (left in place, remove by hand): {stale}")
    total = sum(p.stat().st_size for p in FIXTURES.iterdir())
    biggest = max(FIXTURES.iterdir(), key=lambda p: p.stat().st_size)
    print(f"fixtures: {len(list(FIXTURES.iterdir()))} files, {total / 1e6:.1f} MB, "
          f"largest {biggest.name} {biggest.stat().st_size / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
