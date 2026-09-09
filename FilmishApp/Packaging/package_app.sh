#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
workspace_dir=$(cd "$project_dir/.." && pwd)
app_dir="$project_dir/dist/Filmish.app"
icon_source="$project_dir/Assets/AppIcon.png"
icon_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/filmish_icon.XXXXXXXX")
iconset_dir="$icon_work_dir/AppIcon.iconset"

cleanup() {
    rm -rf -- "$icon_work_dir"
}
trap cleanup EXIT HUP INT TERM

[[ -f $icon_source ]] || {
    printf 'ERROR: App icon source was not found: %s\n' "$icon_source" >&2
    exit 1
}

swift build --package-path "$project_dir" -c release

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
mkdir -p "$iconset_dir"

sips -z 16 16 "$icon_source" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_source" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_512x512.png" >/dev/null
cp "$icon_source" "$iconset_dir/icon_512x512@2x.png"
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"

cp "$project_dir/.build/release/Filmish" "$app_dir/Contents/MacOS/Filmish"
cp "$project_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
cp "$workspace_dir/filmish.sh" "$app_dir/Contents/Resources/filmish.sh"
chmod 755 "$app_dir/Contents/MacOS/Filmish" "$app_dir/Contents/Resources/filmish.sh"

/usr/bin/codesign --force --deep --sign - "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
