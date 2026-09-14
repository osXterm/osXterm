#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
swift_compiler="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_path="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
temporary_directory="$(mktemp -d "${TMPDIR:-/private/tmp}/osxterm-next-font-check.XXXXXX")"

cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

if [[ ! -x "$swift_compiler" || ! -d "$sdk_path" ]]; then
    echo "Xcode compiler and macOS SDK are required to verify bundled fonts." >&2
    exit 2
fi

while IFS=' ' read -r expected_hash font_name; do
    font_path="$project_dir/Sources/OsXtermApp/Resources/Fonts/$font_name"
    if [[ ! -f "$font_path" ]]; then
        echo "Missing bundled terminal font: $font_name" >&2
        exit 1
    fi
    actual_hash="$(shasum -a 256 "$font_path" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "Unexpected bundled terminal font hash: $font_name" >&2
        exit 1
    fi
done <<'EOF'
c064f343b5cfc131f083377ba606b748f9b61a5bbd89708e4010b9066dff5a24 D2Coding-Regular.ttf
770afd3304d03924a05744335315f9dbb51f30870a3e24b05ffba9abd2f9400f D2Coding-Bold.ttf
a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f JetBrainsMono-Regular.ttf
5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb JetBrainsMono-Bold.ttf
5992ab9640e2df491b2f609467b1de60e8bc39b2c28db184342a0592d98f6117 FiraCode-Regular.ttf
41f6554e845e2f5b70adad3950122334b866aac436793b7742ade600067701be FiraCode-Bold.ttf
15f55cc0c85a2988d2b4b3a8cdb5d77fdfbaf319e1bb5309d725db9818fb7125 Hack-Regular.ttf
5bbf531eff7f8a0c2559c9a0656718e2828a012a9b1f60b5f54006d59a4de8d4 Hack-Bold.ttf
EOF

for license_file in \
    D2Coding-OFL-1.1.txt \
    JetBrainsMono-OFL-1.1.txt \
    FiraCode-OFL-1.1.txt \
    Hack-LICENSE.md; do
    test -s "$project_dir/Sources/OsXtermApp/Resources/FontLicenses/$license_file"
done

env CLANG_MODULE_CACHE_PATH="$temporary_directory/clang-cache" \
    "$swift_compiler" \
    -target arm64-apple-macosx26.0 \
    -sdk "$sdk_path" \
    -module-cache-path "$temporary_directory/swift-module-cache" \
    "$project_dir/Scripts/VerifyFontResources.swift" \
    -o "$temporary_directory/VerifyFontResources"
"$temporary_directory/VerifyFontResources" "$project_dir"
