# Corpus metadata audit

This script is read-only. It scans leading `# KEY: value` metadata headers in corpus `.txt` files and writes reports for the JSON metadata revamp.

## Smoke test

```bash
ruby script/corpus_metadata_audit.rb \
  --corpus-root ../corpus \
  --output tmp/corpus_metadata_audit/smoke_$(date -u +%Y%m%dT%H%M%SZ) \
  --max-files 1000
```

## Full audit

```bash
ruby script/corpus_metadata_audit.rb \
  --corpus-root ../corpus \
  --output tmp/corpus_metadata_audit/full_$(date -u +%Y%m%dT%H%M%SZ) \
  --include-rows
```

## Filesystem errors and long paths

The corpus lives under WSL/Windows/OneDrive for local development. Very long paths can make the OS refuse `readdir` or `stat` with errors such as `Errno::EIO`.

The script now treats those as audit data rather than a reason to lose the whole run:

- `txt_files.csv` is written immediately after enumeration, before metadata scanning begins.
- `enumeration_errors.csv` records unreadable directories/files.
- `read_errors.csv` records discovered `.txt` files that could not be opened.
- `progress.json` is updated during long scans.
- Final reports are still written for every readable file.

Use strict mode only when you want a non-zero exit code after reports are written:

```bash
ruby script/corpus_metadata_audit.rb \
  --corpus-root ../corpus \
  --output tmp/corpus_metadata_audit/full_$(date -u +%Y%m%dT%H%M%SZ) \
  --include-rows \
  --strict-enumeration
```

In strict mode, the script still writes the reports first. If enumeration had unreadable paths, it exits with code `2` at the end.

## Important outputs

- `fields.csv` — one row per raw metadata key, with counts and samples.
- `canonical_key_groups.csv` — normalised key groups to catch key spelling/punctuation variants.
- `field_values.csv` — one row per field value, with counts and sample files.
- `field_separators.csv` — comma/semicolon/list separator usage inside values.
- `files.csv` — one row per readable text file scanned.
- `txt_files.csv` — all discovered text files, written before scanning starts.
- `enumeration_errors.csv` — unreadable directories/files during discovery.
- `read_errors.csv` — files discovered but not readable.
- `folder_key_counts.csv` — key counts by parent folder.
- `metadata_rows.csv` — full row dump, only with `--include-rows`.
- `summary.json` and `REPORT.md` — run summaries.
