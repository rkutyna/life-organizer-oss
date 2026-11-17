#!/bin/bash
# Builds the Mac app with no Apple developer team: signed "to run locally" (ad hoc).
#
#   apple/scripts/build.sh [--release] [--derived-data PATH]
#
# The app lands in <derived data>/Build/Products/<Debug|Release>/Life Organizer.app; the default
# derived data is apple/.build/DerivedData. Prints only warnings and errors.
#
# To sign with your own free or paid Apple ID instead (keeps Calendars and Reminders permissions
# and the Keychain item across rebuilds), set DEVELOPMENT_TEAM=<your team id>.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

configuration="Debug"
derived="${DERIVED_DATA:-$APPLE_DIR/.build/DerivedData}"
while [ $# -gt 0 ]; do
  case "$1" in
    --release) configuration="Release" ;;
    --derived-data) derived="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  note "macOS build ($configuration), signed with team $DEVELOPMENT_TEAM -> $derived"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$configuration" \
    -destination 'platform=macOS' -derivedDataPath "$derived" -quiet build \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates
else
  note "macOS build ($configuration), signed to run locally (no team) -> $derived"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$configuration" \
    -destination 'platform=macOS' -derivedDataPath "$derived" -quiet build \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
fi
note "built $derived/Build/Products/$configuration/Life Organizer.app"
