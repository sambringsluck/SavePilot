#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
build_dir="$project_dir/.build"
app_dir="$project_dir/dist/SavePilot.app"
contents_dir="$app_dir/Contents"

cd "$project_dir"
swift build -c "$configuration"

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$build_dir/$configuration/SavePilot" "$contents_dir/MacOS/SavePilot"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
chmod +x "$contents_dir/MacOS/SavePilot"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
