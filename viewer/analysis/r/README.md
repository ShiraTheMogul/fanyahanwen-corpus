# Corpus-search R profiles

These scripts are application-owned research profiles. Visitors supply search
parameters and corpus scopes, never R code.

A prepared search writes `document_counts.csv`, then
runs:

```sh
Rscript --vanilla analysis.R document_counts.csv output_directory
```

The copied `analysis.R`, input table, output tables, `sessionInfo.txt`, warnings,
and `run_metadata.json` are included in the research ZIP. This makes the first
statistical hand-off small and independently rerunnable without installing
third-party packages.

Set `CORPUS_SEARCH_RSCRIPT` when `Rscript` is not on `PATH`. Optional limits are
`CORPUS_SEARCH_R_TIMEOUT` (seconds) and `CORPUS_SEARCH_R_MEMORY_MB`.
