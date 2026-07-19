# Fanya Hanwen Atlas

The atlas is a set of polity overview pages connected directly to the corpus.
Public navigation is organised as:

```text
macro-region → period → polity
```

The corpus manifest supplies macro-region, period, polity, document, work, and
author data. `Atlas::CatalogueBuilder` compiles that information together with
the human-edited files in `content/atlas/entries/`.

Web requests read one prepared catalogue. They do not walk the corpus tree,
glob metadata files, or validate every entry.

## Maintenance commands

Rebuild the full search manifest, corpus index, and atlas catalogue together:

```bash
bin/rails corpus_search:rebuild_manifest
```

Rebuild only the atlas catalogue from an existing manifest:

```bash
bin/rails atlas:rebuild_catalogue
```

Rebuild the metadata-only fallback used before a local manifest is available:

```bash
```

Verify catalogue structure, source articles, and Unicode integrity:

```bash
bin/rails atlas:verify
ruby script/verify_unicode_integrity.rb
```

## Source files

Each polity has a `metadata.json` and, when written, an `index.md`. Markdown
uses the same rendering, citations, corpus quotations, preview, and ticketed
editing workflow as the Grammar Wiki.

Manual fields include:

- names and aliases;
- dates;
- capitals;
- rulers;
- notable writers and works;
- related polities;
- corpus placement;
- attestations and historical notes.

The manifest adds factual corpus counts and representative writers and works.
Those derived lists are labelled as corpus representation, not as claims of
historical importance.

## Writing polity overviews

Atlas prose should read like an article, not like a generated inventory report. The
opening paragraph should identify the polity, place it in its period, and name the
sources in which it is mentioned or attested. For example:

```text
Bogu (薄姑) was a polity during the Shang dynasty, mentioned in the Bamboo Annals.
```

Do not write phrases such as “represented in the corpus folderisation” or “the
research inventory describes it as”. The folder tree and research inventory are
editorial sources; they are not the subject of the public article.

Political relationships belong in the History section as ordinary prose. They are
not displayed as permanent headline facts. Attestation belongs in the overview,
while geography should be written in complete sentences.

Shang polity stubs can be checked and, when explicitly requested, regenerated with:

```bash
ruby script/rewrite_shang_atlas_articles.rb --apply
ruby script/verify_shang_atlas_articles.rb
```

The rewriter preserves the full hand-written Shang and Chong articles. It refuses
to overwrite other manually edited articles unless `--force` is supplied.
