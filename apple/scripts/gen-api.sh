#!/bin/bash
# Regenerates the Swift API types from a local server's OpenAPI schema: the native twin of the
# web's `npm run gen:api`.
#
#   apple/scripts/gen-api.sh [base_url]        # default http://localhost:8601
#   apple/scripts/gen-api.sh --offline         # regenerate from the committed snapshot
#
# The server must run on this Mac with EXPOSE_API_DOCS=true (docs/SETUP.md, "Development"):
#   cd server && EXPOSE_API_DOCS=true uv run uvicorn app.main:app --port 8601
#
# 1. Saves <base_url>/openapi.json as apple/OrganizerKit/openapi.json (the committed snapshot).
# 2. Runs apple/scripts/gen-api.py, which writes Sources/OrganizerAPI/Generated/*.swift.
# 3. Builds OrganizerAPI to check the result compiles.
# Commit the snapshot and the generated Swift together. Never edit the generated files.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

base_url="http://localhost:8601"
offline=0
for arg in "$@"; do
  case "$arg" in
    --offline) offline=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) base_url="${arg%/}" ;;
  esac
done

spec="$APPLE_DIR/OrganizerKit/openapi.json"
if [ "$offline" = 0 ]; then
  require_local "$base_url"
  note "fetching $base_url/openapi.json"
  tmp="$(mktemp)"
  curl -fsS "$base_url/openapi.json" -o "$tmp" \
    || die "could not fetch $base_url/openapi.json (is the server running with EXPOSE_API_DOCS=true?)"
  # Pretty-printed, so a schema change reads as a small diff.
  /usr/bin/python3 -c 'import json, sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"), indent=1, ensure_ascii=False)' "$tmp" "$spec"
  rm -f "$tmp"
fi

note "generating Swift"
/usr/bin/python3 "$APPLE_DIR/scripts/gen-api.py" "$spec"

note "checking it compiles"
(cd "$APPLE_DIR/OrganizerKit" && swift build --target OrganizerAPI 2>&1 | tail -3)
note "done: review and commit apple/OrganizerKit/openapi.json and Sources/OrganizerAPI/Generated/"
