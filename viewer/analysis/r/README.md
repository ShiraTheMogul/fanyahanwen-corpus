# Corpus-search R profiles

The viewer uses application-owned R scripts. Visitors supply search terms and
corpus scopes, never executable R code.

The standard analysis runs as:

```sh
Rscript --vanilla analysis.R document_counts.csv analysis_occurrences.csv output_directory
```

`document_counts.csv` contains one body-only row for every document in the
selected scope, including documents with zero matches. `analysis_occurrences.csv`
contains only compact match offsets and identifiers, avoiding the much larger
concordance snippets in `results.csv`. Metadata headers are absent from both matching and the
searchable-character denominators.

The profile uses base R only. This keeps production installation small, makes
startup predictable, and leaves a readable script that another researcher can
rerun without reconstructing a package environment. It produces CSV summaries,
SVG and PNG figures, a JSON report, warnings, timing, and `sessionInfo()`.

Set `CORPUS_SEARCH_RSCRIPT` when `Rscript` is not on `PATH`. Optional limits are
`CORPUS_SEARCH_R_TIMEOUT` (seconds) and `CORPUS_SEARCH_R_MEMORY_MB`.
