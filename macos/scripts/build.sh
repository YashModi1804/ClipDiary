#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="$(cd "$ROOT/.." && pwd)"
command -v swift >/dev/null || { echo 'Swift is required. Install Apple Command Line Tools.' >&2; exit 1; }
command -v codesign >/dev/null || { echo 'Apple codesign is required.' >&2; exit 1; }
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clipdiary-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
CACHE_PATH="${TMPDIR:-/tmp}/clipdiary-swiftpm-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$CACHE_PATH"
swift build --package-path "$ROOT" --cache-path "$CACHE_PATH" --disable-sandbox --configuration release --product ClipDiary
BIN_DIR="$(swift build --package-path "$ROOT" --cache-path "$CACHE_PATH" --disable-sandbox --configuration release --show-bin-path)"
mkdir -p "$REPOSITORY/dist"
STAGING="$(mktemp -d "$REPOSITORY/dist/.bundle.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/ClipDiary.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClipDiary" "$APP/Contents/MacOS/ClipDiary"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
rm -rf "$REPOSITORY/dist/ClipDiary.app"
mv "$APP" "$REPOSITORY/dist/ClipDiary.app"
printf 'Built %s\n' "$REPOSITORY/dist/ClipDiary.app"
