#!/usr/bin/env bash
#
# Watch fleet ship — THIS MAC only.
#   Xcode archive (ad-hoc) → PUT IPA to MDM server → InstallApplication
#
#   ./Tooling/ship-mdm.sh              # iOS IPA → MDM → phones
#   ./Tooling/ship-mdm.sh --skip-build # ship existing IPA; still verifies
#   ./Tooling/ship-mdm.sh --no-push    # upload IPA only (no phone install)
#
# NOT App Store. NOT GitHub Actions. NOT TestFlight.
# Bundle: watch.apps
#
set -euo pipefail

# Ensure Homebrew/standalone git-lfs (and git) are reachable regardless of the
# invoking environment — pre-push/post-commit LFS hooks abort otherwise.
for _p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$_p:"*) ;;
    *) [[ -d "$_p" ]] && export PATH="$_p:$PATH" ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${WORK_ROOT:-${EDEN_ROOT:-$HOME/Developer/GitHub/Work}}"
IPA_ADHOC="$ROOT/build/export-ios-adhoc/Watch.ipa"
VERSION_FILE="$ROOT/build/export-ios-adhoc/version.txt"
IPA_SHA_FILE="$ROOT/build/export-ios-adhoc/git-sha.txt"
EXPECT_APP="Watch"
EXPECT_BUNDLE="watch.apps"
MIN_IPA_BYTES=262144

EXPLICIT_SKIP=0
SKIP_BUILD=0
PUSH_ALL=1
for arg in "$@"; do
  case "$arg" in
    --skip-build) EXPLICIT_SKIP=1; SKIP_BUILD=1 ;;
    --push-all)   PUSH_ALL=1 ;;
    --no-push)    PUSH_ALL=0 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

export SRCROOT="$ROOT"
# Nested ensure→AUTO ship-mdm is the 25-minute death spiral. This *is* the ship.
export CODE_AUTO_FLEET_SHIP=0
if [[ "${CODE_ALLOW_DIRTY_BUILD:-}" != "1" ]]; then
  # Watch doesn't have a require-main-shipped.sh yet — skip for now
  # bash "$ROOT/Tooling/require-main-shipped.sh" || {
  #   echo "hint: CODE_ALLOW_DIRTY_BUILD=1 to ship with local uncommitted changes" >&2
  #   exit 1
  # }
  :
fi

# Dedicated codesign keychain only. Never unlock or search login.keychain —
# that sheet asks for the Mac password (operator does not have it).
# shellcheck source=codesign-env.sh
source "$ROOT/Tooling/codesign-env.sh"
code_prepare_codesign || { echo "error: dedicated codesign keychain not ready" >&2; exit 1; }
code_isolate_codesign_search
trap 'code_restore_keychain_search' EXIT

GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
GIT_FULL="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo local)"
# Nested require-main-shipped / xcodegen can commit a new HEAD. Stamp IPA+Mac as this SHA.
export CODE_SHIP_GIT_FULL="$GIT_FULL"

echo "▶ Watch ship (Mac → MDM)  commit=$GIT_FULL"

IPA_BUNDLE_ID=""
IPA_BUNDLE_VERSION=""
IPA_MARKETING=""

ipa_inspect() {
  local ipa="${1:-$IPA_ADHOC}" tmp plist bytes
  IPA_BUNDLE_ID=""; IPA_BUNDLE_VERSION=""; IPA_MARKETING=""
  [[ -f "$ipa" ]] || return 1
  bytes="$(wc -c <"$ipa" | tr -d ' ')"
  [[ "$bytes" =~ ^[0-9]+$ ]] && [[ "$bytes" -ge "$MIN_IPA_BYTES" ]] || return 1
  /usr/bin/unzip -tqq "$ipa" >/dev/null 2>&1 || return 1
  tmp="$(mktemp -d)"
  if ! /usr/bin/unzip -q -o "$ipa" -d "$tmp" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  plist="$(/usr/bin/find "$tmp" -path "*/Payload/${EXPECT_APP}.app/Info.plist" -print -quit 2>/dev/null || true)"
  if [[ -z "$plist" ]]; then
    plist="$(/usr/bin/find "$tmp" -path '*/Payload/*.app/Info.plist' -print -quit 2>/dev/null || true)"
  fi
  if [[ -z "$plist" || ! -f "$plist" ]]; then
    rm -rf "$tmp"
    return 1
  fi
  IPA_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  IPA_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
  IPA_MARKETING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  rm -rf "$tmp"
  [[ "$IPA_BUNDLE_ID" == "$EXPECT_BUNDLE" ]] || return 1
  [[ -n "$IPA_BUNDLE_VERSION" ]] || return 1
  return 0
}

