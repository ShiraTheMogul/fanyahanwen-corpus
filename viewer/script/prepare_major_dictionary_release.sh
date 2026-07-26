#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: bash script/prepare_major_dictionary_release.sh CORPUS_ROOT [NEXT_CYCLE_DIR]" >&2
  echo "Set APPLY=1 to import 集韻 and 玉篇 after both database plans pass." >&2
  exit 2
fi

corpus_root="$1"
cycle_root="${2:-}"

if [[ ! -d "$corpus_root" ]]; then
  echo "Corpus root not found: $corpus_root" >&2
  exit 2
fi

if [[ -z "$cycle_root" ]]; then
  cycle_root="tmp/dictionary_import/next_cycle_$(date -u +%Y%m%dT%H%M%SZ)"
  bash script/run_next_dictionary_cycle.sh "$corpus_root" "$cycle_root"
fi

if [[ ! -d "$cycle_root" ]]; then
  echo "Cycle directory not found: $cycle_root" >&2
  exit 2
fi

release_root="$cycle_root/publication"
mkdir -p "$release_root"

printf '%s\n' "=============================================================================="
printf '%s\n' "MAJOR DICTIONARY RELEASE PREPARATION"
printf '%s\n' "=============================================================================="
printf 'Corpus:      %s\n' "$corpus_root"
printf 'Cycle:       %s\n' "$cycle_root"
printf 'Apply DB:    %s\n' "${APPLY:-0}"
printf '%s\n' "Historical, taboo, variant, and unresolved glyph forms are preserved."
printf '%s\n' "Only normalized character links are limited to one Unicode character."

promote_and_plan() {
  local title="$1"
  local portable="$2"
  local publication_dir="$release_root/$portable"
  local ready_file="$publication_dir/entries.ready_for_import_review.jsonl"
  local plan_dir="$publication_dir/database_import_plan"

  printf '\n%s\n' "------------------------------------------------------------------------------"
  printf 'PROMOTE: %s\n' "$title"
  printf '%s\n' "------------------------------------------------------------------------------"

  ruby script/promote_readable_dictionary_jsonl.rb \
    --cycle-root "$cycle_root" \
    --title "$title" \
    --output "$publication_dir"

  local expected
  expected="$(wc -l < "$ready_file" | tr -d ' ')"
  if [[ "$expected" -le 0 ]]; then
    echo "No promoted entries for $title" >&2
    exit 1
  fi

  env \
    FILE="$ready_file" \
    CORPUS_ROOT="$corpus_root" \
    EXPECTED="$expected" \
    SOURCE_LABEL="Fanya Hanwen Corpus" \
    OUTPUT="$plan_dir" \
    bin/rails dictionaries:plan

  if [[ "${APPLY:-0}" == "1" ]]; then
    env \
      FILE="$ready_file" \
      CORPUS_ROOT="$corpus_root" \
      EXPECTED="$expected" \
      SOURCE_LABEL="Fanya Hanwen Corpus" \
      REPLACE=1 \
      LOG_EVERY="${LOG_EVERY:-500}" \
      bin/rails dictionaries:import

    local work_id
    work_id="$(ruby -rjson -e 'row = JSON.parse(File.foreach(ARGV[0], encoding: "UTF-8").find { |line| !line.strip.empty? }); puts row.fetch("dictionary_work_id")' "$ready_file")"
    env CORPUS_WORK_ID="$work_id" bin/rails dictionaries:verify
  fi
}

promote_and_plan "集韻" "jiyun"
promote_and_plan "玉篇" "yupian"

printf '\n%s\n' "------------------------------------------------------------------------------"
printf '%s\n' "重修廣韻 remains reviewable, not discarded."
printf '%s\n' "Review these files before choosing whether to publish its current grouping:"
printf '  %s\n' "$cycle_root/chongxiu_guangyun_only/import_plan/summary.txt"
printf '  %s\n' "$cycle_root/chongxiu_guangyun_only/import_plan/groups.review.csv"
printf '  %s\n' "$cycle_root/chongxiu_guangyun_only/import_plan/sections.review.csv"
printf '  %s\n' "$cycle_root/chongxiu_guangyun_only/import_plan/warnings.csv"

printf '\n%s\n' "=============================================================================="
if [[ "${APPLY:-0}" == "1" ]]; then
  printf '%s\n' "集韻 and 玉篇 were imported and verified."
  printf '%s\n' "They should now appear automatically under /dictionary/catalogue."
else
  printf '%s\n' "Both database plans passed without writes."
  printf '%s\n' "Re-run the same command with APPLY=1 to import and verify them."
fi
printf 'Release root: %s\n' "$release_root"
printf '%s\n' "=============================================================================="
