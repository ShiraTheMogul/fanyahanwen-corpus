#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi
STAGING_ROOT="${FANYA_HARVEST_ROOT:-$(dirname "$REPO_ROOT")/fanyahanwen-source-staging}"
PID_FILE="$STAGING_ROOT/_control/harvest.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "No harvester PID file exists."
  exit 0
fi

pid="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  echo "Invalid PID file; removing it."
  rm -f "$PID_FILE"
  exit 1
fi

if ! kill -0 "$pid" 2>/dev/null; then
  echo "Harvester is already stopped (stale PID $pid)."
  rm -f "$PID_FILE"
  exit 0
fi

sid="$(ps -o sid= -p "$pid" | tr -d '[:space:]' || true)"
echo "Sending TERM to harvester PID $pid${sid:+ (session $sid)}..."
if [[ "$sid" =~ ^[0-9]+$ ]]; then
  kill -TERM -- "-$sid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
else
  kill -TERM "$pid" 2>/dev/null || true
fi

for _ in $(seq 1 20); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "Harvester stopped cleanly. Partial .part files are retained for resume."
    exit 0
  fi
  sleep 1
done

echo "The process did not exit after TERM; forcing the entire harvest session down."
if [[ "$sid" =~ ^[0-9]+$ ]]; then
  kill -KILL -- "-$sid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
else
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$PID_FILE"
echo "Harvester force-stopped. Existing completed files remain usable; .part files can resume."
