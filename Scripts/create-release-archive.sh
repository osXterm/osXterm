#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-0.1.0}"
APP_DIR="$PROJECT_DIR/.build/app/osXterm.app"
DIST_DIR="$PROJECT_DIR/dist"
ARCHIVE="$DIST_DIR/osXterm-$VERSION.zip"

if [[ ! -d "$APP_DIR" ]]; then
    "$PROJECT_DIR/Scripts/package-app.sh"
fi

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"

printf 'Release archive: %s\n' "$ARCHIVE"
shasum -a 256 "$ARCHIVE"
