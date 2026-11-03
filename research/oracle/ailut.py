# Portions of this file (the AiLUT model classes, ailut_reference/lut_reference
# wrappers) are derived from AdaInt, https://github.com/ImCharlesY/AdaInt at
# commit 5678851339dff90becb09c3dec41e7214207ccbc, Copyright (c) MMEditing
# Authors, licensed under Apache-2.0 (Resources/Models/AdaInt-LICENSE.txt).
# Changed by AutoGrade: inference-only rewrite without mmcv/mmedit/CUDA, a
# pure-PyTorch AiLUT transform, and a JIT build of the upstream CPU kernel.
# Those portions remain under Apache-2.0; the rest is PolyForm Noncommercial 1.0.0 (LICENSE).
"""AdaInt (CVPR 2022) inference without mmcv, mmedit or CUDA.

Two transforms live here:
  * `ailut_reference` / `lut_reference` — the upstream C++ CPU kernels
    (non-uniform AiLUT and plain uniform 3D LUT), JIT-built unmodified from
    research/third_party/AdaInt (only CUDA launchers are stubbed). The oracle.
  * `ailut_torch` — the same operator in plain PyTorch, so it runs on MPS.

The model classes mirror upstream adaint/model.py (inference path only) so the
upstream checkpoints load with strict=True; any drift in structure fails loudly.
"""
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F

RESEARCH = Path(__file__).resolve().parent.parent
HERE = Path(__file__).resolve().parent
UPSTREAM = RESEARCH / "third_party" / "AdaInt"   # research/fetch_upstream.sh
CSRC = UPSTREAM / "adaint" / "ailut_transform" / "ailut" / "csrc"


# ---------------------------------------------------------------- oracle ----
_ext = None


def _reference_ext():
    global _ext
    if _ext is None:
        from torch.utils.cpp_extension import load
        build = RESEARCH / "build" / "ailut_cpu_ref"
        build.mkdir(parents=True, exist_ok=True)
        _ext = load(
            name="ailut_cpu_ref",
            sources=[str(CSRC / "ailut_transform.cpp"),
                     str(CSRC / "ailut_transform_cpu.cpp"),
                     str(HERE / "cuda_stubs.cpp")],
            build_directory=str(build),
            extra_cflags=["-O3"],
            verbose=False)
    return _ext


def ailut_reference(img, lut, vertices):
    """Upstream CPU AiLUT-Transform. img (b,3,h,w), lut (b,3,d,d,d), vertices (b,3,d)."""
    img, lut, vertices = (t.detach().cpu().float().contiguous() for t in (img, lut, vertices))
    out = img.new_zeros((img.size(0), lut.size(1), img.size(2), img.size(3)))
    _reference_ext().ailut_cforward(img, lut, vertices, out)
    return out


def lut_reference(img, lut):
    """Upstream CPU uniform 3D-LUT transform. img (b,3,h,w) in [0,1], lut (b,3,d,d,d)."""
    img, lut = (t.detach().cpu().float().contiguous() for t in (img, lut))
    out = img.new_zeros((img.size(0), lut.size(1), img.size(2), img.size(3)))
    _reference_ext().lut_cforward(img, lut, out)
    return out


# ------------------------------------------------------------ pure torch ----
def ailut_torch(img, lut, vertices):
    """AiLUT-Transform in plain PyTorch.

    The kernel locates each channel value in its own non-uniform vertex list
    (lower_bound, clamped to [0, d-2]) and interpolates trilinearly inside that
    cell. Trilinear interpolation is separable, so mapping each channel to the
    *uniform* coordinate (cell + fraction) / (d-1) and calling grid_sample with
    align_corners=True is the same arithmetic. LUT layout is lut[c, b, g, r]
    (r fastest), which is exactly grid_sample's (x, y, z) -> (W, H, D).
    """
    b, _, h, w = img.shape
    d = vertices.shape[-1]
    eps = 1e-10                                    # same eps as the kernel
    x = img.reshape(b, 3, h * w)                   # (b,3,n)
    # torch.searchsorted(side='left') == count(v < x) == the kernel's lower_bound + 1
    idx = torch.searchsorted(vertices.contiguous(), x.contiguous(), side="left")
    idx = (idx - 1).clamp(0, d - 2)
    v0 = torch.gather(vertices, 2, idx)
    v1 = torch.gather(vertices, 2, idx + 1)
    frac = (x - v0) / (v1 - v0 + eps)
    u = (idx.to(x.dtype) + frac) / (d - 1) * 2 - 1  # [-1, 1], align_corners=True
    grid = u.permute(0, 2, 1).reshape(b, 1, 1, h * w, 3)  # last dim (x=r, y=g, z=b)
    out = F.grid_sample(lut, grid, mode="bilinear", padding_mode="border",
                        align_corners=True)        # (b,3,1,1,n)
    return out.reshape(b, lut.shape[1], h, w)


# ----------------------------------------------------------------- model ----
class BasicBlock(nn.Sequential):
    def __init__(self, cin, cout, stride=1, norm=False):
        body = [nn.Conv2d(cin, cout, 3, stride=stride, padding=1), nn.LeakyReLU(0.2)]
        if norm:
            body.append(nn.InstanceNorm2d(cout, affine=True))
        super().__init__(*body)


