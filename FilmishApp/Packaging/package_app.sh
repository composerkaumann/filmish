#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
app_dir="$project_dir/dist/Filmish.app"
project_file="$project_dir/Filmish.xcodeproj"
derived_data="$project_dir/.build/xcode"
built_app="$derived_data/Build/Products/Release/Filmish.app"

[[ -d $project_file ]] || {
    printf 'ERROR: Xcode project was not found: %s\n' "$project_file" >&2
    exit 1
}

xcodebuild \
    -project "$project_file" \
    -scheme Filmish \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build

[[ -d $built_app ]] || {
    printf 'ERROR: Xcode did not create the expected app: %s\n' "$built_app" >&2
    exit 1
}

rm -rf -- "$app_dir"
mkdir -p "$project_dir/dist"
ditto "$built_app" "$app_dir"
chmod 755 "$app_dir/Contents/Resources/filmish.sh"

/usr/bin/codesign --force --deep --sign - "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
