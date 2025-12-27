#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Scraper for Classical Chinese Wikipedia (zh-classical.wikipedia.org).

Features:
- Discovers all pages via MediaWiki API (list=allpages).
- Skips titles containing Latin letters.
- Fetches HTML for each page and strips non-content elements.
- Skips pages whose *main text* still contains Latin letters.
- Requires the page to contain a few "full sentences" (heuristic).
- Outputs RAW (cleaned HTML text, still with Latin) and CLEAN (CJK+punct only).
- Adds metadata header (WORK_TITLE, DISPLAY_TITLE, AUTHOR, TIMES, PAGE_TITLE, CATEGORIES).
- Writes index.csv and index.json summarising pages.

Usage:
    python classical_wiki_scraper.py [--out-dir classical_wiki_corpus] [--max-pages N] [--sleep 0.2]

"""

import argparse
import csv
import json
import os
import re
import time
from typing import Dict, List, Any, Optional

import requests
from bs4 import BeautifulSoup

API_ENDPOINT = "https://zh-classical.wikipedia.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "ClassicalWikiCorpusScraper/0.1 "
        "(contact: chippy2001@live.co.uk; "
        "https://github.com/ShiraTheMogul)"
    )
}

# ---------------------------------------------------------------------------
# CJK ranges and helpers
# ---------------------------------------------------------------------------

CJK_RANGES = [
    (0x3400, 0x4DBF),   # Extension A
    (0x4E00, 0x9FFF),   # CJK Unified Ideographs
    (0x20000, 0x2A6DF), # Extension B
    (0x2A700, 0x2B73F), # Extension C
    (0x2B740, 0x2B81D), # Extension D
    (0x2B820, 0x2CEAD), # Extension E
    (0x2CEB0, 0x2EBE0), # Extension F
    (0x31350, 0x323AF), # Extension H
    (0x2EBF0, 0x2EE5D), # Extension I
    (0x323B0, 0x33479), # Extension J
    (0x2F800, 0x2FA1F), # CJK Compatibility/Supplement
]


def is_cjk_ideograph(ch: str) -> bool:
    """Return True if ch is in one of the CJK ideograph ranges."""
    cp = ord(ch)
    for start, end in CJK_RANGES:
        if start <= cp <= end:
            return True
    return False


LATIN_RE = re.compile(r"[A-Za-z]")


def has_latin(text: str) -> bool:
    return bool(LATIN_RE.search(text))


# ---------------------------------------------------------------------------
# HTML cleaning and text filtering
# ---------------------------------------------------------------------------

def clean_html_to_main_text(html: str) -> str:
    """
    Turn page HTML into a 'main text' string:
      - strip scripts/styles/tables/navboxes/refs/etc
      - normalise whitespace
    """
    soup = BeautifulSoup(html, "html.parser")

    # Remove obvious non-content elements
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()

    selectors = [
        "sup.reference",
        "sup[role='note']",
        "ol.references",
        "div.reflist",
        "div.navbox",
        "table.navbox",
        "table.infobox",
        "div#toc",
        "span.mw-editsection",
        "div#catlinks",
        "div.hatnote",
    ]
    for sel in selectors:
        for t in soup.select(sel):
            t.decompose()

    # Drop all tables outright
    for t in soup.find_all("table"):
        t.decompose()

    # Get text with newlines between block-ish elements
    text = soup.get_text("\n")

    # Basic whitespace normalisation
    text = re.sub(r"\r\n?", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)

    return text.strip()


def filter_to_cjk_and_punct(text: str) -> str:
    """
    Keep only:
      - CJK ideographs (various ranges via is_cjk_ideograph)
      - some punctuation (Chinese + basic ASCII)
      - whitespace + digits (0-9)

    Also:
      - normalises spaces
      - lightly normalises newlines
      - removes "fake" linebreaks between CJK characters
    """
    allowed_punct = "，。、？！：；「」『』（）《》〈〉—…．·,.;:!?'\"-"
    out_chars: List[str] = []

    for ch in text:
        if is_cjk_ideograph(ch):
            out_chars.append(ch)
        elif ch.isdigit():
            out_chars.append(ch)
        elif ch in allowed_punct or ch in "\n\r\t ":
            out_chars.append(ch)
        # else: drop

    s = "".join(out_chars)

    # Normalise newlines and spaces
    s = re.sub(r"\r\n?", "\n", s)
    s = re.sub(r"[ \t]+", " ", s)

    # Only remove newlines between CJK characters: "...字\n字..." -> "...字字..."
    def _join_cjk_newlines(match: re.Match) -> str:
        before = match.group(1)
        after = match.group(2)
        if is_cjk_ideograph(before) and is_cjk_ideograph(after):
            # drop the newline between them
            return before + after
        # keep as-is otherwise
        return before + "\n" + after

    s = re.sub(r"(.)\n(.)", _join_cjk_newlines, s)

    # Collapse 3+ newlines into 2
    s = re.sub(r"\n{3,}", "\n\n", s)

    return s.strip()

def count_cjk_chars(text: str) -> int:
    return sum(1 for ch in text if is_cjk_ideograph(ch))


def count_sentences(text: str) -> int:
    """
    Roughly count sentences by terminal punctuation.
    """
    return len(re.findall(r"[。！？]", text))


# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------

def api_get(params: Dict[str, Any]) -> Dict[str, Any]:
    params = dict(params)
    params["format"] = "json"
    resp = requests.get(API_ENDPOINT, headers=HEADERS, params=params, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    if "error" in data:
        raise RuntimeError(f"API error: {data['error']}")
    return data


def fetch_all_titles(max_pages: Optional[int] = None, sleep: float = 0.2) -> List[str]:
    """
    Use list=allpages to get all page titles.
    """
    titles: List[str] = []
    apcontinue = None

    while True:
        params = {
            "action": "query",
            "list": "allpages",
            "aplimit": "max",
        }
        if apcontinue:
            params["apcontinue"] = apcontinue

        data = api_get(params)
        pages = data.get("query", {}).get("allpages", [])
        for p in pages:
            titles.append(p["title"])
            if max_pages and len(titles) >= max_pages:
                return titles

        cont = data.get("continue", {})
        apcontinue = cont.get("apcontinue")
        if not apcontinue:
            break

        time.sleep(sleep)

    return titles


def parse_page_html_and_categories(title: str) -> (str, List[str]):
    """
    Fetch a page via action=parse and return (HTML, [category titles]).
    """
    params = {
        "action": "parse",
        "page": title,
        "prop": "text|categories",
        "formatversion": "2",
    }
    data = api_get(params)
    parse = data.get("parse", {})
    html = parse.get("text", "")
    categories = parse.get("categories", [])
    cat_titles = []
    for cat in categories:
        # When formatversion=2, categories are dicts with "name"
        name = cat.get("name")
        if name:
            cat_titles.append(name)
    return html, cat_titles


# ---------------------------------------------------------------------------
# File utils
# ---------------------------------------------------------------------------

def make_dirs(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def slugify_filename(title: str) -> str:
    """
    Safe-ish filename from a wiki title. Keep CJK and basic punctuation,
    strip slashes and colons.
    """
    # Replace slashes with underscore, remove colon and question marks etc.
    s = title.replace("/", "_")
    s = s.replace(":", "：")
    s = s.replace("?", "？")
    s = s.replace("*", "＊")
    s = s.replace('"', "”")
    s = s.replace("<", "＜").replace(">", "＞")
    s = s.strip()
    # Avoid empty
    if not s:
        s = "untitled"
    return s


# ---------------------------------------------------------------------------
# Core scraping logic
# ---------------------------------------------------------------------------

def should_skip_title(title: str) -> bool:
    """
    Skip titles containing Latin letters, Special pages, etc.
    """
    # Skip Latin letters in title
    if has_latin(title):
        return True

    # Skip special namespaces like "Wikipedia:", "Template:", etc.
    if ":" in title:
        # But keep main namespace only; everything else dropped
        # zh-classical uses namespace prefixes like "Wikipedia:", "Template:".
        # For a pure article corpus, we only want mainspace (no colon).
        return True

    # Skip extremely short titles (often junk, abbreviations)
    if len(title) < 1:
        return True

    return False


def scrape_classical_wiki(
    out_dir: str,
    max_pages: Optional[int] = None,
    sleep: float = 0.2,
) -> None:
    raw_dir = os.path.join(out_dir, "raw")
    clean_dir = os.path.join(out_dir, "clean")
    make_dirs(raw_dir)
    make_dirs(clean_dir)

    index: List[Dict[str, Any]] = []

    print(f"Starting Classical Chinese Wikipedia scrape.")
    print(f"  Base output: {out_dir}")
    print(f"  RAW dir:     {raw_dir}")
    print(f"  CLEAN dir:   {clean_dir}")
    mode = "TEST" if max_pages else "FULL"
    print(f"  sleep={sleep}s | {mode} mode{f', max_pages={max_pages}' if max_pages else ''}")

    titles = fetch_all_titles(max_pages=max_pages, sleep=sleep)
    print(f"Discovered {len(titles)} titles from allpages.\n")

    for i, title in enumerate(titles, start=1):
        print(f"### [{i}/{len(titles)}] {title} ###")

        if should_skip_title(title):
            print("  >> Skipping title (Latin or non-mainspace):", title)
            continue

        try:
            html, cat_titles = parse_page_html_and_categories(title)
        except Exception as e:
            print(f"  !! Error fetching page {title}: {e}")
            continue

        if not html.strip():
            print(f"  !! Empty HTML for {title}, skipping.")
            continue

        main_text = clean_html_to_main_text(html)

        # Latin guard: if main_text still has Latin letters, skip completely.
        if has_latin(main_text):
            print(f"  >> Page has Latin in main text, skipping: {title}")
            continue

        # RAW text is the cleaned main_text (without refs/navboxes) but with full charset.
        raw_text = main_text.strip()

        # CLEAN text: only CJK + punctuation + digits + whitespace
        clean_text = filter_to_cjk_and_punct(raw_text)

        # Sentence / length heuristics: require some substance
        cjk_count = count_cjk_chars(clean_text)
        sent_count = count_sentences(clean_text)

        # Heuristic thresholds: tweakable
        if cjk_count < 30 and sent_count < 2:
            print(f"  >> Too short/fragmentary (CJK={cjk_count}, sentences={sent_count}), skipping.")
            continue

        # Build metadata header
        work_title = title
        display_title = title
        page_title = title
        author = ""
        times = ""
        categories_str = ", ".join(cat_titles)

        header_lines = [
            f"# WORK_TITLE: {work_title}",
            f"# DISPLAY_TITLE: {display_title}",
            f"# AUTHOR: {author}",
            f"# TIMES: {times}",
            f"# PAGE_TITLE: {page_title}",
            f"# CATEGORIES: {categories_str}",
            "",
        ]
        header = "\n".join(header_lines)

        # Write files
        fname_base = slugify_filename(title) + ".txt"
        raw_path = os.path.join(raw_dir, fname_base)
        clean_path = os.path.join(clean_dir, fname_base)

        with open(raw_path, "w", encoding="utf-8-sig", newline="\n") as f:
            f.write(header)
            f.write(raw_text)

        with open(clean_path, "w", encoding="utf-8-sig", newline="\n") as f:
            f.write(header)
            f.write(clean_text)

        # Update index
        index.append(
            {
                "title": title,
                "file_base": fname_base,
                "raw_path": os.path.relpath(raw_path, out_dir),
                "clean_path": os.path.relpath(clean_path, out_dir),
                "categories": cat_titles,
                "cjk_chars": cjk_count,
                "sentences": sent_count,
            }
        )

        print(
            f"  -> Saved RAW to   {raw_path}\n"
            f"  -> Saved CLEAN to {clean_path}\n"
            f"     (CJK chars={cjk_count}, sentences={sent_count})"
        )

        time.sleep(sleep)

    # Write index files
    index_csv = os.path.join(out_dir, "index.csv")
    index_json = os.path.join(out_dir, "index.json")

    print(f"\nWriting index to {index_csv} and {index_json}")

    # CSV (Excel-friendly): utf-8-sig with newline=""
    fieldnames = [
        "title",
        "file_base",
        "raw_path",
        "clean_path",
        "categories",
        "cjk_chars",
        "sentences",
    ]
    with open(index_csv, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in index:
            row_out = dict(row)
            # categories as pipe-joined string
            row_out["categories"] = "|".join(row_out["categories"])
            writer.writerow(row_out)

    # JSON
    with open(index_json, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)

    print("Done.")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Scrape Classical Chinese Wikipedia into a corpus.")
    ap.add_argument(
        "--out-dir",
        default="classical_wiki_corpus",
        help="Output directory (default: classical_wiki_corpus)",
    )
    ap.add_argument(
        "--max-pages",
        type=int,
        default=None,
        help="Limit number of pages (for testing). Default: all.",
    )
    ap.add_argument(
        "--sleep",
        type=float,
        default=0.2,
        help="Sleep time between requests in seconds (default: 0.2)",
    )
    args = ap.parse_args()

    scrape_classical_wiki(out_dir=args.out_dir, max_pages=args.max_pages, sleep=args.sleep)


if __name__ == "__main__":
    main()
