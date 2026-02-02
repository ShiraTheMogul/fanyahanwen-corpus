# wenyan_syntax (v3)

Pulleyblank-aligned, construction-first syntactic scorer for Literary Chinese vs Modern Mandarin.

Pulleyblank, E. G. (2000). Outline of classical Chinese grammar (Repr). UBC Press.

Core design rules:
- Do **not** score "words". Score **frames** (constructions).
- Ambiguous characters (他, 的, 其, 本, 之) are only counted in **role-bearing frames**.
- Output includes an evidence trace (matched spans), so every decision is auditable.

Feature examples:
- Coverb-heavy frames (自/由/從, 以, 為, 於/于, 云 quoting).
- classifier footprints (NUM+N vs NUM+X+N, 個/个 density)
  - pronoun distribution approximations (subject-like vs object-like frames)
- Segmentation supports unpunctuated corpora via sliding windows.
- oracle-bone divination detector (干支 + 卜 + X, plus 貞 as co-signal).

Run
```bash
python -m wenyan_syntax score my.txt --segment paragraph
```

Unpunctuated corpora
```bash
python -m wenyan_syntax score my.txt --segment window --window-size-han 320 --window-stride-han 200 --json > out.json
```

When sentence punctuation is not a boundary
```bash
python -m wenyan_syntax score my.txt --segment sentence_run --no-punct-boundaries
```


## Install (local / editable)

From the folder that contains `wenyan_syntax/`:

```bash
python -m pip install -e .
```

What this command does:
- `pip install -e .` installs the package in "editable" mode, meaning edits you make to the code
  immediately affect imports (great for iterating on rulesets).

## CLI

Score a file and print a human summary:

```bash
python -m wenyan_syntax score my.txt --segment paragraph
```

Emit JSON (for pipeline chaining):

```bash
python -m wenyan_syntax score my.txt --json > out.json
```

Disable evidence spans (smaller JSON):

```bash
python -m wenyan_syntax score my.txt --json --no-evidence
```

## Weights override

You can override rule weights without changing code:

`weights.json`:
```json
{
  "lc.zhi.negslot_resumptive": 5.0,
  "md.np.de_linker": -2.0
}
```

Run:

```bash
python -m wenyan_syntax score my.txt --weights-override weights.json --json
```

## Output

- `segments[]`: per segment scores, label, role rates per 1000 Han, hits (rule evidence).
- `summary`: median score, label proportions, top contributing rules.