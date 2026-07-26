#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: bash script/run_next_dictionary_cycle.sh CORPUS_ROOT [OUTPUT_DIR]" >&2
  exit 2
fi

corpus_root="$1"
output_root="${2:-tmp/dictionary_import/next_cycle_$(date -u +%Y%m%dT%H%M%SZ)}"
config="config/dictionary_import/next_cycle.yml"

run_profile() {
  local profile="$1"
  local profile_root="$output_root/$profile"
  local bundle_dir="$profile_root/source_bundle"
  local staging_dir="$profile_root/source_staging"
  local import_dir="$profile_root/import_plan"

  mkdir -p "$profile_root/logs"

  printf '\n%s\n' "=============================================================================="
  printf 'PROFILE: %s\n' "$profile"
  printf '%s\n' "=============================================================================="

  ruby script/extract_dictionary_sources.rb \
    --corpus-root "$corpus_root" \
    --viewer-root . \
    --config "$config" \
    --profile "$profile" \
    --output "$bundle_dir" \
    2>&1 | tee "$profile_root/logs/extractor.log"

  ruby script/stage_dictionary_sources.rb \
    --bundle "$bundle_dir" \
    --output "$staging_dir" \
    2>&1 | tee "$profile_root/logs/source_staging.log"

  if [[ "$profile" == "jiyun_only" ]]; then
    ruby -r ./script/dictionary_import/jiyun_boundary_repair.rb \
      script/dry_run_dictionary_imports.rb \
      --bundle "$bundle_dir" \
      --staging "$staging_dir" \
      --output "$import_dir" \
      --config "$config" \
      2>&1 | tee "$profile_root/logs/import_plan.log"
  else
    ruby script/dry_run_dictionary_imports.rb \
      --bundle "$bundle_dir" \
      --staging "$staging_dir" \
      --output "$import_dir" \
      --config "$config" \
      2>&1 | tee "$profile_root/logs/import_plan.log"
  fi
}

mkdir -p "$output_root"

printf '%s\n' "=============================================================================="
printf '%s\n' "NEXT HISTORICAL-DICTIONARY CYCLE"
printf '%s\n' "=============================================================================="
printf 'Corpus: %s\n' "$corpus_root"
printf 'Output: %s\n' "$output_root"
printf '%s\n' "No corpus, metadata, or database writes will be made."

# 集韻 is the intended import candidate. 玉篇 and 重修廣韻 remain isolated
# dry runs so their parser failures cannot contaminate the 集韻 review files.
run_profile jiyun_only
run_profile yupian_only
run_profile chongxiu_guangyun_only

printf '\n%s\n' "=============================================================================="
printf '%s\n' "ALL THREE DRY RUNS COMPLETE"
printf 'Review root: %s\n' "$output_root"
printf '%s\n' "=============================================================================="
