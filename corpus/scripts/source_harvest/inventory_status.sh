#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi
STAGING_ROOT="${FANYA_HARVEST_ROOT:-$(dirname "$REPO_ROOT")/fanyahanwen-source-staging}"
CONTROL_DIR="$STAGING_ROOT/_control"
PID_FILE="$CONTROL_DIR/inventory.pid"
CURRENT_LOG_FILE="$CONTROL_DIR/current_inventory_log"
STATE_FILE="$STAGING_ROOT/_state/last_inventory.json"

pid="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  echo "State: RUNNING"
  ps -o pid=,etime=,%cpu=,%mem=,stat=,cmd= -p "$pid" || true
else
  if [[ -n "$pid" ]]; then
    echo "State: STOPPED (last PID $pid)"
  else
    echo "State: NOT RUNNING"
  fi
fi

echo "Staging: $STAGING_ROOT"
if [[ -f "$STATE_FILE" ]]; then
  python3 - "$STATE_FILE" <<'PY'
import json,sys
p=sys.argv[1]
try:
    d=json.load(open(p,encoding='utf-8'))
except Exception as e:
    print(f"State file unreadable: {e}")
    raise SystemExit
print(f"Inventory status: {d.get('status','unknown')}")
if d.get('output_dir'):
    print(f"Output: {d['output_dir']}")
if d.get('error'):
    print(f"Error: {d['error']}")
PY
fi

if [[ -f "$CURRENT_LOG_FILE" ]]; then
  log_file="$(cat "$CURRENT_LOG_FILE" 2>/dev/null || true)"
  if [[ -n "$log_file" ]]; then
    echo "Log: $log_file"
    echo "--- last 35 lines ---"
    tail -n 35 "$log_file" 2>/dev/null || true
  fi
fi
