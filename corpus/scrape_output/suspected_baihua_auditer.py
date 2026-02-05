#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
suspected_baihua_auditer.py

Audit + reorganize old suspected_baihua scrapes, *and* repair existing damage.

Fixes included (per your report):
- Wikisource {{header}} parsing no longer swallows "|section=|times=..."
- Normalizes TIMES: 民國 -> 中華民國
- Repairs damaged bracket linebreaks in BODY:
    《\n晉書\n》 -> 《晉書》
    〈\n莫孔切。\n〉 -> 〈莫孔切。〉
  (and similarly for any content inside 《》 and 〈〉)
- Optional public-domain banner cutter (enabled by default; safe even if not present)

Core tasks:
- Verify 中華民國/清朝 periodization by YEAR (when we can find YYYY年)
- Arrange into Nation/{clean,raw} and Nation-baihua/{clean,raw}
  (No metadata field is added for suspected_baihua; classification is by moving.)
- Remove empty dirs and empty files.
- Enrich WS_CATEGORIES (via PAGE_TITLE), and fill AUTHOR/TIMES if missing (from {{header}}).
- Produce a results CSV.

Folder normalization target:
  <root>/<Period>/<Nation>/<clean|raw>/...
  <root>/<Period>/<Nation>-baihua/<clean|raw>/...

Period buckets used (as you specified you have these):
  元朝, 明朝, 清朝, 中華民國
If year is missing and we can't infer from path, uses 未知時代.

Dependencies:
  pip install requests

Examples:
  python suspected_baihua_auditer.py ./old_scrapes --sleep 0.2

Recommended (uses scorer output):
  python suspected_baihua_auditer.py ./old_scrapes \
    --index-csv ./wenyan_index.csv \
    --index-key PAGE_TITLE \
    --index-flag suspected_baihua \
    --sleep 0.2
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import requests

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"
HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusScraper/1.3 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

HEADER_LINE_RE = re.compile(r"^#\s*([A-Z0-9_]+)\s*:\s*(.*)\s*$")

YEAR_TOKEN_RE = re.compile(r"^(?P<y>\d{4})年$")
YEAR_ANYWHERE_RE = re.compile(r"(?P<y>\d{4})年")

PERIODS = ("元朝", "明朝", "清朝", "中華民國")
LAYER_NAMES = ("clean", "raw")

# Public-domain cutoff markers (safe even if absent)
PD_MARKERS = [
    "本作品在全世界都属于",
    "本作品在全世界都屬於",
    "此作品在全世界都属于",
    "此作品在全世界都屬於",
    "Public domain",
]

_session = requests.Session()


# -----------------------------
# Header parsing / rebuilding
# -----------------------------

