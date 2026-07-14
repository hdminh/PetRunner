#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSETS="$ROOT_DIR/Assets"

test -f "$ASSETS/AppIcon.svg"
test -f "$ASSETS/AppIcon.png"
test -f "$ASSETS/AppIcon.icns"
test -f "$ASSETS/AppIcon.ico"

test "$(sips -g pixelWidth "$ASSETS/AppIcon.png" | awk '/pixelWidth/ {print $2}')" = "1024"
test "$(sips -g pixelHeight "$ASSETS/AppIcon.png" | awk '/pixelHeight/ {print $2}')" = "1024"
file "$ASSETS/AppIcon.icns" | grep 'Mac OS X icon' >/dev/null
file "$ASSETS/AppIcon.ico" | grep 'MS Windows icon resource' >/dev/null

test "$(plutil -extract CFBundleIconFile raw "$ROOT_DIR/Support/Info.plist")" = "AppIcon.icns"
grep '<ApplicationIcon>../../Assets/AppIcon.ico</ApplicationIcon>' \
  "$ROOT_DIR/windows/PetRunner.Windows/PetRunner.Windows.csproj" >/dev/null