class TPAMIBackbone(nn.Sequential):
    def __init__(self, input_resolution=256, extra_pooling=True):
        body = [BasicBlock(3, 16, 2, True), BasicBlock(16, 32, 2, True),
                BasicBlock(32, 64, 2, True), BasicBlock(64, 128, 2, True),
                BasicBlock(128, 128, 2), nn.Dropout(p=0.5)]
        if extra_pooling:
            body.append(nn.AdaptiveAvgPool2d(2))
        super().__init__(*body)
        self.input_resolution = input_resolution
        self.out_channels = 128 * (4 if extra_pooling else 64)

    def forward(self, imgs):
        imgs = F.interpolate(imgs, size=(self.input_resolution,) * 2,
                             mode="bilinear", align_corners=False)
        return super().forward(imgs).view(imgs.shape[0], -1)


class Res18Backbone(nn.Module):
    def __init__(self, input_resolution=224):
        super().__init__()
        import torchvision
        net = torchvision.models.resnet18(weights=None)
        net.fc = nn.Identity()
        self.net = net
        self.input_resolution = input_resolution
        self.out_channels = 512

    def forward(self, imgs):
        imgs = F.interpolate(imgs, size=(self.input_resolution,) * 2,
                             mode="bilinear", align_corners=False)
        return self.net(imgs).view(imgs.shape[0], -1)


class LUTGenerator(nn.Module):
    def __init__(self, n_colors, n_vertices, n_feats, n_ranks):
        super().__init__()
        self.weights_generator = nn.Linear(n_feats, n_ranks)
        self.basis_luts_bank = nn.Linear(n_ranks, n_colors * n_vertices ** n_colors, bias=False)
        self.n_colors, self.n_vertices = n_colors, n_vertices

    def forward(self, x):
        weights = self.weights_generator(x)
        luts = self.basis_luts_bank(weights)
        return weights, luts.view(x.shape[0], -1, *((self.n_vertices,) * self.n_colors))

    def regularizations(self, smoothness, monotonicity):
        """Upstream AiLUT regularizers on the basis LUTs (adaint/model.py)."""
        basis = self.basis_luts_bank.weight.t().view(self.basis_luts_bank.weight.shape[1], self.n_colors,
                                                     *((self.n_vertices,) * self.n_colors))
        tv, mn = 0, 0
        for i in range(2, basis.ndimension()):
            diff = torch.diff(basis.flip(i), dim=i)
            tv = tv + torch.square(diff).sum(0).mean()
            mn = mn + F.relu(diff).sum(0).mean()
        return smoothness * tv, monotonicity * mn


class AdaInt(nn.Module):
    def __init__(self, n_colors, n_vertices, n_feats):
        super().__init__()
        self.intervals_generator = nn.Linear(n_feats, (n_vertices - 1) * n_colors)
        self.n_vertices = n_vertices

    def forward(self, x):
        x = x.view(x.shape[0], -1)
        intervals = self.intervals_generator(x).view(x.shape[0], -1, self.n_vertices - 1)
        intervals = intervals.softmax(-1)
        return F.pad(intervals.cumsum(-1), (1, 0), "constant", 0)


class AiLUT(nn.Module):
    """Inference-only AiLUT. `predict` returns the per-image LUT and vertices;
    `forward` applies them with the chosen transform."""

    def __init__(self, backbone="tpami", n_ranks=3, n_vertices=33, n_colors=3):
        super().__init__()
        self.backbone = TPAMIBackbone() if backbone == "tpami" else Res18Backbone()
        self.lut_generator = LUTGenerator(n_colors, n_vertices, self.backbone.out_channels, n_ranks)
        self.adaint = AdaInt(n_colors, n_vertices, self.backbone.out_channels)

    def predict(self, imgs):
        codes = self.backbone(imgs)
        _, luts = self.lut_generator(codes)
        return luts, self.adaint(codes)

    def forward(self, imgs, transform=ailut_torch):
        luts, vertices = self.predict(imgs)
        return transform(imgs, luts, vertices)


CHECKPOINTS = {
    "fivek": ("AiLUT-FiveK-sRGB.pth", dict(backbone="tpami", n_ranks=3)),
    "ppr10k": ("AiLUT-PPR10KA-sRGB.pth", dict(backbone="res18", n_ranks=5)),
}


def load_model(name="fivek", device="cpu", checkpoint=None):
    """Upstream pretrained weights by `name`, or a fine-tuned `checkpoint`
    (research/runs/<run>/*.pth, same architecture as `name`)."""
    fname, kw = CHECKPOINTS[name]
    model = AiLUT(**kw)
    path = Path(checkpoint) if checkpoint else UPSTREAM / "pretrained" / fname
    # weights_only: never run pickled code, whether upstream or ours.
    ck = torch.load(path, map_location="cpu", weights_only=True)
    model.load_state_dict(ck["state_dict"], strict=True)
    return model.eval().to(device)
