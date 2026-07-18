# Shang inscription regionalisation: phase 1

This patch reorganises the present `商殷朝` tree around **physical inscribed objects**.

It does not fetch images. It prepares the object folders and JSON relationships so photographs, rubbings, facsimiles, and tracings can be added later without another structural migration.

## The simple model

```text
work       = one physical bone, shell, or bronze object
document   = one transcription segment or translation attached to that object
folder     = political/geographical classification + medium + physical object
identifier = a catalogue number such as 合集00014 or 集成00793
```

For example, these old sentence works:

```text
合集00014正.1
合集00014正.2
合集00014正.3
```

become one physical work:

```text
商/甲骨文/殷墟/出土位置不詳/合集00014/
├── metadata.json
├── 合集00014正.1_ASDC.txt
├── 合集00014正.2_ASDC.txt
└── 合集00014正.3_Schwartz.txt
```

The sentence divisions remain individually searchable documents. They simply stop pretending to be three different bones.

## Files in this patch

```text
script/shang_inscription_regionalisation.rb
script/shang_inscription_regionalisation_README.md
config/corpus_metadata/shang_inscription_regionalisation.yml
config/corpus_metadata/shang_oracle_concordances.csv
config/corpus_metadata/shang_oracle_overrides.csv
test/scripts/shang_inscription_regionalisation_test.rb
```

The Ruby file contains the migration machinery. The YAML and CSV files contain scholarly decisions. This separation is intentional: a changed archaeological attribution should usually be a data edit, not a Ruby-code edit.

## What the script currently understands

Oracle-bone catalogue series:

```text
甲骨文合集                         → 合集
小屯南地甲骨                       → 屯南
英國所藏甲骨                       → 英藏
懷特氏等所藏甲骨                   → 懷
東京大學所藏甲骨                   → 東文研
殷墟花園莊東地甲骨                 → 花東
```

Bronze catalogue series:

```text
殷周金文集成                       → 集成
新收殷周青銅器銘文暨器影彙編       → 新收
```

The old `花園庄（洹北）` import is separated correctly:

```text
花園莊東地/H3 → inside 殷墟
洹北商城       → a separate prepared site folder
```

## Resulting skeleton

The YAML creates these prepared branches even when they are still empty:

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

Empty folders are deliberate authority data. They do not imply that written material has already been found there.

## Metadata produced for an oracle-bone object

A physical object receives one `metadata.json` containing:

```text
work_id
legacy_work_ids
period / polity / local_polity / region
findspot
canonical_identifier
identifiers
sources
categories
documents          # searchable transcription segments
transcriptions     # groups those documents by transcription source
translations       # translation documents, language, and source
variants
images              # empty for this phase
support_files       # only where review/evidence files already exist
```

The lowest existing sentence `work_id` becomes the physical object's stable `work_id`. Other sentence work IDs become aliases in `work_id_aliases.csv`. New work IDs are allocated only for objects that previously existed solely inside a flat compilation import.

Existing `document_id` values are retained. Previously unregistered English 花東 translations receive new document IDs above the current maximum.

## Translation placement

Translations are not mixed into the main transcription list. They are placed beneath the object:

```text
花東113/
├── 花東113.5_Schwartz.txt
└── translation/
    └── eng/
        └── Schwartz/
            └── 花東113.5_Schwartz.txt
```

The relationship is also recorded in `metadata.json`. A later viewer patch can expose source/translation switching without moving the files again.

## Dry run first

Run this from the viewer root:

```bash
ruby script/shang_inscription_regionalisation.rb \
  --shang-root ../corpus/中國漢文/clean/商殷朝 \
  --config config/corpus_metadata/shang_inscription_regionalisation.yml \
  --concordances config/corpus_metadata/shang_oracle_concordances.csv \
  --overrides config/corpus_metadata/shang_oracle_overrides.csv \
  --output "tmp/shang_inscription_regionalisation/plan_$(date -u +%Y%m%dT%H%M%SZ)"
```

What each important part means:

