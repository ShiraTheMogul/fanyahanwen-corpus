#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then :; else REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"; fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_resolve_staging_root.sh"
STAGING_ROOT="$(resolve_fanya_staging_root "$REPO_ROOT")"
echo "Using staging: $STAGING_ROOT"
exec python3 "$SCRIPT_DIR/generate_kanripo_incorporation_overlay.py" \
  --repo-root "$REPO_ROOT" \
  --staging-root "$STAGING_ROOT" \
  "$@"
