#!/usr/bin/env bash
# Shared staging-root resolver for source-harvest scripts.
# Priority:
#   1. explicit FANYA_HARVEST_ROOT
#   2. in-repository fanyahanwen-source-staging/ when present
#   3. legacy sibling fanyahanwen-source-staging/ when present
#   4. in-repository path for new staging data
resolve_fanya_staging_root() {
  local repo_root="$1"
  local in_repo="$repo_root/fanyahanwen-source-staging"
  local legacy_sibling
  legacy_sibling="$(dirname "$repo_root")/fanyahanwen-source-staging"

  if [[ -n "${FANYA_HARVEST_ROOT:-}" ]]; then
    printf '%s\n' "$FANYA_HARVEST_ROOT"
  elif [[ -d "$in_repo" ]]; then
    printf '%s\n' "$in_repo"
  elif [[ -d "$legacy_sibling" ]]; then
    printf '%s\n' "$legacy_sibling"
  else
    printf '%s\n' "$in_repo"
  fi
}
