#!/usr/bin/env bash
set -u

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: bash script/run_dictionary_dry_runs.sh SNAPSHOT_DIR [OUTPUT_DIR]" >&2
  exit 2
fi

snapshot_dir="$1"
output_dir="${2:-${snapshot_dir%/}/dry_runs/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$output_dir/logs"

prepare_out="$output_dir/source_preparation"
import_out="$output_dir/import_plan"

printf '%s\n' "========================================================================"
printf '%s\n' "DICTIONARY DRY RUNS — PARALLEL"
printf '%s\n' "========================================================================"
printf 'Snapshot:           %s\n' "$snapshot_dir"
printf 'Preparation output: %s\n' "$prepare_out"
printf 'Import-plan output: %s\n' "$import_out"
printf '\n'

ruby script/prepare_dictionary_sources.rb \
  --snapshot "$snapshot_dir" \
  --output "$prepare_out" \
  >"$output_dir/logs/source_preparation.log" 2>&1 &
prepare_pid=$!
printf 'Started source preparation: PID %s\n' "$prepare_pid"

ruby script/plan_dictionary_imports.rb \
  --snapshot "$snapshot_dir" \
  --output "$import_out" \
  >"$output_dir/logs/import_plan.log" 2>&1 &
import_pid=$!
printf 'Started import planning:     PID %s\n' "$import_pid"

printf '\nBoth jobs are independent dry runs. They do not alter the corpus or database.\n'
printf 'Waiting for completion...\n\n'

prepare_status=0
import_status=0
wait "$prepare_pid" || prepare_status=$?
wait "$import_pid" || import_status=$?

printf '%s\n' "========================================================================"
printf 'Source preparation exit: %s\n' "$prepare_status"
printf 'Import planning exit:     %s\n' "$import_status"
printf 'Output:                   %s\n' "$output_dir"
printf '%s\n' "========================================================================"

if [[ -f "$prepare_out/summary.txt" ]]; then
  printf '\n--- Source preparation summary ---\n'
  cat "$prepare_out/summary.txt"
fi
if [[ -f "$import_out/summary.txt" ]]; then
  printf '\n--- Import-plan summary ---\n'
  cat "$import_out/summary.txt"
fi

if [[ "$prepare_status" -ne 0 || "$import_status" -ne 0 ]]; then
  printf '\nOne or both jobs failed. Inspect: %s/logs\n' "$output_dir" >&2
  exit 1
fi

printf '\nPackage the review output with:\n'
printf '  tar -czf %s.tar.gz -C %s %s\n' \
  "$output_dir" "$(dirname "$output_dir")" "$(basename "$output_dir")"
