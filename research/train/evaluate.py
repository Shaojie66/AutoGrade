"""Evaluate a fine-tuned run against its film target (plan acceptance 3-4).

For each image: target = film(x). Compared outputs: the fine-tuned model,
plus two baselines — the input unchanged, and the original FiveK model.
Metrics per output vs target: PSNR, mean |error| and p99 |error| in 8-bit
levels. Video frames (the owner's clips) also report the change in sky
brightness vs the input, the property that made FiveK unsuitable for sunsets.

Writes research/runs/<run>/report.json and sheet.jpg (input | film | model | FiveK).

Usage:
  PATH="$PWD/research/.venv/bin:$PATH" research/.venv/bin/python -I research/train/evaluate.py \
      --run velvia50 [--checkpoint step045000.pth] [--images DIR --list FILE | --no-list]
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # -I drops the script dir

import numpy as np
import torch
from PIL import Image, ImageDraw

from fixture_io import load_rgb
from oracle.ailut import ailut_torch, load_model
from train.haldclut import apply_lut, film, load_haldclut
from train.train import ANNFILES, DEFAULT_IMAGES, image_list, psnr

RESEARCH = Path(__file__).resolve().parent.parent
ROOT = RESEARCH.parent
# (clip, frame index, sky rows as a fraction of the stored frame, sky columns as a fraction)
FRAMES = [
    ("out/inputs/istanbul_20260925_190520.mov", 250, (0.0, 1.0), (0.55, 1.0)),   # stored sideways: sky on the right
    ("out/inputs/istanbul_20260925_190520.mov", 120, (0.0, 1.0), (0.55, 1.0)),
    ("out/inputs/sd1793455645_2.mov", 300, (0.0, 0.25), (0.0, 1.0)),
    ("out/inputs/gym_1080p.mp4", 100, (0.0, 0.3), (0.0, 1.0)),
    ("out/inputs/comic_multishot.mp4", 180, (0.0, 0.3), (0.0, 1.0)),
]


def video_frame(path: Path, n: int, width: int = 720) -> torch.Tensor:
    w, h = map(int, subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                             "stream=width,height", "-of", "csv=p=0", str(path)]).decode().strip().split(","))
    oh = round(h * width / w / 2) * 2
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-fps_mode", "passthrough", "-vf",
                          f"select=eq(n\\,{n}),scale={width}:{oh}:in_color_matrix=bt709:in_range=tv:out_range=pc,format=rgb24",
                          "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
    a = np.frombuffer(raw, np.uint8).reshape(oh, width, 3).astype(np.float32) / 255
    return torch.from_numpy(a).permute(2, 0, 1)[None].contiguous()


def errors(out, target) -> dict:
    d = (out.clamp(0, 1) - target.clamp(0, 1)).abs().mul(255).flatten()
    return {"psnr": psnr(out, target), "mean_abs_8bit": d.mean().item(), "p99_abs_8bit": torch.quantile(d[::7], 0.99).item()}


def luma(x, rows, cols):
    _, _, h, w = x.shape
    r = x[:, :, int(rows[0] * h):int(rows[1] * h), int(cols[0] * w):int(cols[1] * w)]
    return (0.2126 * r[:, 0] + 0.7152 * r[:, 1] + 0.0722 * r[:, 2]).mean().item() * 255


@torch.no_grad()
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--checkpoint", default=None, help="file in the run dir (default: latest step*.pth)")
    ap.add_argument("--images", type=Path, default=DEFAULT_IMAGES)
    ap.add_argument("--list", type=Path, default=ANNFILES / "test.txt")
    ap.add_argument("--no-list", action="store_true")
    ap.add_argument("--no-frames", action="store_true", help="skip the owner's video frames")
    args = ap.parse_args()
    run = RESEARCH / "runs" / args.run
    config = json.loads((run / "config.json").read_text())
    ck = run / args.checkpoint if args.checkpoint else sorted(run.glob("step*.pth"))[-1]
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    lut = load_haldclut(film(config["film"])).to(device)
    tuned = load_model("fivek", device, checkpoint=ck)
    fivek = load_model("fivek", device)

    def outputs(x):
        target = apply_lut(x, lut)
        lt, vt = tuned.predict(x)
        lf, vf = fivek.predict(x)
        return target, {"model": ailut_torch(x, lt, vt), "input": x, "fivek": ailut_torch(x, lf, vf)}

    report = {"run": args.run, "checkpoint": ck.name, "film": config["film"], "test": {}, "frames": []}
    acc = {k: [] for k in ("model", "input", "fivek")}
    paths = image_list(args.images, None if args.no_list else args.list)
    for p in paths:
        x = load_rgb(p).to(device)
        target, outs = outputs(x)
        for k, o in outs.items():
            acc[k].append(errors(o, target))
    for k, rows in acc.items():
        report["test"][k] = {m: float(np.mean([r[m] for r in rows])) for m in rows[0]} | {"images": len(rows)}

    tiles = []
    if not args.no_frames:
        for clip, n, rows, cols in FRAMES:
            path = ROOT / clip
            if not path.exists():
                continue
            x = video_frame(path, n).to(device)
            target, outs = outputs(x)
            base = luma(x, rows, cols)
            report["frames"].append({
                "clip": clip, "frame": n,
                "vs_film": {k: errors(o, target) for k, o in outs.items() if k != "input"},
                "sky_luma": {"input": base, "film": luma(target, rows, cols),
                             "model": luma(outs["model"], rows, cols), "fivek": luma(outs["fivek"], rows, cols)},
            })
            tiles.append([x, target, outs["model"], outs["fivek"]])
    (run / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    if tiles:
        cell = 300
        sheet = Image.new("RGB", (cell * 4, (cell + 18) * len(tiles) + 18), "white")
        d = ImageDraw.Draw(sheet)
        for j, label in enumerate(["input", "film (target)", "model", "FiveK"]):
            d.text((j * cell + 4, 3), label, fill="black")
        for i, row in enumerate(tiles):
            for j, t in enumerate(row):
                im = Image.fromarray(t.clamp(0, 1).mul(255).round().byte()[0].permute(1, 2, 0).cpu().numpy())
                im.thumbnail((cell, cell))
                sheet.paste(im, (j * cell, 18 + i * (cell + 18)))
        sheet.save(run / "sheet.jpg", quality=88)
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
