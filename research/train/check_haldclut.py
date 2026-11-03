"""haldclut.py vs ffmpeg `haldclut=interp=trilinear` on the fixture images.

Pass criterion (plan acceptance 1): every 8-bit sample within 1 LSB.
--swap-axes deliberately loads the lattice with red and blue exchanged; it
must FAIL, proving the check can see a layout error.

Usage: PATH="$PWD/research/.venv/bin:$PATH" research/.venv/bin/python -I research/train/check_haldclut.py [--swap-axes]
"""
import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # -I drops the script dir

import numpy as np
import torch

from fixture_io import load_rgb
from train.haldclut import apply_lut, film, load_haldclut

ROOT = Path(__file__).resolve().parents[2]
IMAGES = ["demo_in", "gym_a_in", "comic_in"]
FILMS = ["Fuji/Fuji Velvia 50", "Kodak/Kodak Ektachrome 100 VS", "CreativePack-1/TealOrange"]


def ffmpeg_apply(png: Path, hald: Path) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(png), "-i", str(hald), "-filter_complex",
                          "[0]format=rgb24[a];[1]format=rgb24[b];[a][b]haldclut=interp=trilinear,format=rgb24",
                          "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--swap-axes", action="store_true", help="mutation: exchange r and b lattice axes (must fail)")
    args = ap.parse_args()
    worst_all = 0
    for name in FILMS:
        hald = film(name)
        lut = load_haldclut(hald)
        if args.swap_axes:
            lut = lut.permute(0, 1, 4, 3, 2).contiguous()
        for stem in IMAGES:
            png = ROOT / "fixtures" / f"{stem}.png"
            img = load_rgb(png)
            ours = apply_lut(img, lut).clamp(0, 1).mul(255).round().byte()[0].permute(1, 2, 0).numpy().reshape(-1)
            ref = ffmpeg_apply(png, hald)
            d = np.abs(ours.astype(int) - ref.astype(int))
            worst_all = max(worst_all, int(d.max()))
            print(f"{name:<32} {stem:<9} max {d.max()} LSB, >1 LSB: {(d > 1).mean() * 100:.4f}% of samples")
    ok = worst_all <= 1
    print("PASS" if ok else "FAIL", f"(worst {worst_all} LSB)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    torch.set_num_threads(1)
    main()
