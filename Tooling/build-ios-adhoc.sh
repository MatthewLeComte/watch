#!/usr/bin/env bash
# Build ad-hoc Watch.ipa (product: Watch / watch.apps).
# Uses Xcode Automatic signing with dedicated keychain (no login keychain password prompts).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Generate Xcode project if needed
if [[ -f ios/project.yml ]]; then
  if [[ ! -f ios/Watch.xcodeproj/project.pbxproj ]] || [[ "ios/project.yml" -nt "ios/Watch.xcodeproj/project.pbxproj" ]]; then
    echo "▶ xcodegen generate (project.yml changed or project missing)"
    (cd ios && xcodegen generate)
  else
    echo "▶ xcodegen skipped (project.yml unchanged — keeping incremental build)"
  fi
elif [[ ! -f ios/Watch.xcodeproj/project.pbxproj ]]; then
  echo "error: missing ios/Watch.xcodeproj — install xcodegen" >&2
  exit 1
fi

export CODE_AUTO_FLEET_SHIP="${CODE_AUTO_FLEET_SHIP:-0}"
# Watch doesn't have require-main-shipped.sh yet

# App icon = Eden pixel1 gen set (generate-wordmark-styles.py --style pixel1 --label Watch).
# if [[ -x "$ROOT/Tooling/sync-app-icon-from-eden.sh" ]]; then
#   bash "$ROOT/Tooling/sync-app-icon-from-eden.sh"
# fi

ARCHIVE="$ROOT/build/archives/Watch-iOS.xcarchive"
EXPORT_DIR="$ROOT/build/export-ios-adhoc"

# Drop legacy artifacts
shopt -s nullglob
for stale in \
  "$ROOT/build/archives/Watch-iOS.xcarchive" \
  "$ROOT/build/export-ios/Watch.ipa" \
  "$ROOT/build/export-ios-adhoc/Watch.ipa" \
  ; do
  if [[ -e "$stale" ]]; then
    echo "  rm legacy $stale"
    /usr/bin/trash "$stale"
  fi
done
shopt -u nullglob

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "dev")"
GIT_FULL="$(git rev-parse HEAD 2>/dev/null || echo "")"
BUILD_NO="$(date +%s)"
MARKETING="1.0.${BUILD_NO}"
VERSION="$BUILD_NO"

# The Xcode project has a single "Watch" scheme with Catalyst support.
# Building for iOS requires -destination 'generic/platform=iOS'
SCHEME="Watch"
echo "Archiving Watch scheme=$SCHEME MARKETING=$MARKETING BUILD=$VERSION sha=$GIT_SHA"

# Signing: ~/Library/Keychains/QB54A5B6LN-signing.keychain-db
# Profile: local Ad Hoc "iOS Team Ad Hoc Provisioning Profile: watch.apps"
# No App Store Connect. No login keychain. No SecurityAgent sheet.
# shellcheck source=codesign-env.sh
source "$ROOT/Tooling/codesign-env.sh"
code_prepare_codesign || { echo "error: signing keychain not ready: $CODE_SIGN_KEYCHAIN" >&2; exit 1; }
code_isolate_codesign_search
trap 'code_restore_keychain_search' EXIT
code_dismiss_keychain_dialogs

# Xcode Automatic signing — picks Apple Development cert from DEDICATED keychain
# (login keychain removed from search list to avoid Mac-password ACL dialog).
# Uses Xcode-managed "iOS Team Ad Hoc Provisioning Profile: watch.apps"
xcodebuild -project ios/Watch.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  MARKETING_VERSION="$MARKETING" \
  PRODUCT_BUNDLE_IDENTIFIER=watch.apps \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=QB54A5B6LN \
  OTHER_CODE_SIGN_FLAGS="$CODE_OTHER_CODE_SIGN_FLAGS" \
  archive

rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
OPTS="$ROOT/ios/Tooling/exportOptions-iOS-adhoc.plist"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OPTS"

if [[ ! -f "$EXPORT_DIR/Watch.ipa" ]]; then
  found="$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1 || true)"
  if [[ -n "$found" ]]; then
    cp "$found" "$EXPORT_DIR/Watch.ipa"
  else
    echo "error: no Watch.ipa in $EXPORT_DIR" >&2
    ls -la "$EXPORT_DIR" >&2 || true
    exit 1
  fi
fi
printf '%s' "$VERSION" > "$EXPORT_DIR/version.txt"
if [[ -n "$GIT_FULL" && -f "$EXPORT_DIR/Watch.ipa" ]]; then
  printf '%s %s\n' "$GIT_FULL" "$(/usr/bin/shasum -a 256 "$EXPORT_DIR/Watch.ipa" | awk '{print $1}')" > "$EXPORT_DIR/git-sha.txt"
else
  printf '%s' "$GIT_SHA" > "$EXPORT_DIR/git-sha.txt"
fi
echo "Done: $EXPORT_DIR/Watch.ipa version=$VERSION sha=$GIT_SHA"