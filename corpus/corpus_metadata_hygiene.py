#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
corpus_metadata_hygiene.py

A standalone corpus maintenance tool for '# KEY: value' headers).

It focuses on the two things you asked for:

1) Punc hygiene
   - Clamp leading blank lines to at most 2
   - Merge bracket content that got split over newlines/whitespace (default: 《》 and 〈〉)
   - Remove a newline immediately before comma-like punctuation (default: ，、､﹐﹑)
   - Optionally cut public-domain boilerplate markers (same logic you provided)

2) Retooling categories for nation-scraped corpora
   - Infer a nation candidate from the file path
   - If '# CATEGORY' exactly equals that nation candidate, move it to '# NATION'
     (and delete '# CATEGORY')

3) Enrich existing corpus with zh.wikisource categories
   - Reads '# PAGE_TITLE' from headers
   - Queries MediaWiki categories
   - Writes/updates '# WS_CATEGORIES: ...'

Dependencies:
  pip install requests beautifulsoup4

Examples
--------
# Apply hygiene only
python corpus_metadata_hygiene.py hygiene ./corpus

# Hygiene + PD cut
python corpus_metadata_hygiene.py hygiene ./corpus --cut-pd

# Move CATEGORY->NATION when path agrees
python corpus_metadata_hygiene.py rearrange ./corpus

# Refresh WS_CATEGORIES from Wikisource (uses PAGE_TITLE)
python corpus_metadata_hygiene.py enrich-ws-categories ./corpus --sleep 0.5
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import requests

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"
HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusScraper/1.1 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

# Public-domain cutoff markers (optional)
PD_MARKERS = [
    "本作品在全世界都属于",
    "本作品在全世界都屬於",
    "Public domain",
]

# Hygiene defaults
BRACKET_PAIRS_DEFAULT: List[Tuple[str, str]] = [
    ("「", "」"),
    ("『", "』"),
    ("【", "】"),
    ("〔", "〕"),
    ("（", "）"),
]
COMMAS_DEFAULT: List[str] = ["，", "、", "､", "﹐", "﹑"]

HEADER_LINE_RE = re.compile(r"^#\s*([A-Z0-9_]+)\s*:\s*(.*)\s*$")

_session = requests.Session()


# -----------------------------
# Header parsing / rebuilding
# -----------------------------

def build_header(meta: Dict[str, str]) -> str:
    """
    For X in meta.items():
      emit '# KEY: value' lines
    """
    lines: List[str] = []
    for k, v in meta.items():
        if v is None:
            continue
        vv = str(v).strip()
        if vv == "":
            continue
        lines.append(f"# {k}: {vv}")
    return "\n".join(lines) + "\n\n"


def parse_header(text: str) -> Tuple[Dict[str, str], str]:
    """
    Split into (header_dict, body_text).
    Header = consecutive '# KEY: value' lines from start until first blank line.
    """
    lines = text.splitlines()
    meta: Dict[str, str] = {}
    body_start = 0

    for i, ln in enumerate(lines):
        if ln.strip() == "":
            body_start = i + 1
            break
        m = HEADER_LINE_RE.match(ln)
        if not m:
            body_start = i
            break
        meta[m.group(1)] = m.group(2)

    body = "\n".join(lines[body_start:]) if body_start < len(lines) else ""
    return meta, body


def rebuild_file(meta: Dict[str, str], body: str) -> str:
    return build_header(meta) + body.lstrip("\n")


# -----------------------------
# Hygiene primitives
# -----------------------------

def cut_public_domain(text: str) -> str:
    cut_idx = len(text)
    for marker in PD_MARKERS:
        idx = text.find(marker)
        if idx != -1 and idx < cut_idx:
            cut_idx = idx
    return text[:cut_idx] if cut_idx != len(text) else text


def reduce_leading_blank_lines(text: str, max_blanks: int = 2) -> str:
    lines = text.splitlines(True)
    i = 0
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    return "".join(lines[: min(i, max_blanks)] + lines[i:])


def fix_newline_before_commas(text: str, comma_chars: List[str]) -> str:
    """
    Patterns:
      For token in TOKENS:
        replace [spaces] + newline + [spaces] + token -> token
    Done in one regex for all comma tokens.
    """
    cc = "".join(re.escape(ch) for ch in comma_chars)
    return re.sub(rf"[ \t]*\r?\n[ \t]*([{cc}])", r"\1", text)


