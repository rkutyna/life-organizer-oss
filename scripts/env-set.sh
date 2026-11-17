#!/usr/bin/env bash
# Set one variable in .env without opening the file or printing anything secret.
#
#   scripts/env-set.sh KEY VALUE        # a non-secret value, e.g. ORGANIZER_PORT 8657
#   scripts/env-set.sh KEY              # a secret: typed or pasted, hidden, never echoed
#   scripts/env-set.sh --check KEY      # prints "KEY is set" or "KEY is empty", never the value
#
# It replaces an existing `KEY=` line (commented out or not) or appends one, keeps the file's
# mode at 600, and creates .env from .env.example if it does not exist yet. Agents use this
# instead of reading or editing .env, which holds ORGANIZER_SECRET_KEY and tokens.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
env_file="${ENV_FILE:-$root/.env}"

die() { echo "env-set: $*" >&2; exit 1; }

if [ "${1:-}" = "--check" ]; then
  key="${2:?usage: env-set.sh --check KEY}"
  [ -f "$env_file" ] || die "$env_file does not exist"
  value="$(grep -E "^${key}=" "$env_file" | tail -1 | cut -d= -f2- || true)"
  if [ -n "$value" ]; then echo "$key is set"; else echo "$key is empty"; fi
  exit 0
fi

key="${1:?usage: env-set.sh KEY [VALUE]}"
[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "not a variable name: $key"

if [ $# -ge 2 ]; then
  value="$2"
else
  if [ -t 0 ]; then
    printf '%s (input hidden): ' "$key" >&2
    IFS= read -rs value
    echo >&2
  else
    IFS= read -r value
  fi
fi
[[ "$value" != *$'\n'* ]] || die "the value has a line break"

if [ ! -f "$env_file" ]; then
  [ -f "$root/.env.example" ] || die "no .env and no .env.example"
  (umask 077 && cp "$root/.env.example" "$env_file")
fi

tmp="$(mktemp "${env_file}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
KEY="$key" VALUE="$value" awk '
  BEGIN { key = ENVIRON["KEY"]; value = ENVIRON["VALUE"]; done = 0 }
  {
    line = $0
    sub(/^[ \t]*#[ \t]*/, "", line)
    if (!done && index(line, key "=") == 1) { print key "=" value; done = 1; next }
    print
  }
  END { if (!done) print key "=" value }
' "$env_file" >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$env_file"
trap - EXIT
echo "$key updated in .env"
