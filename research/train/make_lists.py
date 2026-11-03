"""Write train.txt / test.txt for the rendered FiveK subset.

Reads research/data/fivek-dng/selection.json (fetch_fivek_dng.py) and lists
every selected image whose PNG render_dng.swift produced, so the training
split stays inside upstream AdaInt's split. Fails if any selected image is
missing a render, instead of silently training on fewer images.

Usage: research/.venv/bin/python -I research/train/make_lists.py
"""
import hashlib
import json
import sys
from pathlib import Path

RESEARCH = Path(__file__).resolve().parent.parent
SEL = RESEARCH / "data" / "fivek-dng" / "selection.json"
IMG = RESEARCH / "data" / "fivek-srgb480"


def main():
    sel = json.loads(SEL.read_text())
    for split in ("train", "test"):
        names = [r["name"] for r in sel[split]]
        missing = [n for n in names if not (IMG / f"{n}.png").exists()]
        if missing:
            sys.exit(f"{split}: {len(missing)} selected images have no render, e.g. {missing[:3]}")
        (IMG / f"{split}.txt").write_text("\n".join(names) + "\n")
        digest = hashlib.sha256("".join(names).encode()).hexdigest()[:16]
        print(f"{split}: {len(names)} images -> {IMG / f'{split}.txt'} (names sha256 {digest})")


if __name__ == "__main__":
    main()
