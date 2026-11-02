"""Shared conventions between research/ and the Swift tests.

Everything numeric a Swift test reads goes through here, so the two sides
agree by construction:
  * images in: 8-bit RGB -> float32 /255, tensor (1,3,h,w);
  * resize to the network: bilinear, align_corners=False, no antialias
    (what upstream TPAMIBackbone does, and what the weights were trained with);
  * tensors out: raw little-endian float32, C order, described in manifest.json.
"""
import hashlib
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image


def load_rgb(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    return torch.from_numpy(a).permute(2, 0, 1)[None].contiguous()


def resize256(img):
    return F.interpolate(img, size=(256, 256), mode="bilinear", align_corners=False)


def to_u8(t):
    """(1,3,h,w) float -> (h,w,3) uint8, clamp then round half to even (torch.round)."""
    return t.clamp(0, 1).mul(255).round().byte()[0].permute(1, 2, 0).numpy()


class Manifest:
    """fixtures/manifest.json: one entry per file, with shape, dtype and sha256."""

    def __init__(self, root: Path):
        self.root = root
        self.entries = {}

    def record(self, name, path, **meta):
        meta["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        meta["bytes"] = path.stat().st_size
        self.entries[name] = meta

    def tensor(self, name, t, note=""):
        a = t.detach().cpu().float().contiguous().numpy()
        path = self.root / f"{name}.f32"
        path.write_bytes(a.astype("<f4").tobytes(order="C"))
        self.record(name, path, file=path.name, dtype="float32", shape=list(a.shape), note=note)

    def image(self, name, u8, note=""):
        path = self.root / f"{name}.png"
        # PNG without metadata chunks so the bytes are reproducible
        Image.fromarray(u8, "RGB").save(path, optimize=False, compress_level=9)
        self.record(name, path, file=path.name, dtype="uint8", shape=list(u8.shape), note=note)

    def write(self, **header):
        doc = {**header, "files": dict(sorted(self.entries.items()))}
        (self.root / "manifest.json").write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
