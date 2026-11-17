#!/bin/bash
# Shared helpers for apple/scripts/*.sh. Source it; do not run it.

APPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$APPLE_DIR/LifeOrganizer.xcodeproj"
SCHEME="LifeOrganizer"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*" >&2; }

# Development scripts only talk to a server on this Mac (localhost, 127.0.0.1 or ::1), so a
# schema fetch or a test run never reaches a real install by accident.
require_local() {
  local host
  host="$(/usr/bin/python3 -c 'import sys, urllib.parse; print(urllib.parse.urlsplit(sys.argv[1]).hostname or "")' "$1")"
  case "$host" in
    localhost|127.0.0.1|::1) ;;
    *) die "refusing $1: development scripts only use a server on this Mac (localhost, 127.0.0.1 or ::1)" ;;
  esac
}
