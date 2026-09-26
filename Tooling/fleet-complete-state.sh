#!/usr/bin/env bash
# Fleet completion state — hard gate so git push alone cannot be "done".
#
# Apps: make | work | fun | watch
# State dir: ~/Library/Application Support/watch.apps/fleet-complete/
#
# Commands:
#   mark-pending <app> <full-sha> [reason]   # after product hits origin/main
#   mark-fleet-shipped <app> <full-sha> [version]  # after the phone reports that bundle version
#   status [app|all]
#   assert-complete [app|all]   # exit 1 if any pending != fleet shipped
#   open-failure <app>          # write HostShipFailures-compatible open row
#
# Law: plan/task is incomplete while pending_sha is set and != fleet_sha.
set -euo pipefail

STATE_DIR="${CODE_FLEET_STATE_DIR:-$HOME/Library/Application Support/watch.apps/fleet-complete}"
FAILURES_DIR="${CODE_SHIP_SUPPORT:-$HOME/Library/Application Support/watch.apps}"
FAILURES_JSON="$FAILURES_DIR/ship-failures.json"
# Legacy Node path — still merge-read if present
LEGACY_FAILURES="$HOME/Library/Application Support/code-cli-host/ship-failures.json"

mkdir -p "$STATE_DIR" "$FAILURES_DIR"

die() { echo "error: fleet-complete: $*" >&2; exit 1; }
log() { printf '▶ fleet-complete: %s\n' "$*"; }

norm_app() {
  local a
  a="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$a" in
    make|code|codeapp) echo make ;;
    work|eden) echo work ;;
    fun|babel|babelnet) echo fun ;;
    watch) echo watch ;;
    all|"") echo all ;;
    *) die "app must be make|work|fun|watch|all (got: $1)" ;;
  esac
}

state_file() {
  echo "$STATE_DIR/${1}.json"
}

read_state() {
  local app="$1" f
  f="$(state_file "$app")"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo '{}'
  fi
}

write_state() {
  local app="$1" json="$2" f
  f="$(state_file "$app")"
  printf '%s\n' "$json" >"$f"
  chmod 600 "$f" 2>/dev/null || true
}

# JSON helpers via python3 (always on Mac)
py_get() {
  local json="$1" key="$2"
  python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); print(d.get(sys.argv[2],"") or "")' "$json" "$key"
}

