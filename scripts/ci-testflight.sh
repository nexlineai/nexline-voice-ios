#!/usr/bin/env bash
# Signed archive -> App Store Connect (TestFlight, internal testers only).
# Runs only in the approval-gated `testflight` environment. Signing is cloud-managed: with the App Store
# Connect API key, xcodebuild creates or fetches the certificate and profiles itself.
# Run `xcodegen generate` first.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_P8_BASE64:?}" "${APPLE_TEAM_ID:?}" "${BUILD_NUMBER:?}"
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "::error::APPLE_TEAM_ID is not a 10-character Team ID"; exit 1; }

keydir="$(mktemp -d)"
trap 'rm -rf "$keydir"' EXIT
key="$keydir/AuthKey_$ASC_KEY_ID.p8"
printf '%s' "$ASC_KEY_P8_BASE64" | base64 --decode > "$key"
grep -q "BEGIN PRIVATE KEY" "$key" || { echo "::error::ASC_KEY_P8_BASE64 does not decode to a .p8 key"; exit 1; }
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

mkdir -p build
sed "s/__TEAM_ID__/$APPLE_TEAM_ID/" ExportOptions.plist > build/ExportOptions.plist

run() {
  local log=$1; shift
  set +e
  "$@" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  scripts/annotate-errors.sh "$log"
  return "$status"
}

run build/archive.log xcodebuild archive -project NexlineVoice.xcodeproj -scheme NexlineVoice \
  -configuration Release -destination 'generic/platform=iOS' -archivePath build/NexlineVoice.xcarchive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${auth[@]}"

# destination=upload in ExportOptions sends the build straight to App Store Connect.
run build/export.log xcodebuild -exportArchive -archivePath build/NexlineVoice.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export "${auth[@]}"

echo "Uploaded build $BUILD_NUMBER. App Store Connect processes it before TestFlight lists it."
