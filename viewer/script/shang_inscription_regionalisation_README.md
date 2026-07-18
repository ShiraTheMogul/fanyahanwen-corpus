# Shang inscription regionalisation: corrected phase 1

This patch reorganises `商殷朝` around physical inscribed objects while keeping the completed JSON migration's corpus-wide stable IDs safe.

It replaces the first phase-one script. Plans made by that older script are **version 1** and cannot be applied by this corrected **version 2** script.

No Rails routes are changed.

## The data model

```text
work       = one physical bone, shell, or bronze object
document   = one transcription segment or translation attached to that object
folder     = political/geographical classification + medium + physical object
identifier = a catalogue or excavation number such as 合集00014, H3：1573, or 集成00793
```

For example:

```text
合集00014正.1
合集00014正.2
合集00014正.3
```

become documents under one physical work:

```text
商/甲骨文/殷墟/出土位置不詳/合集00014/
├── metadata.json
├── 合集00014正.1_ASDC.txt
├── 合集00014正.2_ASDC.txt
└── 合集00014正.3_ASDC.txt
```

The segments remain individually searchable. They simply stop pretending to be separate bones.

## What was corrected

### 1. Corpus-wide stable IDs

The script now requires the authoritative `metadata_id_registry.csv` produced by the completed JSON migration.

It:

```text
reads the global maxima, not merely the Shang maxima
allocates every new work/document ID above those global maxima
updates every moved active work and document path
records merged sentence-work IDs as aliases
records the three superseded legacy source-collection IDs as aliases
writes a complete reviewed replacement registry
backs up and atomically replaces the authoritative registry during apply
```

A plan cannot be applied if the registry has changed since the dry run.

### 2. The false 花東0 object

The three exceptional Schwartz records are not three segments of one object:

```text
HYZ 0.6 → H3:1573
HYZ 0.7 → H3:1616
HYZ 0.9 → H3:1630
```

They now become three physical folders:

```text
商/甲骨文/殷墟/花園莊東地/H3/H3：1573
商/甲骨文/殷墟/花園莊東地/H3/H3：1616
商/甲骨文/殷墟/花園莊東地/H3/H3：1630
```

The full-width colon is intentional because Windows does not allow `:` in filenames.

The source publication locators remain attached to their translation documents.

### 3. Encoded review-ZIP paths

The `#Uxxxx` decoder no longer greedily consumes a following hexadecimal digit from an object identifier. This matters only for review archives whose filenames have been encoded this way; the live Unicode corpus is unaffected.

## Files in this patch

```text
script/shang_inscription_regionalisation.rb
script/shang_inscription_regionalisation_README.md
script/shang_inscription_regionalisation_VALIDATION.md
config/corpus_metadata/shang_inscription_regionalisation.yml
config/corpus_metadata/shang_oracle_concordances.csv
config/corpus_metadata/shang_oracle_overrides.csv
test/scripts/shang_inscription_regionalisation_test.rb
```

The Ruby file contains migration machinery. The YAML and CSV files contain reviewable scholarly decisions.

## Prepared folder skeleton

```text
商殷朝/
├── 商/
│   ├── 甲骨文/
│   │   ├── 殷墟/
│   │   │   ├── 小屯宮殿宗廟區/YH127/
│   │   │   ├── 小屯南地/
│   │   │   ├── 花園莊東地/H3/
│   │   │   └── 出土位置不詳/
│   │   ├── 洹北商城/
│   │   ├── 鄭州商城/
│   │   ├── 大辛莊/
│   │   └── 出土地不詳/
│   └── 金文/
├── 周方/
│   ├── 甲骨文/周原/{鳳雛,齊家村,周公廟}/
│   └── 金文/
├── 子方/{甲骨文,金文}/
└── 土方/{甲骨文,金文}/
```

Empty folders are deliberate authority data. They do not claim that writing has already been found there.

## Find the authoritative ID registry

Use the exact registry produced by the JSON migration that you applied. To list likely candidates without choosing one automatically:

```bash
find tmp/corpus_metadata_json -name metadata_id_registry.csv -printf '%T@ %p\n' \
  | sort -nr \
  | head
```

Then set the reviewed path explicitly:

```bash
ID_REGISTRY="tmp/corpus_metadata_json/full_YOUR_TIMESTAMP/metadata_id_registry.csv"

test -f "$ID_REGISTRY" && echo "Using $ID_REGISTRY"
```

