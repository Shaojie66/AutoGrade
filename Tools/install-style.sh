#!/bin/bash
# Install a fine-tuned style model for the app and the CLI on this Mac.
#
#   Tools/install-style.sh research/runs/<run>/<Name>.mlpackage <id>
#
# Compiles the package with coremlcompiler (what Xcode does for the built-in
# FiveK model) and installs it as Styles/<id>.mlmodelc, next to a copy of
# <run>/reference/ as Styles/<id>.reference/ for StyleParityTests.
# Styles/ is ~/Library/Application Support/AutoGrade/Styles unless
# AUTOGRADE_STYLES_DIR is set. Style weights stay on this machine: never in
# git, never in the app bundle (CLAUDE.md, 风格模型).
#
# An installed id is never overwritten: remove the old one yourself first.
set -euo pipefail
pkg="${1:?usage: install-style.sh <Name.mlpackage> <id>}"
id="${2:?usage: install-style.sh <Name.mlpackage> <id>}"
styles="${AUTOGRADE_STYLES_DIR:-$HOME/Library/Application Support/AutoGrade/Styles}"

[[ "$id" =~ ^[a-z0-9][a-z0-9_-]{0,39}$ ]] || { echo "id must be lowercase letters, digits, - or _ (got '$id')" >&2; exit 2; }
[[ "$id" != "fivek" ]] || { echo "'fivek' is the built-in style" >&2; exit 2; }
[[ -d "$pkg" && "$pkg" == *.mlpackage ]] || { echo "not an .mlpackage: $pkg" >&2; exit 2; }
ref="$(dirname "$pkg")/reference"
[[ -f "$ref/reference.json" ]] || { echo "no $ref/reference.json: convert with research/convert_coreml.py first" >&2; exit 2; }
for target in "$styles/$id.mlmodelc" "$styles/$id.reference"; do
    [[ ! -e "$target" ]] || { echo "$target already exists; remove it first to reinstall" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
xcrun coremlcompiler compile "$pkg" "$tmp" >/dev/null
compiled=("$tmp"/*.mlmodelc)
[[ ${#compiled[@]} -eq 1 && -d "${compiled[0]}" ]] || { echo "coremlcompiler produced no .mlmodelc" >&2; exit 1; }

mkdir -p "$styles"
cp -R "$ref" "$tmp/reference"
mv "${compiled[0]}" "$styles/$id.mlmodelc"
mv "$tmp/reference" "$styles/$id.reference"
echo "installed $id -> $styles/$id.mlmodelc"
