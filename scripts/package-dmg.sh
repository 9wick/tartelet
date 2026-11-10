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
for name in TARTELET_SIGN_IDENTITY TARTELET_SIGNING_KEYCHAIN TARTELET_NOTARY_PROFILE; do
  if [[ -z "${!name:-}" ]]; then
    echo "Required signing configuration is missing: $name" >&2
    exit 1
  fi
done
if [[ "$TARTELET_SIGN_IDENTITY" == '-' ]]; then
  echo 'Ad-hoc signing cannot be used for a notarized release' >&2
  exit 1
fi
if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 1
fi
lipo "$app_path/Contents/MacOS/Tartelet" -verify_arch arm64

mkdir -p .tmp "$output_dir"
work_dir=$(mktemp -d "$PWD/.tmp/dmg.XXXXXX")
mount_point="$work_dir/mounted"
mounted=false
cleanup() {
  result=$?
  trap - EXIT
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$mount_point"
  fi
  rm -rf "$work_dir"
  exit "$result"
}
trap cleanup EXIT

notarize() {
  local archive="$1" target="$2" label="$3"
  local response="$work_dir/$label-notary.json"
  local submission_result=0
  xcrun notarytool submit "$archive" \
    --keychain-profile "$TARTELET_NOTARY_PROFILE" --keychain "$TARTELET_SIGNING_KEYCHAIN" \
    --wait --timeout 20m --output-format json > "$response" || submission_result=$?
  cat "$response"
  if [[ "$submission_result" -ne 0 ]] || [[ "$(jq -er '.status' "$response")" != Accepted ]]; then
    if jq -e '.status == "Invalid" and (.id | type == "string")' "$response" > /dev/null; then
      xcrun notarytool log "$(jq -er '.id' "$response")" \
        --keychain-profile "$TARTELET_NOTARY_PROFILE" --keychain "$TARTELET_SIGNING_KEYCHAIN" \
        "$work_dir/$label-notary-log.json"
      cat "$work_dir/$label-notary-log.json"
    fi
    echo "Notarization did not succeed for $label" >&2
    exit 1
  fi
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}

sign_code() {
  codesign --force --sign "$TARTELET_SIGN_IDENTITY" --keychain "$TARTELET_SIGNING_KEYCHAIN" \
    --options runtime --timestamp "$1"
}

payload="$work_dir/payload"
app="$payload/Tartelet.app"
mkdir -p "$payload" "$mount_point"
ditto "$app_path" "$app"
# Sign executable files and nested code containers before sealing the outer app.
while IFS= read -r -d '' path; do
  if [[ "$(file -b "$path")" == *Mach-O* ]]; then
    sign_code "$path"
  fi
done < <(find "$app" -type f -print0)
while IFS= read -r -d '' path; do
  sign_code "$path"
done < <(find "$app" -depth -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \) -print0)
codesign --verify --deep --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$work_dir/Tartelet.zip"
notarize "$work_dir/Tartelet.zip" "$app" app
spctl --assess --type execute --verbose=4 "$app"
ln -s /Applications "$payload/Applications"

filename="Tartelet-$tag-arm64.dmg"
dmg="$output_dir/$filename"
hdiutil create -volname "Tartelet $tag" -srcfolder "$payload" -ov -format UDZO "$dmg"
codesign --force --sign "$TARTELET_SIGN_IDENTITY" --keychain "$TARTELET_SIGNING_KEYCHAIN" \
  --timestamp "$dmg"
notarize "$dmg" "$dmg" dmg
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
hdiutil verify "$dmg"

hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$dmg"
mounted=true
codesign --verify --deep --strict --verbose=2 "$mount_point/Tartelet.app"
xcrun stapler validate "$mount_point/Tartelet.app"
spctl --assess --type execute --verbose=4 "$mount_point/Tartelet.app"
hdiutil detach "$mount_point"
mounted=false
(
  cd "$output_dir"
  shasum -a 256 "$filename" > "$filename.sha256"
)