def fix_brackets_strong(text: str, open_ch: str, close_ch: str) -> str:
    """
    Strong bracket fix:
      open + (anything, non-greedy) + close  -> remove ALL whitespace/newlines inside
    This handles:
      《\n甲\n》 -> 《甲》
      〈  \n 甲 〉 -> 〈甲〉
    """
    o = re.escape(open_ch)
    c = re.escape(close_ch)
    pattern = re.compile(rf"{o}([\s\S]*?){c}")

    def repl(m: re.Match) -> str:
        inner = re.sub(r"[ \t\r\n]+", "", m.group(1))
        return f"{open_ch}{inner}{close_ch}"

    text = pattern.sub(repl, text)
    # Also remove newline immediately after close bracket
    text = re.sub(rf"{c}[ \t]*\r?\n[ \t]*", close_ch, text)
    return text


def yoink_dangling_opening_bracket(text: str, opening_set: set[str]) -> str:
    """
    Target the very common pattern:
        ...《\n甲\n》...
    by removing the newline before the opening bracket when it is stranded on its own line.
    """
    lines = text.splitlines(True)
    out: List[str] = []
    for ln in lines:
        s = ln.strip()
        if s in opening_set and out:
            # If previous output line is nonblank, glue bracket onto it.
            if out[-1].strip() != "":
                out[-1] = re.sub(r"\r?\n$", "", out[-1])
                out.append(s + "\n")
                continue
        out.append(ln)
    return "".join(out)


def clamp_internal_blank_lines(text: str, max_blanks: int = 2) -> str:
    """
    Keep at most max_blanks consecutive blank lines anywhere.
    """
    out: List[str] = []
    blanks = 0
    for ln in text.splitlines():
        if ln.strip() == "":
            blanks += 1
            if blanks <= max_blanks:
                out.append("")
        else:
            blanks = 0
            out.append(ln.rstrip())
    return "\n".join(out).strip() + "\n"


def hygiene_normalize(
    body: str,
    *,
    bracket_pairs: List[Tuple[str, str]] = BRACKET_PAIRS_DEFAULT,
    comma_chars: List[str] = COMMAS_DEFAULT,
    cut_pd: bool = False,
) -> str:
    """
    Apply the focused hygiene pass to BODY only.
    """
    text = reduce_leading_blank_lines(body, max_blanks=2)
    opening_set = {o for o, _ in bracket_pairs}
    text = yoink_dangling_opening_bracket(text, opening_set)

    for o, c in bracket_pairs:
        text = fix_brackets_strong(text, o, c)

    text = fix_newline_before_commas(text, comma_chars)

    if cut_pd:
        text = cut_public_domain(text)

    return clamp_internal_blank_lines(text, max_blanks=2)


# -----------------------------
# CATEGORY -> NATION rearrangement
# -----------------------------

def infer_nation_from_path(file_path: Path, corpus_root: Path) -> Optional[str]:
    """
    Path heuristic:
      1) .../countries/<NATION>/... or .../nations/<NATION>/...
      2) .../(raw|clean)/<NATION>/...
    """
    try:
        rel = file_path.relative_to(corpus_root)
        parts = list(rel.parts)
    except Exception:
        parts = list(file_path.parts)

    for marker in ("countries", "country", "nations", "nation"):
        if marker in parts:
            idx = parts.index(marker)
            if idx + 1 < len(parts):
                return parts[idx + 1]

    for marker in ("raw", "clean"):
        if marker in parts:
            idx = parts.index(marker)
            if idx + 1 < len(parts):
                return parts[idx + 1]

    return None


def move_category_to_nation_if_matches(meta: Dict[str, str], nation_candidate: Optional[str]) -> bool:
    """
    If '# CATEGORY' exactly equals the inferred nation, move it to '# NATION' and delete '# CATEGORY'.
    Returns True if meta changed.
    """
    cat = (meta.get("CATEGORY") or "").strip()
    if not cat:
        return False

    # If already has NATION and CATEGORY duplicates it, delete CATEGORY
    nat = (meta.get("NATION") or "").strip()
    if nat and cat == nat:
        meta.pop("CATEGORY", None)
        return True

    if nation_candidate and cat == nation_candidate:
        meta["NATION"] = nation_candidate
        meta.pop("CATEGORY", None)
        return True

    return False


# -----------------------------
# Wikisource category enrichment
# -----------------------------

def safe_request(params: Dict[str, Any], *, sleep: float = 0.5, max_retries: int = 3) -> Dict[str, Any]:
    params = dict(params)
    params.setdefault("format", "json")
    for attempt in range(1, max_retries + 1):
        try:
            time.sleep(sleep)
            r = _session.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=30)
            r.raise_for_status()
            data = r.json()
            if "error" in data:
                print(f"    !! API error: {data['error']}", file=sys.stderr)
                if attempt == max_retries:
                    return {}
                continue
            return data
        except Exception as e:
            print(f"    !! Request error (attempt {attempt}/{max_retries}): {e}", file=sys.stderr)
            if attempt == max_retries:
                return {}
    return {}


