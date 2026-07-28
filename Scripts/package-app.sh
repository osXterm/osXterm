#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_PATH="${OSXTERM_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
CLANG_CACHE="${OSXTERM_CLANG_CACHE:-/private/tmp/osxterm-clang-cache}"
SWIFTPM_CACHE="${OSXTERM_SWIFTPM_CACHE:-/private/tmp/osxterm-swiftpm-cache}"
APP_DIR="$PROJECT_DIR/.build/app/osXterm.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

env \
    SDKROOT="$SDK_PATH" \
    CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
    swift build --package-path "$PROJECT_DIR" --disable-sandbox

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PROJECT_DIR/.build/debug/osXterm" "$MACOS_DIR/osXterm"
cp "$PROJECT_DIR/.build/debug/osXtermAskPass" "$MACOS_DIR/osXtermAskPass"
cp "$PROJECT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod 755 "$MACOS_DIR/osXterm" "$MACOS_DIR/osXtermAskPass"

codesign --force --sign - "$MACOS_DIR/osXtermAskPass"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$CONTENTS_DIR/Info.plist"

printf 'Packaged app: %s\n' "$APP_DIR"
