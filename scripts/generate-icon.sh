#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clipdiary-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/clipdiary-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$ROOT/scripts/generate-icon.swift" "$WORK/AppIcon.iconset"
/usr/bin/iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
printf 'Generated %s\n' "$ROOT/Resources/AppIcon.icns"
