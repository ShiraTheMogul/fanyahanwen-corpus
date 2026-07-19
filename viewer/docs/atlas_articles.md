# Historical Atlas article and folder system

The atlas uses the same article workflow as the Literary Chinese Grammar Wiki,
but its navigation is generated from historically meaningful corpus folders.

## Four separate jobs

The implementation keeps four concerns apart:

1. `content/atlas/hierarchy.json` stores the browse tree: corpus collection,
   period, polity, territory, and other deliberate historical levels.
2. Each `metadata.json` identifies one polity and records its corpus placement.
3. `index.md` stores the readable article, references, corpus quotations,
   preset searches, publication dates, and credits.
4. Rails services load, validate, render, preview, and publish those files.

This is why a Qing reader does not have to pass through Shang polities. The
atlas opens with corpus collections, then follows the period/polity structure
already encoded in the clean corpus folders.

## Content folder pattern

Article storage mirrors the relevant corpus placement:

```text
content/atlas/polities/<corpus-root>/<period>/<polity>/
├── metadata.json
└── index.md                 # absent until an article is written
```

Examples:

```text
content/atlas/polities/中國漢文/商殷朝/土方/
content/atlas/polities/中國漢文/清朝/東寧國漢文/
```

A metadata-only folder is intentional. It creates a real atlas page with the
same preview/edit/ticket workflow, while making clear that prose still needs to
be written.

## Why the hierarchy is selective

The corpus contains more than 100,000 directories, most of which are works.
The atlas therefore does **not** treat every directory as a polity. Only nodes
recorded in `hierarchy.json`, or direct children of a node explicitly marked
with `discover_children_as`, are navigational data.

For example, `中國漢文/商殷朝` is marked so that a new direct child is a polity.
`中國漢文/唐朝` is not marked, because its direct children are normally works.
This is the difference between using the folder tree as data and guessing from
folder depth.

## Corpus quotation pattern

Put a corpus quotation in a Markdown article with:

```text
{% corpus_quote path="中國漢文/clean/.../text.txt" text="quoted text" highlight="word|second word" source="displayed source title" %}
```

- `path` opens the cited corpus document.
- `text` is the displayed quotation.
- `highlight` marks one or more strings separated by `|`.
- `source` is the human-readable source label.

## Preset corpus searches

Searches live in YAML front matter. A broad search is:

```yaml
corpus_searches:
  - label: Mentions of 土方
    mode: exact
    term_a: 土方
    context: 30
```

A folder-scoped search is:

```yaml
  - label: 土方 within its corpus folder
    mode: exact
    term_a: 土方
    folders:
      - 中國漢文/clean/商殷朝/土方
    context: 30
```

The second form is especially useful for one-character names such as `光` or
`呂`. It uses the corpus folder as an exact scope rather than hoping that a
metadata label or a common character is unambiguous.

Available metadata filters remain:

```text
nation, polity, period, region, author, year_start, year_end
```

Folder filters are:

```text
folders, exclude_folders
```

## Updating from the corpus

Run from the viewer directory:

```bash
ruby script/generate_atlas_from_corpus.rb --dry-run
ruby script/generate_atlas_from_corpus.rb --apply
```

When `corpus/` is beside rather than inside `viewer/`, the script detects the
sibling folder. An explicit path can be supplied:

```bash
ruby script/generate_atlas_from_corpus.rb \
  --corpus /mnt/c/Users/chipp/OneDrive/Documents/fanyahanwen-corpus/corpus \
  --dry-run
```

The dry run reports new configured historical children. Apply mode adds only
missing hierarchy nodes and metadata files. It never overwrites an existing
`metadata.json` or `index.md`.

Reports are written under:

```text
tmp/atlas_generation/<timestamp>/
```

## Edit and publication workflow

```text
article page
  -> create/edit/translation form
  -> full preview
  -> accountless ticket
  -> moderator review
  -> validation against the atlas registry
  -> atomic publication into content/atlas
```

“Atomic” means the publisher writes a complete temporary file and then moves it
into place. A failed write cannot leave half an article behind.

## Routes

Routes are intentionally not edited by the patch. Copy the unchanged block in
`ATLAS_ROUTES_TO_ADD.txt` into `config/routes.rb` manually.
