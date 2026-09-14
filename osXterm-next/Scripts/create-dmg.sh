#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-0.1.0}"
app_dir="$project_dir/.build/app/osXterm.app"
stage_dir="$project_dir/.build/dmg-stage"
output_dir="$project_dir/dist"
output_file="$output_dir/osXterm-$version-arm64.dmg"

"$project_dir/Scripts/package-app.sh"

if [[ -e "$stage_dir" ]]; then
    rm -rf "$stage_dir"
fi
mkdir -p "$stage_dir" "$output_dir"
cp -R "$app_dir" "$stage_dir/osXterm.app"
ln -s /Applications "$stage_dir/Applications"

if [[ -e "$output_file" ]]; then
    rm -f "$output_file"
fi
hdiutil create \
    -volname "osXterm" \
    -srcfolder "$stage_dir" \
    -format UDZO \
    -ov \
    "$output_file"

codesign --verify --deep --strict "$app_dir"
echo "Created DMG: $output_file"
