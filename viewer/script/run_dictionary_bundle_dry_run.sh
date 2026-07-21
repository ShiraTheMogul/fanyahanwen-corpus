#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: bash script/run_dictionary_bundle_dry_run.sh BUNDLE_DIR [OUTPUT_DIR]" >&2
  exit 2
fi

bundle_dir="$1"
output_dir="${2:-${bundle_dir%/}/dry_run_$(date -u +%Y%m%dT%H%M%SZ)}"
staging_dir="$output_dir/source_staging"
import_dir="$output_dir/import_plan"
mkdir -p "$output_dir/logs"

printf '%s\n' "=============================================================================="
printf '%s\n' "DICTIONARY SOURCE BUNDLE — STAGED DRY RUN"
printf '%s\n' "=============================================================================="
printf 'Bundle:  %s\n' "$bundle_dir"
printf 'Output:  %s\n' "$output_dir"
printf '\nPhase 1/2: stage safe parser copies and complete diagnostics...\n\n'

ruby script/stage_dictionary_sources.rb \
  --bundle "$bundle_dir" \
  --output "$staging_dir" \
  2>&1 | tee "$output_dir/logs/source_staging.log"

printf '\nPhase 2/2: run source-specific import probes against the staged copies...\n\n'

ruby script/dry_run_dictionary_imports.rb \
  --bundle "$bundle_dir" \
  --staging "$staging_dir" \
  --output "$import_dir" \
  2>&1 | tee "$output_dir/logs/import_plan.log"

printf '%s\n' "=============================================================================="
printf '%s\n' "DRY RUN COMPLETE — NO CORPUS, METADATA, OR DATABASE WRITES"
printf 'Output: %s\n' "$output_dir"
printf '%s\n' "=============================================================================="
