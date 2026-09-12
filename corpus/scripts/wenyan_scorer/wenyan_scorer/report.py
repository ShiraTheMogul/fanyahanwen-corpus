"""
Turn a scan into something readable.

  `flagged.csv`  one row per not_literary / uncertain / too_short document, with
                 the rules that fired and a snippet of the text.
  `rules.csv`    which vernacular rules are driving rejections, ranked, with
                 example matches. This is where false positives show up: if one
                 rule accounts for 6,000 of 7,648 rejections, that rule is the
                 story.
  `roots.csv`    label counts per corpus root and period.
 
"""
from __future__ import annotations

import csv
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Sequence


def iter_records(jsonl: str | Path) -> Iterator[dict]:
    with open(jsonl, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _snippet(corpus_root: Optional[Path], rel: str, chars: int) -> str:
    """First `chars` characters of the source document, whitespace collapsed.

    Without this you are reading a list of file paths and guessing. With it you
    can usually tell in one glance whether a rejection is right.
    """
    if corpus_root is None or chars <= 0:
        return ""
    p = corpus_root / rel
    try:
        t = p.read_text(encoding="utf-8-sig")[: chars * 3]
    except (OSError, UnicodeDecodeError):
        return ""
    return " ".join(t.split())[:chars]


def write_reports(
    jsonl: str | Path,
    out_dir: str | Path,
    *,
    corpus_root: Optional[str | Path] = None,
    labels: Sequence[str] = ("not_literary", "uncertain"),
    snippet_chars: int = 160,
    examples_per_rule: int = 12,
    log=sys.stderr,
) -> Dict[str, object]:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    root = Path(corpus_root) if corpus_root else None
    want = set(labels)

    rule_docs: Counter = Counter()          # rule -> documents it fired in
    rule_hits: Counter = Counter()          # rule -> total hits
    rule_examples: Dict[str, List[str]] = defaultdict(list)
    rule_by_label: Dict[str, Counter] = defaultdict(Counter)
    by_root: Dict[str, Counter] = defaultdict(Counter)
    by_period: Dict[str, Counter] = defaultdict(Counter)
    totals: Counter = Counter()
    han_by_label: Counter = Counter()
    flagged_n = 0

    flagged_path = out / "flagged.csv"
    with open(flagged_path, "w", encoding="utf-8-sig", newline="") as fh:
        # utf-8-sig: Excel on Windows reads a BOM-less UTF-8 CSV as the system
        # code page and turns every Han character into mojibake.
        w = csv.writer(fh)
        w.writerow(["label", "corpus_root", "category", "period", "work",
                    "han", "lc_rate", "vn_rate", "vn_share",
                    "rules_fired", "snippet", "path"])

        for r in iter_records(jsonl):
            if "error" in r:
                totals["error"] += 1
                continue
            lab = r.get("label", "?")
            totals[lab] += 1
            han_by_label[lab] += r.get("han", 0)
            by_root[str(r.get("root", ""))][lab] += 1
            by_period[str(r.get("period", ""))][lab] += 1

            hits = r.get("vn_hits") or {}
            for rid, cnt in hits.items():
                rule_docs[rid] += 1
                rule_hits[rid] += cnt
                rule_by_label[rid][lab] += 1

            if lab not in want:
                continue
            flagged_n += 1
            snip = _snippet(root, r.get("p", ""), snippet_chars)
            for rid in hits:
                if len(rule_examples[rid]) < examples_per_rule and snip:
                    rule_examples[rid].append(snip[:90])
            w.writerow([
                lab, r.get("root", ""), r.get("cat", ""), r.get("period", ""),
                r.get("work", ""), r.get("han", 0), r.get("lc", 0),
                r.get("vn", 0), r.get("vn_share", 0),
                " ".join(f"{k}x{v}" for k, v in sorted(hits.items())),
                snip, r.get("p", ""),
            ])

    # --- the important one -------------------------------------------------
    rules_path = out / "rules.csv"
    with open(rules_path, "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["rule_id", "documents", "total_hits",
                    "docs_not_literary", "docs_uncertain", "docs_literary",
                    "pct_still_literary", "share_of_rejections", "example_text"])
        n_rejected = totals.get("not_literary", 0)
        for rid, ndocs in rule_docs.most_common():
            lb = rule_by_label[rid]
            lit = lb.get("literary", 0)
            rej = lb.get("not_literary", 0)
            w.writerow([
                rid, ndocs, rule_hits[rid], rej, lb.get("uncertain", 0), lit,
                # The column to read: a rule that fires in tens of thousands
                # of documents that stay classified literary is matching
                # Literary Chinese.
                round(lit / ndocs, 4) if ndocs else 0,
                round(rej / n_rejected, 4) if n_rejected else 0,
                " ||| ".join(rule_examples.get(rid, [])[:4]),
            ])

    roots_path = out / "roots.csv"
    all_labels = sorted(totals)
    with open(roots_path, "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["group_kind", "group"] + all_labels + ["total"])
        for kind, table in (("corpus_root", by_root), ("period", by_period)):
            for g, c in sorted(table.items(), key=lambda kv: -sum(kv[1].values())):
                w.writerow([kind, g] + [c.get(l, 0) for l in all_labels]
                           + [sum(c.values())])

    print(f"wrote {flagged_path}  ({flagged_n:,} rows)", file=log)
    print(f"wrote {rules_path}    ({len(rule_docs)} rules — READ THIS ONE FIRST)",
          file=log)
    print(f"wrote {roots_path}", file=log)

    if rule_docs:
        top = rule_docs.most_common(5)
        print("\ntop vernacular rules by documents affected:", file=log)
        for rid, n in top:
            lb = rule_by_label[rid]
            print(f"  {rid:<32} {n:>7,} docs "
                  f"({lb.get('not_literary',0):,} rejected, "
                  f"{lb.get('literary',0):,} still literary)", file=log)
        noisy = [(rid, n, rule_by_label[rid].get("literary", 0) / n)
                 for rid, n in rule_docs.most_common(8) if n >= 500]
        noisy = [x for x in noisy if x[2] > 0.75]
        if noisy:
            print("\n  SUSPECT — fired in many documents that are still literary,"
                  "\n  which is what a false positive looks like at scale:", file=log)
            for rid, n, frac in noisy:
                print(f"    {rid:<32} {frac:.0%} of its {n:,} documents "
                      f"stayed literary", file=log)

    return {
        "labels": dict(totals),
        "han_by_label": dict(han_by_label),
        "flagged_rows": flagged_n,
        "rules_seen": len(rule_docs),
        "files": [str(flagged_path), str(rules_path), str(roots_path)],
    }
