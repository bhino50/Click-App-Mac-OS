#!/usr/bin/env bash
#
# Build, sign, notarize, and package Click for distribution.
#
# Prerequisites (one-time per machine):
#   - Apple Developer ID Application certificate installed in your login keychain.
#   - `xcrun notarytool store-credentials "AC_NOTARY"
#       --apple-id "<your Apple ID>"
#       --team-id "<TEAMID>"
#       --password "<app-specific password>"`
#
# Usage:
#   ./scripts/release.sh                              # uses default identity
#   DEV_ID="Developer ID Application: Name (TEAMID)"  # override
#       ./scripts/release.sh
#
# Output:
#   build/Click.app                  notarized + stapled
#   build/Click.dmg                  notarized + stapled
#
set -euo pipefail

cd "$(dirname "$0")/.."

DEV_ID="${DEV_ID:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/Click.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Click.app"
DMG="$BUILD_DIR/Click.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving"
xcodebuild \
  -project Click.xcodeproj \
  -scheme Click \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  archive

cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF

echo "==> Exporting signed .app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" || true

echo "==> Building DMG"
TMP_DMG_DIR="$(mktemp -d)"
cp -R "$APP" "$TMP_DMG_DIR/Click.app"
ln -s /Applications "$TMP_DMG_DIR/Applications"
hdiutil create -volname Click -srcfolder "$TMP_DMG_DIR" -ov -format UDZO "$DMG"
rm -rf "$TMP_DMG_DIR"

echo "==> Signing DMG"
codesign --sign "$DEV_ID" --timestamp "$DMG"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

echo "==> Done."
echo "    Notarized app: $APP"
echo "    Notarized DMG: $DMG"
