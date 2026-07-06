# Corpus-search audit

Copy this `corpus_search_audit` directory to:

```text
viewer/script/corpus_search_audit/
```

Run from the `viewer` directory:

```bash
ruby script/corpus_search_audit/run.rb --profile smoke
ruby script/corpus_search_audit/run.rb --profile full
ruby script/corpus_search_audit/run.rb --profile overnight
```

For WSL, keep the audit's large disposable indexes and SQLite caches off the
Windows-mounted `/mnt/c` filesystem. The corpus itself may remain there:

```bash
mkdir -p "$HOME/.cache/fanya-corpus-search/audit"
ruby script/corpus_search_audit/run.rb \
  --profile full \
  --real-cache-root "$HOME/.cache/fanya-corpus-search/audit"
```

The same cache directory can be reused by later audit runs. Every cache record
is checked against the corpus manifest or individual file fingerprint before it
is trusted.

The supervisor runs each case in its own process group, records stdout/stderr and
resource samples, continues after individual failures, warns when work is slow,
and terminates a case that reaches its hard limit or stops making progress.

This edition tests the Ruby analysis profile. `CORPUS_SEARCH_RUBY` or `--ruby`
selects the child Ruby executable. `CORPUS_ROOT` selects the corpus tree.

Use `--list` to see every case and `--help` for all options.
