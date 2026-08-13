#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then :; else REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"; fi
source "$SCRIPT_DIR/_resolve_staging_root.sh"
STAGING_ROOT="$(resolve_fanya_staging_root "$REPO_ROOT")"
CONTROL_DIR="$STAGING_ROOT/_control"
PID_FILE="$CONTROL_DIR/harvest.pid"
CURRENT_LOG_FILE="$CONTROL_DIR/current_log"
printf 'Staging: %s\n' "$STAGING_ROOT"
pid="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  echo "State:   RUNNING"
  ps -o pid=,sid=,etime=,%cpu=,%mem=,cmd= -p "$pid" || true
else
  echo "State:   STOPPED"
  [[ -n "$pid" ]] && echo "Stale PID: $pid"
fi
if [[ -d "$STAGING_ROOT" ]]; then printf 'Disk:    '; du -sh "$STAGING_ROOT" 2>/dev/null | awk '{print $1}' || true; fi
if [[ -f "$CURRENT_LOG_FILE" ]]; then
  log_file="$(cat "$CURRENT_LOG_FILE" 2>/dev/null || true)"
  if [[ -n "$log_file" && -f "$log_file" ]]; then
    echo; echo "Latest log: $log_file"; echo "----------------------------------------"; tail -n 30 "$log_file" || true
  fi
fi
