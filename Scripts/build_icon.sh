#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="Assets/AppIcon-1024.png"
ICONSET=".build/AppIcon.iconset"
OUT="Assets/AppIcon.icns"

if [ "${1:-}" = "--render" ] || [ ! -f "$MASTER" ]; then
    swift Scripts/make_icon.swift
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" \
            "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$MASTER" --out "$ICONSET/$2.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT"
