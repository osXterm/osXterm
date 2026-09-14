#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_configuration="${OSXTERM_BUILD_CONFIGURATION:-release}"
app_dir="$project_dir/.build/app/osXterm.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$project_dir"
bin_dir="$(swift build --configuration "$build_configuration" --show-bin-path)"
swift build --configuration "$build_configuration"

if [[ -e "$app_dir" ]]; then
    rm -rf "$app_dir"
fi
mkdir -p "$macos_dir" "$resources_dir"

install -m 755 "$bin_dir/osXterm" "$macos_dir/osXterm"
install -m 755 "$bin_dir/osXtermAskPass" "$macos_dir/osXtermAskPass"
install -m 755 "$bin_dir/osXtermProxy" "$macos_dir/osXtermProxy"
install -m 644 "$project_dir/Packaging/Info.plist" "$contents_dir/Info.plist"
install -m 644 "$project_dir/Packaging/AppIcon.icns" "$resources_dir/AppIcon.icns"
install -m 644 "$project_dir/LICENSE" "$resources_dir/LICENSE.txt"
install -m 644 "$project_dir/THIRD_PARTY_NOTICES.md" "$resources_dir/THIRD_PARTY_NOTICES.md"

find "$bin_dir" -maxdepth 1 -type d -name '*.bundle' -print0 | while IFS= read -r -d '' bundle; do
    cp -R "$bundle" "$resources_dir/"
done

if [[ -f "$project_dir/.build/checkouts/SwiftTerm/LICENSE" ]]; then
    mkdir -p "$resources_dir/THIRD_PARTY_NOTICES"
    install -m 644 "$project_dir/.build/checkouts/SwiftTerm/LICENSE" "$resources_dir/THIRD_PARTY_NOTICES/SwiftTerm-LICENSE.txt"
fi

codesign --force --sign - "$macos_dir/osXtermAskPass"
codesign --force --sign - "$macos_dir/osXtermProxy"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
plutil -lint "$contents_dir/Info.plist"
if ! lipo -archs "$macos_dir/osXterm" | tr ' ' '\n' | grep -Fx arm64 >/dev/null; then
    echo "Release packaging requires an arm64 osXterm executable." >&2
    exit 1
fi
echo "Packaged app: $app_dir"
