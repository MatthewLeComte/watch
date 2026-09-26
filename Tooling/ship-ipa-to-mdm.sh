#!/usr/bin/env bash
# Xcode-built Watch.ipa → MDM server (R2) → InstallApplication.
# Flow: archive on Mac/Xcode → this script → https://mdm…/mdm/tools/upload-watch-ipa
# NOT GitHub Actions. NOT App Store Connect upload.
set -euo pipefail

IPA="${1:?usage: $0 /path/to/Watch.ipa [version]}"
VERSION="${2:-}"
ORIGIN="${MDM_API_ORIGIN:-https://mdm.cornerstonecoatings.com}"
# private also proxies some tools; prefer mdm host
if [[ ! -f "$IPA" ]]; then
  echo "error: IPA not found: $IPA" >&2
  exit 2
fi
if [[ -z "$VERSION" ]]; then
  VERSION="$(date +%s)"
fi

# Load operator / tools auth (Code host env)
ENV_FILE="${MAKE_CLI_HOST_ENV:-${EDEN_CLI_HOST_ENV:-}}"
if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
  for cand in \
    "$HOME/Library/Application Support/make.apps/env" \
    "$HOME/Library/Application Support/com.primary.make.id/env"
  do
    if [[ -f "$cand" ]]; then ENV_FILE="$cand"; break; fi
  done
fi
if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

HDRS=(
  -H "Accept: application/json"
  -H "Content-Type: application/octet-stream"
  -H "X-Make-Ipa-Version: ${VERSION}"
  -H "X-Apple-Bundle-Id: watch.apps"
  -H "User-Agent: Watch/xcode-ship-mdm"
)
if [[ -n "${EDEN_OPERATOR_EMAIL:-}" && -n "${EDEN_DEVICE_SECRET:-}" ]]; then
  HDRS+=(-H "X-Eden-Operator-Email: ${EDEN_OPERATOR_EMAIL}")
  HDRS+=(-H "X-Eden-Device-Secret: ${EDEN_DEVICE_SECRET}")
fi
KEY="${MDM_TOOLS_PUSH_KEY:-${MDM_BOOTSTRAP_KEY:-}}"
if [[ -n "$KEY" ]]; then
  HDRS+=(-H "X-Eden-Tools-Key: ${KEY}")
  HDRS+=(-H "X-Eden-Bootstrap-Key: ${KEY}")
fi

# USB is the proof. CoreDevice UUID first, hardware UDID second.
phone_has_watch_version() {
  local want="$1" dev json
  json="$(mktemp)"
  for dev in \
    "${PHONE_COREDEVICE:-56ADC86F-41CD-5CEC-860E-CB9C150A5435}" \
    "${PHONE_UDID:-00008120-000658260283C01E}"
  do
    if xcrun devicectl device info apps --device "$dev" --json-output "$json" >/dev/null 2>&1; then
      if python3 - "$json" "$want" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = sys.argv[2]
def walk(o):
    if isinstance(o, dict):
        bid = o.get("bundleIdentifier") or o.get("bundleID")
        ver = str(o.get("bundleVersion") or "")
        if bid == "watch.apps" and ver == want:
            return True
        return any(walk(v) for v in o.values())
    if isinstance(o, list):
        return any(walk(v) for v in o)
    return False
sys.exit(0 if walk(d) else 1)
PY
      then
        rm -f "$json"
        return 0
      fi
    fi
  done
  rm -f "$json"
  return 1
}

