"""Fine-tune AdaInt (FiveK sRGB weights) toward a film look from the
RawTherapee collection. Targets are generated on the fly: target = film(aug(x)),
so the model learns the film rendering itself (plan: research/train, 2026-11-02).

Augmentation mirrors upstream adaint/configs/fivekrgb.py: random ratio crop
0.6-1.0, horizontal flip, input brightness/saturation jitter 0.2. Losses:
MSE + 1e-4 * mean(weights^2) + 10 * monotonicity; Adam 1e-4, AdaInt x0.1.

Usage:
  PATH="$PWD/research/.venv/bin:$PATH" research/.venv/bin/python -I research/train/train.py \
      --film "Fuji/Fuji Velvia 50" --run velvia50 [--steps 45000] [--images DIR --list FILE]
"""
import argparse
import hashlib
import json
import random
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # -I drops the script dir

import numpy as np
import torch
import torch.nn.functional as F

from fixture_io import load_rgb
from oracle.ailut import UPSTREAM, ailut_torch, load_model
from train.haldclut import apply_lut, film, load_haldclut

RESEARCH = Path(__file__).resolve().parent.parent
ROOT = RESEARCH.parent
DEFAULT_IMAGES = RESEARCH / "data" / "fivek480p" / "input" / "JPG" / "480p"
ANNFILES = UPSTREAM / "adaint" / "annfiles" / "FiveK"


