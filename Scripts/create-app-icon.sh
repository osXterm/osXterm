#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_IMAGE="${1:-$PROJECT_DIR/Packaging/osXterm-source.png}"
OUTPUT_ICON="$PROJECT_DIR/Packaging/osXterm.icns"
WORK_DIR="$(mktemp -d /private/tmp/osxterm-icon.XXXXXX)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

[[ -f "$SOURCE_IMAGE" ]] || {
    printf 'Icon source image is missing: %s\n' "$SOURCE_IMAGE" >&2
    exit 1
}

for size in 16 32 128 256 512 1024; do
    sips -z "$size" "$size" -s format tiff \
        --out "$WORK_DIR/icon-$size.tiff" \
        "$SOURCE_IMAGE" >/dev/null
done

tiffutil -catnosizecheck \
    "$WORK_DIR/icon-16.tiff" \
    "$WORK_DIR/icon-32.tiff" \
    "$WORK_DIR/icon-128.tiff" \
    "$WORK_DIR/icon-256.tiff" \
    "$WORK_DIR/icon-512.tiff" \
    "$WORK_DIR/icon-1024.tiff" \
    -out "$WORK_DIR/osxterm-icons.tiff" >/dev/null

/usr/bin/tiff2icns "$WORK_DIR/osxterm-icons.tiff" "$OUTPUT_ICON"
printf 'Created app icon: %s\n' "$OUTPUT_ICON"
