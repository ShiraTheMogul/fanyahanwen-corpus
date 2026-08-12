# External source harvester

This directory downloads external source datasets into an **untracked staging directory**. It does not edit corpus works, metadata, the viewer database, or Rails routes.

The default staging directory is a sibling of the repository:

```text
fanyahanwen-corpus/
fanyahanwen-source-staging/
```

The separation is intentional. Downloading a source proves only that PALCC has obtained a reproducible source snapshot; it does not mean that the material has passed rights, Literary-Chinese, deduplication, witness, or metadata review.

## Background run

From anywhere inside the repository:

```bash
bash corpus/scripts/source_harvest/run_background.sh
```

The wrapper uses one sequential harvester and starts it with low CPU/I/O priority (`nice`, plus `ionice` where available). The default run:

1. records the BNE witness for Juan Cobo's 1593 *Shilu*;
2. snapshots both Classical Chinese Universal Dependencies treebanks;
3. downloads the CODH metadata/text/tag bulk packages;
4. enumerates Kanripo and downloads every selected edition branch as a commit-pinned ZIP;
5. inventories the NIJL Kokusho OCR GitLab groups, but does **not** download their payload by default because per-item rights still need to be retained/verified before PALCC ingestion.

Check it without attaching to the process:

```bash
bash corpus/scripts/source_harvest/status.sh
```

Stop the whole harvest process group:

```bash
bash corpus/scripts/source_harvest/stop_background.sh
```

`stop_background.sh` sends `TERM` first. If the job has not exited after 20 seconds it sends `KILL` to the detached harvest session. Completed files remain intact and incomplete HTTP downloads remain as `.part` files so a later run can resume them.

## Useful variants

Catalogue Kanripo without downloading thousands of repository snapshots. The harvester now uses Kanripo's HTML department catalogue pages: one request each for `KR1` ... `KR6`. Those pages already contain the work records beneath each department, so a normal full catalogue pass needs roughly six requests rather than dozens of API searches:

```bash
bash corpus/scripts/source_harvest/run_background.sh --kanripo-catalog-only
```

Only collect the small/cheap sources while another benchmark is particularly sensitive to disk I/O:

```bash
bash corpus/scripts/source_harvest/run_background.sh --sources cobo,ud,codh --kanripo-catalog-only
```

If the catalogue result is plausible (thousands of work IDs), collect Kanripo separately:

```bash
bash corpus/scripts/source_harvest/run_background.sh --sources kanripo
```

Use only Kanripo's master/default edition rather than all edition branches:

```bash
bash corpus/scripts/source_harvest/run_background.sh --sources kanripo --kanripo-editions master
```

Test the Kanripo machinery on ten works:

```bash
bash corpus/scripts/source_harvest/run_background.sh --sources kanripo --kanripo-limit 10
```

Explicitly download enumerated NIJL OCR repositories into staging:

```bash
bash corpus/scripts/source_harvest/run_background.sh --sources nijl --nijl-payload
```

The NIJL material remains marked `staging_only_pending_per_item_verification`; harvesting it is not an ingestion decision.

To put staging somewhere else, use an environment variable consistently for `run`, `status`, and `stop`:

```bash
export FANYA_HARVEST_ROOT=/mnt/d/fanyahanwen-source-staging
bash corpus/scripts/source_harvest/run_background.sh
```

## What is preserved

Each source gets `source.json` metadata and SHA-256 checksums for downloaded payloads. Git-backed sources are pinned to the commit SHA observed at harvest time. Kanripo edition branches are recorded independently; branches that point at the same commit reuse one ZIP rather than downloading duplicate bytes.

The staging area is designed to answer four separate questions later:

```text
What did upstream publish?
        ↓
Which exact version did we obtain?
        ↓
Are its rights suitable for PALCC?
        ↓
Is it a new work, another witness, or annotation for an existing work?
```

Only the final answer belongs in the corpus.

## Cobo

The harvester records the surviving BNE witness (`R/33396`) and its rights/provenance references, but it intentionally does not launch OCR or image-cleaning. The thin-paper/bleed-through problem is an image-processing task and should be benchmarked separately rather than consuming CPU while viewer performance measurements are running.

## Dependencies

- Python 3.10+
- Git
- Bash for the detached run/status/stop wrappers
- `nice`; `ionice` is used automatically when available

No Python packages are required.

## Overnight source inventory and matcher

After the catalogue/download harvest has completed, build a read-only comparison
against the **current local corpus**:

```bash
bash corpus/scripts/source_harvest/run_inventory_background.sh
```

The default is deliberately thorough. It walks current `metadata.json` files and
primary `clean/` / `suspected_baihua/` text headers so it does not assume the
checked-in aggregate indexes are perfectly current. It then parses the harvested
UD, CODH, Kanripo and NIJL catalogues/packages and performs title candidate
matching offline.

Monitor it:

```bash
bash corpus/scripts/source_harvest/inventory_status.sh
```

Or stream the log until the inventory process exits:

```bash
PID=$(cat ../fanyahanwen-source-staging/_control/inventory.pid)
LOG=$(cat ../fanyahanwen-source-staging/_control/current_inventory_log)
tail --pid="$PID" -f "$LOG"
```

Stop the whole detached inventory session:

```bash
bash corpus/scripts/source_harvest/stop_inventory_background.sh
```

