# 維基大典 JSON and layout migration

This script completes the old-header to `metadata.json` migration for the flat
`維基大典/clean` pages. It is deliberately stricter than a file mover.

For each page, it:

1. loads the existing same-named child `metadata.json`;
2. parses all six legacy header values, including compacted headers where several markers share a physical line;
3. validates the mappings against the current `config/corpus_metadata/json_generation_map.yml`;
4. merges every nonblank value into the proper work-level or document-level JSON field;
5. repairs an old line-based parser artefact only when the current JSON value exactly equals the polluted remainder of the original physical header line;
6. blocks every other disagreement instead of overwriting it;
7. removes the legacy header from the TXT;
8. moves the body-only TXT beside `metadata.json`;
9. updates the document path and `body_start_line`;
10. verifies that the legacy values are represented in JSON after writing.

## Mapping

The mapping is read and checked against the current JSON workflow:

- `WORK_TITLE` → work `title`
- `DISPLAY_TITLE` → document `display_title`
- `AUTHOR` → work `authors`
- `TIMES` → work `date_label` when date-like, otherwise mapped geography/period
- `PAGE_TITLE` → document `page_title`
- `CATEGORIES` → work `categories`

Blank legacy values are ignored, not written as empty data. Existing identical
values are retained.

## Narrow repair of the old compact-header artefact

Four known files have metadata titles such as:

```text
平原王（釋義）# DISPLAY_TITLE: 平原王（釋義）# AUTHOR:
```

This was produced by the older JSON generator reading the remainder of a
physical line as `WORK_TITLE`. The current script repairs this only when all of
the following are true:

1. the new parser extracts a clean value such as `平原王（釋義）`;
2. the existing JSON value exactly equals the remainder of the original
   physical header line;
3. the suffix begins with another recognised legacy marker such as
   `# DISPLAY_TITLE:`.

A merely different title still blocks. This is not a general overwrite rule.
The action is reported as `repair_legacy_header_bleed` in `metadata_merge.csv`.

## Dry run

From the viewer root:

```bash
ruby script/repair_wiki_clean_layout.rb \
  --corpus-root ../corpus \
  --output tmp/wiki_clean_layout_repair/full_json_dry_run_v4
```

Review:

- `summary.txt`
- `metadata_merge.csv`
- `metadata_conflicts.csv`
- `blockers.csv`

Do not apply unless both blockers and metadata conflicts are zero.

## Apply

```bash
ruby script/repair_wiki_clean_layout.rb \
  --corpus-root ../corpus \
  --output tmp/wiki_clean_layout_repair/full_json_apply \
  --apply
```

The original TXT and JSON files are backed up beneath the output directory.

## After apply

```bash
bin/rails corpus_search:rebuild_manifest

ruby script/project_state_audit.rb \
  --corpus-root ../corpus \
  --scope '維基大典/clean' \
  --output tmp/project_state_audit/wiki_clean_post_repair

ruby script/verify_unicode_integrity.rb
```