py_set() {
  python3 - "$@" <<'PY'
import json, sys, time
app, path = sys.argv[1], sys.argv[2]
updates = json.loads(sys.argv[3])
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
d.update(updates)
d["app"] = app
d["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
with open(path, "w") as f:
    json.dump(d, f, indent=2, sort_keys=True)
    f.write("\n")
print(json.dumps(d))
PY
}

mark_pending() {
  local app sha reason f
  app="$(norm_app "${1:-}")"
  [[ "$app" != "all" ]] || die "mark-pending needs a single app"
  sha="${2:-}"
  reason="${3:-product_on_main_fleet_not_shipped}"
  [[ ${#sha} -ge 7 ]] || die "mark-pending needs full or short git sha"
  f="$(state_file "$app")"
  py_set "$app" "$f" "$(python3 -c 'import json,sys; print(json.dumps({"pending_sha":sys.argv[1],"pending_reason":sys.argv[2],"pending_at":__import__("time").strftime("%Y-%m-%dT%H:%M:%SZ",__import__("time").gmtime())}))' "$sha" "$reason")" >/dev/null
  log "$app pending_sha=${sha:0:12}… — NOT DONE until fleet ship"
  open_failure "$app" "$sha" "$reason" || true
  # Loud terminal banner — agents must not ignore
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  FLEET SHIP REQUIRED — git push is NOT complete              ║"
  echo "║  app=$app  sha=${sha:0:12}                                     "
  echo "║  Run:  bash Tooling/ship-mdm.sh   (Watch)                    ║"
  echo "║  Or:   MCP make ship app=watch mode=full                     ║"
  echo "║  Gate: bash Tooling/fleet-complete-state.sh assert-complete  ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
}

mark_fleet_shipped() {
  local app sha version f pending
  app="$(norm_app "${1:-}")"
  [[ "$app" != "all" ]] || die "mark-fleet-shipped needs a single app"
  sha="${2:-}"
  version="${3:-}"
  [[ ${#sha} -ge 7 ]] || die "mark-fleet-shipped needs git sha of the IPA"
  f="$(state_file "$app")"
  pending="$(py_get "$(read_state "$app")" pending_sha)"
  py_set "$app" "$f" "$(python3 -c 'import json,sys; print(json.dumps({"fleet_sha":sys.argv[1],"fleet_version":sys.argv[2],"fleet_shipped_at":__import__("time").strftime("%Y-%m-%dT%H:%M:%SZ",__import__("time").gmtime()),"pending_sha":"","pending_reason":"","last_ok":True}))' "$sha" "$version")" >/dev/null
  log "$app fleet_sha=${sha:0:12}… version=${version:-?} — fleet step OK"
  resolve_failure "$app" "$sha" || true
  if [[ -n "$pending" && "$pending" != "$sha" && "${pending:0:12}" != "${sha:0:12}" ]]; then
    log "note: pending was ${pending:0:12}… fleet marked ${sha:0:12}… (override)"
  fi
}

status_one() {
  local app="$1" j pending fleet
  j="$(read_state "$app")"
  pending="$(py_get "$j" pending_sha)"
  fleet="$(py_get "$j" fleet_sha)"
  local ok=0
  if [[ -z "$pending" ]]; then
    ok=1
  elif [[ -n "$fleet" && ( "$pending" == "$fleet" || "${pending:0:12}" == "${fleet:0:12}" ) ]]; then
    ok=1
  fi
  local fleet_s="${fleet:0:12}"
  local pend_s="${pending:0:12}"
  [[ -n "$fleet_s" ]] || fleet_s="none"
  [[ -n "$pend_s" ]] || pend_s="none"
  if [[ "$ok" -eq 1 ]]; then
    echo "OK  $app  fleet=$fleet_s  pending=clear"
    return 0
  fi
  echo "NEED $app  pending=$pend_s  fleet=$fleet_s  → ship-mdm required"
  return 1
}

cmd_status() {
  local app rc=0
  app="$(norm_app "${1:-all}")"
  if [[ "$app" == "all" ]]; then
    for a in make work fun watch; do
      status_one "$a" || rc=1
    done
    return $rc
  fi
  status_one "$app"
}

cmd_assert() {
  local app
  app="$(norm_app "${1:-all}")"
  if cmd_status "$app"; then
    log "assert-complete OK ($app)"
    return 0
  fi
  echo "" >&2
  echo "error: FLEET INCOMPLETE — cannot claim plan/task done" >&2
  echo "  fix: bash ~/Developer/GitHub/Make/Tooling/ship-mdm.sh   # Make" >&2
  echo "  fix: bash ~/Developer/GitHub/Work/Tooling/ship-mdm.sh      # Work" >&2
  echo "  fix: bash ~/Developer/GitHub/Fun/Tooling/ship-mdm.sh       # Fun" >&2
  echo "  fix: bash ~/Developer/GitHub/watch/Tooling/ship-mdm.sh     # Watch" >&2
  echo "  then: bash Tooling/fleet-complete-state.sh assert-complete" >&2
  exit 1
}

# Record fleet_pending for MCP `ship failures` only. Never reset chatInjectedAt —
# the host used to dump this into a random ACP session and kick plan mode.
open_failure() {
  local app="$1" sha="$2" reason="$3"
  local id="fleet_pending_${app}_${sha:0:12}"
  python3 - "$FAILURES_JSON" "$LEGACY_FAILURES" "$id" "$app" "$sha" "$reason" <<'PY'
import json, sys, time, os
path, legacy, fid, app, sha, reason = sys.argv[1:7]
paths = [path]
if legacy and os.path.isfile(legacy):
    paths.append(legacy)

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {"open": [], "resolved": []}

root = load(path)
open_rows = root.get("open") or []
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
# Keep an existing same-id row so we do not re-arm chat inject.
existing = next((r for r in open_rows if r.get("id") == fid), None)
open_rows = [r for r in open_rows if not (
    str(r.get("id","")) == fid
    or str(r.get("id","")).startswith(f"fleet_pending_{app}_")
    or (r.get("app") == app and r.get("reason") == "fleet_pending")
)]
row = existing or {
    "id": fid,
    "app": app,
    "sha": sha,
    "exitCode": None,
    "reason": "fleet_pending",
    "logTail": (
        f"Git product is on origin/main ({sha[:12]}) but phones do not have this IPA yet.\n"
        f"Reason: {reason}\n"
        f"Required: bash Tooling/ship-mdm.sh in the {app} repo (or MCP make ship app={app} mode=full).\n"
        f"Then: bash Tooling/fleet-complete-state.sh assert-complete\n"
        "You may NOT ack this until fleet_sha matches pending_sha."
    ),
    "createdAt": now,
}
row["sha"] = sha
row["logTail"] = (
    f"Git product is on origin/main ({sha[:12]}) but phones do not have this IPA yet.\n"
    f"Reason: {reason}\n"
    f"Required: bash Tooling/ship-mdm.sh in the {app} repo (or MCP make ship app={app} mode=full).\n"
    f"Then: bash Tooling/fleet-complete-state.sh assert-complete\n"
    "You may NOT ack this until fleet_sha matches pending_sha."
)
# Stamp injected so even an old host will not enqueue this as a user prompt.
if not row.get("chatInjectedAt"):
    row["chatInjectedAt"] = now
open_rows.append(row)
root["open"] = open_rows
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(root, f, indent=2)
    f.write("\n")
# mirror legacy path so older host readers see it
try:
    os.makedirs(os.path.dirname(legacy), exist_ok=True)
    with open(legacy, "w") as f:
        json.dump(root, f, indent=2)
        f.write("\n")
except Exception:
    pass
print(fid)
PY
}

resolve_failure() {
  local app="$1" sha="$2"
  python3 - "$FAILURES_JSON" "$LEGACY_FAILURES" "$app" "$sha" <<'PY'
import json, sys, time, os
path, legacy, app, sha = sys.argv[1:5]
def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {"open": [], "resolved": []}
root = load(path)
open_rows = root.get("open") or []
resolved = root.get("resolved") or []
keep = []
for r in open_rows:
    rid = str(r.get("id",""))
    if r.get("app") == app and (
        r.get("reason") == "fleet_pending" or rid.startswith(f"fleet_pending_{app}_")
    ):
        r["resolvedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        r["resolvedSha"] = sha
        resolved.append(r)
    else:
        keep.append(r)
root["open"] = keep
root["resolved"] = resolved[-50:]
for p in (path, legacy):
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            json.dump(root, f, indent=2)
            f.write("\n")
    except Exception:
        pass
PY
}

# --- main ---
CMD="${1:-status}"
shift || true
case "$CMD" in
  mark-pending) mark_pending "$@" ;;
  mark-fleet-shipped) mark_fleet_shipped "$@" ;;
  status) cmd_status "${1:-all}" ;;
  assert-complete|assert) cmd_assert "${1:-all}" ;;
  open-failure) open_failure "$(norm_app "${1:-}")" "${2:-unknown}" "${3:-manual}" ;;
  -h|--help|help)
    sed -n '2,20p' "$0"
    ;;
  *)
    die "unknown command: $CMD (status|mark-pending|mark-fleet-shipped|assert-complete)"
    ;;
esac