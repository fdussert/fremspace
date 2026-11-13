#!/usr/bin/env bash
# Draws packaging/dmg/background.tiff again (1x and 2x in one file) from packaging/dmg/background.swift.
# Only needed after a change to that drawing: the repository keeps the result.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift packaging/dmg/background.swift "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out packaging/dmg/background.tiff
echo "packaging/dmg/background.tiff"
