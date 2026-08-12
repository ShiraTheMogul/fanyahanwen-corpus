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
LOG_DIR="$CONTROL_DIR/logs"
PID_FILE="$CONTROL_DIR/harvest.pid"
CURRENT_LOG_FILE="$CONTROL_DIR/current_log"
mkdir -p "$LOG_DIR"

if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A harvester is already running as PID $old_pid."
    echo "Use: bash $SCRIPT_DIR/status.sh"
    exit 1
  fi
  rm -f "$PID_FILE"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
log_file="$LOG_DIR/harvest-$stamp.log"
printf '%s\n' "$log_file" > "$CURRENT_LOG_FILE"

priority=(nice -n "${FANYA_HARVEST_NICE:-15}")
if command -v ionice >/dev/null 2>&1; then
  priority+=(ionice -c 2 -n 7)
fi

command=(
  "${priority[@]}"
  python3 "$SCRIPT_DIR/harvest_sources.py"
  --staging-root "$STAGING_ROOT"
  "$@"
)

# setsid gives the harvester its own process group. stop_background.sh can then
# terminate the Python process and any git/network child together.
nohup setsid "${command[@]}" >"$log_file" 2>&1 </dev/null &
pid=$!
printf '%s\n' "$pid" > "$PID_FILE"

sleep 0.25
if ! kill -0 "$pid" 2>/dev/null; then
  echo "Harvester exited immediately. Log: $log_file"
  tail -n 40 "$log_file" || true
  exit 1
fi

echo "Harvester started."
echo "PID:          $pid"
echo "Staging:      $STAGING_ROOT"
echo "Log:          $log_file"
echo "Status:       bash $SCRIPT_DIR/status.sh"
echo "Stop cleanly: bash $SCRIPT_DIR/stop_background.sh"
