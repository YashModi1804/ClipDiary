#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_XCTEST=false
if [[ $# -gt 0 ]]; then
    case "$1" in
        --xctest) RUN_XCTEST=true; shift ;;
        --help|-h) echo 'Usage: test.sh [--xctest]'; echo 'Default: standalone core and isolated-pasteboard integration checks. --xctest additionally requires XCTest/full Xcode.'; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
fi
[[ $# -eq 0 ]] || { echo 'Too many arguments.' >&2; exit 2; }
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clipdiary-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
CACHE_PATH="${TMPDIR:-/tmp}/clipdiary-swiftpm-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$CACHE_PATH"
swift run --package-path "$ROOT" --cache-path "$CACHE_PATH" --disable-sandbox ClipDiaryCoreChecks
swift build --package-path "$ROOT" --cache-path "$CACHE_PATH" --disable-sandbox --product ClipDiary
BIN_DIR="$(swift build --package-path "$ROOT" --cache-path "$CACHE_PATH" --disable-sandbox --show-bin-path)"
"$BIN_DIR/ClipDiary" --integration-test
if $RUN_XCTEST; then
    swift test --package-path "$ROOT" --cache-path "$CACHE_PATH" --disable-sandbox
fi
