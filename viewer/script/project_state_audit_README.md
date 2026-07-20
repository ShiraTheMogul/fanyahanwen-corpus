# Project-state audit v2

`script/project_state_audit.rb` is a read-only reconciliation script for the
post-JSON Fanya Hanwen Corpus. It does not edit routes, corpus files, metadata,
the search manifest, atlas content, or the database.

Version 2 corrects the problems exposed by the first 1,000-file run:

- raw scrapes are reported separately from canonical clean documents;
- raw path-hash IDs are not presented as failed JSON migration work;
- legacy-header checks run only on canonical clean texts;
- limited/scoped runs are marked partial in `summary.json`;
- `--scope`, `--clean-only`, and `--raw-only` are available;
- a limited audit no longer rescans the full Shang tree several times;
- `花東0.9_Schwartz.txt`-style source locators are separated from an exact
  object folder named `花東0`;
- Atlas checks distinguish the unwanted 西域 branch from legitimate exclusion
  rules and corpus-root utilities;
- Atlas title-only ordering is detected from the actual builder expressions;
- every major phase records its elapsed time.

## Recommended next test: 維基大典 clean files

From the viewer directory:

```bash
ruby script/project_state_audit.rb \
  --corpus-root ../corpus \
  --scope '維基大典/clean' \
  --max-files 1000 \
  --output tmp/project_state_audit/wiki_clean_1000
```

This directly tests the uncertain 維基大典 layout. The first test mostly
encountered raw files, so it could not answer that question.

The command follows a reusable pattern:

```text
ruby SCRIPT --option VALUE
```

- `ruby` runs the standalone Ruby program; Rails does not start.
- `--scope` restricts traversal to one corpus-relative subtree.
- `--max-files 1000` makes this a machinery test, not a complete audit.
- `--output` chooses where the reports are written.

## Full clean-corpus audit

After the scoped test succeeds:

```bash
ruby script/project_state_audit.rb \
  --corpus-root ../corpus \
  --clean-only \
  --output tmp/project_state_audit/full_clean
```

`--clean-only` prunes raw trees before traversing them. This is the most useful
run for checking the JSON migration and stable document IDs.

For an absolutely complete inventory, including raw sources:

```bash
ruby script/project_state_audit.rb \
  --corpus-root ../corpus \
  --output tmp/project_state_audit/full_all
```

Only this unscoped, unfiltered, unlimited run performs the final manifest
“paths missing from corpus” comparison.

## Useful options

```text
--scope PATH          scan one corpus-relative subtree
--clean-only          scan only clean/ trees
--raw-only            scan only raw/ trees
--manifest PATH       use a particular manifest file
--no-manifest         skip manifest comparison
--skip-atlas          skip Atlas source checks
--skip-shang          skip Shang checks
--max-files N         stop after N selected text files
--progress-every N    print progress every N records
--read-retries N      retry unstable filesystem reads N times
--strict              exit 2 if confirmed structural errors exist
```

A scoped or limited run does not secretly traverse the complete Shang tree.
To audit Shang alone without scanning the rest of the corpus:

```bash
ruby script/project_state_audit.rb \
  --corpus-root ../corpus \
  --scope '中國漢文/clean/商殷朝' \
  --output tmp/project_state_audit/shang
```

## Main reports

- `summary.txt`: readable totals, split by document role.
- `summary.json`: machine-readable totals and phase timings.
- `documents.csv`: every scanned text, including source bucket and role.
- `metadata_files.csv`: every scanned `metadata.json`.
- `metadata_documents.csv`: every document listed by scanned metadata.
- `structural_findings.csv`: corpus and metadata findings.
- `manifest_findings.csv`: current metadata/manifest disagreements.
- `documents_without_numeric_ids_by_group.csv`: missing IDs grouped by source
  bucket, document role, and work location.
- `atlas_findings.csv`: Atlas exclusion, continuity, and ordering checks.
- `shang_findings.csv`: object-centred migration evidence.

## Important statuses

`unmanaged_raw_path_hash`
: A raw source file has no canonical metadata ID and the manifest uses its
  expected path hash. This is reported separately and is not treated as failed
  clean-corpus migration work.

`confirmed_path_hash_fallback`
: A metadata-expected document lacks a numeric document ID and the manifest uses
  its path hash. This deserves investigation.

`path_hash_despite_numeric_metadata`
: Current metadata has a numeric ID, but the manifest still uses a path hash.
  Rebuild or metadata lookup should be checked before allocating another ID.

`ancestor_metadata_only`
: An ancestor `metadata.json` lists the document, but the current
  `CorpusMetadataStore` reads only a sibling `metadata.json`. The report labels
  this as a viewer lookup limitation rather than automatically blaming corpus
  placement.

`metadata_in_same_named_child`
: The corpus resembles:

```text
clean/〇.txt
clean/〇/metadata.json
```

The desired form is:

```text
clean/〇/〇.txt
clean/〇/metadata.json
```

## Removing the accidental Western Regions Atlas branch

The patch also provides an idempotent, dry-run-first script:

```bash
ruby script/remove_western_regions_from_atlas.rb --dry-run
```

It removes the accidental empty 西域 / Western Regions macro-region from:

```text
content/atlas/periodisation.json
script/atlas_node_type_rules.json
```

It also makes one narrow change to `script/rectify_atlas_node_types.rb`, so a
later rectification run preserves `excluded_corpus_roots` instead of silently
dropping the exclusion. The script refuses to apply if that method no longer
matches the known safe pattern.

It preserves the real `西域漢文` corpus root by adding it to
`excluded_corpus_roots`. It does not alter routes, corpus files, articles,
period records, or the database.

Apply after reviewing the dry run:

```bash
ruby script/remove_western_regions_from_atlas.rb --apply
bin/rails atlas:rebuild_catalogue
bin/rails atlas:verify
```

The apply mode backs up both JSON files and the rectifier under
`tmp/atlas_western_regions_removal/<timestamp>/`.
