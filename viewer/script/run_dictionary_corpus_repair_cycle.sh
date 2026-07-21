#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'TEXT'
Usage:
  bash script/run_dictionary_corpus_repair_cycle.sh \
    CORPUS_ROOT REVIEWED_SOURCE_BUNDLE OUTPUT_DIR [--apply]

Without --apply:
  writes an exact corpus TXT repair plan only.

With --apply:
  1. applies the guarded TXT repairs with backups;
  2. freshly extracts 洪武正韻 from the repaired corpus;
  3. stages parser copies;
  4. reruns the parser without an editorial overlay;
  5. verifies 14,379 direct-from-corpus entries and zero localized gaps.

This workflow never changes metadata.json and never writes database rows.
TEXT
  exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage

corpus_root="$1"
reviewed_bundle="$2"
output_dir="$3"
mode="${4:-}"
[[ -z "$mode" || "$mode" == "--apply" ]] || usage

repair_plan_dir="$output_dir/corpus_repair_plan"
repair_apply_dir="$output_dir/corpus_repair_apply"
repaired_bundle_dir="$output_dir/repaired_hongwu_bundle"
staging_dir="$output_dir/post_repair/source_staging"
import_dir="$output_dir/post_repair/import_plan"
verify_dir="$output_dir/post_repair/verification"
mkdir -p "$output_dir/logs"

printf '%s\n' "=============================================================================="
printf '%s\n' "HONGWU CORPUS TXT REPAIR CYCLE"
printf '%s\n' "=============================================================================="
printf 'Corpus:           %s\n' "$corpus_root"
printf 'Reviewed bundle:  %s\n' "$reviewed_bundle"
printf 'Output:           %s\n' "$output_dir"
printf 'Mode:             %s\n' "$([[ "$mode" == "--apply" ]] && echo APPLY || echo DRY RUN)"
printf '%s\n\n' "Metadata JSON will not be modified."

printf '%s\n' "Phase 1: build exact TXT repair plan..."
ruby script/plan_dictionary_corpus_repairs.rb \
  --bundle "$reviewed_bundle" \
  --corpus-root "$corpus_root" \
  --output "$repair_plan_dir" \
  2>&1 | tee "$output_dir/logs/corpus_repair_plan.log"

if [[ "$mode" != "--apply" ]]; then
  printf '\n%s\n' "DRY RUN COMPLETE — NO CORPUS, METADATA, OR DATABASE WRITES"
  printf 'Review: %s\n' "$repair_plan_dir/corpus_repair_plan.csv"
  printf 'Then rerun with --apply after approval.\n'
  exit 0
fi

printf '\n%s\n' "Phase 2: apply approved TXT repairs with backups..."
ruby script/plan_dictionary_corpus_repairs.rb \
  --bundle "$reviewed_bundle" \
  --corpus-root "$corpus_root" \
  --output "$repair_apply_dir" \
  --apply \
  2>&1 | tee "$output_dir/logs/corpus_repair_apply.log"

printf '\n%s\n' "Phase 3: freshly extract repaired 洪武正韻 from the live corpus..."
ruby script/extract_dictionary_sources.rb \
  --corpus-root "$corpus_root" \
  --viewer-root . \
  --output "$repaired_bundle_dir" \
  --profile hongwu_only \
  --strict \
  2>&1 | tee "$output_dir/logs/repaired_source_extraction.log"

printf '\n%s\n' "Phase 4: stage safe parser copies from the repaired extraction..."
ruby script/stage_dictionary_sources.rb \
  --bundle "$repaired_bundle_dir" \
  --output "$staging_dir" \
  2>&1 | tee "$output_dir/logs/post_repair_staging.log"

printf '\n%s\n' "Phase 5: parse the repaired corpus directly..."
ruby script/dry_run_dictionary_imports.rb \
  --bundle "$repaired_bundle_dir" \
  --staging "$staging_dir" \
  --output "$import_dir" \
  2>&1 | tee "$output_dir/logs/post_repair_import_plan.log"

printf '\n%s\n' "Phase 6: verify the overlay is no longer required..."
ruby script/verify_dictionary_repair_cycle.rb \
  --import-plan "$import_dir" \
  --output "$verify_dir" \
  --title 洪武正韻 \
  --expected-entries 14379 \
  2>&1 | tee "$output_dir/logs/post_repair_verification.log"

printf '%s\n' "=============================================================================="
printf '%s\n' "REPAIR CYCLE COMPLETE"
printf 'Repaired corpus TXT files: %s\n' "$repair_apply_dir/corpus_repair_plan.csv"
printf 'Backups:                   %s\n' "$repair_apply_dir/backups"
printf 'Fresh source bundle:        %s\n' "$repaired_bundle_dir"
printf 'Direct parser output:       %s\n' "$import_dir"
printf 'Verification:               %s\n' "$verify_dir/summary.txt"
printf '%s\n' "Metadata JSON modified:      0"
printf '%s\n' "Database rows written:       0"
printf '%s\n' "=============================================================================="
