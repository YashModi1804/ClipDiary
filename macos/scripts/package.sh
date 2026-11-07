#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="$(cd "$ROOT/.." && pwd)"
"$ROOT/scripts/build.sh"
ARCH="$(uname -m)"
ARCHIVE="$REPOSITORY/dist/ClipDiary-1.0.6-$ARCH.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$REPOSITORY/dist/ClipDiary.app" "$ARCHIVE"
printf 'Packaged %s\n' "$ARCHIVE"
