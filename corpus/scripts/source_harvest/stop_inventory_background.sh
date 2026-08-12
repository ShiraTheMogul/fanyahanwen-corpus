#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi
STAGING_ROOT="${FANYA_HARVEST_ROOT:-$(dirname "$REPO_ROOT")/fanyahanwen-source-staging}"
PID_FILE="$STAGING_ROOT/_control/inventory.pid"

pid="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  echo "No inventory PID is recorded."
  exit 0
fi
if ! kill -0 "$pid" 2>/dev/null; then
  echo "Inventory PID $pid is no longer running."
  exit 0
fi

echo "Stopping inventory session $pid..."
kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 20); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Inventory stopped."
    exit 0
  fi
  sleep 1
done

echo "Inventory did not stop after 20 seconds; killing its detached session."
kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
