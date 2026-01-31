#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
taiping_yulan_scraper.py

Scrape zh.wikisource 太平御覽 main page, discover subpages robustly, and save each
subpage as a separate .txt file with the exact metadata header you requested.

Dependencies:
  pip install requests beautifulsoup4

Usage patterns (cookie-cutter):
  # Basic run
  python taiping_yulan_scraper.py --out ./scrape_output/太平御覽

  # Slow down requests (be polite)
  python taiping_yulan_scraper.py --out ./scrape_output/太平御覽 --sleep 0.8

  # Test mode: only first N pages
  python taiping_yulan_scraper.py --out ./scrape_output/太平御覽 --limit 20

What the main flags do (applies elsewhere):
  --out     : where to create raw/ and clean/ folders
  --sleep   : seconds to wait between HTTP requests (rate limiting)
  --limit   : cap number of pages (quick test)
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import quote

import requests
from bs4 import BeautifulSoup

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusScraper/1.0 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul)"
    )
}

WORK_TITLE = "太平御覽"
AUTHOR = "李昉"
NATION = "北宋"
TIMES = "984年"
EXTRA_CATEGORY = "宋四大書"

# If you ever generalise this scraper:
# Pattern for "subpages of this work"
SUBPAGE_PREFIX = WORK_TITLE + "/"

# Conservative cleanup: remove PD boilerplate often injected by Wikisource skins
PD_MARKERS = [
    "本作品在全世界都属于",
    "本作品在全世界都屬於",
    "本作品在美国属于",
    "本作品在美國屬於",
    "Public domain Public domain false false",
    "Public domain",
]

_session = requests.Session()


# Bracket pairs that frequently get linebroken by HTML -> text extraction
BRACKET_PAIRS_STRONG = [
    ("《", "》"),
    ("〈", "〉"),
]

def fix_brackets_strong(text: str, open_br: str, close_br: str) -> str:
    """
    Join bracketed spans back into a single inline token by removing all
    whitespace inside the brackets.

    Example:
      《\n三五曆記\n》 -> 《三五曆記》
      〈\n莫孔切。\n〉 -> 〈莫孔切。〉
    """
    if not text:
        return text
    # Non-greedy capture of anything between open/close, including newlines
    pattern = re.compile(re.escape(open_br) + r"(.*?)" + re.escape(close_br), re.DOTALL)

    def repl(m: re.Match) -> str:
        inner = m.group(1)
        inner = re.sub(r"[ \t\r\n]+", "", inner)  # kill newlines + spaces inside
        return f"{open_br}{inner}{close_br}"

    return pattern.sub(repl, text)

def apply_strong_bracket_fixes(text: str) -> str:
    """Apply fix_brackets_strong for all bracket pairs we care about."""
    for o, c in BRACKET_PAIRS_STRONG:
        text = fix_brackets_strong(text, o, c)
    return text


def safe_request(params: Dict[str, Any], *, sleep: float, max_retries: int = 4) -> Dict[str, Any]:
    """GET the MediaWiki API with retries. Common pattern you can reuse anywhere."""
    params = dict(params)
    params.setdefault("format", "json")

    last_err: Optional[Exception] = None
    for attempt in range(1, max_retries + 1):
        try:
            time.sleep(sleep)
            r = _session.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=45)
            r.raise_for_status()
            data = r.json()
            if "error" in data:
                raise RuntimeError(str(data["error"]))
            return data
        except Exception as e:
            last_err = e
            print(f"[warn] request failed attempt {attempt}/{max_retries}: {e}", file=sys.stderr)
            # Tiny backoff (pattern: increase wait with attempts)
            time.sleep(min(2.0, 0.3 * attempt))
    print(f"[error] giving up after {max_retries} retries: {last_err}", file=sys.stderr)
    return {}


def fetch_html(title: str, *, sleep: float) -> str:
    """Fetch rendered HTML for a page title."""
    data = safe_request(
        {"action": "parse", "page": title, "prop": "text", "formatversion": "2"},
        sleep=sleep,
    )
    parse = data.get("parse") or {}
    html = parse.get("text") or ""
    if isinstance(html, dict):
        html = html.get("*", "")
    return html or ""