def parse_header(text: str) -> Tuple[Dict[str, str], str]:
    """
    Header = consecutive '# KEY: value' lines from the start until:
      - blank line, or
      - first non-matching line
    Returns (meta_dict, body_text).
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


def build_header(meta: Dict[str, str]) -> str:
    """
    For key,value in meta.items():
      emit '# KEY: value'
    """
    out: List[str] = []
    for k, v in meta.items():
        if v is None:
            continue
        vv = str(v).strip()
        if vv == "":
            continue
        out.append(f"# {k}: {vv}")
    return "\n".join(out) + "\n\n"


def rebuild_file(meta: Dict[str, str], body: str) -> str:
    return build_header(meta) + body.lstrip("\n")


# -----------------------------
# Header value cleanup
# -----------------------------

def clean_header_value(v: str) -> str:
    """
    If header value accidentally contains template tail:
      '魯迅|section=|times=民國|...' -> '魯迅'
    """
    v = (v or "").strip()
    if "|" in v:
        v = v.split("|", 1)[0].strip()
    return v


def normalize_times(v: str) -> str:
    """
    Your rule:
      民國 => 中華民國
    """
    v = clean_header_value(v)
    if v == "民國":
        return "中華民國"
    return v


def normalize_author(v: str) -> str:
    return clean_header_value(v)


def normalize_existing_header_fields(meta: Dict[str, str]) -> None:
    """
    Repair damage already written into files.
    """
    if "AUTHOR" in meta:
        meta["AUTHOR"] = normalize_author(meta.get("AUTHOR") or "")
    if "TIMES" in meta:
        meta["TIMES"] = normalize_times(meta.get("TIMES") or "")


# -----------------------------
# BODY damage repair (《》/〈〉 + PD banners)
# -----------------------------

def cut_public_domain(text: str) -> str:
    """
    Cut from earliest PD marker if present.
    """
    if not text:
        return text
    cut_idx = len(text)
    for marker in PD_MARKERS:
        idx = text.find(marker)
        if idx != -1 and idx < cut_idx:
            cut_idx = idx
    return text[:cut_idx] if cut_idx != len(text) else text


def fix_brackets_strong(text: str, open_br: str, close_br: str) -> str:
    """
    Strong bracket fix:
      open + (anything) + close  -> remove all whitespace/newlines inside
    Handles:
      《\n晉書\n》 -> 《晉書》
      〈  \n 莫孔切。\n 〉 -> 〈莫孔切。〉
    """
    if not text:
        return text
    pattern = re.compile(re.escape(open_br) + r"([\s\S]*?)" + re.escape(close_br), re.DOTALL)

    def repl(m: re.Match) -> str:
        inner = re.sub(r"[ \t\r\n]+", "", m.group(1))
        return f"{open_br}{inner}{close_br}"

    return pattern.sub(repl, text)


def apply_damage_repairs(body: str, *, cut_pd: bool = True) -> str:
    """
    Apply all body repairs that address existing scraped damage.
    """
    out = body

    # Repair known broken bracket constructs
    out = fix_brackets_strong(out, "《", "》")
    out = fix_brackets_strong(out, "〈", "〉")

    # PD safety net (cheap & safe)
    if cut_pd:
        out = cut_public_domain(out)

    # Ensure trailing newline
    out = out.rstrip() + "\n"
    return out


# -----------------------------
# Wikisource API
# -----------------------------

def safe_request(params: Dict[str, Any], *, sleep: float, retries: int = 3) -> Dict[str, Any]:
    params = dict(params)
    params.setdefault("format", "json")
    for attempt in range(1, retries + 1):
        try:
            if sleep:
                time.sleep(sleep)
            r = _session.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=30)
            r.raise_for_status()
            data = r.json()
            if "error" in data:
                if attempt == retries:
                    return {}
                continue
            return data
        except Exception:
            if attempt == retries:
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


def fetch_wikitext(page_title: str, *, sleep: float) -> str:
    """
    Fetch raw wikitext so we can parse {{header ...}} fields.
    """
    data = safe_request(
        {
            "action": "query",
            "prop": "revisions",
            "titles": page_title,
            "rvprop": "content",
            "rvslots": "main",
            "formatversion": "2",
        },
        sleep=sleep,
    )
    pages = (data.get("query") or {}).get("pages") or []
    if not pages:
        return ""
    revs = pages[0].get("revisions") or []
    if not revs:
        return ""
    slots = revs[0].get("slots") or {}
    main = slots.get("main") or {}
    return main.get("content") or ""


def parse_header_template_fields(wikitext: str) -> Dict[str, str]:
    """
    Pragmatic parser for:
      {{header
       | author = ...
       | times  = ...
      }}

    Key rule: stop at the next '|field=' rather than swallowing '|section=...'.
    """
    m = re.search(r"\{\{\s*header\b([\s\S]*?)\}\}", wikitext, flags=re.IGNORECASE)
    if not m:
        return {}

    block = m.group(1)

    def get_field(name: str) -> str:
        # Grab everything after '| name =', lazily, until the NEXT '| something ='
        rx = re.compile(
            rf"\|\s*{re.escape(name)}\s*=\s*(.*?)(?=\n\s*\|\s*\w+\s*=|\Z)",
            flags=re.IGNORECASE | re.DOTALL,
        )
        mm = rx.search(block)
        if not mm:
            return ""
        val = mm.group(1).strip()

        # Light cleanup of common wiki markup
        val = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", val)
        val = re.sub(r"\[\[([^\]]+)\]\]", r"\1", val)
        val = re.sub(r"<[^>]+>", "", val)
        return val.strip()

    out: Dict[str, str] = {}
    a = get_field("author")
    t = get_field("times")

    if a:
        out["author"] = a
    if t:
        out["times"] = t
    return out


# -----------------------------
# Year / period logic
# -----------------------------

def extract_year_from_categories(cats: List[str]) -> Optional[int]:
    """
    Find tokens like '1905年' in categories; choose earliest year if multiple.
    """
    years: List[int] = []
    for c in cats:
        mm = YEAR_TOKEN_RE.fullmatch(c.strip())
        if mm:
            years.append(int(mm.group("y")))
    return min(years) if years else None


def extract_year_from_times(times_val: str) -> Optional[int]:
    m = YEAR_ANYWHERE_RE.search(times_val or "")
    return int(m.group("y")) if m else None


def year_to_period(year: int) -> str:
    """
    Heuristic bucketizer for the four periods you said are present.
    """
    if year <= 1367:
        return "元朝"
    if 1368 <= year <= 1643:
        return "明朝"
    if 1644 <= year <= 1911:
        return "清朝"
    return "中華民國"  # year >= 1912


def infer_period_from_path(p: Path) -> Optional[str]:
    for per in PERIODS:
        if per in p.parts:
            return per
    return None


def infer_layer_from_path(p: Path) -> Optional[str]:
    for layer in LAYER_NAMES:
        if layer in p.parts:
            return layer
    return None


def infer_nation_from_path(p: Path) -> Optional[str]:
    """
    Heuristic:
      - .../(clean|raw)/<Nation>/... -> Nation is next segment
      - .../<Nation>/(clean|raw)/... -> Nation is previous segment
    """
    parts = list(p.parts)
    for layer in LAYER_NAMES:
        if layer in parts:
            i = parts.index(layer)
            if i + 1 < len(parts):
                return parts[i + 1]
    for layer in LAYER_NAMES:
        if layer in parts:
            i = parts.index(layer)
            if i - 1 >= 0:
                return parts[i - 1]
    return None


def remove_year_token_from_ws(meta: Dict[str, str], year: int) -> None:
    ws = (meta.get("WS_CATEGORIES") or "").strip()
    if not ws:
        return
    parts = [p.strip() for p in ws.split(";") if p.strip()]
    parts = [p for p in parts if p != f"{year}年"]
    meta["WS_CATEGORIES"] = ";".join(parts)


# -----------------------------
# Index CSV lookup (recommended)
# -----------------------------

@dataclass
class IndexLookup:
    key_col: str
    flag_col: str
    mapping: Dict[str, bool]

    @staticmethod
    def from_csv(path: Path, key_col: str, flag_col: str) -> "IndexLookup":
        mapping: Dict[str, bool] = {}
        with path.open("r", encoding="utf-8", newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                k = (row.get(key_col) or "").strip()
                if not k:
                    continue
                v_raw = (row.get(flag_col) or "").strip().lower()
                v = v_raw in ("1", "true", "yes", "y", "t")
                mapping[k] = v
        return IndexLookup(key_col=key_col, flag_col=flag_col, mapping=mapping)

    def is_baihua(self, key: str) -> Optional[bool]:
        return self.mapping.get(key)


# -----------------------------
# Enrichment + classification
# -----------------------------

def enrich_meta_from_ws(meta: Dict[str, str], *, sleep: float) -> Tuple[List[str], Dict[str, str], str]:
    """
    Returns (categories_list, parsed_header_fields, status_string)
    """
    title = (meta.get("PAGE_TITLE") or "").strip()
    if not title:
        return [], {}, "no_page_title"

    cats = fetch_categories(title, sleep=sleep)
    if cats:
        meta["WS_CATEGORIES"] = ";".join(cats)

    wikitext = fetch_wikitext(title, sleep=sleep)
    header_fields = parse_header_template_fields(wikitext) if wikitext else {}

    # Fill AUTHOR/TIMES if missing (do not stomp non-empty)
    if header_fields.get("author") and not (meta.get("AUTHOR") or "").strip():
        meta["AUTHOR"] = normalize_author(header_fields["author"])

    if header_fields.get("times") and not (meta.get("TIMES") or "").strip():
        meta["TIMES"] = normalize_times(header_fields["times"])

    # Always normalize after touching it
    normalize_existing_header_fields(meta)

    return cats, header_fields, "ok"


def decide_baihua(meta: Dict[str, str], src_path: Path, index: Optional[IndexLookup]) -> Tuple[bool, str]:
    """
    Priority:
    1) Index CSV match (recommended)
    2) If path already contains 'suspected_baihua', preserve it as True
    3) Else default False (conservative)
    """
    if index is not None:
        key = (meta.get("PAGE_TITLE") or "").strip()
        if key:
            v = index.is_baihua(key)
            if v is not None:
                return v, "index_csv"

    if "suspected_baihua" in src_path.parts:
        return True, "path_preserve"

    return False, "default_false"


# -----------------------------
# Cleanup utilities
# -----------------------------

def is_empty_text_file(p: Path) -> bool:
    try:
        if p.stat().st_size == 0:
            return True
        txt = p.read_text(encoding="utf-8", errors="ignore")
        return txt.strip() == ""
    except Exception:
        return False


def remove_empty_dirs(root: Path) -> None:
    for dirpath, _dirnames, _filenames in os.walk(root, topdown=False):
        dp = Path(dirpath)
        try:
            next(dp.iterdir())
        except StopIteration:
            try:
                dp.rmdir()
            except OSError:
                pass


# -----------------------------
# Move + rewrite
# -----------------------------

def normalize_and_move_file(
    *,
    root: Path,
    src: Path,
    meta: Dict[str, str],
    body: str,
    cats: List[str],
    baihua: bool,
    nation: str,
    layer: str,
    period: str,
    cut_pd: bool,
) -> Tuple[Path, Optional[int]]:
    """
    Repair meta/body, write file, then move into normalized layout:
      root/period/(nation or nation-baihua)/layer/<tail>
    """
    # Repair body damage (brackets + PD)
    body2 = apply_damage_repairs(body, cut_pd=cut_pd)

    # Year extraction: categories first, then TIMES
    year = extract_year_from_categories(cats)
    if year is None:
        year = extract_year_from_times((meta.get("TIMES") or "").strip())

    # If year exists, TIMES becomes YYYY年, and YYYY年 is removed from WS_CATEGORIES
    if year is not None:
        meta["TIMES"] = f"{year}年"
        remove_year_token_from_ws(meta, year)

    # Normalize AUTHOR/TIMES again (cheap insurance)
    normalize_existing_header_fields(meta)

    # Rebuild file in place
    new_text = rebuild_file(meta, body2)
    src.write_text(new_text, encoding="utf-8")

    # Destination
    nation_folder = f"{nation}-baihua" if baihua else nation
    dest_base = root / period / nation_folder / layer
    dest_base.mkdir(parents=True, exist_ok=True)

    # Preserve relative structure *after* nation segment if present; else use filename
    rel_tail: Path
    parts = list(src.parts)
    if nation in parts:
        i = parts.index(nation)
        tail_parts = parts[i + 1 :]
        rel_tail = Path(*tail_parts) if tail_parts else Path(src.name)
    else:
        rel_tail = Path(src.name)

    dest = dest_base / rel_tail
    dest.parent.mkdir(parents=True, exist_ok=True)

    # Overwrite collisions deterministically
    if dest.exists() and dest.is_file():
        dest.unlink()

    shutil.move(str(src), str(dest))
    return dest, year


# -----------------------------
# CLI entrypoint
# -----------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="Audit + reorganize old suspected_baihua scrapes (with damage repair).")
    ap.add_argument("root", help="Corpus root folder containing old scrapes")
    ap.add_argument("--sleep", type=float, default=0.3, help="Seconds between Wikisource API requests")
    ap.add_argument("--index-csv", type=str, default="", help="Optional scorer CSV to decide suspected_baihua")
    ap.add_argument("--index-key", type=str, default="PAGE_TITLE", help="Column name used to match (join key)")
    ap.add_argument("--index-flag", type=str, default="suspected_baihua", help="Boolean column for suspected_baihua")
    ap.add_argument("--results-csv", type=str, default="baihua_audit_results.csv", help="Output CSV name")
    ap.add_argument("--no-cut-pd", action="store_true", help="Disable public-domain banner cutting")
    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()
    if not root.exists():
        raise SystemExit(f"Root not found: {root}")

    index: Optional[IndexLookup] = None
    if args.index_csv.strip():
        idx_path = Path(args.index_csv).expanduser().resolve()
        if not idx_path.exists():
            raise SystemExit(f"Index CSV not found: {idx_path}")
        index = IndexLookup.from_csv(idx_path, args.index_key, args.index_flag)

    cut_pd = not bool(args.no_cut_pd)

    txt_files = list(root.rglob("*.txt"))

    results: List[Dict[str, str]] = []
    removed_empty_files = 0
    processed = 0
    moved = 0
    ws_skipped = 0

    for src in sorted(txt_files):
        # Remove empty files
        if is_empty_text_file(src):
            try:
                src.unlink()
                removed_empty_files += 1
            except Exception:
                pass
            continue

        # Read file
        try:
            text = src.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = src.read_text(encoding="utf-8", errors="replace")

        meta, body = parse_header(text)

        # Repair existing broken header fields (very important before anything else)
        normalize_existing_header_fields(meta)

        # Infer nation + layer from path
        nation = infer_nation_from_path(src) or "未知國別"
        layer = infer_layer_from_path(src) or "raw"

        # Enrich from Wikisource (categories + header template author/times)
        cats: List[str] = []
        header_fields: Dict[str, str] = {}
        ws_status = "skipped"
        if (meta.get("PAGE_TITLE") or "").strip():
            cats, header_fields, ws_status = enrich_meta_from_ws(meta, sleep=float(args.sleep))
        else:
            ws_skipped += 1

        # Decide baihua
        baihua, baihua_reason = decide_baihua(meta, src, index)

        # Determine year and therefore period
        year = extract_year_from_categories(cats)
        if year is None:
            year = extract_year_from_times((meta.get("TIMES") or "").strip())

        period_from_year = year_to_period(year) if year is not None else None
        period_from_path = infer_period_from_path(src)
        period = period_from_year or period_from_path or "未知時代"

        # Move/normalize (also repairs body)
        dest, year_used = normalize_and_move_file(
            root=root,
            src=src,
            meta=meta,
            body=body,
            cats=cats,
            baihua=baihua,
            nation=nation,
            layer=layer,
            period=period,
            cut_pd=cut_pd,
        )

        processed += 1
        moved += 1

        results.append(
            {
                "src": str(src),
                "dest": str(dest),
                "nation": nation,
                "layer": layer,
                "period": period,
                "baihua": "1" if baihua else "0",
                "baihua_reason": baihua_reason,
                "ws_status": ws_status,
                "page_title": (meta.get("PAGE_TITLE") or "").strip(),
                "author": (meta.get("AUTHOR") or "").strip(),
                "times": (meta.get("TIMES") or "").strip(),
                "year": str(year_used) if year_used is not None else "",
                "ws_categories": (meta.get("WS_CATEGORIES") or "").strip(),
            }
        )

    # Cleanup empty directories
    remove_empty_dirs(root)

    # Write results CSV
    out_csv = root / args.results_csv
    with out_csv.open("w", encoding="utf-8", newline="") as f:
        fieldnames = [
            "src",
            "dest",
            "nation",
            "layer",
            "period",
            "baihua",
            "baihua_reason",
            "ws_status",
            "page_title",
            "author",
            "times",
            "year",
            "ws_categories",
        ]
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in results:
            w.writerow(r)

    print(f"[done] processed={processed} moved={moved} removed_empty_files={removed_empty_files} ws_skipped={ws_skipped}")
    print(f"[done] results csv -> {out_csv}")


if __name__ == "__main__":
    main()
