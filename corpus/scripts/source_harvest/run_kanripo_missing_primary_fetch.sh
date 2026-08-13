#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=_resolve_staging_root.sh
source "$SCRIPT_DIR/_resolve_staging_root.sh"
STAGING_ROOT="$(resolve_fanya_staging_root "$REPO_ROOT")"

# Never allow a missing public GitHub repository to turn into an interactive
# username/password prompt. GitHub can present some 404s as credential failures.
export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never

echo "Using staging: $STAGING_ROOT" >&2
exec python3 "$SCRIPT_DIR/fetch_kanripo_missing_primary.py" \
  --staging-root "$STAGING_ROOT" \
  "$@"
