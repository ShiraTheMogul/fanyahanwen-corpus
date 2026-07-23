#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: bash script/run_wuyin_jiyun_reparse_audit.sh CORPUS_ROOT OUTPUT_DIR [PREVIOUS_JSONL]" >&2
  exit 2
fi

corpus_root="$1"
output="$2"
previous_jsonl="${3:-}"
mkdir -p "$output/logs"

printf '%s\n' '=============================================================================='
printf '%s\n' '五音集韻 PARSER V10 — ZERO-WRITE REPARSE, AUDIT, AND PARITY REPORT'
printf '%s\n' '=============================================================================='
printf 'Corpus:         %s\n' "$corpus_root"
printf 'Output:         %s\n' "$output"
printf 'Previous JSONL: %s\n\n' "${previous_jsonl:-not supplied}"

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

if [[ -n "$previous_jsonl" ]]; then
  ruby script/compare_wuyin_jiyun_imports.rb \
    --previous "$previous_jsonl" \
    --current "$output/import_plan/entries.ready_for_import_review.jsonl" \
    --output "$output/import_comparison" \
    2>&1 | tee "$output/logs/05_compare.log"
fi

printf '\nV10 audit complete.\n'
printf 'Structural decision: %s\n' "$output/structure_audit/summary.txt"
printf 'Source findings:      %s\n' "$output/structure_audit/source_quality_findings.csv"
printf 'Ready JSONL:          %s\n' "$output/import_plan/entries.ready_for_import_review.jsonl"
if [[ -n "$previous_jsonl" ]]; then
  printf 'Parity report:        %s\n' "$output/import_comparison/summary.txt"
fi
printf '\nThis runner performs no corpus writes and no database writes.\n'
