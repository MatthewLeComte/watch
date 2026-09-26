#!/usr/bin/env bash
# Shared headless codesign env for Watch ship scripts.
# Source only:
#   # shellcheck source=codesign-env.sh
#   source "$(dirname "$0")/codesign-env.sh"
#   code_prepare_codesign || exit 1
#   code_isolate_codesign_search
#   trap 'code_restore_keychain_search' EXIT
#
# Never the login keychain. Same Apple Development / Developer ID hashes live
# in login.keychain-db with a Mac-password ACL. xcodebuild Automatic + login
# in the search list pops "codesign wants to access keychain" — the operator
# does not have that password. Dedicated KC password is in secrets.env.
#
# Exports:
#   CODE_SIGN_KEYCHAIN
#   CODE_SIGN_KEYCHAIN_ARGS   (array: --keychain PATH)
#   CODE_DEVELOPER_ID_APP
#   CODE_DEVELOPER_ID_INSTALLER
#   CODE_APPLE_DEV_HASH / CODE_APPLE_DIST_HASH / CODE_IOS_SIGN_HASH
#   CODE_OTHER_CODE_SIGN_FLAGS
#
# Intentionally no set -e — this file is sourced.

# Match certs by type, never a person CN. Apple still prints the cert name at codesign time.
CODE_DEVELOPER_ID_APP="${CODE_DEVELOPER_ID_APP:-Developer ID Application}"
CODE_DEVELOPER_ID_INSTALLER="${CODE_DEVELOPER_ID_INSTALLER:-Developer ID Installer}"
# Lives in ~/Library/Keychains so it is a real macOS keychain, not a hidden
# .appstoreconnect leftover. Team ID in the filename so it cannot be lost.
CODE_SIGN_KEYCHAIN="${CODE_SIGN_KEYCHAIN:-$HOME/Library/Keychains/QB54A5B6LN-signing.keychain-db}"
CODE_SIGN_KEYCHAIN_ARGS=()
CODE_APPLE_DEV_HASH=""
CODE_APPLE_DIST_HASH=""
CODE_IOS_SIGN_HASH=""
CODE_OTHER_CODE_SIGN_FLAGS=""
CODE_LOGIN_KEYCHAIN="${CODE_LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
CODE_SYSTEM_KEYCHAIN="${CODE_SYSTEM_KEYCHAIN:-/Library/Keychains/System.keychain}"
CODE_AUTH_ARGS=()

# Apple Developer API key — team Ad Hoc profiles only. Not an App Store upload.
code_developer_auth_args() {
  CODE_AUTH_ARGS=()
  local issuer key_id key_path key_dir
  issuer="${DEVELOPER_ISSUER_ID:-$(tr -d '[:space:]' < "$HOME/.appstoreconnect/issuer_id" 2>/dev/null || true)}"
  key_id="${DEVELOPER_API_KEY_ID:-6T4GU3JSR3}"
  key_path="${DEVELOPER_API_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8}"
  [[ -n "$issuer" && -f "$key_path" ]] || return 0
  key_dir="$HOME/Library/Keychains/QB54A5B6LN-signing-auth"
  mkdir -p "$key_dir"
  cp "$key_path" "$key_dir/AuthKey_${key_id}.p8"
  chmod 600 "$key_dir/AuthKey_${key_id}.p8"
  CODE_AUTH_ARGS=(
    -authenticationKeyPath "$key_dir/AuthKey_${key_id}.p8"
    -authenticationKeyID "$key_id"
    -authenticationKeyIssuerID "$issuer"
  )
}

code_restore_keychain_search() {
  # Put login back for GUI apps after a ship. Dedicated stays in the list last.
  if [[ -f "$CODE_SIGN_KEYCHAIN" ]]; then
    security list-keychains -d user -s \
      "$CODE_LOGIN_KEYCHAIN" "$CODE_SYSTEM_KEYCHAIN" "$CODE_SIGN_KEYCHAIN" 2>/dev/null \
      || security list-keychains -d user -s "$CODE_LOGIN_KEYCHAIN" "$CODE_SYSTEM_KEYCHAIN"
  else
    security list-keychains -d user -s "$CODE_LOGIN_KEYCHAIN" "$CODE_SYSTEM_KEYCHAIN" 2>/dev/null || true
  fi
  security default-keychain -d user -s "$CODE_LOGIN_KEYCHAIN" 2>/dev/null || true
}

code_isolate_codesign_search() {
  # Dedicated + system ONLY. Login omitted so duplicate Apple Dev keys cannot
  # trigger the Mac-password ACL dialog.
  if [[ ! -f "$CODE_SIGN_KEYCHAIN" ]]; then
    echo "error: dedicated codesign keychain missing: $CODE_SIGN_KEYCHAIN" >&2
    return 1
  fi
  security list-keychains -d user -s "$CODE_SIGN_KEYCHAIN" "$CODE_SYSTEM_KEYCHAIN"
  security default-keychain -d user -s "$CODE_LOGIN_KEYCHAIN" 2>/dev/null || true
  printf '▶ codesign-env: search list isolated (no login) keychain=%s\n' \
    "$(basename "$CODE_SIGN_KEYCHAIN")"
}

