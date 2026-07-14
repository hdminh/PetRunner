#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DMG="${1:-$ROOT_DIR/dist/release/PetRunner-0.1.0-macos-universal.dmg}"
CHECKSUM="$DMG.sha256"

test -f "$DMG"
test -f "$CHECKSUM"
(cd "$(dirname "$DMG")" && shasum -a 256 -c "$(basename "$CHECKSUM")")

MOUNT_DIR="$(mktemp -d)"
cleanup() {
  hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_DIR" -quiet
APP="$MOUNT_DIR/PetRunner.app"
BINARY="$APP/Contents/MacOS/PetRunner"

test -x "$BINARY"
test "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = "vn.hodinhminh.petrunner"
test "$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")" = "14.0"

ARCHS="$(lipo -archs "$BINARY")"
case " $ARCHS " in *" arm64 "*) ;; *) exit 1 ;; esac
case " $ARCHS " in *" x86_64 "*) ;; *) exit 1 ;; esac

codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep "Signature=adhoc" >/dev/null
