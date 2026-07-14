#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ROOT_DIR/Assets"
SOURCE="$ASSETS/AppIcon.svg"
MASTER="$ASSETS/AppIcon.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"

cleanup() {
  rm -rf "$(dirname "$ICONSET")"
}
trap cleanup EXIT

for tool in rsvg-convert sips iconutil magick; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'missing required tool: %s\n' "$tool" >&2
    exit 1
  }
done

mkdir -p "$ICONSET"
rsvg-convert --width 1024 --height 1024 "$SOURCE" > "$MASTER"

make_png() {
  local pixels="$1"
  local name="$2"
  sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/$name" >/dev/null
}

make_png 16 icon_16x16.png
make_png 32 icon_16x16@2x.png
make_png 32 icon_32x32.png
make_png 64 icon_32x32@2x.png
make_png 128 icon_128x128.png
make_png 256 icon_128x128@2x.png
make_png 256 icon_256x256.png
make_png 512 icon_256x256@2x.png
make_png 512 icon_512x512.png
make_png 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$ASSETS/AppIcon.icns"
magick "$MASTER" -define icon:auto-resize=256,128,64,48,32,16 "$ASSETS/AppIcon.ico"