def fetch_categories(title: str, *, sleep: float) -> List[str]:
    """
    Get non-hidden categories for a page.
    Reusable pattern: action=query + prop=categories + clshow=!hidden.
    """
    data = safe_request(
        {
            "action": "query",
            "prop": "categories",
            "titles": title,
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

    # Add the required super-category, de-dup
    out.append(EXTRA_CATEGORY)
    return sorted(set(out))


def cut_public_domain(text: str) -> str:
    """Cut at the earliest PD marker (keeps your corpus cleaner)."""
    cut_idx = len(text)
    for marker in PD_MARKERS:
        idx = text.find(marker)
        if idx != -1 and idx < cut_idx:
            cut_idx = idx
    return text[:cut_idx] if cut_idx != len(text) else text


def extract_visible_text_from_html(html: str) -> str:
    """
    Convert MediaWiki HTML to plain text and drop common junk.
    This is the same basic “parse -> soup -> get_text” pattern you already use.
    """
    if not html:
        return ""
    soup = BeautifulSoup(html, "html.parser")

    # Remove edit links, navboxes, toc, tables, scripts/styles
    for selector in [
        ".mw-editsection",
        ".mw-navigation",
        ".navbox",
        ".toc",
        "table",
        "style",
        "script",
    ]:
        for elem in soup.select(selector):
            elem.decompose()

    text = soup.get_text("\n")
    text = re.sub(r"\r\n?", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = text.replace("\xa0", " ").strip()
    return text


def clean_text_for_corpus(text: str) -> str:
    """Conservative clean pass: keep content, reduce noise."""
    text = text.replace("\u3000", " ")
    text = cut_public_domain(text).strip()
    # Remove short inline ref markers like [1]
    text = re.sub(r"\[\d+\]", "", text)
    # Collapse too many blank lines
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def safe_filename(name: str) -> str:
    """Windows-safe filename. Reusable anywhere."""
    name = name.strip()
    return re.sub(r'[\\/:*?"<>|]', "_", name)


def page_url(title: str) -> str:
    """
    Build a stable URL. Uses /wiki/<urlencoded title>.
    (You can reuse this for any MediaWiki site.)
    """
    return "https://zh.wikisource.org/wiki/" + quote(title, safe=":/()_-%")


def build_header(meta: Dict[str, str]) -> str:
    """
    Metadata header format exactly like:
      # KEY: value
    """
    lines: List[str] = []
    for k, v in meta.items():
        v2 = (v or "").strip()
        if v2:
            lines.append(f"# {k}: {v2}")
    return "\n".join(lines) + "\n\n"


def discover_subpages_from_main_html(*, sleep: float) -> List[str]:
    """
    Primary discovery:
      - Parse the main 太平御覽 page HTML
      - Collect <a title="太平御覽/..."> in on-page order
      - De-dup while preserving order

    This avoids grabbing random inline links in the long header prose.
    """
    html = fetch_html(WORK_TITLE, sleep=sleep)
    if not html:
        return []

    soup = BeautifulSoup(html, "html.parser")
    body = soup.find("div", class_="mw-parser-output") or soup

    ordered: List[str] = []
    seen: set[str] = set()

    for a in body.select("a[title]"):
        t = a.get("title") or ""
        if not t.startswith(SUBPAGE_PREFIX):
            continue
        if t not in seen:
            ordered.append(t)
            seen.add(t)

    # If we got a real TOC, this will be huge (hundreds+)
    return ordered


def discover_subpages_via_allpages(*, sleep: float) -> List[str]:
    """
    Fallback discovery:
      - MediaWiki generator=allpages with prefix 太平御覽/
      - Sort by numeric suffix if present (0001..1000)
    """
    parts: List[str] = []
    apcontinue: Optional[str] = None

    while True:
        params: Dict[str, Any] = {
            "action": "query",
            "generator": "allpages",
            "gapnamespace": 0,
            "gapprefix": SUBPAGE_PREFIX,
            "gaplimit": "max",
            "formatversion": "2",
        }
        if apcontinue:
            params["gapcontinue"] = apcontinue

        data = safe_request(params, sleep=sleep)
        pages = (data.get("query") or {}).get("pages") or []
        for pg in pages:
            t = pg.get("title", "")
            if t.startswith(SUBPAGE_PREFIX):
                parts.append(t)

        apcontinue = (data.get("continue") or {}).get("gapcontinue")
        if not apcontinue:
            break

    # De-dup then sort (numeric first)
    uniq = sorted(set(parts), key=subpage_sort_key)
    return uniq


def subpage_sort_key(title: str) -> Tuple[int, int, str]:
    """
    Sort key:
      太平御覽/0001, /0002 ... in numeric order
      non-numeric pages (like 目錄卷) come after, deterministically.
    """
    leaf = title.split("/", 1)[-1]
    if re.fullmatch(r"\d{4}", leaf):
        return (0, int(leaf), title)
    return (1, 999999, title)


def choose_subpages(*, sleep: float) -> List[str]:
    """
    Unified strategy:
      1) HTML parse ordered list (best, preserves the curated order: 前言 -> 目錄卷 -> 卷...)
      2) allpages prefix fallback (robust if HTML changed)
    """
    parts = discover_subpages_from_main_html(sleep=sleep)
    # sanity check: for 太平御覽 this should be massive
    if len(parts) >= 50:
        return parts

    parts2 = discover_subpages_via_allpages(sleep=sleep)
    return parts2


@dataclass
class SaveConfig:
    out: Path
    sleep: float
    limit: Optional[int]


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def scrape_page(title: str, *, cfg: SaveConfig, raw_dir: Path, clean_dir: Path) -> None:
    html = fetch_html(title, sleep=cfg.sleep)
    raw_body = extract_visible_text_from_html(html)
    clean_body = clean_text_for_corpus(raw_body)
    clean_body = apply_strong_bracket_fixes(clean_body) # remove annoying bracket stuff

    cats = fetch_categories(title, sleep=cfg.sleep)

    meta = {
        "WORK_TITLE": WORK_TITLE,
        "PAGE_TITLE": title,
        "AUTHOR": AUTHOR,
        "NATION": NATION,
        "TIMES": TIMES,
        "CATEGORIES": ";".join(cats),
        "URL": page_url(title),
    }

    header = build_header(meta)

    leaf = title.split("/", 1)[-1]
    # Nice stable filenames: 0001.txt, 目錄卷.txt, etc.
    fname = safe_filename(leaf) + ".txt"

    write_text(raw_dir / fname, header + raw_body)
    write_text(clean_dir / fname, header + clean_body)


def main() -> None:
    ap = argparse.ArgumentParser(description="Scrape zh.wikisource 太平御覽 into raw/ and clean/ with corpus metadata.")
    ap.add_argument("--out", required=True, help="Output folder (creates raw/太平御覽 and clean/太平御覽 inside it)")
    ap.add_argument("--sleep", type=float, default=0.6, help="Seconds to sleep between requests")
    ap.add_argument("--limit", type=int, default=None, help="Only scrape first N pages (test mode)")
    args = ap.parse_args()

    cfg = SaveConfig(out=Path(args.out).expanduser().resolve(), sleep=float(args.sleep), limit=args.limit)

    raw_dir = cfg.out / "raw" / WORK_TITLE
    clean_dir = cfg.out / "clean" / WORK_TITLE
    raw_dir.mkdir(parents=True, exist_ok=True)
    clean_dir.mkdir(parents=True, exist_ok=True)

    print(f"[info] discovering subpages from: {page_url(WORK_TITLE)}")
    parts = choose_subpages(sleep=cfg.sleep)

    if cfg.limit is not None:
        parts = parts[: cfg.limit]

    print(f"[info] discovered pages: {len(parts)}")
    print(f"[info] raw output:   {raw_dir}")
    print(f"[info] clean output: {clean_dir}")

    # Scrape
    for i, title in enumerate(parts, start=1):
        print(f"[{i}/{len(parts)}] {title}")
        try:
            scrape_page(title, cfg=cfg, raw_dir=raw_dir, clean_dir=clean_dir)
        except Exception as e:
            print(f"[warn] failed {title}: {e}", file=sys.stderr)

    print("[done]")


if __name__ == "__main__":
    main()
