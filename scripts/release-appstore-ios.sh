#!/usr/bin/env zsh
# Release pipeline for the iOS App Store / TestFlight.
#
# Produces a signed, validated .ipa under build/release/ios/ and (if
# APP_STORE_PWD is set) uploads it to App Store Connect. After upload,
# Apple's processing takes ~30 min before the build appears in TestFlight
# and the App Store Connect submission UI.
#
# Prerequisites (one-time on the build machine):
#   1. "Apple Distribution: Web Performance Incorporated (266QZGP4BG)"
#      certificate present in login Keychain.
#   2. iOS App ID `org.czei.paperlessclipper2.ios` registered in the
#      Apple Developer portal with App Groups + Keychain Sharing
#      capabilities, assigned to App Group `group.org.czei.PaperlessClipper`.
#      Same for `org.czei.paperlessclipper2.ios.extension`.
#   3. App Store Connect record created for `org.czei.paperlessclipper2.ios`
#      at appstoreconnect.apple.com.
#   4. App-specific password exported as APP_STORE_PWD env var (the same
#      kind you created for notarization, but altool reads it from env
#      directly because keychain-profile doesn't apply here):
#        export APP_STORE_PWD='xxxx-xxxx-xxxx-xxxx'
#      Optional: APPLE_ID env var, defaults to michael@czei.org.
#   5. xcodegen on PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

TEAM_ID="266QZGP4BG"
SCHEME="PaperlessClipper-iOS"
PRODUCT_NAME="PaperlessClipper"
CONFIGURATION="Release"
APPLE_ID="${APPLE_ID:-michael@czei.org}"

VERSION="$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [[ -z "${VERSION}" ]]; then
  echo "Could not parse MARKETING_VERSION from project.yml" >&2
  exit 1
fi

BUILD_DIR="${REPO_ROOT}/build/release/ios"
ARCHIVE_PATH="${BUILD_DIR}/${PRODUCT_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

echo "==> Cleaning previous build artifacts"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Bumping CURRENT_PROJECT_VERSION (App Store Connect requires unique build numbers)"
# Strategy: read current value, increment, write back. Format is "X" not "X.Y".
CURRENT_BUILD="$(grep -E '^\s*CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
NEXT_BUILD=$((CURRENT_BUILD + 1))
sed -i.bak "s/CURRENT_PROJECT_VERSION: \"${CURRENT_BUILD}\"/CURRENT_PROJECT_VERSION: \"${NEXT_BUILD}\"/" project.yml
rm -f project.yml.bak
echo "    Build ${CURRENT_BUILD} -> ${NEXT_BUILD}"

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Writing ExportOptions.plist (app-store-connect distribution)"
cat > "${EXPORT_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>destination</key>
  <string>export</string>
  <key>uploadSymbols</key>
  <true/>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
EOF

echo "==> Archiving (${SCHEME}, ${CONFIGURATION})"
xcodebuild archive \
  -project "${PRODUCT_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "generic/platform=iOS" \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic

echo "==> Exporting Apple-Distribution-signed IPA"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

IPA_PATH="$(find "${EXPORT_DIR}" -name '*.ipa' -maxdepth 1 | head -1)"
if [[ -z "${IPA_PATH}" || ! -f "${IPA_PATH}" ]]; then
  echo "Export did not produce an .ipa in ${EXPORT_DIR}" >&2
  exit 1
fi
echo "==> IPA at ${IPA_PATH}"

if [[ -z "${APP_STORE_PWD:-}" ]]; then
  echo
  echo "ℹ️  APP_STORE_PWD not set — skipping upload. To upload:"
  echo "    APP_STORE_PWD='xxxx-xxxx-xxxx-xxxx' $0"
  echo "    or upload via Xcode Organizer (Window → Organizer)"
  echo "    or use Transporter.app (free, on the Mac App Store)"
  exit 0
fi

echo "==> Validating with App Store Connect"
xcrun altool --validate-app \
  --type ios \
  --file "${IPA_PATH}" \
  --username "${APPLE_ID}" \
  --password "${APP_STORE_PWD}"

echo "==> Uploading to App Store Connect (build ${NEXT_BUILD})"
xcrun altool --upload-app \
  --type ios \
  --file "${IPA_PATH}" \
  --username "${APPLE_ID}" \
  --password "${APP_STORE_PWD}"

echo
echo "✅ Uploaded build ${NEXT_BUILD} of v${VERSION} to App Store Connect."
echo "   Apple processing takes ~30 min. Watch:"
echo "   https://appstoreconnect.apple.com/apps"
echo
echo "Next: fill in metadata + screenshots in App Store Connect, then submit for review (or add to TestFlight)."
