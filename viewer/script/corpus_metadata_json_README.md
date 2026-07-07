# Corpus JSON metadata generation workflow

This workflow turns legacy txt-header metadata into conservative `metadata.json` files.

The important rule is:

```text
Every work must have its own folder.
metadata.json belongs in the folder beside that work's .txt files.
```

That includes works discovered inside compilations. If a contained work is still flat inside a compilation folder, the preflight reports a folderisation plan: create the contained work folder, move that work's txt files into it, then write the contained work's `metadata.json` there.

The scripts are verbose by default. They print phases, counts, and progress so a long run does not look hung.

## 1. Generate staged JSON metadata

Use the latest full metadata audit and geography mapping outputs:

```bash
ruby script/corpus_metadata_json_dry_run.rb \
  --audit-output tmp/corpus_metadata_audit/full_20260707T032633Z \
  --geography-suggestions tmp/corpus_metadata_audit/geography_mapping_20260707T075018Z/geography_mapping_suggestions.csv \
  --output tmp/corpus_metadata_json/full_$(date -u +%Y%m%dT%H%M%SZ)
```

Default source mode is `clean`, so raw paths are excluded.

The main outputs are:

```text
staged_metadata.jsonl
work_manifest.csv
document_manifest.csv
contained_work_proposals.csv
metadata_conflicts.csv
metadata_fold_decisions.csv
metadata_id_registry.csv
JSON_GENERATION_REPORT.md
```

`contained_work_proposals.csv` includes `target_folder`, `target_paths`, and `folderisation_action`.

## 2. Run apply preflight

Use the actual timestamped dry-run output folder:

```bash
LATEST_DRY_RUN="$(ls -dt tmp/corpus_metadata_json/full_* | head -n 1)"

echo "Using dry run: $LATEST_DRY_RUN"

ruby script/corpus_metadata_apply_preflight.rb \
  --dry-run-output "$LATEST_DRY_RUN" \
  --corpus-root ../corpus \
  --output tmp/corpus_metadata_apply_preflight/preflight_$(date -u +%Y%m%dT%H%M%SZ)
```

The preflight is non-destructive. It writes:

```text
apply_plan.csv
would_write_metadata_json.csv
would_move_txt_files.csv
contained_work_folderisation_plan.csv
would_overwrite.csv
would_skip.csv
APPLY_PREFLIGHT_REPORT.md
```

Only continue if `would_skip.csv` is empty and overwrites are expected/reviewed.

## 3. Dry-run the apply command

```bash
LATEST_PREFLIGHT="$(ls -dt tmp/corpus_metadata_apply_preflight/preflight_* | head -n 1)"

echo "Using dry run: $LATEST_DRY_RUN"
echo "Using preflight: $LATEST_PREFLIGHT"

ruby script/corpus_metadata_apply_json.rb \
  --dry-run-output "$LATEST_DRY_RUN" \
  --preflight-output "$LATEST_PREFLIGHT" \
  --corpus-root ../corpus
```

This still does not change the corpus.

## 4. Apply after review

Only after reviewing the preflight reports:

```bash
ruby script/corpus_metadata_apply_json.rb \
  --dry-run-output "$LATEST_DRY_RUN" \
  --preflight-output "$LATEST_PREFLIGHT" \
  --corpus-root ../corpus \
  --apply
```

This creates needed contained-work folders, moves the applicable txt files into them, and writes `metadata.json` beside each work's txt files.

It does not remove old txt headers. The Rails viewer must be updated to read JSON metadata before old headers are stripped.
