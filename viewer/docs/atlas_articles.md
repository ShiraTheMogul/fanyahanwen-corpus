# Fanya Hanwen Atlas

The Atlas is a set of polity overview pages connected directly to the corpus.
Public navigation uses explicit node types:

```text
macro-region → period → subperiod → polity
```

A folder's location no longer decides what it is. Source type decides it:

```text
content/atlas/entries/   = polities
content/atlas/periods/   = periods and subperiods
```

The corpus manifest supplies document, work, writer, macro-region, period, and
polity data. `Atlas::CatalogueBuilder` combines that manifest with the
human-edited Atlas sources and writes one runtime catalogue:

```text
storage/corpus_search/atlas/catalogue-v3.json.gz
```

Web requests read that prepared catalogue. They do not scan the corpus or the
Atlas source tree.

## One-time migration from the earlier Atlas

Preview the classification and renames:

```bash
ruby script/rectify_atlas_node_types.rb --dry-run
```

Review the generated `tmp/atlas_node_type_migration_*/` report, then apply:

```bash
ruby script/rectify_atlas_node_types.rb --apply
```

The script backs up `content/atlas/` before changing it. It is idempotent: a
second dry run reports that the actions are already applied. Old polity-style
IDs for period pages are preserved as redirects, and article/reference data is
moved rather than discarded.

The migration deliberately leaves these entries for human review rather than
guessing: 長沙國, 高句麗, 蝦夷島, 渤海, and 新羅.

## Maintenance commands

Rebuild the full search manifest, corpus index, and Atlas catalogue together:

```bash
bin/rails corpus_search:rebuild_manifest
```

Rebuild only the Atlas catalogue from the existing manifest:

```bash
bin/rails atlas:rebuild_catalogue
```

Verify typed sources, articles, catalogue structure, and Unicode integrity:

```bash
bin/rails atlas:verify
ruby script/verify_unicode_integrity.rb
```

## Macro-regions and corpus roots

Atlas macro-regions use human geographical labels such as `中國`, `日本`, and
`朝鮮`. Corpus roots keep their actual collection names, including `中國漢文`,
`日本漢文`, and `朝鮮漢文`. The migration never renames corpus folders.

## Writing polity overviews

Each polity has a `metadata.json` and, when written, an `index.md`. Markdown
uses the same rendering, citations, corpus quotations, preview, and ticketed
editing workflow as the Grammar Wiki.

Atlas prose should read like an article, not an inventory report. An opening
should identify the polity, place it in its period, and name its attestations:

```text
Bogu (薄姑) was a polity during the Shang dynasty, mentioned in the Bamboo Annals.
```

Political relationships belong in the History section as ordinary prose. They
are not permanent headline facts or listing labels. Geography should be written
in complete sentences.

Shang polity stubs can be checked and, when explicitly requested, regenerated:

```bash
ruby script/rewrite_shang_atlas_articles.rb --apply
ruby script/verify_shang_atlas_articles.rb
```

The rewriter preserves the full hand-written Shang and Chong articles and will
not overwrite other manually edited articles without `--force`.

## How represented polities reach period pages

The Atlas catalogue is rebuilt from three different kinds of input:

1. `content/atlas/periods/` defines the human period tree.
2. `content/atlas/entries/` contains human-edited polity metadata and articles.
3. The corpus manifest plus `directory_index-v1.json.gz` records what the corpus
   actually contains.

An existing Atlas article is not a whitelist. A polity represented by an
explicitly configured corpus folder layer still appears on its period page when
no article has been written yet. It receives an ordinary “Article needed” page
and can be filled in later.

Period metadata controls folder discovery with:

```json
{
  "polity_discovery": "all_children",
  "excluded_polity_folders": ["原不詳", "春秋金文"]
}
```

`all_children` is used where every immediate child is intended as a polity, as
with the Western Zhou, Spring and Autumn, and Warring States folders.
`political_names` is used for mixed Japanese folders: names such as `邪馬台国`,
`仙台藩`, `北朝`, and `蝦夷共和國` are included, while modern prefectures and
source buckets are not promoted into polity articles.

The full directory index is maintenance data. Web requests read only the
compiled Atlas catalogue and never traverse the corpus filesystem.

Public aliases must be real alternative names. Period labels, corpus paths, and
legacy IDs belong in typed fields such as `legacy_ids`; they must not appear in
`name.alt`.
