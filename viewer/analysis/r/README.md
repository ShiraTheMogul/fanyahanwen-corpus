# Corpus-search R profiles

The viewer uses application-owned R scripts. Visitors supply search terms and
corpus scopes, never executable R code.

The standard analysis runs as:

```sh
Rscript --vanilla analysis.R document_counts.csv analysis_occurrences.csv output_directory
```

`document_counts.csv` contains one body-only row for every document in the
selected scope, including documents with zero matches. It also records a SHA-256
fingerprint of the body after metadata removal so exact duplicate texts can be
audited without treating metadata differences as textual differences.

`analysis_occurrences.csv` contains compact match offsets, identifiers, and
the five nearest non-punctuation body characters on each side. Those compact
neighbour strings support character analysis without loading the much larger concordance
snippets in `results.csv`. Metadata headers are absent from matching, contexts,
and searchable-character denominators.

The profile uses base R only. This keeps production installation small, makes
startup predictable, and leaves a readable script that another researcher can
rerun without reconstructing a package environment. It produces:

- grouped normalized-frequency tables and figures;
- neighbouring-character summaries and matched source-form distributions;
- OR-alternative and proximity-order summaries when applicable;
- two-scope neighbouring-character keyness when a comparison is requested;
- document-level DP and corrected DPnorm dispersion measures;
- dated-century rates, Poisson intervals, and an exploratory exposure-offset
  Poisson or quasi-Poisson trend model when the data are sufficient;
- exact-body duplicate groups and a one-exact-body-one-unit sensitivity table;
- fixed-seed samples of matching documents and occurrences for manual review;
- CSV summaries, SVG and PNG figures, a JSON report, warnings, timing, and
  `sessionInfo()`.

Set `CORPUS_SEARCH_RSCRIPT` when `Rscript` is not on `PATH`. Optional limits are
`CORPUS_SEARCH_R_TIMEOUT` (seconds) and `CORPUS_SEARCH_R_MEMORY_MB`.

DP follows Gries (2008). DPnorm uses the corrected normalization from Lijffijt
and Gries (2012): `DP / (1 - min(s))`, where `s` contains each document's
share of searchable body characters.
