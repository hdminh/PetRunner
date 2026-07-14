#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PetRunner"
BUNDLE_ID="vn.hodinhminh.petrunner"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Support/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
RELEASE_DIR="$ROOT_DIR/dist/release"
APP="$RELEASE_DIR/$APP_NAME.app"
DMG="$RELEASE_DIR/$APP_NAME-$VERSION-macos-universal.dmg"
STAGING_DIR="$(mktemp -d)"
BUILD_ROOT="$ROOT_DIR/.build/release-universal"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"
for ARCH in arm64 x86_64; do
  swift build \
    -c release \
    --triple "$ARCH-apple-macosx14.0" \
    --sdk "$SDK_PATH" \
    --scratch-path "$BUILD_ROOT/$ARCH"
done

rm -rf "$APP" "$DMG" "$DMG.sha256"
mkdir -p "$APP/Contents/MacOS"
lipo -create \
  "$BUILD_ROOT/arm64/arm64-apple-macosx/release/$APP_NAME" \
  "$BUILD_ROOT/x86_64/x86_64-apple-macosx/release/$APP_NAME" \
  -output "$APP/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp=none \
  --identifier "$BUNDLE_ID" \
  --sign - \
  "$APP"
codesign --verify --deep --strict "$APP"

cp -R "$APP" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG"

(cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG.sha256")")
printf '%s\n' "$DMG"
