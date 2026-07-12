#!/usr/bin/env bash
#
# Strict public-release entry point for Click.
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE="AC_NOTARY" \
#     ./scripts/release.sh
#
# DEV_ID remains a supported legacy alias for DEVELOPER_ID. Credentials are
# never defaulted: a public release must be an explicit, fully configured act.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if (( $# != 0 )); then
  echo "release.sh does not accept arguments; configure release credentials through the environment." >&2
  exit 2
fi

if [[ -n "${DEV_ID:-}" ]]; then
  if [[ -n "${DEVELOPER_ID:-}" && "$DEV_ID" != "$DEVELOPER_ID" ]]; then
    echo "DEV_ID and DEVELOPER_ID disagree; refusing to choose a signing identity." >&2
    exit 2
  fi
  export DEVELOPER_ID="$DEV_ID"
fi

if [[ -z "${DEVELOPER_ID:-}" || -z "${NOTARY_PROFILE:-}" ]]; then
  echo "A public Click release requires both DEVELOPER_ID and NOTARY_PROFILE." >&2
  echo "For a clearly labeled local-only artifact, run ./scripts/package_release.sh instead." >&2
  exit 2
fi

# Keep one release implementation so signing, DMG notarization, Gatekeeper,
# artifact naming, and manifest rules cannot diverge between entry points.
exec "$SCRIPT_DIR/package_release.sh"
