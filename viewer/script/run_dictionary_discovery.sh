#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: bash script/run_dictionary_discovery.sh CORPUS_ROOT [OUTPUT_DIR] [all|starter]" >&2
  exit 2
fi

corpus_root="$1"
output_dir="${2:-tmp/dictionary_import/discovery_$(date -u +%Y%m%dT%H%M%SZ)}"
profile="${3:-all}"
snapshot_dir="$output_dir/source_snapshot"
dry_run_dir="$output_dir/dry_runs"
mkdir -p "$output_dir/logs"

printf '%s\n' "========================================================================"
printf '%s\n' "DICTIONARY IMPORT DISCOVERY"
printf '%s\n' "========================================================================"
printf 'Corpus:  %s\n' "$corpus_root"
printf 'Profile: %s\n' "$profile"
printf 'Output:  %s\n' "$output_dir"
printf '\nPhase 1/2: creating immutable source snapshot...\n\n'

ruby script/snapshot_dictionary_sources.rb \
  --corpus-root "$corpus_root" \
  --profile "$profile" \
  --output "$snapshot_dir" \
  2>&1 | tee "$output_dir/logs/source_snapshot.log"

printf '\nPhase 2/2: running preparation and import planning in parallel...\n\n'
bash script/run_dictionary_dry_runs.sh "$snapshot_dir" "$dry_run_dir" \
  2>&1 | tee "$output_dir/logs/parallel_runner.log"

printf '\nAll discovery jobs completed. No corpus or database files were modified.\n'
printf '\nPackage everything for review with:\n'
printf '  tar -czf %s.tar.gz -C %s %s\n' \
  "$output_dir" "$(dirname "$output_dir")" "$(basename "$output_dir")"
