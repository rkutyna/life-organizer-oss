#!/usr/bin/env bash
# Install from source: build organizer-helper (release), copy it to ~/.local/bin (or $DEST_DIR),
# and sign it so macOS has a stable identity to attach the Calendars and Reminders grants to.
#
#   scripts/install.sh                    # ad-hoc signature: the grants must be approved again
#                                         # after each rebuild
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/install.sh
#                                         # a certificate signature: the grants survive rebuilds
#                                         # ("Apple Development: ..." works too)
#   DEST_DIR=/usr/local/bin scripts/install.sh
#   BUNDLE_ID=org.example.helper scripts/install.sh
#                                         # another bundle id (embedded Info.plist and signature);
#                                         # set the same bundle_id in the config
#
# Then: mkdir -p ~/.config/life-organizer-for-mac
#       cp helper.example.json ~/.config/life-organizer-for-mac/helper.json   (set server.url)
#       ~/.local/bin/organizer-helper set-token
#       ~/.local/bin/organizer-helper doctor
#       ~/.local/bin/organizer-helper install     # loads the LaunchAgent; approve the prompts
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest_dir="${DEST_DIR:-$HOME/.local/bin}"
dest="$dest_dir/organizer-helper"
identity="${SIGN_IDENTITY:--}"
bundle_id="${BUNDLE_ID:-com.lifeorganizerformac.helper}"
label="${LAUNCH_AGENT_LABEL:-$bundle_id}"
scratch="$here/.build"

if [[ "$bundle_id" != "com.lifeorganizerformac.helper" ]]; then
  # A copy of the Info.plist with the other bundle id, linked in instead of Resources/Info.plist
  # (Package.swift reads ORGANIZER_HELPER_INFO_PLIST). Its own scratch path keeps the builds apart.
  scratch="$here/.build/install-$bundle_id"
  mkdir -p "$scratch"
  plist="$scratch/Info.plist"
  cp "$here/Resources/Info.plist" "$plist"
  plutil -replace CFBundleIdentifier -string "$bundle_id" "$plist"
  export ORGANIZER_HELPER_INFO_PLIST="$plist"
fi

# Never replace a different helper that happens to live at the same path (another build with
# its own bundle id): its LaunchAgent and permission grants belong to it.
if [[ -e "$dest" ]]; then
  existing="$(codesign -dv "$dest" 2>&1 | sed -n 's/^Identifier=//p')"
  if [[ -n "$existing" && "$existing" != "$bundle_id" ]]; then
    echo "error: $dest is another helper (signed as $existing, not $bundle_id)." >&2
    echo "       Set DEST_DIR to install somewhere else, or BUNDLE_ID if it really is this one." >&2
    exit 1
  fi
fi

echo "==> swift build -c release"
swift build -c release --package-path "$here" --scratch-path "$scratch"
bin="$(swift build -c release --package-path "$here" --scratch-path "$scratch" --show-bin-path)/organizer-helper"

echo "==> install $dest"
mkdir -p "$dest_dir"
# Replace rather than overwrite in place: a running daemon keeps its old inode.
tmp="$dest.new.$$"
cp "$bin" "$tmp"

# Hardened runtime and the calendars entitlement: recent macOS refuses to prompt for Calendars on
# behalf of a hardened binary that lacks it, and the entitlement is harmless otherwise. It also
# covers Reminders: there is no separate reminders entitlement (the personal-information
# entitlements are addressbook, calendars and photos-library; sandboxed apps that use Reminders
# carry the calendars one). Reminders needs only NSRemindersFullAccessUsageDescription in the
# embedded Info.plist.
echo "==> codesign (identity: $identity)"
codesign --force --sign "$identity" \
  --identifier "$bundle_id" \
  --options runtime \
  --entitlements "$here/Resources/organizer-helper.entitlements" \
  "$tmp"
mv -f "$tmp" "$dest"

codesign -dv "$dest" 2>&1 | grep -E '^(Identifier|Info.plist|Signature|Runtime)' || true
"$dest" version

if [[ ! -f "$HOME/.config/life-organizer-for-mac/helper.json" ]]; then
  echo "note: no config yet: mkdir -p ~/.config/life-organizer-for-mac && cp \"$here/helper.example.json\" ~/.config/life-organizer-for-mac/helper.json"
fi
if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  echo "==> restarting the running LaunchAgent ($label)"
  launchctl kickstart -k "gui/$(id -u)/$label"
fi
echo "done: $dest"