def image_list(images: Path, list_file: Path | None) -> list[Path]:
    if list_file:
        names = [l.strip() for l in list_file.read_text().splitlines() if l.strip()]
        paths = [images / f"{n}.jpg" for n in names]
    else:
        paths = sorted(p for p in images.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
    missing = [p for p in paths if not p.exists()]
    if missing:
        raise FileNotFoundError(f"{len(missing)} listed images missing, e.g. {missing[0]}")
    return paths


def manifest_sha(paths: list[Path]) -> str:
    h = hashlib.sha256()
    for p in paths:
        h.update(p.name.encode()); h.update(str(p.stat().st_size).encode())
    return h.hexdigest()


def augment(img: torch.Tensor, rng: random.Random) -> torch.Tensor:
    """(1,3,H,W) -> augmented copy: ratio crop, flip, brightness and saturation jitter."""
    _, _, h, w = img.shape
    rh, rw = rng.uniform(0.6, 1.0), rng.uniform(0.6, 1.0)
    ch, cw = max(16, int(h * rh)), max(16, int(w * rw))
    y0, x0 = rng.randint(0, h - ch), rng.randint(0, w - cw)
    img = img[:, :, y0:y0 + ch, x0:x0 + cw]
    if rng.random() < 0.5:
        img = img.flip(-1)
    img = img * rng.uniform(0.8, 1.2)                                   # brightness
    grey = (0.299 * img[:, 0:1] + 0.587 * img[:, 1:2] + 0.114 * img[:, 2:3])
    s = rng.uniform(0.8, 1.2)                                            # saturation
    img = grey + s * (img - grey)
    return img.clamp(0, 1).contiguous()


def psnr(a: torch.Tensor, b: torch.Tensor) -> float:
    mse = F.mse_loss(a.clamp(0, 1), b.clamp(0, 1)).item()
    return 99.0 if mse == 0 else 10 * np.log10(1 / mse)


@torch.no_grad()
def validate(model, lut, paths, device) -> dict:
    model.eval()
    ps, errs = [], []
    for p in paths:
        x = load_rgb(p).to(device)
        target = apply_lut(x, lut)
        luts, ver = model.predict(x)
        out = ailut_torch(x, luts, ver)
        ps.append(psnr(out, target))
        errs.append((out.clamp(0, 1) - target.clamp(0, 1)).abs().mean().item() * 255)
    model.train()
    return {"psnr": float(np.mean(ps)), "mean_abs_8bit": float(np.mean(errs)), "images": len(paths)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--film", required=True, help='e.g. "Fuji/Fuji Velvia 50"')
    ap.add_argument("--run", required=True, help="run name under research/runs/")
    ap.add_argument("--steps", type=int, default=45000)
    ap.add_argument("--images", type=Path, default=DEFAULT_IMAGES)
    ap.add_argument("--list", type=Path, default=ANNFILES / "train.txt")
    ap.add_argument("--val-list", type=Path, default=ANNFILES / "test.txt")
    ap.add_argument("--val-count", type=int, default=50)
    ap.add_argument("--every", type=int, default=4500, help="validate + checkpoint interval")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-list", action="store_true", help="use every image in --images (smoke tests)")
    args = ap.parse_args()

    run = RESEARCH / "runs" / args.run
    if run.exists() and any(run.iterdir()):
        sys.exit(f"{run} is not empty; choose a new --run (never overwrite a run)")
    run.mkdir(parents=True, exist_ok=True)
    random.seed(args.seed); np.random.seed(args.seed); torch.manual_seed(args.seed)
    rng = random.Random(args.seed)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")

    train_paths = image_list(args.images, None if args.no_list else args.list)
    val_paths = image_list(args.images, None if args.no_list else args.val_list)[: args.val_count]
    hald = film(args.film)
    lut = load_haldclut(hald).to(device)
    model = load_model("fivek", "cpu").to(device).train()

    adaint = [p for n, p in model.named_parameters() if n.startswith("adaint.")]
    rest = [p for n, p in model.named_parameters() if not n.startswith("adaint.")]
    opt = torch.optim.Adam([{"params": rest, "lr": 1e-4}, {"params": adaint, "lr": 1e-5}], betas=(0.9, 0.999), eps=1e-8)

    config = {
        "film": args.film, "film_sha256": hashlib.sha256(hald.read_bytes()).hexdigest(),
        "steps": args.steps, "seed": args.seed, "device": str(device), "torch": torch.__version__,
        "train_images": len(train_paths), "train_manifest_sha256": manifest_sha(train_paths),
        "val_images": len(val_paths), "init": "AdaInt FiveK sRGB (upstream 5678851)",
        "git": subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip(),
        "uptime_at_start": subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(),
        "losses": "MSE + 1e-4*mean(w^2) + 10*monotonicity", "optimizer": "Adam lr 1e-4 (adaint 1e-5)",
        "augment": "ratio crop 0.6-1.0, hflip, brightness/saturation jitter 0.2; target = film(aug(x))",
        "licences": "inputs: MIT-Adobe FiveK (research only); film: RawTherapee collection CC BY-SA 4.0",
    }
    (run / "config.json").write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
    log = (run / "log.csv").open("w")
    log.write("step,loss,mse,seconds,val_psnr,val_mean_abs_8bit\n")
    print(json.dumps(config, indent=2, ensure_ascii=False))

    base = validate(model, lut, val_paths, device)
    print(f"step 0: val psnr {base['psnr']:.2f} dB, mean |err| {base['mean_abs_8bit']:.2f} LSB (FiveK weights vs film)")
    log.write(f"0,,,0,{base['psnr']:.4f},{base['mean_abs_8bit']:.4f}\n"); log.flush()

    start, running = time.time(), []
    for step in range(1, args.steps + 1):
        x = augment(load_rgb(rng.choice(train_paths)), rng).to(device)
        with torch.no_grad():
            target = apply_lut(x, lut)
        codes = model.backbone(x)
        weights, luts = model.lut_generator(codes)
        vertices = model.adaint(codes)
        out = ailut_torch(x, luts, vertices)
        mse = F.mse_loss(out, target)
        _, mono = model.lut_generator.regularizations(0.0, 10.0)
        loss = mse + 1e-4 * weights.pow(2).mean() + mono
        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()
        running.append((loss.item(), mse.item()))
        if step % 100 == 0:
            l, m = np.mean(running, axis=0); running = []
            log.write(f"{step},{l:.6g},{m:.6g},{time.time() - start:.1f},,\n"); log.flush()
            print(f"step {step}: loss {l:.5f} mse {m:.5f} ({time.time() - start:.0f} s)", flush=True)
        if step % args.every == 0 or step == args.steps:
            v = validate(model, lut, val_paths, device)
            torch.save({"state_dict": {k: t.detach().cpu() for k, t in model.state_dict().items()}}, run / f"step{step:06d}.pth")
            log.write(f"{step},,,{time.time() - start:.1f},{v['psnr']:.4f},{v['mean_abs_8bit']:.4f}\n"); log.flush()
            print(f"step {step}: val psnr {v['psnr']:.2f} dB, mean |err| {v['mean_abs_8bit']:.2f} LSB", flush=True)
    summary = {"seconds": round(time.time() - start, 1), "final": v, "initial": base,
               "uptime_at_end": subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()}
    (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