```text
ruby SCRIPT.rb       run a Ruby program
--shang-root PATH    tell it which 商殷朝 folder to inspect
--config PATH        use this reviewed folder/catalogue authority file
--concordances PATH  use only reviewed same-object catalogue matches
--overrides PATH     use reviewed object-level geography/period corrections
--output PATH        write reports and the exact plan here
```

The default mode changes nothing in the corpus.

For a smaller diagnostic run:

```bash
--scope oracle_bones
--scope bronzes
```

## Dry-run outputs

```text
REGIONALISATION_REPORT.md  readable summary
summary.json               counts
object_plan.csv            one row per object/collection
document_moves.csv         every exact source and target file
work_id_aliases.csv        old sentence work ID → physical object work ID
unparsed.csv               cases the script refused to guess
warnings.csv               non-blocking observations
folder_skeleton.csv        prepared empty folders
migration_plan.json        exact machine-readable reviewed plan
```

Apply is blocked whenever `unparsed.csv` contains rows.

## Cross-catalogue concordances

Do not make the Ruby script guess that an `英藏` number and a `合集` number are the same object. Put a reviewed match in:

```text
config/corpus_metadata/shang_oracle_concordances.csv
```

Example shape:

```csv
series,object_value,canonical_series,canonical_object_value,source,note
英國所藏甲骨,23,甲骨文合集,00014,full citation or authority,brief note
```

This says:

```text
英藏23 and 合集00014 are one physical object
canonical folder name = 合集00014
both identifiers remain in metadata
```

The example is structural only; do not add a row without an actual concordance source.

## Per-object location and period corrections

Defaults can later be corrected without editing Ruby. Add reviewed rows to:

```text
config/corpus_metadata/shang_oracle_overrides.csv
```

Example shape:

```csv
series,object_value,target_path,period,polity,local_polity,region,site,area,locus,source,note
甲骨文合集,00014,周方/甲骨文/周原/鳳雛,商朝,商,周方,周原,周原,鳳雛,,full citation,brief note
```

Again, this is only an explanation of the columns, not a claim about `合集00014`.

`target_path` is relative to `商殷朝`. The script adds the object folder name itself.

This is the mechanism for:

```text
moving a securely excavated object out of 殷墟/出土位置不詳
assigning a known pit such as H3 or YH127
placing a 周原 object under 周方
changing a securely post-conquest object to a Zhou-period destination later
```

The default Shang bias remains intact unless a reviewed override says otherwise.

## Apply a reviewed plan

After inspecting the report and CSV files:

```bash
PLAN="$(ls -dt tmp/shang_inscription_regionalisation/plan_* | head -1)"

ruby script/shang_inscription_regionalisation.rb \
  --shang-root ../corpus/中國漢文/clean/商殷朝 \
  --config config/corpus_metadata/shang_inscription_regionalisation.yml \
  --concordances config/corpus_metadata/shang_oracle_concordances.csv \
  --overrides config/corpus_metadata/shang_oracle_overrides.csv \
  --reviewed-plan "$PLAN" \
  --apply
```

The first command stores the newest plan directory in a shell variable called `PLAN`. The second command applies that exact plan.

Apply mode:

1. checks that the YAML and both CSV files have not changed;
2. checks the SHA-256 hash of every source file;
3. refuses a different pre-existing target file;
4. backs up old metadata into the plan directory;
5. moves every transcription, translation, and support file;
6. writes JSON atomically;
7. removes only superseded metadata and empty legacy directories;
8. writes `APPLIED.json` so the same plan cannot be applied twice.

An interrupted run can be resumed with the same command: already moved files are accepted only when the target hash is identical.

## Tests

Run the standalone migration tests from the viewer root:

```bash
ruby test/scripts/shang_inscription_regionalisation_test.rb
```

The tests cover:

```text
sentence → physical-object collapse
reviewed cross-catalogue merging
translation and support-file preservation
conventional bronze identifiers
object-level geography overrides
full dry-run/apply behaviour
hash/second-apply safety
```

## Deliberately deferred

This phase does not:

```text
download photographs or rubbings
judge unreviewed catalogue concordances
invent precise excavation loci
move ambiguous transition-period material into Western Zhou
change Rails routes
add the future image/transcription-switching viewer interface
```

The new object folders and `images: []` field are the landing place for the next phase.
