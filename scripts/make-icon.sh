#!/bin/bash
# Turns Assets/AppIcon.svg into Assets/AppIcon.icns with tools that ship with
# macOS (WebKit, sips, iconutil). Run it after changing the SVG and commit
# both files; build-app.sh only copies the .icns.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d -t dme-icon)"
set="$work/AppIcon.iconset"
mkdir -p "$set"
swift scripts/render-svg.swift Assets/AppIcon.svg "$work/1024.png" 1024

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/1024.png" --out "$set/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/1024.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o Assets/AppIcon.icns
trash "$work"
echo "made: Assets/AppIcon.icns"