def fetch_categories(page_title: str, *, sleep: float) -> List[str]:
    data = safe_request(
        {
            "action": "query",
            "prop": "categories",
            "titles": page_title,
            "cllimit": "max",
            "clshow": "!hidden",
            "formatversion": "2",
        },
        sleep=sleep,
    )
    pages = (data.get("query") or {}).get("pages") or []
    if not pages:
        return []
    cats = pages[0].get("categories") or []
    out: List[str] = []
    for c in cats:
        t = c.get("title", "")
        if t.startswith("Category:"):
            t = t.split(":", 1)[1]
        if t:
            out.append(t)
    return sorted(set(out))


# -----------------------------
# Corpus walkers
# -----------------------------

def iter_txt_files(root: Path) -> List[Path]:
    return list(root.rglob("*.txt"))


def cmd_hygiene(corpus_root: str, *, cut_pd: bool) -> None:
    root = Path(corpus_root).expanduser().resolve()
    if not root.exists():
        raise SystemExit(f"Corpus root does not exist: {root}")

    files = iter_txt_files(root)
    print(f"Found {len(files)} .txt files under {root}")

    updated = 0
    for p in files:
        try:
            text = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = p.read_text(encoding="utf-8", errors="replace")

        meta, body = parse_header(text)
        new_body = hygiene_normalize(body, cut_pd=cut_pd)
        new_text = rebuild_file(meta, new_body)

        if new_text != text:
            p.write_text(new_text, encoding="utf-8")
            updated += 1

    print(f"Done. Updated {updated} files.")


def cmd_rearrange(corpus_root: str) -> None:
    root = Path(corpus_root).expanduser().resolve()
    if not root.exists():
        raise SystemExit(f"Corpus root does not exist: {root}")

    files = iter_txt_files(root)
    print(f"Found {len(files)} .txt files under {root}")

    moved = 0
    updated = 0
    for p in files:
        try:
            text = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = p.read_text(encoding="utf-8", errors="replace")

        meta, body = parse_header(text)
        nation = infer_nation_from_path(p, root)
        changed_meta = move_category_to_nation_if_matches(meta, nation)

        if changed_meta:
            moved += 1

        new_text = rebuild_file(meta, body)
        if new_text != text:
            p.write_text(new_text, encoding="utf-8")
            updated += 1

    print(f"Done. Updated {updated} files.")
    print(f"Moved CATEGORY→NATION in {moved} files.")


def cmd_enrich_ws_categories(corpus_root: str, *, sleep: float) -> None:
    root = Path(corpus_root).expanduser().resolve()
    if not root.exists():
        raise SystemExit(f"Corpus root does not exist: {root}")

    files = iter_txt_files(root)
    print(f"Found {len(files)} .txt files under {root}")

    updated = 0
    skipped = 0
    for p in files:
        try:
            text = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = p.read_text(encoding="utf-8", errors="replace")

        meta, body = parse_header(text)
        page_title = (meta.get("PAGE_TITLE") or "").strip()
        if not page_title:
            skipped += 1
            continue

        cats = fetch_categories(page_title, sleep=sleep)
        meta["WS_CATEGORIES"] = ";".join(cats)

        new_text = rebuild_file(meta, body)
        if new_text != text:
            p.write_text(new_text, encoding="utf-8")
            updated += 1

    print(f"Done. Updated {updated} files. Skipped {skipped} (no PAGE_TITLE).")


# -----------------------------
# CLI
# -----------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="Standalone corpus hygiene + metadata maintenance.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    ap_h = sub.add_parser("hygiene", help="Run focused punctuation/bracket hygiene on BODY (headers preserved).")
    ap_h.add_argument("corpus_root")
    ap_h.add_argument("--cut-pd", action="store_true", help="Cut public-domain boilerplate markers in body text")

    ap_r = sub.add_parser("rearrange", help="Move CATEGORY→NATION when path indicates a nation folder.")
    ap_r.add_argument("corpus_root")

    ap_c = sub.add_parser("enrich-ws-categories", help="Refresh # WS_CATEGORIES using # PAGE_TITLE via zh.wikisource API.")
    ap_c.add_argument("corpus_root")
    ap_c.add_argument("--sleep", type=float, default=0.5, help="Seconds between API requests")

    args = ap.parse_args()

    if args.cmd == "hygiene":
        cmd_hygiene(args.corpus_root, cut_pd=bool(args.cut_pd))
        return

    if args.cmd == "rearrange":
        cmd_rearrange(args.corpus_root)
        return

    if args.cmd == "enrich-ws-categories":
        cmd_enrich_ws_categories(args.corpus_root, sleep=float(args.sleep))
        return


if __name__ == "__main__":
    main()
