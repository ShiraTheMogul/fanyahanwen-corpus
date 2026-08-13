#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then :; else REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"; fi
source "$SCRIPT_DIR/_resolve_staging_root.sh"
STAGING_ROOT="$(resolve_fanya_staging_root "$REPO_ROOT")"
CONTROL_DIR="$STAGING_ROOT/_control"
PID_FILE="$CONTROL_DIR/kanripo_compare.pid"
CURRENT_LOG_FILE="$CONTROL_DIR/current_kanripo_compare_log"
STATE_FILE="$STAGING_ROOT/_state/last_kanripo_compare.json"
pid="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then echo "State: RUNNING"; ps -o pid=,etime=,%cpu=,%mem=,stat=,cmd= -p "$pid" || true; else [[ -n "$pid" ]] && echo "State: STOPPED (last PID $pid)" || echo "State: NOT RUNNING"; fi
echo "Staging: $STAGING_ROOT"
if [[ -f "$STATE_FILE" ]]; then
  python3 - "$STATE_FILE" <<'PY'
import json,sys
p=sys.argv[1]
try: d=json.load(open(p,encoding='utf-8'))
except Exception as e: print(f"State file unreadable: {e}"); raise SystemExit
print(f"Comparison status: {d.get('status','unknown')}")
print(f"Progress: {d.get('processed_works',0):,}/{d.get('selected_works',0):,} complete; {d.get('failed_works',0):,} failed")
if d.get('output_dir'): print(f"Output: {d['output_dir']}")
if d.get('error'): print(f"Error: {d['error']}")
PY
fi
if [[ -f "$CURRENT_LOG_FILE" ]]; then log_file="$(cat "$CURRENT_LOG_FILE" 2>/dev/null || true)"; if [[ -n "$log_file" ]]; then echo "Log: $log_file"; echo "--- last 35 lines ---"; tail -n 35 "$log_file" 2>/dev/null || true; fi; fi
