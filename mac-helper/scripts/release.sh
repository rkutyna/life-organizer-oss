#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) organizer-helper for distribution, signed with a Developer ID,
# notarized, and stapled where the format allows.
#
#   scripts/release.sh             signed + notarized release (needs the variables below)
#   scripts/release.sh --unsigned  just the universal binary, ad-hoc signed and zipped (testing)
#
# Environment:
#   SIGN_IDENTITY       "Developer ID Application: <name> (<team id>)"; required unless --unsigned
#   NOTARY_PROFILE      a notarytool keychain profile, made once with
#                         xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#                       required unless --unsigned
#   INSTALLER_IDENTITY  "Developer ID Installer: <name> (<team id>)"; optional. When set, the
#                       release is a signed .pkg that installs /usr/local/bin/organizer-helper and
#                       is stapled. When unset, it is a notarized .zip: a bare binary cannot be
#                       stapled, so Gatekeeper checks the notarization online on first launch.
#   BUNDLE_ID           default com.lifeorganizerformac.helper. The embedded Info.plist is
#                       generated with this id, and the signature's identifier matches it. Users
#                       of such a build set the same "bundle_id" in their config.
#   OUT_DIR             default dist/ (inside mac-helper)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unsigned=0
for arg in "$@"; do
  case "$arg" in
    --unsigned) unsigned=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
  esac
done

bundle_id="${BUNDLE_ID:-com.lifeorganizerformac.helper}"
out_dir="${OUT_DIR:-$here/dist}"
entitlements="$here/Resources/organizer-helper.entitlements"

die() { echo "release.sh: $*" >&2; exit 1; }

# --- preflight: fail before building -------------------------------------------------------------
for tool in swift lipo codesign ditto plutil shasum; do
  command -v "$tool" >/dev/null || die "$tool not found (install the Xcode command line tools)"
done
reverse_dns='^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
if [[ ! "$bundle_id" =~ $reverse_dns ]]; then
  die "BUNDLE_ID '$bundle_id' is not a reverse-DNS name such as org.example.helper"
fi

if [[ $unsigned -eq 0 ]]; then
  [[ -n "${SIGN_IDENTITY:-}" ]] || die "SIGN_IDENTITY is not set (a 'Developer ID Application: ...' identity). Use --unsigned for a test build."
  [[ -n "${NOTARY_PROFILE:-}" ]] || die "NOTARY_PROFILE is not set (see 'xcrun notarytool store-credentials'). Use --unsigned for a test build."
  if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    die "SIGN_IDENTITY '$SIGN_IDENTITY' is not a valid code-signing identity in your keychain (security find-identity -v -p codesigning)"
  fi
  case "$SIGN_IDENTITY" in
    *"Developer ID Application"*) ;;
    *) echo "warning: SIGN_IDENTITY is not a 'Developer ID Application' identity; notarization will refuse it" >&2 ;;
  esac
  if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
    for tool in pkgbuild productsign; do command -v "$tool" >/dev/null || die "$tool not found"; done
    if ! security find-identity -v | grep -Fq "$INSTALLER_IDENTITY"; then
      die "INSTALLER_IDENTITY '$INSTALLER_IDENTITY' is not in your keychain (security find-identity -v)"
    fi
  fi
  xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found (needs Xcode 13 or later)"
  xcrun --find stapler >/dev/null 2>&1 || die "stapler not found"
fi

# --- build ----------------------------------------------------------------------------------------
build_dir="$here/.build/release-$bundle_id"
mkdir -p "$build_dir"
plist="$build_dir/Info.plist"
cp "$here/Resources/Info.plist" "$plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$plist"
version="$(plutil -extract CFBundleShortVersionString raw "$plist")"
# Package.swift links ORGANIZER_HELPER_INFO_PLIST into the binary's __TEXT,__info_plist section.
export ORGANIZER_HELPER_INFO_PLIST="$plist"

echo "==> building organizer-helper $version ($bundle_id) for arm64 and x86_64"
bins=()
for arch in arm64 x86_64; do
  scratch="$build_dir/$arch"
  swift build -c release --package-path "$here" --scratch-path "$scratch" --triple "$arch-apple-macosx14.0"
  bins+=("$(swift build -c release --package-path "$here" --scratch-path "$scratch" --triple "$arch-apple-macosx14.0" --show-bin-path)/organizer-helper")
done

stage="$build_dir/stage"
rm -rf "$stage"
mkdir -p "$stage"
bin="$stage/organizer-helper"
lipo -create -output "$bin" "${bins[@]}"
archs="$(lipo -archs "$bin")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || die "the binary is not universal (lipo says: $archs)"
echo "==> universal binary: $archs"

# `version` prints the embedded bundle id; it touches neither EventKit nor the network.
reported="$("$bin" version)"
[[ "$reported" == *"($bundle_id)"* ]] || die "the binary's embedded Info.plist does not carry $bundle_id (it says: $reported)"

mkdir -p "$out_dir"
base="organizer-helper-$version-macos-universal"

# --- unsigned test build --------------------------------------------------------------------------
if [[ $unsigned -eq 1 ]]; then
  # Ad-hoc signature with the bundle id, so macOS can still attach permissions to it.
  codesign --force --sign - --identifier "$bundle_id" --options runtime --entitlements "$entitlements" "$bin"
  "$bin" version
  zip="$out_dir/$base-unsigned.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$bin" "$zip"
  (cd "$out_dir" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
  echo "==> $zip (unsigned: Gatekeeper blocks it when downloaded; for testing only)"
  exit 0
fi

# --- sign -----------------------------------------------------------------------------------------
echo "==> codesign ($SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$bundle_id" --options runtime --timestamp \
  --entitlements "$entitlements" "$bin"
codesign --verify --strict --verbose=2 "$bin"
"$bin" version

notarize() {  # notarize <file>
  local file="$1" result status id
  echo "==> notarizing $(basename "$file") (this can take a few minutes)"
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" \
    || die "notarytool submit failed: $result"
  status="$(plutil -extract status raw - <<<"$result" 2>/dev/null || echo unknown)"
  id="$(plutil -extract id raw - <<<"$result" 2>/dev/null || echo unknown)"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization $id ended with status '$status' (log above)"
  fi
  echo "==> notarization $id accepted"
}

# --- package: a stapled .pkg, or a notarized .zip -------------------------------------------------
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
  root="$build_dir/pkgroot"
  rm -rf "$root"
  mkdir -p "$root/usr/local/bin"
  ditto "$bin" "$root/usr/local/bin/organizer-helper"
  component="$build_dir/component.pkg"
  pkg="$out_dir/$base.pkg"
  pkgbuild --root "$root" --identifier "$bundle_id.pkg" --version "$version" --install-location / "$component"
  productsign --sign "$INSTALLER_IDENTITY" --timestamp "$component" "$pkg"
  pkgutil --check-signature "$pkg"
  notarize "$pkg"
  xcrun stapler staple "$pkg"
  xcrun stapler validate "$pkg"
  spctl --assess --type install --verbose=2 "$pkg" || echo "warning: spctl did not accept the pkg" >&2
  artifact="$pkg"
else
  zip="$out_dir/$base.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$bin" "$zip"
  notarize "$zip"
  echo "note: a bare binary in a zip cannot be stapled; Gatekeeper checks the notarization online on first launch."
  echo "      Set INSTALLER_IDENTITY to build a stapled .pkg instead."
  artifact="$zip"
fi

(cd "$out_dir" && shasum -a 256 "$(basename "$artifact")" > "$(basename "$artifact").sha256")
echo "==> $artifact"
cat "$artifact.sha256"
