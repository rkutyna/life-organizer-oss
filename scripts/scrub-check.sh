#!/usr/bin/env bash
# Fails if personal data is in the repo: the tracked files, the staged files, or every commit.
#
#   scripts/scrub-check.sh             # tracked files (default)
#   scripts/scrub-check.sh --staged    # staged changes (the pre-commit hook)
#   scripts/scrub-check.sh --history   # every commit on every ref
#   scripts/scrub-check.sh --file PATH # one file, e.g. a commit message (the commit-msg hook)
#
# Two kinds of check:
# 1. Generic, always on: absolute home-directory paths, tailnet host names, and email addresses
#    outside an allow-list of example domains.
# 2. A personal denylist, one extended regex per line (case-insensitive, # comments allowed),
#    read from $SCRUB_DENYLIST or ~/.config/organizer-scrub/denylist.txt. It is never in the
#    repo, because the list itself is personal. CI runs without it; run it locally before
#    making the repo public.
set -euo pipefail

mode="${1:---tree}"
file_arg="${2:-}"
root="$(git rev-parse --show-toplevel)"
cd "$root"

denylist="${SCRUB_DENYLIST:-$HOME/.config/organizer-scrub/denylist.txt}"
self="scripts/scrub-check.sh"

generic_patterns=(
  '/(Users|home)/[A-Za-z0-9._-]+/'
  '[A-Za-z0-9-]+\.tail[0-9a-f]+\.ts\.net'
)
# Emails are allowed only at these domains.
email_re='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
email_ok='@(example\.(com|org|net)|anthropic\.com|users\.noreply\.github\.com)$'

content() {
  case "$mode" in
    --tree) git ls-files -z | grep -zv -e '^server/uv.lock$' -e '^web/package-lock.json$' \
              -e "^$self\$" | xargs -0 grep -nHI -E "" -- 2>/dev/null || true ;;
    --staged) git diff --cached -U0 --no-color -- . ":(exclude)$self" \
                ":(exclude)server/uv.lock" ":(exclude)web/package-lock.json" \
              | grep -E '^\+[^+]' | sed 's/^+//' || true ;;
    # Author names are left out (the repo owner's handle is public anyway); author emails are
    # kept, so a private address in a commit fails the email check.
    --history) git log --all -p --no-color --format='commit %H %ae%n%B' -- . ":(exclude)$self" \
                 ":(exclude)server/uv.lock" ":(exclude)web/package-lock.json" \
               | sed -E -e 's/[0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com/<github-noreply>/g' \
                   -e 's/^[+-]//' ;;
    --file) grep -v '^#' "${file_arg:?--file needs a path}" || true ;;
    *) echo "usage: $0 [--tree|--staged|--history|--file PATH]" >&2; exit 2 ;;
  esac
}

text="$(content)"
failed=0

report() {
  echo "scrub-check: $1" >&2
  echo "$2" | head -20 | sed 's/^/    /' >&2
  failed=1
}

for pattern in "${generic_patterns[@]}"; do
  hits="$(grep -E -- "$pattern" <<<"$text" | grep -vE '/(Users|home)/(you|me|name|user|runner)/' || true)"
  [ -n "$hits" ] && report "generic pattern /$pattern/" "$hits"
done

emails="$(grep -oE "$email_re" <<<"$text" | sort -u | grep -vE "$email_ok" || true)"
[ -n "$emails" ] && report "email addresses outside the example domains" "$emails"

if [ -f "$denylist" ]; then
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in ''|'#'*) continue ;; esac
    hits="$(grep -iE -- "$pattern" <<<"$text" || true)"
    # Never echo the denylist entry itself in CI logs; show only where it matched.
    if [ -n "$hits" ]; then
      if [ "$mode" = "--tree" ]; then
        report "a denylist entry matched" "$(cut -d: -f1-2 <<<"$hits" | sort -u)"
      else
        report "a denylist entry matched $(wc -l <<<"$hits" | tr -d ' ') line(s)" \
          "(not shown; find them with: git log --all -p | grep -inE '<entry>')"
      fi
    fi
  done <"$denylist"
else
  echo "scrub-check: no denylist at $denylist; generic checks only" >&2
fi

if [ "$failed" -ne 0 ]; then
  echo "scrub-check: FAILED ($mode)" >&2
  exit 1
fi
echo "scrub-check: ok ($mode)"
