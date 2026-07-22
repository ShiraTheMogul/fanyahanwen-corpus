#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: bash script/run_wuyin_jiyun_reparse_audit.sh CORPUS_ROOT OUTPUT_DIR" >&2
  exit 2
fi

corpus_root="$1"
output="$2"
mkdir -p "$output/logs"

printf '%s\n' '=============================================================================='
printf '%s\n' '五音集韻 STRUCTURAL REPARSE — ZERO WRITE'
printf '%s\n' '=============================================================================='
printf 'Corpus: %s\n' "$corpus_root"
printf 'Output: %s\n\n' "$output"

ruby script/extract_dictionary_sources.rb \
  --corpus-root "$corpus_root" \
  --viewer-root . \
  --output "$output/source_bundle" \
  --profile wuyin_only \
  --strict \
  2>&1 | tee "$output/logs/01_extract.log"

ruby script/stage_dictionary_sources.rb \
  --bundle "$output/source_bundle" \
  --output "$output/source_staging" \
  2>&1 | tee "$output/logs/02_stage.log"

ruby script/dry_run_dictionary_imports.rb \
  --bundle "$output/source_bundle" \
  --staging "$output/source_staging" \
  --output "$output/import_plan" \
  2>&1 | tee "$output/logs/03_parse.log"

ruby script/audit_wuyin_jiyun_structure.rb \
  --import-plan "$output/import_plan" \
  --output "$output/structure_audit" \
  2>&1 | tee "$output/logs/04_audit.log"

printf '\nStructural audit complete.\n'
printf 'Review: %s\n' "$output/structure_audit/summary.txt"
printf 'Do not replace the existing database import unless ready_to_replace_existing_import=true.\n'
