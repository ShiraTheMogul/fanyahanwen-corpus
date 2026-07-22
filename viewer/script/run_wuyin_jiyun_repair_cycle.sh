#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 3 && $# -le 4 ]] || { echo "Usage: bash script/run_wuyin_jiyun_repair_cycle.sh CORPUS_ROOT REVIEWED_BUNDLE OUTPUT_DIR [--apply]" >&2; exit 2; }
corpus_root="$1"; bundle="$2"; output="$3"; mode="${4:-}"
[[ -z "$mode" || "$mode" == "--apply" ]] || exit 2
mkdir -p "$output/logs"

ruby script/plan_dictionary_exact_text_repairs.rb \
  --bundle "$bundle" --corpus-root "$corpus_root" \
  --output "$output/text_repair_plan" \
  2>&1 | tee "$output/logs/text_repair_plan.log"

[[ "$mode" == "--apply" ]] || { echo "Dry run complete. Review $output/text_repair_plan/text_repair_plan.csv"; exit 0; }

ruby script/plan_dictionary_exact_text_repairs.rb \
  --bundle "$bundle" --corpus-root "$corpus_root" \
  --output "$output/text_repair_apply" --apply \
  2>&1 | tee "$output/logs/text_repair_apply.log"

ruby script/extract_dictionary_sources.rb \
  --corpus-root "$corpus_root" --viewer-root . \
  --output "$output/repaired_bundle" --profile wuyin_only --strict \
  2>&1 | tee "$output/logs/extract.log"

ruby script/stage_dictionary_sources.rb \
  --bundle "$output/repaired_bundle" --output "$output/post_repair/source_staging" \
  2>&1 | tee "$output/logs/stage.log"

ruby script/dry_run_dictionary_imports.rb \
  --bundle "$output/repaired_bundle" --staging "$output/post_repair/source_staging" \
  --output "$output/post_repair/import_plan" \
  2>&1 | tee "$output/logs/parse.log"

ruby script/verify_dictionary_repair_cycle.rb \
  --import-plan "$output/post_repair/import_plan" \
  --output "$output/post_repair/verification" \
  --title 五音集韻 --expected-entries 46984 \
  2>&1 | tee "$output/logs/verify.log"
