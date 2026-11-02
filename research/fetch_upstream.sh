#!/bin/bash
# Fetch upstream AdaInt at the pinned commit into research/third_party/AdaInt.
# Read-only third-party code: never edit it; the oracle builds its CPU kernel
# from these sources unmodified (CUDA launchers are stubbed in research/oracle).
set -euo pipefail
commit=5678851339dff90becb09c3dec41e7214207ccbc
dest="$(cd "$(dirname "$0")" && pwd)/third_party/AdaInt"
if [ -d "$dest/.git" ] && [ "$(git -C "$dest" rev-parse HEAD)" = "$commit" ]; then
  echo "AdaInt already at $commit"; exit 0
fi
# Never delete an existing checkout (CLAUDE.md 红线): stop and let a person decide.
if [ -e "$dest" ]; then
  echo "error: $dest exists but is not AdaInt@$commit; move or remove it by hand, then rerun" >&2
  exit 1
fi
mkdir -p "$dest"
git -C "$dest" init -q
git -C "$dest" remote add origin https://github.com/ImCharlesY/AdaInt.git
git -C "$dest" fetch -q --depth 1 origin "$commit"
git -C "$dest" checkout -q FETCH_HEAD
echo "AdaInt at $(git -C "$dest" rev-parse HEAD)"
