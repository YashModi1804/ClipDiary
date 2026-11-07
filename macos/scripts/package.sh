#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="$(cd "$ROOT/.." && pwd)"
"$ROOT/scripts/build.sh"
ARCH="$(uname -m)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ARCHIVE="$REPOSITORY/dist/ClipDiary-$VERSION-$ARCH.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$REPOSITORY/dist/ClipDiary.app" "$ARCHIVE"
printf 'Packaged %s\n' "$ARCHIVE"
