#!/bin/bash
# Compile Core/Shaders/*.metal into one metallib.
#
#   Tools/build-metallib.sh <output.metallib>
#
# Called by the AutoGradeCore pre-build phase (project.yml); also runnable by
# hand. Kernels are compiled here, not by Xcode, for two reasons carried over
# from SpektraLab:
#   * Xcode's Metal build defaults to fast math, which reassociates and drops
#     the precision the parity suite measures. We pin safe math and precise
#     fp32 functions; Probe.metal + ProbeTests fail if that ever regresses.
#   * Without -mmacosx-version-min the metallib is stamped for the host OS and
#     will not load on an older macOS than the build machine.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: build-metallib.sh <output.metallib>}"
min_os=15.0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

airs=()
for src in "$here"/Core/Shaders/*.metal; do
  air="$tmp/$(basename "${src%.metal}").air"
  xcrun -sdk macosx metal -c "$src" -o "$air" \
    -std=metal3.1 -mmacosx-version-min="$min_os" \
    -fmetal-math-mode=safe -fmetal-math-fp32-functions=precise \
    -Werror
  airs+=("$air")
done
mkdir -p "$(dirname "$out")"
xcrun -sdk macosx metallib "${airs[@]}" -o "$out"
echo "metallib: $out (${#airs[@]} sources, macOS >= $min_os)"
