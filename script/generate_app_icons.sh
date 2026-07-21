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

MSIX_ASSETS="$ROOT_DIR/windows/PetRunner.Package/Assets"
mkdir -p "$MSIX_ASSETS"
sips -z 50 50 "$MASTER" --out "$MSIX_ASSETS/StoreLogo.png" >/dev/null
sips -z 44 44 "$MASTER" --out "$MSIX_ASSETS/Square44x44Logo.png" >/dev/null
sips -z 71 71 "$MASTER" --out "$MSIX_ASSETS/Square71x71Logo.png" >/dev/null
sips -z 150 150 "$MASTER" --out "$MSIX_ASSETS/Square150x150Logo.png" >/dev/null
sips -z 310 310 "$MASTER" --out "$MSIX_ASSETS/Square310x310Logo.png" >/dev/null
magick "$MASTER" -resize 128x128 -background none -gravity center -extent 310x150 \
  "$MSIX_ASSETS/Wide310x150Logo.png"
magick "$MASTER" -resize 200x200 -background none -gravity center -extent 620x300 \
  "$MSIX_ASSETS/SplashScreen.png"
