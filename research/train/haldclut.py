"""HaldCLUT (RawTherapee Film Simulation Collection) as a 3D LUT tensor.

A level-L Hald CLUT is an L^3 x L^3 image holding an N^3 lattice, N = L^2,
red fastest, then green, then blue: pixel k (row-major) is lattice point
(r, g, b) = (k mod N, (k div N) mod N, k div N^2). That is exactly this
project's LUT layout lut[c][b][g][r] (r fastest), so loading is a reshape.

Applying it uses the project's own uniform trilinear transform (the same
arithmetic as upstream lut_transform / Grade.metal lut_apply), and is held
to ffmpeg's `haldclut=interp=trilinear` by check_haldclut.py.
"""
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

RESEARCH = Path(__file__).resolve().parent.parent
COLLECTION = RESEARCH / "third_party" / "rawtherapee-film" / "HaldCLUT"


def load_haldclut(path) -> torch.Tensor:
    """-> float32 tensor (1, 3, N, N, N), lut[0][c][b][g][r], values in [0, 1]."""
    im = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    side = im.shape[0]
    level = round(side ** (1 / 3))
    if level ** 3 != side or im.shape[1] != side:
        raise ValueError(f"{path}: {im.shape} is not a Hald CLUT image")
    n = level * level
    flat = im.reshape(-1, 3)                      # row-major pixels, red fastest
    lut = flat.reshape(n, n, n, 3)                # [b][g][r][c]
    return torch.from_numpy(np.ascontiguousarray(lut.transpose(3, 0, 1, 2)))[None]


def apply_lut(img: torch.Tensor, lut: torch.Tensor) -> torch.Tensor:
    """Uniform trilinear 3D LUT. img (B,3,H,W) in [0,1]; lut (1 or B,3,N,N,N)."""
    b, _, h, w = img.shape
    grid = img.clamp(0, 1).mul(2).sub(1).permute(0, 2, 3, 1).reshape(b, 1, h, w, 3)   # (x=r, y=g, z=b)
    if lut.shape[0] != b:
        lut = lut.expand(b, -1, -1, -1, -1)
    out = F.grid_sample(lut, grid, mode="bilinear", padding_mode="border", align_corners=True)
    return out.reshape(b, 3, h, w)


def film(name: str) -> Path:
    """Path of a colour film in the collection, e.g. film('Fuji/Fuji Velvia 50')."""
    p = COLLECTION / "Color" / f"{name}.png"
    if not p.exists():
        raise FileNotFoundError(p)
    return p
