#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="$HOME/Applications"
REPLACE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { echo '--destination requires a directory.' >&2; exit 2; }
            DESTINATION="$2"
            shift 2
            ;;
        --replace) REPLACE=true; shift ;;
        --help|-h)
            echo 'Usage: install.sh [--destination DIRECTORY] [--replace]'
            echo 'Default destination: ~/Applications. Quit ClipDiary before replacement.'
            exit 0
            ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
SOURCE="$ROOT/dist/ClipDiary.app"
[[ -d "$SOURCE" ]] || { echo 'Run scripts/build.sh first.' >&2; exit 1; }
mkdir -p "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"
[[ "$DESTINATION" != "$ROOT/dist" ]] || { echo 'The app is already in dist; choose another destination.' >&2; exit 2; }
TARGET="$DESTINATION/ClipDiary.app"
if [[ -e "$TARGET" ]]; then
    $REPLACE || { echo 'ClipDiary.app exists; use --replace to update it.' >&2; exit 1; }
    if /usr/bin/pgrep -x ClipDiary >/dev/null; then
        echo 'Quit ClipDiary before replacing the installed app.' >&2
        exit 1
    fi
fi
STAGING="$(mktemp -d "$DESTINATION/.clipdiary-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$SOURCE" "$STAGING/ClipDiary.app"
/usr/bin/codesign --verify --strict "$STAGING/ClipDiary.app"
if [[ -e "$TARGET" ]]; then
    mv "$TARGET" "$STAGING/Previous.app"
fi
if ! mv "$STAGING/ClipDiary.app" "$TARGET"; then
    if [[ -d "$STAGING/Previous.app" ]]; then mv "$STAGING/Previous.app" "$TARGET"; fi
    exit 1
fi
printf 'Installed %s\nOpen it once, then enable Start at login in Settings if desired.\n' "$TARGET"
