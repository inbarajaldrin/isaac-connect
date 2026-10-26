#!/usr/bin/env bash
# Render the vector source into a PNG and, on macOS, a complete ICNS icon.
# Usage: bash Scripts/render-icon.sh [asset path without extension]
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick 7 (magick) is required to render the SVG." >&2
  exit 1
fi

ICON_BASE="${1:-Assets/Icon/AppIcon}"
magick -background none "${ICON_BASE}.svg" \
  -colorspace sRGB -depth 8 -strip "${ICON_BASE}.png"

if command -v iconutil >/dev/null 2>&1; then
  icon_tmpdir="$(mktemp -d)"
  trap 'rm -rf "$icon_tmpdir"' EXIT
  iconset="${icon_tmpdir}/AppIcon.iconset"
  mkdir "$iconset"
  for size in 16 32 128 256 512; do
    magick "${ICON_BASE}.png" -resize "${size}x${size}" \
      -strip "${iconset}/icon_${size}x${size}.png"
    retina_size=$((size * 2))
    magick "${ICON_BASE}.png" -resize "${retina_size}x${retina_size}" \
      -strip "${iconset}/icon_${size}x${size}@2x.png"
  done
  iconutil -c icns "$iconset" -o "${ICON_BASE}.icns"
fi

echo "Rendered ${ICON_BASE}.png"
if [[ -f "${ICON_BASE}.icns" ]]; then
  echo "Rendered ${ICON_BASE}.icns"
fi
