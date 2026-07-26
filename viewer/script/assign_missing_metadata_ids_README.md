# Assign missing corpus metadata IDs

This script reconciles the corpus `metadata.json` files with the canonical
`metadata_id_registry.csv`.

It does four separate jobs:

1. preserves every valid ID already present in metadata;
2. reuses the registry ID when a path is already known there;
3. assigns a new ID when both metadata and registry lack one;
4. adds direct `.txt` files omitted from a work's `documents` array.

It never creates a new `metadata.json` for a text folder. There is not enough
information to decide whether such a folder is a work, a volume, or accidental
material. Unowned files are listed in `orphan_text_files.csv` for review.

## Why the default does not fill numerical gaps

An ID is a permanent name, not a row number. A gap such as work IDs 100, 101,
103 is harmless. ID 102 may have belonged to a deleted or aliased work, and an
old URL may still refer to it.

The default mode is therefore:

```text
append
```

It assigns a number greater than every ID already present in either the
registry or corpus metadata.

There is an explicit `lowest-unused` mode, but it is only safe when the supplied
registry is the complete historical ledger. It still refuses to reuse anything
that appears in an inactive or alias registry row.

## 1. Select the latest registry

From the viewer root:

```bash
REGISTRY="$({
  find tmp/corpus_metadata_json \
    -name metadata_id_registry.csv \
    -printf '%T@ %p\n'
} | sort -nr | head -n 1 | cut -d' ' -f2-)"

printf 'Registry: %s\n' "$REGISTRY"
```

What this does:

- `find ... -printf` prints every candidate with its modification time;
- `sort -nr` puts the newest first;
- `head -n 1` keeps one result;
- `cut` removes the timestamp and leaves the path.

Do not proceed if the printed path is not the registry from the latest accepted
metadata run.

## 2. Dry run

```bash
RUN="tmp/metadata_id_assignment/run_$(date -u +%Y%m%dT%H%M%SZ)"

ruby script/assign_missing_metadata_ids.rb \
  --corpus-root ../corpus \
  --registry "$REGISTRY" \
  --output "$RUN"
```

This changes nothing in the corpus. It writes:

```text
ASSIGNMENT_REPORT.md
plan.json
summary.json
changes.csv
conflicts.csv
warnings.csv
unlisted_text_files.csv
orphan_text_files.csv
listed_document_files_missing.csv
new_registry_rows.csv
metadata_id_registry.updated.csv
staged_metadata/...
```

The default `--include-unlisted direct` means:

- a `.txt` beside its work's `metadata.json` is added to `documents`;
- an unlisted `.txt` deeper below that work is only reported.

Use `--include-unlisted all` only after confirming that nested folders are
volumes or document containers rather than separate works.

## 3. Review

```bash
cat "$RUN/ASSIGNMENT_REPORT.md"
column -s, -t < "$RUN/conflicts.csv" | less -S
column -s, -t < "$RUN/changes.csv" | less -S
```

`conflicts.csv` must contain only its header. The report must say:

```text
Ready to apply: true
```

## 4. Apply the reviewed plan

```bash
ruby script/assign_missing_metadata_ids.rb \
  --apply-from "$RUN"
```

Apply mode does not rescan and invent a new plan. It installs the exact staged
files already reviewed. Before writing, it checks SHA-256 hashes of:

- the canonical registry;
- every metadata file to be changed;
- every staged replacement.

If anything changed after the dry run, apply stops. On a write or verification
failure, it restores the originals from `backup_on_apply/`.

## 5. Rebuild the viewer manifest

After a successful apply:

```bash
bin/rails corpus_search:rebuild_manifest
```

The registry and `metadata.json` files are the source records. The search
manifest and database-derived views are rebuilt consumers of those records.