Reports are written under:

```text
../fanyahanwen-source-staging/_inventory/YYYYMMDD-HHMMSS/
```

Important outputs:

- `summary.txt` — human-readable totals;
- `summary.json` — machine-readable totals;
- `corpus_works.csv` — current PALCC works seen by the matcher;
- `ud_matches.csv` — UD annotation targets against PALCC;
- `codh_matches.csv` — CODH bibliography/text inventory and PALCC matches;
- `kanripo_matches.csv` — all Kanripo catalogue works and title matches;
- `nijl_matches.csv` — NIJL OCR projects, including exact CODH bibliographic-ID joins;
- `strong_matches.csv` — easy existing-work candidates;
- `needs_review.csv` — fuzzy/ambiguous/unresolved relationships;
- `new_candidates.csv` — source records that look like possible new PALCC material.

The classifications are **triage, not import decisions**. In particular, an exact
title match may still be a different edition or witness. No report-writing step
copies or modifies a corpus work.

For a quicker metadata-only corpus scan (mainly for testing):

```bash
bash corpus/scripts/source_harvest/run_inventory_background.sh --quick-corpus-scan
```

### Refined action queues

A successful background inventory now automatically runs a cheap second-stage
refinement pass. This reuses the completed `corpus_works.csv`; it does **not**
rescan the corpus. Refined reports are written to:

```text
../fanyahanwen-source-staging/_inventory/YYYYMMDD-HHMMSS/refined/
```

The refined pass exists because title similarity is discovery, not identity. In
particular it:

- treats UD TueCL as `莊子 / 逍遙遊`;
- keeps the exact Kumārajīva UD sources distinct from similarly named Buddhist texts;
- prevents short/numeric NIJL title collisions from becoming automatic witness matches;
- separates NIJL identifier-only projects from genuine human review;
- treats fuzzy Kanripo matches as related-title review rather than proven witnesses;
- scans CODH's 31 text-bearing records for discrete Han-dominant prefaces, postscripts,
  題詞, and similar passages without pretending the whole Japanese host work is Literary Chinese.

Important refined files include:

- `ud_annotation_targets.csv`;
- `codh_text_triage.csv` and `codh_embedded_han_segments.csv`;
- `kanripo_existing_title_witnesses.csv`, `kanripo_title_review.csv`, and
  `kanripo_probable_new_works.csv`;
- `nijl_existing_title_witnesses.csv`, `nijl_related_or_collision_review.csv`,
  `nijl_titled_unmatched.csv`, and `nijl_identifier_only_unresolved.csv`.

To refine an already-completed inventory without rerunning the deep corpus scan:

```bash
python3 corpus/scripts/source_harvest/refine_inventory.py \
  --staging-root ../fanyahanwen-source-staging
```


## Kanripo witness-comparison pilot (v6)

After `refine_inventory.py` has produced `refined/kanripo_existing_title_witnesses.csv`,
run the queue-aware comparison pilot:

```bash
bash corpus/scripts/source_harvest/run_kanripo_compare_background.sh
```

The default batch is 100 exact-title Kanripo works. It does **not** enumerate/download
all Kanripo works again. For each selected work it:

1. reads every PALCC exact-title candidate path attached to the refined row;
2. obtains Kanripo branch heads with `git ls-remote`;
3. excludes underscore-prefixed administrative branches such as `_data`;
4. downloads each unique textual branch commit as a commit-pinned ZIP into staging;
5. extracts a punctuation/markup-insensitive Han-character stream for comparison only;
6. compares every edition branch against every attached PALCC candidate;
7. writes reports under `../fanyahanwen-source-staging/_kanripo_compare/<timestamp>/`.

The original Kanripo ZIPs are never normalized or rewritten. PALCC is read-only.
An `IDENTICAL` result means only that the normalized Han-character streams match;
it is not permission to overwrite provenance, metadata, or witness identity.

Monitor:

```bash
bash corpus/scripts/source_harvest/kanripo_compare_status.sh
```

Or stream the current log until the detached process exits:

```bash
PID=$(cat ../fanyahanwen-source-staging/_control/kanripo_compare.pid)
LOG=$(cat ../fanyahanwen-source-staging/_control/current_kanripo_compare_log)
tail --pid="$PID" -f "$LOG"
```

Stop the whole detached session:

```bash
bash corpus/scripts/source_harvest/stop_kanripo_compare_background.sh
```

Useful batches:

```bash
# Default pilot: first 100 refined rows
bash corpus/scripts/source_harvest/run_kanripo_compare_background.sh

# A smaller smoke test
bash corpus/scripts/source_harvest/run_kanripo_compare_background.sh --limit 10

# Next sequential batch after the first 100
bash corpus/scripts/source_harvest/run_kanripo_compare_background.sh --offset 100 --limit 100

# Eventually process everything after an offset
bash corpus/scripts/source_harvest/run_kanripo_compare_background.sh --offset 0 --limit 0
```

Downloaded commit ZIPs and branch manifests are cached under
`../fanyahanwen-source-staging/kanripo/works/<KR-ID>/`, so repeating/completing a
batch does not redownload already-pinned commits. If `_state/last_inventory.json`
is missing, the comparator automatically falls back to the newest refined queue
under `_inventory/*/refined/`; this avoids forcing a corpus rescan merely because
a convenience pointer was lost.
