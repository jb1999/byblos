#!/usr/bin/env bash
#
# generate-icons.sh — Generate macOS .icns from AppIcon.svg
#
# Requirements: rsvg-convert (from librsvg, install via: brew install librsvg)
#               iconutil (ships with Xcode / macOS)
#
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

# Check for rsvg-convert (preferred) or fall back to sips
USE_RSVG=false
if command -v rsvg-convert &>/dev/null; then
  USE_RSVG=true
elif ! command -v sips &>/dev/null; then
  echo "Error: Neither rsvg-convert nor sips found."
  echo "Install librsvg: brew install librsvg"
  exit 1
fi

# Create iconset directory
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# macOS icon sizes: each size needs a 1x and 2x variant
# Filename format: icon_<size>x<size>.png and icon_<size>x<size>@2x.png
#
# Required sizes (points -> pixels):
#   16x16     -> 16px (1x), 32px (2x)
#   32x32     -> 32px (1x), 64px (2x)
#   128x128   -> 128px (1x), 256px (2x)
#   256x256   -> 256px (1x), 512px (2x)
#   512x512   -> 512px (1x), 1024px (2x)

declare -A ICON_SPECS=(
  ["icon_16x16.png"]=16
  ["icon_16x16@2x.png"]=32
  ["icon_32x32.png"]=32
  ["icon_32x32@2x.png"]=64
  ["icon_128x128.png"]=128
  ["icon_128x128@2x.png"]=256
  ["icon_256x256.png"]=256
  ["icon_256x256@2x.png"]=512
  ["icon_512x512.png"]=512
  ["icon_512x512@2x.png"]=1024
)

render_icon() {
  local filename="$1"
  local size="$2"
  local output="$ICONSET_DIR/$filename"

  if $USE_RSVG; then
    rsvg-convert -w "$size" -h "$size" "$SVG_INPUT" -o "$output"
  else
    # sips cannot read SVG directly — export a large PNG first, then resize
    # This fallback requires a pre-rendered PNG; create one with qlmanage
    local tmp_png="/tmp/byblos_icon_master.png"
    if [ ! -f "$tmp_png" ]; then
      # Attempt qlmanage for SVG -> PNG (macOS built-in, best-effort)
      qlmanage -t -s 1024 -o /tmp "$SVG_INPUT" 2>/dev/null
      local ql_output="/tmp/$(basename "$SVG_INPUT").png"
      if [ -f "$ql_output" ]; then
        mv "$ql_output" "$tmp_png"
      else
        echo "Error: Cannot convert SVG without rsvg-convert."
        echo "Install it: brew install librsvg"
        exit 1
      fi
    fi
    sips -z "$size" "$size" "$tmp_png" --out "$output" >/dev/null 2>&1
  fi
}

echo "Generating icon set from: $SVG_INPUT"

for filename in "${!ICON_SPECS[@]}"; do
  size="${ICON_SPECS[$filename]}"
  echo "  ${filename} (${size}x${size})"
  render_icon "$filename" "$size"
done

echo ""
echo "Converting iconset to icns..."
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_OUTPUT"

echo "Done: $ICNS_OUTPUT"

# Clean up the iconset directory (optional — comment out to keep PNGs)
# rm -rf "$ICONSET_DIR"
