#!/bin/bash
# Build script for the Roku app.
# Injects WATCH_PUBLIC_KEY / WATCH_PRIVATE_KEY into a staging copy of Auth.brs, then zips.
# Source tree is never mutated, so the key can't leak into git.
set -euo pipefail

ROKU_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROKU_DIR"

if [ -z "${WATCH_PUBLIC_KEY:-}" ] && [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [ -z "${WATCH_PUBLIC_KEY:-}" ] || [ -z "${WATCH_PRIVATE_KEY:-}" ]; then
  echo "ERROR: WATCH_PUBLIC_KEY / WATCH_PRIVATE_KEY not set. Export them or create .env (see .env.example)."
  exit 1
fi

echo "Building with key ID: ${WATCH_PUBLIC_KEY:0:8}..."

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -r manifest source components images "$STAGE/"

python3 - "$STAGE/source/Auth.brs" "$WATCH_PUBLIC_KEY" "$WATCH_PRIVATE_KEY" <<'EOF'
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
