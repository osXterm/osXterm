#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$PROJECT_DIR/Vendor/GhosttyVt"

# A checked-out Git submodule is the normal source location. Set GHOSTTY_SOURCE
# to the supplied local Ghostty checkout when bootstrapping the submodule.
GHOSTTY_SOURCE="${GHOSTTY_SOURCE:-$PROJECT_DIR/Vendor/ghostty-source}"
GHOSTTY_ZIG="${GHOSTTY_ZIG:-$PROJECT_DIR/Tools/zig-0.16.0/zig}"
CACHE_ROOT="${OSXTERM_GHOSTTY_CACHE_DIR:-$PROJECT_DIR/.build/ghostty-vt-cache}"

# shellcheck source=/dev/null
source "$VENDOR_DIR/Ghostty.lock"

fail() {
    printf 'Ghostty VT build error: %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required to build this artifact"
[[ -d "$GHOSTTY_SOURCE" ]] || fail "Ghostty source is missing: $GHOSTTY_SOURCE"
[[ -x "$GHOSTTY_ZIG" ]] || fail "Zig executable is missing: $GHOSTTY_ZIG"

actual_commit="$(git -C "$GHOSTTY_SOURCE" rev-parse HEAD 2>/dev/null)" || \
    fail "Ghostty source must be a Git checkout"
[[ "$actual_commit" == "$GHOSTTY_COMMIT" ]] || \
    fail "Ghostty commit mismatch: expected $GHOSTTY_COMMIT, got $actual_commit"

origin_url="$(git -C "$GHOSTTY_SOURCE" config --get remote.origin.url 2>/dev/null || true)"
case "$origin_url" in
    https://github.com/ghostty-org/ghostty|https://github.com/ghostty-org/ghostty.git|\
    git@github.com:ghostty-org/ghostty.git|ssh://git@github.com/ghostty-org/ghostty.git)
        ;;
    *)
        fail "Ghostty origin mismatch: expected $GHOSTTY_SOURCE_URL, got ${origin_url:-<none>}"
        ;;
esac

actual_zig_version="$($GHOSTTY_ZIG version)"
[[ "$actual_zig_version" == "$GHOSTTY_ZIG_VERSION" ]] || \
    fail "Zig version mismatch: expected $GHOSTTY_ZIG_VERSION, got $actual_zig_version"

host_arch="$(uname -m)"
case "$host_arch" in
    arm64|x86_64)
        ;;
    *)
        fail "Unsupported macOS architecture: $host_arch"
        ;;
esac

artifact_dir="$VENDOR_DIR/Artifacts/$GHOSTTY_COMMIT/$host_arch-macos"
build_prefix="$CACHE_ROOT/install/$GHOSTTY_COMMIT/$host_arch-macos"
zig_dir="$(cd "$(dirname "$GHOSTTY_ZIG")" && pwd)"

mkdir -p "$CACHE_ROOT/local" "$CACHE_ROOT/global" "$artifact_dir/lib" "$artifact_dir/include"
# Older local builds wrote a second module map next to the raw Ghostty
# headers. The SwiftPM target owns the only GhosttyVt module map now.
rm -f "$artifact_dir/include/module.modulemap"

# Ghostty's build scripts invoke `zig env`, so the selected Zig binary must
# also be on PATH rather than only called through an absolute path.
export PATH="$zig_dir:$PATH"
export ZIG_LOCAL_CACHE_DIR="$CACHE_ROOT/local"
export ZIG_GLOBAL_CACHE_DIR="$CACHE_ROOT/global"

sdk_path="$(xcrun --sdk macosx --show-sdk-path)" || fail "macOS SDK is unavailable"
export SDKROOT="${SDKROOT:-$sdk_path}"

(
    cd "$GHOSTTY_SOURCE"
    "$GHOSTTY_ZIG" build \
        -Demit-lib-vt=true \
        -Demit-xcframework=false \
        -Demit-macos-app=false \
        -Doptimize=ReleaseSafe \
        -Dlib-version-string="$GHOSTTY_LIB_VERSION" \
        -p "$build_prefix" \
        --cache-dir "$CACHE_ROOT/local" \
        --global-cache-dir "$CACHE_ROOT/global"
)

static_library="$build_prefix/lib/libghostty-vt.a"
headers_dir="$build_prefix/include/ghostty"
[[ -f "$static_library" ]] || fail "Ghostty did not create libghostty-vt.a"
[[ -f "$headers_dir/vt.h" ]] || fail "Ghostty did not install its public C headers"

# Keep only the static library in the project artifact. This prevents the app
# from acquiring an unbundled dylib dependency at launch.
install -m 0644 "$static_library" "$artifact_dir/lib/libghostty-vt.a"
ditto "$headers_dir" "$artifact_dir/include/ghostty"
install -m 0644 "$VENDOR_DIR/LICENSE" "$artifact_dir/LICENSE.Ghostty.txt"
install -m 0644 "$VENDOR_DIR/Ghostty.lock" "$artifact_dir/Ghostty.lock"

lipo "$artifact_dir/lib/libghostty-vt.a" -verify_arch "$host_arch"
nm -gU "$artifact_dir/lib/libghostty-vt.a" | grep ' _ghostty_terminal_new$' >/dev/null || \
    fail "Ghostty terminal constructor symbol is missing"

printf 'Built Ghostty VT static artifact: %s\n' "$artifact_dir"
