#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then :; else REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"; fi
source "$SCRIPT_DIR/_resolve_staging_root.sh"
STAGING_ROOT="$(resolve_fanya_staging_root "$REPO_ROOT")"
CONTROL_DIR="$STAGING_ROOT/_control"
LOG_DIR="$CONTROL_DIR/logs"
PID_FILE="$CONTROL_DIR/kanripo_compare.pid"
CURRENT_LOG_FILE="$CONTROL_DIR/current_kanripo_compare_log"
mkdir -p "$LOG_DIR"
if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then echo "A Kanripo comparison job is already running as PID $old_pid."; echo "Use: bash $SCRIPT_DIR/kanripo_compare_status.sh"; exit 1; fi
  rm -f "$PID_FILE"
fi
stamp="$(date +%Y%m%d-%H%M%S)"
log_file="$LOG_DIR/kanripo-compare-$stamp.log"
printf '%s\n' "$log_file" > "$CURRENT_LOG_FILE"
priority=(nice -n "${FANYA_KANRIPO_COMPARE_NICE:-10}")
if command -v ionice >/dev/null 2>&1; then priority+=(ionice -c 2 -n 6); fi
command=("${priority[@]}" python3 "$SCRIPT_DIR/kanripo_witness_compare.py" --repo-root "$REPO_ROOT" --staging-root "$STAGING_ROOT" "$@")
nohup setsid "${command[@]}" >"$log_file" 2>&1 </dev/null &
pid=$!
printf '%s\n' "$pid" > "$PID_FILE"
sleep 0.25
if ! kill -0 "$pid" 2>/dev/null; then echo "Kanripo comparison exited immediately. Log: $log_file"; tail -n 80 "$log_file" || true; exit 1; fi
echo "Kanripo witness comparison started."
echo "PID:          $pid"
echo "Staging:      $STAGING_ROOT"
echo "Log:          $log_file"
echo "Default batch: 100 refined exact-title works"
echo "Status:       bash $SCRIPT_DIR/kanripo_compare_status.sh"
echo "Stop cleanly: bash $SCRIPT_DIR/stop_kanripo_compare_background.sh"
