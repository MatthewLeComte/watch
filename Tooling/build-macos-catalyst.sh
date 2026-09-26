#!/usr/bin/env bash
#
# Build, sign, and install Watch Catalyst on macOS (arm64).
# Product: Watch / watch.apps
#
# Usage:
#   ./Tooling/build-macos-catalyst.sh          # → /Applications/Watch.app
#   ./Tooling/build-macos-catalyst.sh --dev    # ad-hoc sign for local dev
#   ./Tooling/build-macos-catalyst.sh --allow-dirty
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SRCROOT="$ROOT"

APP_NAME="Watch"
BUNDLE_ID="watch.apps"
TEAM_ID="QB54A5B6LN"
BUILD_DIR="$ROOT/build/macos"
DERIVED="$BUILD_DIR/DerivedData"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

INSTALL=1
DEV=0
ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --no-install) INSTALL=0 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: must run on macOS" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found" >&2
  exit 1
fi

if [[ -f "$ROOT/ios/project.yml" ]] && {
  [[ ! -f "$ROOT/ios/Watch.xcodeproj/project.pbxproj" ]] ||
  [[ "$ROOT/ios/project.yml" -nt "$ROOT/ios/Watch.xcodeproj/project.pbxproj" ]]
}; then
  echo "▶ xcodegen generate (project.yml changed or project missing)"
  (cd "$ROOT/ios" && xcodegen generate)
elif [[ ! -f "$ROOT/ios/Watch.xcodeproj/project.pbxproj" ]]; then
  echo "error: missing ios/Watch.xcodeproj — install xcodegen" >&2
  exit 1
else
  echo "▶ xcodegen skipped (project.yml unchanged — keeping incremental build)"
fi

if [[ "$ALLOW_DIRTY" == "1" ]]; then
  export CODE_ALLOW_DIRTY_BUILD=1
fi
export CODE_AUTO_FLEET_SHIP="${CODE_AUTO_FLEET_SHIP:-0}"
if [[ -z "${CODE_SHIP_GIT_FULL:-}" ]]; then
  # Watch doesn't have require-main-shipped.sh yet
  :
else
  export CODE_ALLOW_DIRTY_BUILD=1
fi

echo "▶ Incremental $BUILD_DIR (keep DerivedData)"
mkdir -p "$BUILD_DIR" "$DERIVED"
rm -rf "$APP_BUNDLE"

GIT_COMMIT_STAMP="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
MAC_BUILD="${CODE_MAC_BUILD:-$(date +%s)}"
MAC_MARKET="${CODE_MAC_MARKET:-1.0.${MAC_BUILD}}"
echo "▶ Building $APP_NAME (Catalyst, Release) scheme=Watch bundleId=$BUNDLE_ID version=$MAC_MARKET ($MAC_BUILD)"

# XcodeGen multiplatform → scheme Watch (product PRODUCT_NAME=Watch)
# Catalyst destination: generic/platform=macOS with MAC_CATALYST=1
# shellcheck source=codesign-env.sh
source "$ROOT/Tooling/codesign-env.sh"
code_dismiss_keychain_dialogs

if [[ "$DEV" == "1" ]]; then
  # Dev: ad-hoc sign, no keychain dance
  echo "▶ Build + ad-hoc sign (--dev)"
  xcodebuild \
    -project "$ROOT/ios/Watch.xcodeproj" \
    -scheme Watch \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    ENABLE_DEBUG_DYLIB=NO \
    ENABLE_PREVIEWS=NO \
    CURRENT_PROJECT_VERSION="$MAC_BUILD" \
    MARKETING_VERSION="$MAC_MARKET" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGNING_ALLOWED=YES \
    build

  BUILT_APP="$(find "$DERIVED" -path '*/Build/Products/Release/Watch.app' -type d | head -n1)"
  if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
    BUILT_APP="$(find "$DERIVED" -path '*/Build/Products/Release/*.app' -type d | head -n1)"
  fi
  if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
    echo "✘ Could not locate Watch under $DERIVED" >&2
    find "$DERIVED" -name '*.app' 2>/dev/null >&2 || true
    exit 1
  fi

  ditto "$BUILT_APP" "$APP_BUNDLE"
  xattr -cr "$APP_BUNDLE" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :GitCommit string $GIT_COMMIT_STAMP" \
      "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

  ENTITLEMENTS="$ROOT/ios/Watch-macOS.entitlements"
  echo "▶ Apple Development codesign (--dev Ad Hoc)"
  /usr/bin/codesign --force --deep --sign "5A0D9428EC62190C5C801D41D2807579A3D6B16E" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE" 2>&1 | sed 's/^/   /' || {
    echo "✘ codesign failed" >&2
    exit 1
  }

