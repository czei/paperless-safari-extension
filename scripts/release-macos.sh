#!/usr/bin/env zsh
# One-shot release script for the macOS app + extension.
#
# Produces a notarized, stapled .dmg in build/release/ ready to attach
# to a GitHub Release.
#
# Prerequisites (set up once on the build machine):
#   1. "Developer ID Application: Web Performance Incorporated (266QZGP4BG)"
#      certificate present in login Keychain.
#   2. App-specific password stored under the keychain profile name
#      "PaperlessClipper-notary":
#        xcrun notarytool store-credentials "PaperlessClipper-notary" \
#          --apple-id "<your-apple-id>" --team-id "266QZGP4BG" --password "<app-pw>"
#   3. xcodegen on PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

NOTARY_PROFILE="PaperlessClipper-notary"
TEAM_ID="266QZGP4BG"
SCHEME="PaperlessClipper-macOS"
PRODUCT_NAME="PaperlessClipper"
CONFIGURATION="Release"

VERSION="$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [[ -z "${VERSION}" ]]; then
  echo "Could not parse MARKETING_VERSION from project.yml" >&2
  exit 1
fi

BUILD_DIR="${REPO_ROOT}/build/release"
ARCHIVE_PATH="${BUILD_DIR}/${PRODUCT_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_STAGING="${BUILD_DIR}/dmg-staging"
DMG_PATH="${BUILD_DIR}/${PRODUCT_NAME}-${VERSION}.dmg"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

echo "==> Cleaning previous build artifacts"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Writing ExportOptions.plist (developer-id distribution)"
cat > "${EXPORT_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>destination</key>
  <string>export</string>
</dict>
</plist>
EOF

echo "==> Archiving (${SCHEME}, ${CONFIGURATION})"
xcodebuild archive \
  -project "${PRODUCT_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "generic/platform=macOS" \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  | xcbeautify 2>/dev/null || true

# Re-run without xcbeautify if the previous failed silently
if [[ ! -d "${ARCHIVE_PATH}" ]]; then
  echo "==> Archive missing; re-running xcodebuild without filter"
  xcodebuild archive \
    -project "${PRODUCT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic
fi

echo "==> Exporting Developer ID-signed app"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

APP_PATH="${EXPORT_DIR}/${PRODUCT_NAME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Export did not produce ${APP_PATH}" >&2
  exit 1
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
codesign -dvv "${APP_PATH}" 2>&1 | grep -E "Authority|TeamIdentifier" | head -5

echo "==> Building DMG"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_PATH}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create \
  -volname "${PRODUCT_NAME} ${VERSION}" \
  -srcfolder "${DMG_STAGING}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "==> Signing DMG"
codesign --sign "Developer ID Application: Web Performance Incorporated (${TEAM_ID})" "${DMG_PATH}"

echo "==> Submitting for notarization (this can take 2-15 min)"
xcrun notarytool submit "${DMG_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

echo "==> Stapling ticket"
xcrun stapler staple "${DMG_PATH}"

echo "==> Verifying stapled DMG"
xcrun stapler validate "${DMG_PATH}"
spctl --assess --type install --verbose=4 "${DMG_PATH}" || true

echo
echo "✅ Done. Artifact:"
echo "    ${DMG_PATH}"
echo
echo "Next: gh release create v${VERSION} \"${DMG_PATH}\" --title \"v${VERSION}\" --notes \"…\""
