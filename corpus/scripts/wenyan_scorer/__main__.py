"""
CLI.

    python -m wenyan_syntax score FILE...          score text files
    python -m wenyan_syntax rules                  list the ruleset with citations
    python -m wenyan_syntax explain RULE_ID        show one rule in full
    python -m wenyan_syntax calibrate ...          fit weights against labelled text
    python -m wenyan_syntax corpus-stats ROOT      what is in a corpus subtree
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .calibrate import LogisticModel, fit
from .rules import DEFAULT_RULESETS, load_rulesets
from .score import (DEFAULT_LC_THRESHOLD, DEFAULT_MIN_HAN, DEFAULT_VN_THRESHOLD,
                    score_text)


def _read(path: str) -> str:
    # utf-8-sig so that BOM and no-BOM files both read cleanly and the BOM never
    # ends up as a stray ﻿ at the head of the first segment.
    return Path(path).read_text(encoding="utf-8-sig")


def cmd_score(args) -> int:
    model = LogisticModel.from_json(args.model) if args.model else None
    rulesets = [s.strip() for s in args.rulesets.split(",") if s.strip()]

    results = []
    for p in args.paths:
        res = score_text(
            _read(p),
            segment=args.segment,
            rulesets=rulesets,
            weights_override_json=args.weights_override,
            keep_evidence=not args.no_evidence,
            window_size_han=args.window_size_han,
            window_stride_han=args.window_stride_han,
            min_han=args.min_han,
            lc_threshold=args.lc_threshold,
            vn_threshold=args.vn_threshold,
            apparatus_limit=args.apparatus_limit,
            model=model,
        )
        res["meta"]["source_path"] = p
        results.append(res)

    if args.json:
        out = results if len(results) > 1 else results[0]
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    for res in results:
        s = res["summary"]
        print("=" * 74)
        print(res["meta"].get("source_path", "<text>"))
        if s.get("scored_segment_count", 0) == 0:
            print(f"  {s.get('note', 'nothing scored')}")
            continue
        print(f"  label            : {s['document_label']}")
        print(f"  why              : {s['why']}")
        print(f"  literary evidence: {s['lc_rate_mean']:.2f} per 1000 Han")
        print(f"  vernacular evid. : {s['vn_rate_mean']:.2f} per 1000 Han")
        print(f"  P(literary)      : {s['median_probability_literary']} "
              f"({res['segments'][0].get('probability_source', '?')})")
        print(f"  segments         : {s['scored_segment_count']} scored "
              f"of {s['segment_count']}  ({s['han_chars']} Han)")
        print(f"  per-segment      : {s['label_counts']}")
        if s["top_rules"]:
            print("  strongest evidence:")
            for r in s["top_rules"][:8]:
                print(f"    {r['rule_id']:<38} {r['weighted_rate']:>8.2f}")
        skipped = res["segments"][0].get("skipped_rules") or []
        if skipped:
            print(f"  NOTE: {len(skipped)} rule(s) need punctuation this text "
                  f"lacks and could not fire: {', '.join(skipped[:5])}"
                  f"{' …' if len(skipped) > 5 else ''}")
    return 0


def cmd_rules(args) -> int:
    rules = load_rulesets([s.strip() for s in args.rulesets.split(",") if s.strip()])
    if args.json:
        print(json.dumps([{
            "rule_id": r.rule_id, "family": r.family, "polarity": r.polarity,
            "tier": r.tier, "weight": r.weight, "cite": r.cite,
            "pattern": r.regex.pattern, "notes": r.notes, "repair": r.repair,
            "requires_punctuation": r.requires_punctuation,
        } for r in rules], ensure_ascii=False, indent=2))
        return 0

    for pol in ("lc", "vn"):
        subset = [r for r in rules if r.polarity == pol]
        heading = ("LITERARY CHINESE — positive evidence" if pol == "lc"
                   else "VERNACULAR — the only evidence that can say 'not Literary'")
        print(f"\n{heading}  ({len(subset)} rules)")
        print("-" * 74)
        for tier in (1, 2, 3):
            tr = [r for r in subset if r.tier == tier]
            if not tr:
                continue
            print(f"  tier {tier}:")
            for r in tr:
                print(f"    {r.rule_id:<38} w={r.weight:<5} {r.cite}")
    print(f"\n{len(rules)} rules total.")
    return 0


def cmd_explain(args) -> int:
    rules = {r.rule_id: r for r in load_rulesets(
        [s.strip() for s in args.rulesets.split(",") if s.strip()])}
    r = rules.get(args.rule_id)
    if r is None:
        print(f"no such rule: {args.rule_id}", file=sys.stderr)
        print("run `python -m wenyan_syntax rules` to list them", file=sys.stderr)
        return 1
    print(f"{r.rule_id}")
    print(f"  family   : {r.family}")
    print(f"  polarity : {r.polarity}  ({'literary evidence' if r.polarity == 'lc' else 'vernacular evidence'})")
    print(f"  tier     : {r.tier}")
    print(f"  weight   : {r.weight}")
    print(f"  cite     : Pulleyblank {r.cite}")
    print(f"  needs punctuation: {r.requires_punctuation}")
    print(f"  pattern  : {r.regex.pattern}")
    print(f"\n  {r.notes}")
    if r.repair:
        print(f"\n  repair: {r.repair}")
    return 0


def cmd_calibrate(args) -> int:
    from .corpus import load_samples, summarise_samples

    samples = load_samples(
        positive_roots=args.positive,
        negative_roots=args.negative or [],
        group_level=args.group_level,
        limit_per_root=args.limit,
    )
    summary = summarise_samples(samples)
    print("corpus:", json.dumps(summary, ensure_ascii=False, indent=2))

    if summary["negative"] == 0:
        print(
            "\nNo negative samples. Every tradition in the Fanyahanwen tree is\n"
            "Literary Chinese, so the corpus alone is a single-class dataset and\n"
            "a model fitted on it would learn only to say yes.\n"
            "Pass --negative DIR with modern Mandarin or vernacular fiction.",
            file=sys.stderr,
        )
        return 2

    model, report = fit(
        [s.text for s in samples],
        [s.label for s in samples],
        rulesets=[s.strip() for s in args.rulesets.split(",") if s.strip()],
        name=args.name,
        l2=args.l2,
    )
    print("\nheld-out performance:", json.dumps(report, ensure_ascii=False, indent=2))

    model.to_json(args.out)
    print(f"\nmodel written to {args.out}")

    rules = load_rulesets([s.strip() for s in args.rulesets.split(",") if s.strip()])
    disagreements = [d for d in model.compare_to_hand_weights(rules)
                     if not d["sign_agrees"]]
    if disagreements:
        print(f"\n{len(disagreements)} rule(s) where the corpus contradicts the "
              "asserted weight — these are the ones worth reading:")
        for d in disagreements[:20]:
            print(f"  {d['rule_id']:<38} asserted {d['asserted_weight']:>6} "
                  f"fitted {d['fitted_coefficient']:>8}   {d['cite']}")
    return 0


def cmd_scan(args) -> int:
    from .scan import scan
    summary = scan(
        args.root, args.out,
        rulesets=[x.strip() for x in args.rulesets.split(",") if x.strip()],
        workers=args.workers, limit=args.limit,
        min_han=args.min_han, lc_threshold=args.lc_threshold,
        vn_threshold=args.vn_threshold, apparatus_limit=args.apparatus_limit,
        index_csv=args.index, skip_raw=not args.include_raw,
        resume=not args.no_resume, progress_every=args.progress_every,
        flush_every=args.flush_every,
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


def cmd_summarise(args) -> int:
    from .scan import summarise_jsonl
    print(json.dumps(summarise_jsonl(args.jsonl, group=args.group),
                     ensure_ascii=False, indent=2))
    return 0


def cmd_report(args) -> int:
    from .report import write_reports
    res = write_reports(
        args.jsonl, args.out_dir,
        corpus_root=args.corpus_root,
        labels=[x.strip() for x in args.labels.split(",") if x.strip()],
        snippet_chars=args.snippet_chars,
    )
    print(json.dumps(res, ensure_ascii=False, indent=2))
    return 0


def cmd_corpus_stats(args) -> int:
    from .corpus import group_key, iter_works

    counts = {}
    chars = {}
    n = 0
    for w in iter_works(args.root, limit=args.limit):
        k = group_key(w, args.group_level)
        counts[k] = counts.get(k, 0) + 1
        chars[k] = chars.get(k, 0) + len(w.read_text())
        n += 1
    print(json.dumps({
        "works": n,
        "by_" + args.group_level: {
            k: {"works": counts[k], "chars": chars[k]}
            for k in sorted(counts, key=lambda x: -counts[x])
        },
    }, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wenyan_syntax",
        description="Construction-based Literary Chinese scorer, after Pulleyblank (2000).",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("score", help="score one or more UTF-8 text files")
    s.add_argument("paths", nargs="+")
    s.add_argument("--segment", default="paragraph",
                   choices=["paragraph", "line", "sentence_run", "window", "whole"])
    s.add_argument("--rulesets", default=",".join(DEFAULT_RULESETS))
    s.add_argument("--weights-override", default=None)
    s.add_argument("--model", default=None, help="calibrated model JSON")
    s.add_argument("--json", action="store_true")
    s.add_argument("--no-evidence", action="store_true")
    s.add_argument("--window-size-han", type=int, default=300)
    s.add_argument("--window-stride-han", type=int, default=200)
    s.add_argument("--min-han", type=int, default=DEFAULT_MIN_HAN)
    s.add_argument("--lc-threshold", type=float, default=DEFAULT_LC_THRESHOLD)
    s.add_argument("--vn-threshold", type=float, default=DEFAULT_VN_THRESHOLD)
    s.add_argument("--apparatus-limit", type=float, default=None,
                   help="refuse to score segments whose kana/hangul/Latin ratio "
                        "exceeds this (default: off — measured and reported only)")
    s.set_defaults(func=cmd_score)

    r = sub.add_parser("rules", help="list the ruleset with Pulleyblank citations")
    r.add_argument("--rulesets", default=",".join(DEFAULT_RULESETS))
    r.add_argument("--json", action="store_true")
    r.set_defaults(func=cmd_rules)

    e = sub.add_parser("explain", help="show one rule in full")
    e.add_argument("rule_id")
    e.add_argument("--rulesets", default=",".join(DEFAULT_RULESETS))
    e.set_defaults(func=cmd_explain)

    c = sub.add_parser("calibrate", help="fit weights against labelled text")
    c.add_argument("--positive", nargs="+", required=True,
                   help="corpus subtrees that ARE Literary Chinese")
    c.add_argument("--negative", nargs="*", default=[],
                   help="directories of .txt that are NOT")
    c.add_argument("--out", default="model.json")
    c.add_argument("--name", default="fanyahanwen")
    c.add_argument("--l2", type=float, default=1.0)
    c.add_argument("--limit", type=int, default=None)
    c.add_argument("--group-level", default="macro_region",
                   choices=["corpus_root", "macro_region", "period", "polity", "work"])
    c.add_argument("--rulesets", default=",".join(DEFAULT_RULESETS))
    c.set_defaults(func=cmd_calibrate)

    sc = sub.add_parser("scan", help="score a whole corpus subtree to JSONL (resumable)")
    sc.add_argument("root", help="corpus subtree to walk, or the corpus root")
    sc.add_argument("--out", required=True, help="JSONL output; also the checkpoint")
    sc.add_argument("--workers", type=int, default=0, help="0 = one per CPU")
    sc.add_argument("--limit", type=int, default=None, help="stop after N new documents")
    sc.add_argument("--index", default=None,
                    help="enumerate from index_corpus.csv instead of walking. "
                         "Faster, but the index is stale: it omits 四庫全書, "
                         "維基大典, 礦藝大典 and 琉球漢文 entirely")
    sc.add_argument("--include-raw", action="store_true",
                    help="also scan raw/ (default: clean/ only — raw/ is the "
                         "same works again)")
    sc.add_argument("--no-resume", action="store_true",
                    help="do not skip documents already in --out")
    sc.add_argument("--progress-every", type=int, default=500)
    sc.add_argument("--flush-every", type=int, default=50,
                    help="flush the checkpoint every N records (default 50). "
                         "1 = flush per record: safest, and slow on a synced path")
    sc.add_argument("--min-han", type=int, default=DEFAULT_MIN_HAN)
    sc.add_argument("--lc-threshold", type=float, default=DEFAULT_LC_THRESHOLD)
    sc.add_argument("--vn-threshold", type=float, default=DEFAULT_VN_THRESHOLD)
    sc.add_argument("--apparatus-limit", type=float, default=None)
    sc.add_argument("--rulesets", default=",".join(DEFAULT_RULESETS))
    sc.set_defaults(func=cmd_scan)

    sm = sub.add_parser("summarise", help="aggregate a scan JSONL without loading it")
    sm.add_argument("jsonl")
    sm.add_argument("--group", default="root",
                    choices=["root", "cat", "period", "work", "label"])
    sm.set_defaults(func=cmd_summarise)

    rp = sub.add_parser("report", help="turn a scan JSONL into readable CSVs")
    rp.add_argument("jsonl")
    rp.add_argument("--out-dir", default="report")
    rp.add_argument("--corpus-root", default=None,
                    help="corpus root, so each flagged row can carry a snippet "
                         "of the actual text. Without it you get paths only")
    rp.add_argument("--labels", default="not_literary,uncertain",
                    help="which labels to list in flagged.csv "
                         "(add too_short to see what was skipped)")
    rp.add_argument("--snippet-chars", type=int, default=160)
    rp.set_defaults(func=cmd_report)

    cs = sub.add_parser("corpus-stats", help="summarise a corpus subtree")
    cs.add_argument("root")
    cs.add_argument("--limit", type=int, default=None)
    cs.add_argument("--group-level", default="period",
                    choices=["corpus_root", "macro_region", "period", "polity", "work"])
    cs.set_defaults(func=cmd_corpus_stats)

    return p


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
