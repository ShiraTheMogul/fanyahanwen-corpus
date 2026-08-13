# External source harvester

This directory downloads external source datasets into an **untracked staging directory**. It does not edit corpus works, metadata, the viewer database, or Rails routes.

The default staging directory is **inside the repository working directory** and is gitignored:

```text
fanyahanwen-corpus/
├── corpus/
├── viewer/
└── fanyahanwen-source-staging/
```

For compatibility with older harvest runs, the wrappers will still use a pre-existing sibling `../fanyahanwen-source-staging/` if no in-project staging directory exists. `FANYA_HARVEST_ROOT` always overrides both locations.

Keeping staging untracked is intentional. Downloading a source proves only that PALCC has obtained a reproducible source snapshot; it does not mean that the material has passed rights, Literary-Chinese, deduplication, witness, or metadata review.

## Background run

From anywhere inside the repository:

```bash
bash corpus/scripts/source_harvest/run_background.sh
```

The wrapper uses one sequential harvester and starts it with low CPU/I/O priority (`nice`, plus `ionice` where available). The default run:

1. records the BNE witness for Juan Cobo's 1593 *Shilu*;
2. snapshots both Classical Chinese Universal Dependencies treebanks;
3. downloads the CODH metadata/text/tag bulk packages;
4. enumerates Kanripo and downloads every selected Kanripo branch as a commit-pinned ZIP;
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

Use only Kanripo's master/default branch rather than all branches:

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

Each source gets `source.json` metadata and SHA-256 checksums for downloaded payloads. Git-backed sources are pinned to the commit SHA observed at harvest time. Kanripo branches are recorded independently; branches that point at the same commit reuse one ZIP rather than downloading duplicate bytes.

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
6. compares every textual branch against every attached PALCC candidate;
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

## Kanripo incorporation planner (v11)

After the witness-comparison runs have finished, build a **read-only incorporation
plan** from all comparison batches:

```bash
bash corpus/scripts/source_harvest/run_kanripo_merge_plan.sh
```

The planner aggregates every completed `_kanripo_compare/*` batch rather than only
`last_kanripo_compare.json`. This is important when the first 100 works were run as
a pilot and the remaining 4,311 were run separately.

The provenance model is deliberately physical-to-digital:

```text
work / textual tradition
        ↓
source witness or source edition
  e.g. 郭店楚簡, 馬王堆帛書, 宋刊本, 永樂大典本, 四庫全書・文淵閣本
        ↓
digital transcription edition
  e.g. Kanripo master, historical Kanripo WYG branch, Wikisource
        ↓
digital revision / snapshot
  e.g. Kanripo commit SHA or a dated Wikisource capture
```

This distinction matters because errors or readings in the physical/documentary
source witness can be inherited by every transcription made from it, while a digital
transcription can introduce a second layer of errors of its own. PALCC therefore
needs to retain both halves of the provenance chain.

Canonical selection is quality-aware. A clearly partial or truncated Wikisource/
Wikimedia-derived transcription must not block a demonstrably more complete maintained
transcription. The planner therefore measures Han-character coverage for readable PALCC
candidates and can emit `PREFER_KANRIPO_COMPLETE_DIGITAL_TRANSCRIPTION` when the gap is
extreme. This is deliberately conservative: length is only an automatic signal for
obvious truncation, not a claim that a longer textual witness is inherently better.
The shorter text remains preserved as an alternate/partial digital transcription with
its own source-witness provenance.

Kanripo's upstream property is literally named `#+PROPERTY: BASEEDITION ...`. The
planner preserves that value verbatim as `upstream_baseedition`, but interprets it as
evidence for the **source witness**, not as the name of a digital branch. This avoids
a real ambiguity in Kanripo: `BASEEDITION=WYG` and a branch named `WYG` are different
facts. A current `master` branch may still be a newer digital transcription of the
WYG / 四庫全書・文淵閣本 witness.

For compatibility, PALCC's existing `editions[]` records do not have to be renamed
immediately. The planner treats those existing records semantically as source
witness/source-edition records and proposes digital-transcription provenance beneath
them. In Rails terms the useful pattern is roughly `Work has_many :source_witnesses`
and `SourceWitness has_many :digital_transcriptions`; the current JSON structure can
be migrated or aliased later without blocking incorporation.

Reports are written under:

```text
../fanyahanwen-source-staging/_merge_plan/YYYYMMDD-HHMMSS/
```

Important outputs:

- `kanripo_merge_plan.csv` — one high-level action row per exact-title Kanripo source;
- `siku_preferred_digital_transcription_candidates.csv` — readable PALCC Siku works
  where the preferred current Kanripo digital transcription of the WYG source witness
  can replace the maintained PALCC text while the older Wikisource digital transcription
  is preserved;
- `quality_preferred_digital_transcription_candidates.csv` — cases where existing
  readable PALCC material is so incomplete relative to Kanripo's current transcription
  that it should be preserved as a partial/alternate digital transcription rather than
  treated as the canonical text;
- `metadata_only_fill_candidates.csv` — PALCC work records that have metadata but no
  primary `.txt` files, so Kanripo would add primary text without creating a duplicate
  work record;
- `witness_digital_transcription_candidates.csv` — branch/commit-level provenance with
  source witness and digital publication state kept in separate fields;
- `alternate_source_witness_candidates.csv` — cases where Kanripo supplies another
  source witness, or another digital transcription of an existing witness;