http_transient() {
  case "$1" in
    000|408|425|429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

BYTES="$(wc -c <"$IPA" | tr -d ' ')"
echo "▶ PUT Watch.ipa → MDM (${BYTES} bytes) version=$VERSION"

ENC_VER="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$VERSION")"
body_file="$(mktemp)"
code=000
put_ok=0
delay=2
# Hosts × endpoints, then backoff rounds for 5xx / timeout. Permanent 4xx does not retry forever.
for round in 1 2 3 4; do
  saw_transient=0
  for base in "$ORIGIN" "https://private.cornerstonecoatings.com" "https://mdm.cornerstonecoatings.com"; do
    for path in \
      "/mdm/tools/upload-watch-ipa?version=${ENC_VER}"
    do
      code="$(curl -sS --connect-timeout 30 --max-time 600 \
        -o "$body_file" -w '%{http_code}' \
        -X PUT "${base}${path}" \
        "${HDRS[@]}" \
        --data-binary @"$IPA" || echo 000)"
      echo "  $base${path%%\?*} → HTTP $code (round $round)"
      if [[ "$code" == "200" || "$code" == "201" ]]; then
        cat "$body_file"; echo
        put_ok=1
        break 3
      fi
      if http_transient "$code"; then
        saw_transient=1
      else
        echo "  non-retryable HTTP $code at $base${path%%\?*}" >&2
      fi
    done
  done
  if [[ "$put_ok" -eq 1 ]]; then
    break
  fi
  if [[ "$saw_transient" -eq 0 || "$round" -ge 4 ]]; then
    break
  fi
  echo "warn: PUT not accepted (last HTTP $code) — retry $round/4 in ${delay}s" >&2
  sleep "$delay"
  delay=$((delay * 2))
done
rm -f "$body_file"

if [[ "$put_ok" -ne 1 ]]; then
  echo "error: MDM rejected Watch IPA upload (last HTTP $code)" >&2
  exit 1
fi

if [[ "${CODE_MDM_SKIP_INSTALL:-0}" == "1" ]]; then
  echo "✅ IPA on MDM (install skipped)"
  exit 0
fi

echo "▶ InstallApplication Watch → Matthew"
install_ok=0
delay=2
for attempt in 1 2 3; do
  for base in "$ORIGIN" "https://private.cornerstonecoatings.com" "https://mdm.cornerstonecoatings.com"; do
    ic="$(curl -sS --connect-timeout 20 --max-time 120 \
      -o /tmp/watch-install.json -w '%{http_code}' \
      -X POST "${base}/mdm/tools/install-watch" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      ${KEY:+-H "X-Eden-Tools-Key: $KEY"} \
      ${KEY:+-H "X-Eden-Bootstrap-Key: $KEY"} \
      ${EDEN_OPERATOR_EMAIL:+-H "X-Eden-Operator-Email: $EDEN_OPERATOR_EMAIL"} \
      ${EDEN_DEVICE_SECRET:+-H "X-Eden-Device-Secret: $EDEN_DEVICE_SECRET"} \
      -d '{"force":true,"removeFirst":false}' || echo 000)"
    echo "  install $base → HTTP $ic (attempt $attempt)"
    cat /tmp/watch-install.json 2>/dev/null; echo
    if [[ "$ic" == "200" || "$ic" == "201" ]]; then
      install_ok=1
      break 2
    fi
  done
  echo "warn: install HTTP $ic — retry in ${delay}s" >&2
  sleep "$delay"
  delay=$((delay * 2))
done

if [[ "$install_ok" -ne 1 ]]; then
  echo "error: InstallApplication failed after retries — IPA may be on MDM but phones were NOT woken" >&2
  exit 1
fi

# Queued / already_pending is not installed. The phone has to report the version.
echo "▶ Confirm watch.apps $VERSION is on the phone. A queued MDM command is not an install."
phone_ok=0
for i in $(seq 1 30); do
  if phone_has_watch_version "$VERSION"; then
    phone_ok=1
    break
  fi
  echo "  phone does not have $VERSION yet ($i/30)"
  sleep 4
done
if [[ "$phone_ok" -ne 1 ]]; then
  echo "error: MDM queued InstallApplication but the connected phone does not have watch.apps $VERSION" >&2
  exit 1
fi

echo "✅ Phone has watch.apps $VERSION"
echo "   OTA: https://mdm.cornerstonecoatings.com/mdm/apps/watch/Watch.ipa"