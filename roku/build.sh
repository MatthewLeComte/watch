#!/bin/bash
# Build script for the Roku app.
# Injects WATCH_PUBLIC_KEY / WATCH_PRIVATE_KEY into a staging copy of Main.brs, then zips.
# Source tree is never mutated, so the key can't leak into git.
set -euo pipefail

ROKU_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROKU_DIR"

if [ -f ".env" ]; then
  # .env provides defaults; explicit environment always wins.
  _OVERRIDE_HOST="${ROKU_HOST:-}"
  _OVERRIDE_USER="${ROKU_DEV_USER:-}"
  _OVERRIDE_PASS="${ROKU_DEV_PASSWORD:-}"
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  if [ -n "$_OVERRIDE_HOST" ]; then ROKU_HOST="$_OVERRIDE_HOST"; fi
  if [ -n "$_OVERRIDE_USER" ]; then ROKU_DEV_USER="$_OVERRIDE_USER"; fi
  if [ -n "$_OVERRIDE_PASS" ]; then ROKU_DEV_PASSWORD="$_OVERRIDE_PASS"; fi
fi

if [ -z "${WATCH_PUBLIC_KEY:-}" ] || [ -z "${WATCH_PRIVATE_KEY:-}" ]; then
  echo "ERROR: WATCH_PUBLIC_KEY / WATCH_PRIVATE_KEY not set. Export them or create .env (see .env.example)."
  exit 1
fi

echo "Building with key ID: ${WATCH_PUBLIC_KEY:0:8}..."

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -r manifest source components images "$STAGE/"

python3 - "$STAGE/source/Main.brs" "$WATCH_PUBLIC_KEY" "$WATCH_PRIVATE_KEY" <<'EOF'
import sys
path, pub, priv = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
assert src.count("__WATCH_PUBLIC_KEY__") == 1, "public key placeholder missing or duplicated"
assert src.count("__WATCH_PRIVATE_KEY__") == 1, "private key placeholder missing or duplicated"
src = src.replace("__WATCH_PUBLIC_KEY__", pub).replace("__WATCH_PRIVATE_KEY__", priv)
open(path, "w").write(src)
EOF

rm -f app.zip
(cd "$STAGE" && zip -qr "$ROKU_DIR/app.zip" manifest source components images -x "*.DS_Store")

echo "Built app.zip ($(wc -c < app.zip) bytes)"
unzip -l app.zip | awk '{print $4}' | grep -E "^(manifest|source/|components/|images/)" | sort

if [ "${1:-}" = "--install" ]; then
  if [ -z "${ROKU_HOST:-}" ] || [ -z "${ROKU_DEV_PASSWORD:-}" ]; then
    echo "ERROR: ROKU_HOST / ROKU_DEV_PASSWORD not set. Add them to .env (see .env.example)."
    echo "ROKU_DEV_PASSWORD is the Developer Mode password (Roku Settings -> System -> Advanced system settings -> Developer settings)."
    exit 1
  fi
  ROKU_DEV_USER="${ROKU_DEV_USER:-rokudev}"
  echo "Installing to http://${ROKU_HOST} as ${ROKU_DEV_USER}..."
  RESP=$(curl -s --digest --max-time 120 -u "${ROKU_DEV_USER}:${ROKU_DEV_PASSWORD}" -F "archive=@app.zip" -F "mysubmit=Install" "http://${ROKU_HOST}/plugin_install")
  echo "$RESP" | python3 -c "
import json, re, sys
html = sys.stdin.read()
m = re.search(r\"params = JSON\.parse\('(.*?)'\);\", html, re.S)
if not m:
    print('installer: UNREADABLE RESPONSE')
    sys.exit(3)
raw = m.group(1)
try:
    params = json.loads(raw)
except Exception:
    params = json.loads(raw.replace(chr(92) + chr(39), chr(39)))
errs = [x['text'] for x in params.get('messages', []) if x.get('type') == 'error']
for e in errs:
    print('installer ERROR:')
    print(e[:1500])
sys.exit(1 if errs else 0)
" || { echo "INSTALL FAILED (see error above)"; exit 1; }
  echo "installer: compiled + staged OK"
  WANT=$(awk -F= '/^(major|minor|build)_version/{gsub(/ /,"",$2); sub(/^0+/,"",$2); if($2=="")$2=0; printf "%s%s",$2,(++n<3?".":"\n")}' manifest)
  GOT=""
  for i in $(seq 1 10); do
    GOT=$(curl -s --max-time 10 "http://${ROKU_HOST}:8060/query/apps" | grep 'id="dev"' | sed 's/.*version="\([^"]*\)".*/\1/' || true)
    if [ -n "$GOT" ]; then break; fi
    sleep 3
  done
  echo "manifest version: ${WANT}  installed version: ${GOT:-<none>}"
  if [ "${GOT}" != "${WANT}" ]; then
    echo "ERROR: installed version does not match. Install failed (check dev password + Developer Mode)."
    exit 1
  fi
  echo "Installed OK."
fi
