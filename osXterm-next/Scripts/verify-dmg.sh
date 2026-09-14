#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-0.1.0}"
dmg_path="$project_dir/dist/osXterm-$version-arm64.dmg"
mount_dir="$(mktemp -d /private/tmp/osxterm-next-dmg.XXXXXX)"
copy_dir="$(mktemp -d /private/tmp/osxterm-next-install.XXXXXX)"

cleanup() {
    if mount | grep -F "on $mount_dir " >/dev/null 2>&1; then
        hdiutil detach "$mount_dir" -quiet || true
    fi
    rm -rf "$mount_dir" "$copy_dir"
}
trap cleanup EXIT

if [[ ! -f "$dmg_path" ]]; then
    echo "DMG is missing: $dmg_path" >&2
    exit 2
fi

hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null
if [[ ! -d "$mount_dir/osXterm.app" ]]; then
    echo "Mounted DMG does not contain osXterm.app." >&2
    exit 1
fi

ditto "$mount_dir/osXterm.app" "$copy_dir/osXterm.app"
installed_app="$copy_dir/osXterm.app"

codesign --verify --deep --strict "$installed_app"
plutil -lint "$installed_app/Contents/Info.plist"
for executable in osXterm osXtermAskPass osXtermProxy; do
    test -x "$installed_app/Contents/MacOS/$executable"
done

if ! lipo -archs "$installed_app/Contents/MacOS/osXterm" | tr ' ' '\n' | grep -Fx arm64 >/dev/null; then
    echo "The extracted app is missing an arm64 main executable." >&2
    exit 1
fi

for bundled_resource in \
    D2Coding-Regular.ttf \
    D2Coding-Bold.ttf \
    JetBrainsMono-Regular.ttf \
    JetBrainsMono-Bold.ttf \
    FiraCode-Regular.ttf \
    FiraCode-Bold.ttf \
    Hack-Regular.ttf \
    Hack-Bold.ttf \
    D2Coding-OFL-1.1.txt \
    JetBrainsMono-OFL-1.1.txt \
    FiraCode-OFL-1.1.txt \
    Hack-LICENSE.md; do
    if ! find "$installed_app/Contents/Resources" -type f -name "$bundled_resource" -print -quit | grep -q .; then
        echo "The extracted app is missing bundled terminal resource: $bundled_resource" >&2
        exit 1
    fi
done

if [[ "${OSXTERM_VERIFY_PACKAGE_INTEGRATION:-1}" == "1" ]]; then
    OSXTERM_PROXY_HELPER="$installed_app/Contents/MacOS/osXtermProxy" \
    OSXTERM_ASKPASS_HELPER="$installed_app/Contents/MacOS/osXtermAskPass" \
    "$project_dir/Scripts/run-integration-tests.sh"
fi

echo "Verified extracted app at $installed_app before cleanup."