- `unresolved_or_unavailable.csv` — multi-stub placement cases and unavailable
  upstream repositories;
- `metadata_model_example.json` — staging-only illustration of the proposed
  physical-to-digital provenance chain.

The planner estimates text/archive sizes where the source ZIP is already cached.
It never invents an old Wikisource scrape date: if current metadata does not record
one, the plan says `not_recorded_in_current_metadata` so that date can be recovered
before a final merge.

### Metadata-only PALCC stubs

A deep inventory now records `primary_text_file_count` separately from general
`evidence_file_count`. This prevents `metadata.json` alone from making an empty work
look like an already-transcribed corpus work. Future refinement runs place exact
Kanripo matches whose PALCC candidates all have zero primary text into:

```text
refined/kanripo_fill_missing_primary_text.csv
```

UD targets get the same distinction: an exact metadata record with no text becomes
`FILL_MISSING_PRIMARY_TEXT_AND_ANNOTATE`, rather than pretending there is already a
text to annotate.

For an older completed inventory (which predates `primary_text_file_count`), the v8
merge planner checks the actual candidate work directories directly, so there is no
need to rerun the 256k-file inventory merely to recover this distinction.

### Fetch the newly discovered missing primary texts

The comparison stage deliberately refused to compare a Kanripo source when PALCC
had no readable primary text. Once the merge planner has identified those
metadata-only records, fetch their Kanripo snapshots directly into staging:

```bash
bash corpus/scripts/source_harvest/run_kanripo_missing_primary_fetch.sh
```

This reads `metadata_only_fill_candidates.csv`, downloads each Kanripo source only
once (even where PALCC has multiple empty exact-title records), and records every
digital branch/commit together with upstream `BASEEDITION`. It still changes **zero
corpus files**.

Then rerun:

```bash
bash corpus/scripts/source_harvest/run_kanripo_merge_plan.sh
```

so the plan can use the newly cached source-witness code, digital branch, commit,
retrieval time, and size information.


### Metadata-only versus source-witness placement

A metadata-only exact-title PALCC record is not automatically a Kanripo target. If a readable 四庫全書 record also exists and Kanripo identifies its source witness as WYG, the Kanripo transcription belongs to the readable Siku witness. The empty same-title record remains unresolved rather than being filled with the wrong witness. `metadata_only_fill_candidates.csv` therefore contains only cases with no readable exact-title PALCC target at all; mixed cases are written separately to `mixed_stub_and_readable_candidates.csv`.

There is one important exception to "mixed means review": if the readable candidate is
clearly only a fragment and Kanripo has a dramatically more complete current
transcription, the complete transcription wins the canonical slot. For example, a
short Wikisource fragment must not prevent PALCC from adopting a full Kanripo text.
The fragment is retained as evidence and as an alternate digital transcription; its
existence is not treated as proof that the work is already adequately represented.

## Generate the actual Kanripo incorporation overlay (v12)

After the quality-aware merge plan is satisfactory, generate the repository-ready
corpus overlay without modifying the checkout:

```bash
bash corpus/scripts/source_harvest/run_kanripo_incorporation_overlay.sh
```

By default this materialises every deterministic canonical-text action:

- `PROMOTE_KANRIPO_WYG_DIGITAL_TRANSCRIPTION`;
- `PREFER_KANRIPO_COMPLETE_DIGITAL_TRANSCRIPTION`;
- `FILL_METADATA_ONLY_WORK` when its preferred Kanripo snapshot is cached.

Ambiguous multi-stub cases, unavailable upstream repositories, and alternate-witness
only decisions are not silently imported.

The generator cleans Kanripo/Mandoku page-layout markup for the PALCC primary text,
keeps the commit-pinned source ZIP untouched in staging, updates `metadata.json` with
the physical/source-witness -> digital-transcription -> revision chain, and records
the replaced PALCC/Wikisource state as recoverable from the base Git commit instead
of duplicating gigabytes of superseded text in the working tree.

Outputs are written under:

```text
fanyahanwen-source-staging/_incorporation_overlays/YYYYMMDD-HHMMSS/
```

The generated overlay ZIP contains **only repository-ready files**. Because replacing
a work can change its number of primary text files, a companion `apply_overlay.sh`
is written beside the ZIP (not inside it). It verifies the exact base commit and that
every target work is clean, deletes only stale root-level primary `.txt` files in
those target work directories, then extracts the overlay. It never changes Rails
routes.

To smoke-test one or more works without touching the corpus:

```bash
bash corpus/scripts/source_harvest/run_kanripo_incorporation_overlay.sh \
  --source-id KR1b0003
```

or:

```bash
bash corpus/scripts/source_harvest/run_kanripo_incorporation_overlay.sh --limit 25
```

If metadata-only rows say that their preferred cached archive is missing, fetch those
small missing-primary sources first and rerun the merge plan:

```bash
bash corpus/scripts/source_harvest/run_kanripo_missing_primary_fetch.sh
bash corpus/scripts/source_harvest/run_kanripo_merge_plan.sh
```

Then regenerate the incorporation overlay.


### Missing Kanripo repositories and credential prompts

The metadata-only fetch is explicitly non-interactive. GitHub sometimes answers a
request for a non-existent public repository with an authentication-looking Git
error. The fetcher checks for a definite HTTP 404 first and sets Git credential
prompting off, so a missing Kanripo mirror is recorded as an unavailable upstream
repository and the batch continues. **Do not enter GitHub credentials for Kanripo
harvesting.**
