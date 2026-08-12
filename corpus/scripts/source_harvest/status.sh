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
PID_FILE="$CONTROL_DIR/harvest.pid"
CURRENT_LOG_FILE="$CONTROL_DIR/current_log"

printf 'Staging: %s\n' "$STAGING_ROOT"
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
else
  pid=""
fi

if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  echo "State:   RUNNING"
  ps -o pid=,sid=,etime=,%cpu=,%mem=,cmd= -p "$pid" || true
else
  echo "State:   STOPPED"
  if [[ -n "$pid" ]]; then
    echo "Stale PID: $pid"
  fi
fi

if [[ -d "$STAGING_ROOT" ]]; then
  printf 'Disk:    '
  du -sh "$STAGING_ROOT" 2>/dev/null | awk '{print $1}' || true
fi

if [[ -f "$CURRENT_LOG_FILE" ]]; then
  log_file="$(cat "$CURRENT_LOG_FILE" 2>/dev/null || true)"
  if [[ -n "$log_file" && -f "$log_file" ]]; then
    echo
    echo "Latest log: $log_file"
    echo "----------------------------------------"
    tail -n 30 "$log_file" || true
  fi
fi
