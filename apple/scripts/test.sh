#!/bin/bash
# Runs the package tests (OrganizerKit: API, core and UI logic). No server, no network.
#
#   apple/scripts/test.sh [--filter TEXT]
#
#   --filter TEXT   only tests whose name matches (swift test --filter)
#
# Snapshots (PNGs of the screens, drawn offscreen) need a local demo server and a token:
#   ORGANIZER_TEST_SERVER=http://localhost:8601 ORGANIZER_TEST_TOKEN=... \
#     ORGANIZER_SNAPSHOT_DIR=/tmp/shots apple/scripts/test.sh --filter Snapshot
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

filter=()
while [ $# -gt 0 ]; do
  case "$1" in
    --filter) filter=(--filter "$2"); shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [ -n "${ORGANIZER_TEST_SERVER:-}" ]; then
  require_local "$ORGANIZER_TEST_SERVER"
fi

note "swift test (OrganizerKit)"
(cd "$APPLE_DIR/OrganizerKit" && swift test ${filter[@]+"${filter[@]}"})
note "tests ok"