ipa_file_hash() {
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

# Skip only when stamp is "FULLSHA HASH" and HASH matches the IPA on disk.
# A lone SHA (old format) is treated as unverified — rebuild, don't ship stale.
ipa_is_head() {
  local stamp_sha stamp_hash got rest
  ipa_inspect "$IPA_ADHOC" || return 1
  [[ -f "$IPA_SHA_FILE" ]] || return 1
  read -r stamp_sha stamp_hash rest < "$IPA_SHA_FILE" || return 1
  stamp_sha="$(printf '%s' "$stamp_sha" | tr -d '[:space:]')"
  stamp_hash="$(printf '%s' "$stamp_hash" | tr -d '[:space:]')"
  [[ -n "$stamp_sha" && -n "$stamp_hash" ]] || return 1
  [[ "$stamp_sha" == "$GIT_FULL" || "$stamp_sha" == "$GIT_SHA" ]] || return 1
  got="$(ipa_file_hash "$IPA_ADHOC")"
  [[ -n "$got" && "$got" == "$stamp_hash" ]] || return 1
  if [[ -f "$VERSION_FILE" ]]; then
    local v
    v="$(tr -d '[:space:]' < "$VERSION_FILE")"
    [[ -z "$v" || "$v" == "$IPA_BUNDLE_VERSION" ]] || return 1
  fi
  return 0
}

write_ipa_stamp() {
  local hash
  ipa_inspect "$IPA_ADHOC" || return 1
  hash="$(ipa_file_hash "$IPA_ADHOC")"
  [[ -n "$hash" ]] || return 1
  mkdir -p "$(dirname "$IPA_SHA_FILE")"
  printf '%s %s\n' "$GIT_FULL" "$hash" > "$IPA_SHA_FILE"
  printf '%s' "$IPA_BUNDLE_VERSION" > "$VERSION_FILE"
}

if [[ "$EXPLICIT_SKIP" -eq 1 ]]; then
  if ! ipa_is_head; then
    echo "error: --skip-build but $IPA_ADHOC is not a verified HEAD $GIT_SHA IPA (missing/corrupt/wrong bundle, or SHA+sha256 stamp mismatch)" >&2
    exit 1
  fi
  echo "▶ Skip iOS archive — verified IPA $GIT_SHA (upload + install only)"
elif ipa_is_head; then
  echo "▶ Skip iOS archive — verified IPA already $GIT_SHA (upload + install only)"
  SKIP_BUILD=1
else
  if [[ -f "$IPA_ADHOC" ]]; then
    echo "▶ Existing IPA is not a verified HEAD build — archive"
  fi
  SKIP_BUILD=0
fi

if [[ "$SKIP_BUILD" -eq 0 && "$EXPLICIT_SKIP" -eq 0 ]]; then
  echo "▶ Archive + ad-hoc export on this Mac"
  bash "$ROOT/Tooling/build-ios-adhoc.sh"
fi

if ! ipa_inspect "$IPA_ADHOC"; then
  echo "error: no valid Watch.ipa at $IPA_ADHOC (missing, tiny, corrupt zip, or bundle id ≠ $EXPECT_BUNDLE)" >&2
  exit 1
fi
write_ipa_stamp
VERSION="$IPA_BUNDLE_VERSION"
if [[ -n "${CODE_MDM_VERSION:-}" && "$CODE_MDM_VERSION" != "$VERSION" ]]; then
  echo "warn: ignoring CODE_MDM_VERSION=$CODE_MDM_VERSION — IPA CFBundleVersion=$VERSION" >&2
fi
echo "▶ Fleet version (from IPA CFBundleVersion)=$VERSION  git=$GIT_SHA  bundle=$IPA_BUNDLE_ID"
ls -lh "$IPA_ADHOC"

SHIP="$ROOT/Tooling/ship-ipa-to-mdm.sh"
if [[ ! -x "$SHIP" ]]; then
  echo "error: missing $SHIP" >&2
  exit 1
fi

if [[ "$PUSH_ALL" -eq 1 ]]; then
  bash "$SHIP" "$IPA_ADHOC" "$VERSION"
else
  CODE_MDM_SKIP_INSTALL=1 bash "$SHIP" "$IPA_ADHOC" "$VERSION"
fi

# Watch is a Catalyst app (iPad app for Mac). Build Mac version too.
# Pin Mac version to iOS IPA version so phone and Mac move together.
export CODE_MAC_BUILD="$VERSION"
export CODE_MAC_MARKET="${IPA_MARKETING:-1.0.${VERSION}}"
echo "▶ Pin Mac version to IPA — BUILD=$CODE_MAC_BUILD MARKET=$CODE_MAC_MARKET"

if [[ "$SKIP_BUILD" -eq 0 && "$EXPLICIT_SKIP" -eq 0 ]]; then
  echo "▶ Build Mac Catalyst app (same commit as IPA — required)"
  bash "$ROOT/Tooling/build-macos-catalyst.sh"
else
  echo "▶ Skip Mac Catalyst build (using existing)"
  # Verify existing Mac app matches
  if [[ -x "/Applications/Watch.app/Contents/MacOS/Watch" ]]; then
    MAC_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "/Applications/Watch.app/Contents/Info.plist" 2>/dev/null || true)"
    echo "   Mac app version: $MAC_VER (expected $CODE_MAC_BUILD)"
  fi
fi

if [[ "$PUSH_ALL" -eq 1 && -x "$ROOT/Tooling/fleet-complete-state.sh" ]]; then
  bash "$ROOT/Tooling/fleet-complete-state.sh" mark-fleet-shipped watch "$GIT_FULL" "$VERSION"
  bash "$ROOT/Tooling/fleet-complete-state.sh" status watch || true
elif [[ "$PUSH_ALL" -eq 0 ]]; then
  echo "warn: --no-push — not marking fleet shipped (phones were not woken)" >&2
fi

echo ""
echo "✅ Watch → MDM complete (ad-hoc OTA, not App Store)"
echo "   version:  $VERSION"
echo "   commit:   $GIT_FULL"
echo "   IPA:      $IPA_ADHOC"
echo "   OTA:      https://mdm.cornerstonecoatings.com/mdm/apps/watch/Watch.ipa"
echo "   Mac:      /Applications/Watch.app ($MAC_VER) — same commit as IPA"
echo "   fleet:    $([[ "$PUSH_ALL" -eq 1 ]] && echo 'mark-fleet-shipped watch' || echo 'not marked (--no-push)')"