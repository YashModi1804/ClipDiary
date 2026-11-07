#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"
ARCH="$(uname -m)"
ARCHIVE="$ROOT/dist/ClipDiary-1.0.6-$ARCH.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/ClipDiary.app" "$ARCHIVE"
printf 'Packaged %s\n' "$ARCHIVE"
