#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PetRunner"
BUNDLE_ID="vn.hodinhminh.petrunner"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
if [[ ! -x "$ROOT_DIR/node_modules/.bin/vite" ]]; then
  echo "Installing npm dependencies (vite not found in node_modules)..."
  npm install
fi
npm run dashboard:build
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

# Stage outside the repo when Documents/Desktop is iCloud-synced: File Provider
# re-stamps FinderInfo on .app bundles and codesign then fails with
# "resource fork, Finder information, or similar detritus not allowed".
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/petrunner-app.XXXXXX")"
cleanup_stage() { rm -rf "$STAGE_ROOT"; }
trap cleanup_stage EXIT

STAGE_BUNDLE="$STAGE_ROOT/$APP_NAME.app"
STAGE_CONTENTS="$STAGE_BUNDLE/Contents"
STAGE_MACOS="$STAGE_CONTENTS/MacOS"
STAGE_RESOURCES="$STAGE_CONTENTS/Resources"
mkdir -p "$STAGE_MACOS" "$STAGE_RESOURCES"
cp "$BUILD_BINARY" "$STAGE_MACOS/$APP_NAME"
cp "$ROOT_DIR/Support/Info.plist" "$STAGE_CONTENTS/Info.plist"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$STAGE_RESOURCES/AppIcon.icns"
# ditto avoids copying Finder resource forks / extended attributes.
/usr/bin/ditto --norsrc --noextattr "$ROOT_DIR/Assets/DefaultPets" "$STAGE_RESOURCES/DefaultPets"
/usr/bin/ditto --norsrc --noextattr "$ROOT_DIR/DashboardWeb/dist" "$STAGE_RESOURCES/DashboardWeb"
chmod +x "$STAGE_MACOS/$APP_NAME"
xattr -cr "$STAGE_BUNDLE" 2>/dev/null || true
codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp=none \
  --identifier "$BUNDLE_ID" \
  --sign - \
  "$STAGE_BUNDLE"
codesign --verify --deep --strict "$STAGE_BUNDLE"

rm -rf "$APP_BUNDLE"
mkdir -p "$DIST_DIR"
/usr/bin/ditto --norsrc --noextattr "$STAGE_BUNDLE" "$APP_BUNDLE"

# dist/ often lives under iCloud Documents. File Provider re-stamps
# com.apple.FinderInfo / fpfs xattrs and codesign then fails with
# "resource fork, Finder information, or similar detritus not allowed".
# Prefer a durable launch path outside the synced tree when that happens.
sign_bundle() {
  local target="$1"
  xattr -cr "$target" 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$target" 2>/dev/null || true
  /usr/bin/dot_clean -m "$target" 2>/dev/null || true
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp=none \
    --identifier "$BUNDLE_ID" \
    --sign - \
    "$target" >/dev/null
}

# iCloud Desktop & Documents stamps xattrs on .app bundles under these folders.
# Detect by path: reading parent xattrs is often EPERM.
under_icloud_docs() {
  case "$1" in
    */Documents|*/Documents/*|*/Desktop|*/Desktop/*) return 0 ;;
    *) return 1 ;;
  esac
}

LAUNCH_BUNDLE="$APP_BUNDLE"
if under_icloud_docs "$DIST_DIR" || ! sign_bundle "$APP_BUNDLE" 2>/dev/null; then
  CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/Library/Caches}/$BUNDLE_ID"
  LAUNCH_BUNDLE="$CACHE_ROOT/$APP_NAME.app"
  mkdir -p "$CACHE_ROOT"
  rm -rf "$LAUNCH_BUNDLE"
  /usr/bin/ditto --norsrc --noextattr "$STAGE_BUNDLE" "$LAUNCH_BUNDLE"
  sign_bundle "$LAUNCH_BUNDLE"
  echo "note: dist/ is under Documents/Desktop (iCloud xattrs block codesign); launching $LAUNCH_BUNDLE" >&2
fi
codesign --verify --deep --strict "$LAUNCH_BUNDLE"
APP_BUNDLE="$LAUNCH_BUNDLE"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
