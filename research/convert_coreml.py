"""Convert AdaInt FiveK-sRGB to Resources/Models/AdaIntFiveK.mlpackage.

The CoreML model is the network only: a 256x256 RGB tensor in, the per-image
LUT (1,3,33,33,33) and AdaInt vertices (1,3,33) out. The 256x256 resize and
the AiLUT transform are *not* in it; the app does both in Metal so they can be
held to the oracle separately (CLAUDE.md, "对照先于功能").

After conversion the package is checked against PyTorch on the upstream demo
image and on random inputs, fp32 on cpuAndGPU, tolerance 1e-4.

Usage: research/.venv/bin/python -I research/convert_coreml.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I drops the script dir

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn

from oracle.ailut import UPSTREAM, load_model
from fixture_io import load_rgb, resize256

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "Models" / "AdaIntFiveK.mlpackage"
TOL = 1e-4


class Network(nn.Module):
    """AiLUT minus the input resize: backbone body -> (lut, vertices)."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, image256):
        m = self.model
        codes = nn.Sequential.forward(m.backbone, image256).view(1, -1)
        _, lut = m.lut_generator(codes)
        return lut, m.adaint(codes)


def main():
    net = Network(load_model("fivek")).eval()
    example = torch.rand(1, 3, 256, 256)
    traced = torch.jit.trace(net, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 3, 256, 256), dtype=np.float32)],
        outputs=[ct.TensorType(name="lut", dtype=np.float32),
                 ct.TensorType(name="vertices", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.author = "AdaInt (Yang et al., CVPR 2022), converted by AutoGrade research/convert_coreml.py"
    mlmodel.license = "Apache-2.0 (code). Weights trained on MIT-Adobe FiveK; usage terms unverified."
    mlmodel.short_description = ("AiLUT network, FiveK sRGB. Input: RGB in [0,1] already resized to 256x256 "
                                 "(bilinear, align_corners=False). Output: LUT lut[c][b][g][r] and per-channel vertices.")
    mlmodel.version = "fivek-srgb@5678851"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(OUT))
    print(f"wrote {OUT.relative_to(ROOT)}")

    # ---- verify the saved package, not the in-memory object
    reloaded = ct.models.MLModel(str(OUT), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    demo = resize256(load_rgb(UPSTREAM / "resources" / "a4739.jpg"))
    worst = {"lut": 0.0, "vertices": 0.0}
    for x in [demo] + [torch.rand(1, 3, 256, 256) for _ in range(4)]:
        with torch.no_grad():
            lut_t, ver_t = net(x)
        got = reloaded.predict({"image": x.numpy()})
        worst["lut"] = max(worst["lut"], float(np.abs(got["lut"] - lut_t.numpy()).max()))
        worst["vertices"] = max(worst["vertices"], float(np.abs(got["vertices"] - ver_t.numpy()).max()))
    print(f"CoreML (cpuAndGPU, fp32) vs PyTorch, 5 inputs: "
          f"lut max {worst['lut']:.2e}, vertices max {worst['vertices']:.2e} (tolerance {TOL:.0e})")
    if max(worst.values()) > TOL:
        sys.exit("FAILED: CoreML output outside tolerance")


if __name__ == "__main__":
    main()
