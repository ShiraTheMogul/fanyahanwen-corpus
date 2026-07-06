# Corpus-search Ruby profiles

The viewer uses application-owned Ruby analysis scripts. Visitors provide search
terms and scope choices, but cannot provide executable code, command-line
options, filesystem paths, or libraries.

The standard profile can be rerun from an extracted export bundle:

```sh
ruby analysis/standard/analysis.rb document_counts.csv analysis_occurrences.csv analysis/standard
```

A comparison export adds the bundled comparison definition:

```sh
ruby analysis/standard/analysis.rb document_counts.csv analysis_occurrences.csv analysis/standard comparison.csv
```

The profile uses only Ruby's standard library. It reads the body-only document
and occurrence tables, then writes:

- overall and grouped frequency tables;
- document prevalence and normalized rates;
- document concentration and dispersion diagnostics;
- neighbouring-character and matched-form tables;
- OR-alternative and proximity-order summaries when applicable;
- exact-body duplicate and sensitivity tables;
- dated-century rates and a descriptive Poisson/quasi-Poisson trend model when
  the dataset is large enough;
- deterministic document and occurrence samples;
- SVG and PNG figures;
- `analysis_report.json`, `warnings.txt`, `timing.csv`, and
  `runtime_info.txt`.

Within Rails, `CorpusSearch::AnalysisRunner` copies the fixed profile into the
export and starts it as a separate child process. This separation matters:
Rails remains the web application, while the child process is the bounded unit
that may time out or hit its memory limit. The runner records the command,
inputs, runtime version, limits, stdout, stderr, exit status, and duration in
`run_metadata.json`.

Configuration:

- `CORPUS_SEARCH_RUBY` selects the Ruby executable. It defaults to the same Ruby
  executable that launched Rails.
- `CORPUS_SEARCH_ANALYSIS_TIMEOUT` sets the wall-clock limit in seconds.
- `CORPUS_SEARCH_ANALYSIS_MEMORY_MB` sets the child-process address-space limit
  where the operating system supports it.
