#!/usr/bin/env bash
#
# generate-icons.sh — Generate macOS .icns from AppIcon.svg
#
# Requirements: rsvg-convert (brew install librsvg) or sips+qlmanage
# Usage: ./scripts/generate-icons.sh [path/to/icon.svg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

SVG_INPUT="${1:-$PROJECT_DIR/macos/Byblos/Assets/AppIcon.svg}"
ICONSET_DIR="$PROJECT_DIR/macos/Byblos/Assets/AppIcon.iconset"
ICNS_OUTPUT="$PROJECT_DIR/macos/Byblos/Assets/AppIcon.icns"

if [ ! -f "$SVG_INPUT" ]; then
  echo "Error: SVG file not found at $SVG_INPUT"
  exit 1
fi

echo "Generating icon set from: $SVG_INPUT"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Generate a PNG at a given size.
generate_png() {
  local size=$1
  local output=$2

  if command -v rsvg-convert &>/dev/null; then
    rsvg-convert -w "$size" -h "$size" "$SVG_INPUT" -o "$output"
  else
    # Fallback: render SVG with qlmanage, then resize with sips.
    local tmpdir
    tmpdir=$(mktemp -d)
    qlmanage -t -s "$size" -o "$tmpdir" "$SVG_INPUT" &>/dev/null
    local rendered="$tmpdir/$(basename "$SVG_INPUT").png"
    if [ -f "$rendered" ]; then
      sips -z "$size" "$size" "$rendered" --out "$output" &>/dev/null
    else
      # Last resort: create a placeholder.
      sips -z "$size" "$size" "$SVG_INPUT" --out "$output" &>/dev/null 2>&1 || true
    fi
    rm -rf "$tmpdir"
  fi
}

# macOS icon sizes: name pixel_size
SPECS="
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
"

echo "$SPECS" | while read -r name size; do
  [ -z "$name" ] && continue
  echo "  Generating $name (${size}px)"
  generate_png "$size" "$ICONSET_DIR/$name"
done

echo "Converting iconset to icns..."
iconutil -c icns -o "$ICNS_OUTPUT" "$ICONSET_DIR"

if [ -f "$ICNS_OUTPUT" ]; then
  echo "Success: $ICNS_OUTPUT"
  ls -lh "$ICNS_OUTPUT"
else
  echo "Failed to generate ICNS."
  exit 1
fi
