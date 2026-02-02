"""
CLI: python -m wenyan_syntax ...
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from typing import List, Optional

from .score import score_text

def cmd_score(
    paths: List[str],
    segment: str,
    ruleset: str,
    json_out: bool,
    keep_evidence: bool,
    weights_override: Optional[str],
    no_punct_boundaries: bool,
    window_size_han: int,
    window_stride_han: int,
):
    results = []
    for p in paths:
        text = Path(p).read_text(encoding="utf-8")
        res = score_text(
            text,
            segment=segment,
            ruleset=ruleset,
            keep_evidence=keep_evidence,
            weights_override_json=weights_override,
            treat_punct_as_boundaries=not no_punct_boundaries,
            window_size_han=window_size_han,
            window_stride_han=window_stride_han,
        )
        res["meta"]["source_path"] = p
        results.append(res)

    if json_out:
        print(json.dumps(results if len(results) > 1 else results[0], ensure_ascii=False, indent=2))
        return

    for res in results:
        src = res["meta"].get("source_path", "<text>")
        summ = res["summary"]
        print("=" * 72)
        print(src)
        print(f"Segments: {summ['segment_count']}")
        print(f"Median default score: {summ['median_default_score']:.3f}")
        print("Proportions:", {k: round(v, 3) for k, v in summ["proportions"].items()})
        print("Top rules:")
        for item in summ["top_rules_by_abs_contribution"][:10]:
            print(f"  {item['rule_id']}: {item['contribution']:.3f}")

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="wenyan_syntax", description="Pulleyblank-aligned construction scorer (v3).")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("score", help="Score one or more UTF-8 text files.")
    s.add_argument("paths", nargs="+", help="Text file paths (UTF-8).")
    s.add_argument("--segment", choices=["paragraph", "sentence_run", "window"], default="paragraph")
    s.add_argument("--ruleset", default="pulleyblank_core_v3")
    s.add_argument("--weights-override", default=None)
    s.add_argument("--json", action="store_true")
    s.add_argument("--no-evidence", action="store_true")
    s.add_argument("--no-punct-boundaries", action="store_true")
    s.add_argument("--window-size-han", type=int, default=300)
    s.add_argument("--window-stride-han", type=int, default=200)
    return p

def main():
    args = build_parser().parse_args()
    if args.cmd == "score":
        cmd_score(
            paths=args.paths,
            segment=args.segment,
            ruleset=args.ruleset,
            json_out=args.json,
            keep_evidence=not args.no_evidence,
            weights_override=args.weights_override,
            no_punct_boundaries=args.no_punct_boundaries,
            window_size_han=args.window_size_han,
            window_stride_han=args.window_stride_han,
        )

if __name__ == "__main__":
    main()
