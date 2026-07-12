#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Click"
BUNDLE_ID="brandon.Click"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

resolve_developer_dir() {
  local active
  active="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [ -n "$active" ] && [ -x "$active/usr/bin/xcodebuild" ] && \
     DEVELOPER_DIR="$active" "$active/usr/bin/xcodebuild" -version >/dev/null 2>&1; then
    printf '%s\n' "$active"
    return
  fi
  local candidate
  for candidate in \
    /Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode-beta.app/Contents/Developer; do
    if [ -x "$candidate/usr/bin/xcodebuild" ] && \
       DEVELOPER_DIR="$candidate" "$candidate/usr/bin/xcodebuild" -version >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  echo "Xcode is required. Install Xcode or set DEVELOPER_DIR." >&2
  exit 1
}

if [ -z "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR="$(resolve_developer_dir)"
fi

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

/usr/bin/xcrun xcodebuild \
  -project "$ROOT_DIR/Click.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/xcrun lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..40}; do
      if /usr/bin/pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not remain running after launch" >&2
    exit 1
    ;;
esac