`test -f` asks the shell whether the file exists. The text after `&&` runs only when that check succeeds.

Do not use a registry from an abandoned earlier dry run.

## Run the tests

From the viewer root:

```bash
ruby test/scripts/shang_inscription_regionalisation_test.rb
```

The tests cover:

```text
global rather than dynasty-local ID allocation
physical-object collapse
H3:1573 / H3:1616 / H3:1630 separation
work and document registry path rewrites
legacy work-ID aliases
outside-Shang ID collision blocking
registry backup and atomic installation
second-apply refusal
#Uxxxx filename decoding
```

## Generate a fresh dry-run plan

Do not reuse the uploaded version-one plan.

```bash
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PLAN="tmp/shang_inscription_regionalisation/plan_$STAMP"

ruby script/shang_inscription_regionalisation.rb \
  --shang-root ../corpus/中國漢文/clean/商殷朝 \
  --config config/corpus_metadata/shang_inscription_regionalisation.yml \
  --concordances config/corpus_metadata/shang_oracle_concordances.csv \
  --overrides config/corpus_metadata/shang_oracle_overrides.csv \
  --id-registry "$ID_REGISTRY" \
  --output "$PLAN"
```

This changes nothing in the corpus or authoritative registry. It writes a proposed complete replacement registry into the plan folder.

## Dry-run outputs

```text
REGIONALISATION_REPORT.md
summary.json
object_plan.csv
document_moves.csv
work_id_aliases.csv
unparsed.csv
warnings.csv
folder_skeleton.csv
id_registry_changes.csv
metadata_id_registry.updated.csv
migration_plan.json
```

The two new registry files mean:

```text
id_registry_changes.csv
= only the rows added or rewritten, for human review

metadata_id_registry.updated.csv
= the complete registry that apply mode will install
```

## Checks before apply

The full uploaded Shang archive produced these structural counts during validation:

```text
physical oracle-bone objects  13,908
bronze objects                 2,633
document/support moves        29,658
work-ID alias rows            24,658
unparsed rows                  0
warnings                       0
```

Your global maximum IDs will differ from the synthetic validation ceiling, so review the before/after maxima shown in the report rather than comparing their absolute values.

Confirm that `花東0` is absent:

```bash
if grep -n '花東0' "$PLAN/object_plan.csv"; then
  echo "STOP: 花東0 still exists"
else
  echo "OK: no 花東0 object"
fi
```

Confirm the three H3 objects:

```bash
grep -nE 'H3：1573|H3：1616|H3：1630' "$PLAN/object_plan.csv"
```

Confirm the three old source-collection aliases:

```bash
grep -nE '^50042,|^50043,|^50044,' "$PLAN/work_id_aliases.csv"
```

Read the report:

```bash
cat "$PLAN/REGIONALISATION_REPORT.md"
```

Do not apply unless:

```text
Unparsed/problem rows: 0
Warnings: 0
registry before/after maxima are sensible
花東0 is absent
all three H3 objects are present
```

## Apply the exact reviewed plan

```bash
ruby script/shang_inscription_regionalisation.rb \
  --shang-root ../corpus/中國漢文/clean/商殷朝 \
  --config config/corpus_metadata/shang_inscription_regionalisation.yml \
  --concordances config/corpus_metadata/shang_oracle_concordances.csv \
  --overrides config/corpus_metadata/shang_oracle_overrides.csv \
  --id-registry "$ID_REGISTRY" \
  --reviewed-plan "$PLAN" \
  --apply
```

Apply mode:

1. verifies plan version 2;
2. verifies the YAML and both CSV hashes;
3. verifies the authoritative registry hash;
4. verifies every source-file SHA-256;
5. backs up old metadata and the authoritative registry into the plan folder;
6. moves documents and support files;
7. writes object metadata atomically;
8. installs the reviewed complete registry atomically;
9. writes `APPLIED.json` and refuses a second apply.

It is resume-safe when individual files have already moved and their target hashes match. It also accepts the reviewed updated registry during a resumed run if installation happened before an interruption.

## Rebuild the search manifest afterwards

The previous manifest records the old paths, so rebuild it after a successful apply:

```bash
bin/rails corpus_search:rebuild_manifest
```

## Deliberately deferred

```text
image and rubbing acquisition
image-rights review
viewer controls for switching image/transcription layers
large-scale scholarly concordance population
precise findspot corrections not already supported by evidence
Rails route changes
```

The new folders and `images: []` arrays are the landing place for the image phase.
