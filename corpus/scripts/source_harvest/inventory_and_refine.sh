#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$1"
STAGING_ROOT="$2"
shift 2

python3 "$SCRIPT_DIR/inventory_sources.py" \
  --repo-root "$REPO_ROOT" \
  --staging-root "$STAGING_ROOT" \
  "$@"

python3 "$SCRIPT_DIR/refine_inventory.py" \
  --staging-root "$STAGING_ROOT"
