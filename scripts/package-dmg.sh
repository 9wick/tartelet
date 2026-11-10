#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 APP_PATH TAG OUTPUT_DIRECTORY" >&2
  exit 1
fi
app_path="$1"
tag="$2"
output_dir="$3"
if [[ ! "$tag" =~ ^v[0-9A-Za-z][0-9A-Za-z.-]*$ ]]; then
  echo 'The release tag must start with v and contain only letters, numbers, dots, and hyphens' >&2
  exit 1
fi
if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 1
fi
lipo "$app_path/Contents/MacOS/Tartelet" -verify_arch arm64

mkdir -p .tmp "$output_dir"
staging_dir=$(mktemp -d "$PWD/.tmp/dmg.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT

ditto "$app_path" "$staging_dir/Tartelet.app"
codesign --force --deep --sign - "$staging_dir/Tartelet.app"
codesign --verify --deep --strict --verbose=2 "$staging_dir/Tartelet.app"
ln -s /Applications "$staging_dir/Applications"

filename="Tartelet-$tag-arm64.dmg"
hdiutil create -volname "Tartelet $tag" -srcfolder "$staging_dir" \
  -ov -format UDZO "$output_dir/$filename"
hdiutil verify "$output_dir/$filename"
(
  cd "$output_dir"
  shasum -a 256 "$filename" > "$filename.sha256"
)