code_dismiss_keychain_dialogs() {
  # Any leftover SecurityAgent sheet is the login-keychain ACL prompt. Kill it.
  # Never wait for a password. Never launch SecurityAgent ourselves.
  killall SecurityAgent >/dev/null 2>&1 || true
  killall authorizationhost >/dev/null 2>&1 || true
}

code_load_identity_hashes() {
  local ids
  ids="$(security find-identity -v -p codesigning "$CODE_SIGN_KEYCHAIN" 2>/dev/null || true)"
  CODE_APPLE_DIST_HASH="$(printf '%s\n' "$ids" | awk '/Apple Distribution/ {print $2; exit}')"
  CODE_APPLE_DEV_HASH="$(printf '%s\n' "$ids" | awk '/Apple Development/ {print $2; exit}')"
  CODE_IOS_SIGN_HASH="${CODE_APPLE_DIST_HASH:-$CODE_APPLE_DEV_HASH}"
  CODE_OTHER_CODE_SIGN_FLAGS="--keychain ${CODE_SIGN_KEYCHAIN}"
  CODE_SIGN_KEYCHAIN_ARGS=(--keychain "$CODE_SIGN_KEYCHAIN")
}

code_prepare_codesign() {
  local eden="${EDEN_ROOT:-$HOME/Developer/GitHub/Work}"
  if [[ "${SKIP_CODESIGN_PREPARE:-0}" != "1" && -f "$eden/Tooling/prepare-codesign-keychain.sh" ]]; then
    # Unlock dedicated KC from secrets.env / R2. Never unlock login.
    bash "$eden/Tooling/prepare-codesign-keychain.sh" || true
  fi
  if [[ ! -f "$CODE_SIGN_KEYCHAIN" ]]; then
    echo "error: dedicated codesign keychain missing: $CODE_SIGN_KEYCHAIN" >&2
    echo "       bootstrap: $eden/Tooling/prepare-codesign-keychain.sh --bootstrap" >&2
    return 1
  fi

  code_load_identity_hashes

  if [[ -z "$CODE_APPLE_DEV_HASH" && -z "$CODE_APPLE_DIST_HASH" ]]; then
    echo "error: no Apple Development/Distribution identity in $CODE_SIGN_KEYCHAIN" >&2
    security find-identity -v -p codesigning "$CODE_SIGN_KEYCHAIN" >&2 || true
    return 1
  fi

  if ! security find-identity -v -p codesigning "$CODE_SIGN_KEYCHAIN" 2>/dev/null \
    | grep -Fq "$CODE_DEVELOPER_ID_APP"
  then
    echo "warn: $CODE_DEVELOPER_ID_APP not in dedicated keychain (Mac Developer ID ships will fail)" >&2
  fi

  # Installer identity is not in -p codesigning; check the full list.
  if ! security find-identity -v "$CODE_SIGN_KEYCHAIN" 2>/dev/null \
    | grep -Fq "$CODE_DEVELOPER_ID_INSTALLER"
  then
    echo "warn: $CODE_DEVELOPER_ID_INSTALLER not in dedicated keychain (pkg productsign will fail)" >&2
  fi

  code_dismiss_keychain_dialogs
  printf '▶ codesign-env: keychain=%s dist=%s dev=%s\n' \
    "$(basename "$CODE_SIGN_KEYCHAIN")" \
    "${CODE_APPLE_DIST_HASH:0:12}" \
    "${CODE_APPLE_DEV_HASH:0:12}"
  return 0
}

code_codesign_app() {
  # $1 = .app path. Deep + runtime + timestamp + dedicated keychain.
  local app="${1:?app path}"
  local ents="${2:-}"
  local extra=()
  if [[ -n "$ents" && -f "$ents" ]]; then
    extra+=(--entitlements "$ents")
  fi
  codesign --force --deep --options runtime --timestamp \
    "${CODE_SIGN_KEYCHAIN_ARGS[@]}" \
    --sign "$CODE_DEVELOPER_ID_APP" \
    "${extra[@]}" \
    "$app"
}

code_sign_macos_from_p12() {
  # Compile-unsigned then this. Throwaway keychain from identities.p12.
  # Login is never the signing source. $1=.app  $2=entitlements  $3=identity substring
  local app="${1:?app path}"
  local ents="${2:-}"
  local want="${3:-Apple Development}"
  local eden="${EDEN_ROOT:-$HOME/Developer/GitHub/Work}"
  local sign="$eden/Tooling/sign-from-p12.sh"
  if [[ ! -f "$sign" ]]; then
    echo "error: missing $sign" >&2
    return 1
  fi
  ENTITLEMENTS="$ents" bash "$sign" "$app" "$want"
}

code_productsign() {
  # $1 = unsigned component pkg, $2 = signed out pkg
  local inn="${1:?in pkg}"
  local out="${2:?out pkg}"
  productsign \
    --sign "$CODE_DEVELOPER_ID_INSTALLER" \
    "${CODE_SIGN_KEYCHAIN_ARGS[@]}" \
    "$inn" "$out"
}