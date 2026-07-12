#!/usr/bin/env bash
#
# Build and verify the Mac App Store variant of Click (MAS_BUILD).
#
# The MAS variant is sandboxed, uses Input Monitoring, and contains no
# self-updater or website references. Updates ship through the App Store.
#
# Modes:
#   ./scripts/build_mas.sh            # smoke: ad hoc signed, full verification
#   ./scripts/build_mas.sh store      # signed .pkg ready for Transporter
#
# store mode requires:
#   SIGN_ID="Apple Distribution: Brandon Hinojosa (VJPMCBH6NX)"
#   INSTALLER_ID="3rd Party Mac Developer Installer: Brandon Hinojosa (VJPMCBH6NX)"
#   PROFILE=path/to/ClickMAS.provisionprofile
#
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-smoke}"
BUILD_DIR="build/MAS"
APP="$BUILD_DIR/Build/Products/Release/Click.app"
PKG="build/Click-MAS.pkg"
ENTITLEMENTS="Click/Click.AppStore.entitlements"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

if [ "$MODE" = "store" ]; then
  : "${SIGN_ID:?store mode needs SIGN_ID=\"Apple Distribution: ...\"}"
  : "${INSTALLER_ID:?store mode needs INSTALLER_ID=\"3rd Party Mac Developer Installer: ...\"}"
  : "${PROFILE:?store mode needs PROFILE=path/to/ClickMAS.provisionprofile}"
fi

fail() { echo "FAIL: $1" >&2; exit 1; }

rm -rf "$BUILD_DIR"

echo "==> Building MAS variant ($MODE)"
# Ad hoc identity for the build; store mode re-signs below after embedding
# the provisioning profile. CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps
# get-task-allow out so the entitlements file stays authoritative.
xcodebuild \
  -project Click.xcodeproj \
  -scheme Click \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  OTHER_SWIFT_FLAGS='$(inherited) -DMAS_BUILD' \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_USER_SELECTED_FILES=readonly \
  INFOPLIST_KEY_LSApplicationCategoryType=public.app-category.utilities \
  INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO \
  CODE_SIGN_IDENTITY="-" \
  build

if [ "$MODE" = "store" ]; then
  echo "==> Embedding provisioning profile and signing for distribution"
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  # App Store / TestFlight require the application identifier signed into
  # the bundle, matching the provisioning profile (upload warning 90886).
  STORE_ENTS="$BUILD_DIR/entitlements-store.plist"
  cp "$ENTITLEMENTS" "$STORE_ENTS"
  /usr/libexec/PlistBuddy -c \
    "Add :com.apple.application-identifier string VJPMCBH6NX.brandon.Click" "$STORE_ENTS"
  /usr/libexec/PlistBuddy -c \
    "Add :com.apple.developer.team-identifier string VJPMCBH6NX" "$STORE_ENTS"
  codesign --force --options runtime --sign "$SIGN_ID" --entitlements "$STORE_ENTS" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  if ! codesign -dvv "$APP" 2>&1 | grep -Eq 'flags=.*runtime'; then
    fail "distribution re-sign stripped the hardened runtime flag"
  fi
  echo "    ok: distribution signature preserves hardened runtime"
fi

echo "==> Verifying the build is App Store ready"

# 1. The self-updater must be compiled out.
if nm "$APP/Contents/MacOS/Click" 2>/dev/null | grep -qi "UpdateChecker"; then
  fail "updater symbols found in MAS binary (MAS_BUILD flag not applied?)"
fi
echo "    ok: no self-updater code in binary"

# 2. Entitlements: sandbox + user-selected read-only, and nothing risky.
ENTS="$BUILD_DIR/entitlements-actual.plist"
codesign -d --entitlements - --xml "$APP" > "$ENTS" 2>/dev/null
for key in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-only; do
  if [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$ENTS" 2>/dev/null)" != "true" ]; then
    fail "missing entitlement: $key"
  fi
done
if grep -q "get-task-allow" "$ENTS"; then
  fail "get-task-allow leaked into entitlements"
fi
echo "    ok: app-sandbox + user-selected read-only entitlements"

# 3. Info.plist sanity.
PLIST="$APP/Contents/Info.plist"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST" 2>/dev/null)" != "true" ]; then
  fail "LSUIElement missing (menu bar app must not show a Dock icon)"
fi
if /usr/libexec/PlistBuddy -c 'Print :NSAccessibilityUsageDescription' "$PLIST" >/dev/null 2>&1; then
  fail "stale Accessibility usage description present"
fi
APP_CATEGORY="$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$PLIST" 2>/dev/null || true)"
if [ -z "$APP_CATEGORY" ]; then
  fail "LSApplicationCategoryType missing (App Store rejects uploads without a category)"
fi
echo "    ok: Info.plist (LSUIElement set, category $APP_CATEGORY, no stale Accessibility string)"

# 4. Universal binary so Intel and Apple Silicon customers are both served.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Click")"
case "$ARCHS" in
  *x86_64*arm64*|*arm64*x86_64*)
    echo "    ok: universal binary ($ARCHS)" ;;
  *)
    if [ "$MODE" = "store" ]; then
      fail "binary is not universal: $ARCHS"
    fi
    echo "    note: single-arch build ($ARCHS) — acceptable for smoke only" ;;
esac

if [ "$MODE" = "smoke" ]; then
  echo "==> Smoke build verified: $APP"
  echo "    Open it, grant Input Monitoring, type, and confirm sounds + pack import."
  exit 0
fi

echo "==> Building installer package"
productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG"

echo "==> Done: $PKG"
echo "    Upload with Transporter.app (drag the pkg in),"
echo "    then select the build in App Store Connect and submit for review."
