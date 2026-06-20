# Pronunciation source archives

Place the original Xiaoxuetang download here as:

```text
resources/pronunciations/xiaoxuetang.zip
```

The importer reads the nested family ZIP files and XLSX workbooks directly. Do
not extract, rename, or edit the source archive.

Dry run one trial set:

```bash
bin/rails xiaoxuetang:import DATASETS=73,120,176,215,222,240,365
```

Apply that reviewed set:

```bash
bin/rails xiaoxuetang:import DATASETS=73,120,176,215,222,240,365 APPLY=1
```

A dry run writes an audit directory under `tmp/xiaoxuetang_imports/`. Missing
tone or other partial source data is imported conservatively rather than being
rejected. Only rows that cannot be attached to one Unicode codepoint, contain no
pronunciation information at all, or cannot be read are skipped.
