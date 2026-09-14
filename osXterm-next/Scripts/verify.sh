#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

"$project_dir/Scripts/verify-font-resources.sh"
swift package resolve
swift test --parallel
"$project_dir/Scripts/run-integration-tests.sh"
"$project_dir/Scripts/package-app.sh"
codesign --verify --deep --strict "$project_dir/.build/app/osXterm.app"
"$project_dir/Scripts/create-dmg.sh"
"$project_dir/Scripts/verify-dmg.sh"
echo "Verification succeeded."
