#!/bin/bash
set -euo pipefail

for name in MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD \
  APPLE_API_KEY_P8_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID GITHUB_ENV; do
  if [[ -z "${!name:-}" ]]; then
    echo "Required signing configuration is missing: $name" >&2
    exit 1
  fi
done

umask 077
mkdir -p .tmp
keychain="$PWD/.tmp/tartelet-signing.keychain-db"
if [[ -e "$keychain" ]]; then
  echo "Signing keychain already exists: $keychain" >&2
  exit 1
fi
credentials_dir=$(mktemp -d "$PWD/.tmp/signing.XXXXXX")
created_keychain=false
keep_keychain=false
cleanup() {
  result=$?
  trap - EXIT
  rm -rf "$credentials_dir"
  if [[ "$created_keychain" == true && "$keep_keychain" == false ]]; then
    security delete-keychain "$keychain"
  fi
  exit "$result"
}
trap cleanup EXIT

printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$credentials_dir/certificate.p12"
printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$credentials_dir/notary.p8"
keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
created_keychain=true
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$credentials_dir/certificate.p12" -k "$keychain" \
  -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$keychain_password" "$keychain" > /dev/null
identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2; exit}')
if [[ ! "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo 'No valid Developer ID Application identity was found in the signing certificate' >&2
  exit 1
fi

profile=tartelet-release
xcrun notarytool store-credentials "$profile" --keychain "$keychain" \
  --key "$credentials_dir/notary.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID"
printf 'TARTELET_SIGN_IDENTITY=%s\nTARTELET_SIGNING_KEYCHAIN=%s\nTARTELET_NOTARY_PROFILE=%s\n' \
  "$identity" "$keychain" "$profile" >> "$GITHUB_ENV"
keep_keychain=true