else
  # Ship: unsigned build, then Developer ID sign from p12
  echo "▶ Build unsigned (CODE_SIGNING_ALLOWED=NO — p12 after embed)"
  xcodebuild \
    -project "$ROOT/ios/Watch.xcodeproj" \
    -scheme Watch \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    ENABLE_DEBUG_DYLIB=NO \
    ENABLE_PREVIEWS=NO \
    CURRENT_PROJECT_VERSION="$MAC_BUILD" \
    MARKETING_VERSION="$MAC_MARKET" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ENABLE_HARDENED_RUNTIME=YES \
    build

  BUILT_APP="$(find "$DERIVED" -path '*/Build/Products/Release/Watch.app' -type d | head -n1)"
  if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
    BUILT_APP="$(find "$DERIVED" -path '*/Build/Products/Release/*.app' -type d | head -n1)"
  fi
  if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
    echo "✘ Could not locate Watch under $DERIVED" >&2
    find "$DERIVED" -name '*.app' 2>/dev/null >&2 || true
    exit 1
  fi

  # Debug/Previews stub cannot own a menu-bar extra
  if strings "$BUILT_APP/Contents/MacOS/Watch" 2>/dev/null | grep -q 'Previews.StubExecutor'; then
    echo "✘ Built a Previews stub, not a real Watch binary. Refusing to install." >&2
    echo "   ENABLE_DEBUG_DYLIB=NO and Release configuration are required." >&2
    exit 1
  fi
  if [[ -f "$BUILT_APP/Contents/MacOS/Watch.debug.dylib" ]]; then
    echo "✘ Built Watch.debug.dylib (Xcode debug dylib). Refusing to install." >&2
    exit 1
  fi

  echo "▶ Copying → $APP_BUNDLE"
  ditto "$BUILT_APP" "$APP_BUNDLE"
  xattr -cr "$APP_BUNDLE" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :GitCommit string $GIT_COMMIT_STAMP" \
      "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

  # Identity check
  DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  BUNDLE_GOT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  echo "▶ Identity check: display=$DISPLAY_NAME id=$BUNDLE_GOT"
  if [[ "$BUNDLE_GOT" != "$BUNDLE_ID" ]]; then
    echo "✘ Bundle id is '$BUNDLE_GOT' (want $BUNDLE_ID)" >&2
    exit 1
  fi

  # Stamp git commit
  GIT_FULL="${CODE_SHIP_GIT_FULL:-$(git -C "$ROOT" rev-parse HEAD)}"
  mkdir -p "$APP_BUNDLE/Contents/Resources"
  printf '%s\n' "$GIT_FULL" > "$APP_BUNDLE/Contents/Resources/git-sha.txt"

  # Re-sign after embed — Developer ID from p12
  code_sign_macos_from_p12 "$APP_BUNDLE" "$ROOT/ios/Watch-macOS.entitlements" "Developer ID Application"

  echo "▶ Verifying code signature"
  if ! codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/   /'; then
    echo "✘ codesign verify failed — refusing to install unsigned app" >&2
    exit 1
  fi
  codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | sed 's/^/   /' | head -25
  if command -v spctl >/dev/null 2>&1; then
    spctl --assess --type execute --verbose=4 "$APP_BUNDLE" 2>&1 | sed 's/^/   /' || {
      echo "   note: local Developer ID install (not quarantined) opens without notarization"
    }
  fi
fi

if [[ "$INSTALL" == "1" ]]; then
  echo "▶ Installing → $DEST"
  launchctl bootout "gui/$(id -u)/watch.apps" 2>/dev/null || true
  pkill -f "/Applications/Watch.app/Contents/MacOS/Watch" 2>/dev/null || true

  # Kill GUI Watch (no args) so new install doesn't run alongside old binary
  gui_pids=($(pgrep -f '^/Applications/Watch\.app/Contents/MacOS/Watch$' 2>/dev/null || true))
  if [[ -n "${gui_pids[0]:-}" ]]; then
    echo "   killing GUI Watch pids: ${gui_pids[*]}"
    kill "${gui_pids[@]}" 2>/dev/null || true
    sleep 0.4
    survivors=($(pgrep -f '^/Applications/Watch\.app/Contents/MacOS/Watch$' 2>/dev/null || true))
    if [[ -n "${survivors[0]:-}" ]]; then
      echo "   force-killing GUI Watch: ${survivors[*]}"
      kill -9 "${survivors[@]}" 2>/dev/null || true
    fi
  fi

  if [[ -d "$DEST" ]]; then
    OLD_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -n "$OLD_ID" && "$OLD_ID" != "$BUNDLE_ID" ]]; then
      echo "✘ Refusing to replace $DEST (bundle id $OLD_ID ≠ $BUNDLE_ID)" >&2
      exit 1
    fi
    rm -rf "$DEST"
  fi
  ditto "$APP_BUNDLE" "$DEST"
  /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
  codesign --verify --deep --strict "$DEST"
  echo "   Installed and signature verified"
  /usr/bin/trash "$APP_BUNDLE"
  echo "   Staging → /Applications only ($APP_BUNDLE removed)"
fi

echo "▶ Launching $APP_NAME"
open "/Applications/$APP_NAME.app" || true

echo ""
echo "✔ Done."
echo "   App bundle : $APP_BUNDLE"
echo "   Display    : Watch"
echo "   Bundle ID  : $BUNDLE_ID"
echo "   Team       : $TEAM_ID"
echo "   Installed  : /Applications/Watch.app"
echo "   Version    : $MAC_MARKET ($MAC_BUILD)"
exit 0