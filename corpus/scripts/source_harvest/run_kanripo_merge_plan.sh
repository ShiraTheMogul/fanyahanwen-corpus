#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=_resolve_staging_root.sh
source "$SCRIPT_DIR/_resolve_staging_root.sh"
STAGING_ROOT="$(resolve_fanya_staging_root "$REPO_ROOT")"

echo "Using staging: $STAGING_ROOT" >&2
exec python3 "$SCRIPT_DIR/plan_kanripo_merge.py" \
  --repo-root "$REPO_ROOT" \
  --staging-root "$STAGING_ROOT" \
  "$@"
