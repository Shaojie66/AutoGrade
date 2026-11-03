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


def make_vfr(path):
    """2 s of testsrc2 at 30 fps with every 7th frame dropped and timestamps kept,
    muxed variable-frame-rate: a frame count cannot be turned into a time."""
    ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30,trim=duration=2",
           "-vf", "select='not(eq(mod(n\\,7)\\,3))',format=yuv420p", "-fps_mode", "vfr",
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


def frame_times(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "frame=pts_time", "-of", "csv=p=0", str(path)]).decode()
    return [float(t.strip(",")) for t in out.split()]


def yuv_planes(path, index, w, h):
    raw = ffmpeg("-i", str(path), "-fps_mode", "passthrough", "-vf", f"select=eq(n\\,{index})",
                 "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-")
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
    m.write(generator="research/make_fixtures.py", upstream="AdaInt@5678851339dff90becb09c3dec41e7214207ccbc",
            torch=torch.__version__, cut_threshold=CUT, synthetic_shots=expected, vfr_frame_times=vfr_times)
    print(f"synthetic shots: {expected}")


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
