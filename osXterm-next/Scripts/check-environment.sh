#!/bin/zsh

set -euo pipefail

requires_integration=false

case "${1:-}" in
    "")
        ;;
    --integration)
        requires_integration=true
        ;;
    *)
        echo "Usage: $0 [--integration]" >&2
        exit 64
        ;;
esac

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "osXterm packaging requires an Apple Silicon arm64 Mac." >&2
    exit 2
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        echo "Xcode 26 or later is required at /Applications/Xcode.app." >&2
        exit 2
    fi
fi

if ! /usr/bin/xcodebuild -license check >/dev/null 2>&1; then
    echo "The selected Xcode license has not been accepted." >&2
    echo "The machine owner must run 'sudo xcodebuild -license' before building osXterm." >&2
    exit 3
fi

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
    echo "The selected Xcode developer directory does not provide Swift." >&2
    exit 2
fi

if [[ ! -x /usr/bin/ssh ]]; then
    echo "macOS /usr/bin/ssh is required." >&2
    exit 2
fi

if [[ "$requires_integration" == true ]]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker Compose is required for isolated integration tests." >&2
        exit 4
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo "Docker Compose is required for isolated integration tests." >&2
        exit 4
    fi
fi

if [[ "$requires_integration" == true ]]; then
    echo "Environment preflight passed for build and integration tests."
else
    echo "Environment preflight passed for build and packaging."
fi
