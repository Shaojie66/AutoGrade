"""Download a fixed subset of MIT-Adobe FiveK DNGs from the official site only.

Source: https://data.csail.mit.edu/graphics/fivek/ (no mirrors, CLAUDE.md).
Selection: seeded sample inside upstream AdaInt's train.txt / test.txt, so
the split matches the paper's. Resumable: files already present with the
right size are kept. Writes research/data/fivek-dng/selection.json with the
rule, names, sizes and sha256. Licence: FiveK research licences (licenses/).

Usage: research/.venv/bin/python -I research/train/fetch_fivek_dng.py [--train 800 --test 200 --seed 0 --jobs 4]
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import random
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://data.csail.mit.edu/graphics/fivek/"
RESEARCH = Path(__file__).resolve().parent.parent
OUT = RESEARCH / "data" / "fivek-dng"
ANN = RESEARCH / "third_party" / "AdaInt" / "adaint" / "annfiles" / "FiveK"
UA = {"User-Agent": "AutoGrade-research/0.1 (FiveK research download; contact via github.com/Shaojie66/AutoGrade)"}


def get(url: str, timeout: int = 120) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read()


def fetch(name: str, rel: str) -> dict:
    dest = OUT / Path(rel).name
    url = BASE + urllib.parse.quote(rel)          # some FiveK filenames contain spaces
    for attempt in range(4):
        try:
            head = urllib.request.urlopen(urllib.request.Request(url, headers=UA, method="HEAD"), timeout=60)
            size = int(head.headers["Content-Length"])
            if not (dest.exists() and dest.stat().st_size == size):
                data = get(url)
                if len(data) != size:
                    raise IOError(f"{name}: got {len(data)} bytes, expected {size}")
                tmp = dest.with_suffix(".part")
                tmp.write_bytes(data)
                tmp.replace(dest)
            return {"name": name, "file": dest.name, "bytes": size,
                    "sha256": hashlib.sha256(dest.read_bytes()).hexdigest()}
        except Exception as e:  # network hiccup: back off, retry
            if attempt == 3:
                raise
            time.sleep(5 * (attempt + 1))
            print(f"retry {name}: {e}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", type=int, default=800)
    ap.add_argument("--test", type=int, default=200)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    page = get(BASE).decode("utf-8", "replace")
    links = {code: rel for rel, code in re.findall(r'href="(img/dng/(a\d{4})-[^"]+\.dng)"', page)}
    train = [l.strip() for l in (ANN / "train.txt").read_text().split() if l.strip()]
    test = [l.strip() for l in (ANN / "test.txt").read_text().split() if l.strip()]
    rng = random.Random(args.seed)
    pick = {"train": sorted(rng.sample(train, args.train)), "test": sorted(rng.sample(test, args.test))}
    missing = [n for n in pick["train"] + pick["test"] if n not in links]
    if missing:
        sys.exit(f"{len(missing)} selected names have no DNG link on the official page, e.g. {missing[:3]}")
    print(f"official page lists {len(links)} DNGs; downloading {args.train} train + {args.test} test", flush=True)

    todo = [(n, links[n]) for n in pick["train"] + pick["test"]]
    done, total = [], 0
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for k, rec in enumerate(ex.map(lambda t: fetch(*t), todo), 1):
            done.append(rec); total += rec["bytes"]
            if k % 50 == 0 or k == len(todo):
                print(f"{k}/{len(todo)} files, {total / 1e9:.2f} GB", flush=True)
    by = {r["name"]: r for r in done}
    selection = {
        "source": BASE, "fetched": time.strftime("%Y-%m-%d"), "rule": f"random.Random({args.seed}).sample within upstream "
        "AdaInt annfiles train.txt / test.txt (sorted)", "licence": "MIT-Adobe FiveK research licences (see licenses/)",
        "train": [by[n] for n in pick["train"]], "test": [by[n] for n in pick["test"]],
        "total_bytes": total,
    }
    (OUT / "selection.json").write_text(json.dumps(selection, indent=1) + "\n")
    print(f"wrote {OUT / 'selection.json'}: {len(done)} files, {total / 1e9:.2f} GB")


if __name__ == "__main__":
    main()
