#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: bash script/run_dictionary_extraction_and_dry_run.sh CORPUS_ROOT [OUTPUT_DIR] [all|starter]" >&2
  exit 2
fi

corpus_root="$1"
output_dir="${2:-tmp/dictionary_import/full_capture_$(date -u +%Y%m%dT%H%M%SZ)}"
profile="${3:-all}"
bundle_dir="$output_dir/source_bundle"
mkdir -p "$output_dir/logs"

printf '%s\n' "=============================================================================="
printf '%s\n' "DICTIONARY SOURCE CAPTURE + DRY RUN"
printf '%s\n' "=============================================================================="
printf 'Corpus:  %s\n' "$corpus_root"
printf 'Profile: %s\n' "$profile"
printf 'Output:  %s\n' "$output_dir"
printf '\nPhase 1/3: extract complete named source folders and viewer context...\n\n'

ruby script/extract_dictionary_sources.rb \
  --corpus-root "$corpus_root" \
  --viewer-root . \
  --profile "$profile" \
  --output "$bundle_dir" \
  2>&1 | tee "$output_dir/logs/extractor.log"

printf '\nPhases 2–3: stage and dry-parse the extracted bundle...\n\n'
bash script/run_dictionary_bundle_dry_run.sh "$bundle_dir" "$output_dir/dry_run" \
  2>&1 | tee "$output_dir/logs/dry_run_pipeline.log"

printf '\nAll jobs completed. Nothing was written to the corpus or database.\n'
printf '\nPackage everything for review with:\n'
printf '  tar -czf %s.tar.gz -C %s %s\n' \
  "$output_dir" "$(dirname "$output_dir")" "$(basename "$output_dir")"
