#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
category_scraper.py

Scrape all works in a zh.wikisource category (e.g. 朝鮮王朝) into a
raw/clean corpus with metadata indexes.

Key features:
- Follows pagination of categories.
- Groups titles like 春秋公羊傳註疏/卷01, 春秋公羊傳註疏/卷02, ... into one work folder 春秋公羊傳註疏.
- Groups titles like 題雲水亭八景帖·曠野行人, 題雲水亭八景帖·XX... into one work folder 題雲水亭八景帖.
- If there is *only* a root page (no / or · children), falls back to SKQS-style
  juan discovery via parse-links.
- CLEAN text keeps only Han characters + traditional punctuation (Hangul & Latin
  etc. are stripped), while RAW keeps everything.

Usage examples:

  # Basic: scrape Category:朝鮮王朝 into ./category_corpus
  python category_scraper.py 朝鮮王朝

  # Explicit category name and output dir
  python category_scraper.py "Category:朝鮮王朝" joseon_corpus

  # Limit to first 10 works in TEST mode
  python category_scraper.py 朝鮮王朝 joseon_corpus --test --max-works 10

  # Skip works that already exist in another corpus root
  python category_scraper.py 朝鮮王朝 joseon_corpus --skip-existing-from siku_quanshu_corpus
"""

import argparse
import csv
import json
import os
import platform
import re
import time
from typing import Any, Dict, List, Tuple

import requests
from bs4 import BeautifulSoup

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "SikuCorpusScraper/0.1 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

import os
import platform

# Enable long path support for Windows
if platform.system() == "Windows":
    # This helps with long paths in Python
    os.system('git config --system core.longpaths true')

import os
import sys

# Python-specific long path workaround for Windows
if os.name == 'nt':  # Windows
    # Enable long path support in Python
    try:
        import ctypes
        from ctypes import wintypes
        
        # Set ERROR_SUCCESS
        ERROR_SUCCESS = 0x0
        
        # Try to enable long paths for this process
        kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        process = kernel32.GetCurrentProcess()
        
        # This is a more direct approach
        print("🛠️ Attempting to enable Windows long paths for Python process...")
        
    except Exception as e:
        print(f"⚠️ Could not enable long paths via ctypes: {e}")
    
    # Use extended path prefix for all file operations
    def make_extended_path(path):
        path = os.path.abspath(path)
        if not path.startswith('\\\\?\\'):
            return '\\\\?\\' + path
        return path
else:
    def make_extended_path(path):
        return path

def safe_write_file(filepath: str, content: str, max_retries: int = 2) -> bool:
    """
    Safely write content to a file with retries and error handling.
    Returns True if successful, False if failed after retries.
    """
    filepath = make_extended_path(filepath)
    ensure_dir(os.path.dirname(filepath))
    
    for attempt in range(1, max_retries + 1):
        try:
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(content)
            return True
        except (OSError, IOError) as e:
            print(f"    !! File write error on attempt {attempt}/{max_retries}: {e}")
            if attempt < max_retries:
                time.sleep(0.5)
    
    return False

# ------------- basic helpers ------------- #

def safe_filename(name: str) -> str:
    name = name.strip()
    return re.sub(r'[\\/:*?"<>|]', "_", name)


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def safe_request(params: Dict[str, Any], max_retries: int = 3, sleep: float = 0.5) -> Dict[str, Any]:
    params = dict(params)
    params.setdefault("format", "json")
    params.setdefault("formatversion", 2)

    for attempt in range(1, max_retries + 1):
        try:
            resp = requests.get(API_ENDPOINT, headers=HEADERS, params=params, timeout=30)
            resp.raise_for_status()
            data = resp.json()
            if "error" in data:
                print(f"    !! API error: {data['error']}")
            return data
        except Exception as e:
            print(f"    !! HTTP error on attempt {attempt}/{max_retries}: {e}")
            if attempt < max_retries:
                time.sleep(sleep)
    return {}


# ------------- base-title logic for grouping ------------- #

def get_base_title(title: str) -> str:
    """
    Derive a 'work-level' base title.

    Examples:
      春秋公羊傳註疏/卷01            -> 春秋公羊傳註疏
      題雲水亭八景帖·曠野行人        -> 題雲水亭八景帖
      三國遺事                      -> 三國遺事
    """
    base = title.split("/", 1)[0]
    base = base.split("·", 1)[0]
    return base.strip()


# ------------- Han / punctuation filter (from zhengzi) ------------- #

def is_han_character(char: str) -> bool:
    code_point = ord(char)

    # CJK Unified Ideographs
    if 0x4E00 <= code_point <= 0x9FFF:
        return True
    # Extension A
    if 0x3400 <= code_point <= 0x4DBF:
        return True
    # Extension B
    if 0x20000 <= code_point <= 0x2A6DF:
        return True
    # Extension C
    if 0x2A700 <= code_point <= 0x2B73F:
        return True
    # Extension D
    if 0x2B740 <= code_point <= 0x2B81D:
        return True
    # Extension E
    if 0x2B820 <= code_point <= 0x2CEAD:
        return True
    # Extension F
    if 0x2CEB0 <= code_point <= 0x2EBE0:
        return True
    # Extension H
    if 0x31350 <= code_point <= 0x323AF:
        return True
    # Extension I
    if 0x2EBF0 <= code_point <= 0x2EE5D:
        return True
    # Extension J
    if 0x323B0 <= code_point <= 0x33479:
        return True
    # CJK Compatibility Ideographs (Supplement)
    if 0x2F800 <= code_point <= 0x2FA1F:
        return True

    return False


def is_traditional_punctuation(char: str) -> bool:
    code_point = ord(char)

    # CJK Symbols and Punctuation
    if 0x3000 <= code_point <= 0x303F:
        return True
    # Vertical forms
    if 0xFE10 <= code_point <= 0xFE1F:
        return True
    # CJK Compatibility Forms
    if 0xFE30 <= code_point <= 0xFE4F:
        return True
    # Halfwidth and Fullwidth Forms
    if 0xFF00 <= code_point <= 0xFFEF:
        return True

    traditional_punctuation = {
        "。", "，", "、", "；", "：", "？", "！", "「", "」", "『", "』",
        "《", "》", "（", "）", "［", "］", "｛", "｝", "【", "】", "…",
        "—", "～", "・", "〃", "〄", "々", "〆", "〇", "〈", "〉",
        "〖", "〗", "〘", "〙", "〚", "〛", "〜", "〝", "〞", "〟",
        "〰", "〱", "〲", "〳", "〴", "〵", "〶", "〷", "〸", "〹", "〺",
    }
    return char in traditional_punctuation


def is_allowed_character(char: str) -> bool:
    return (
        is_han_character(char)
        or is_traditional_punctuation(char)
        or char in "\n\r\t "
    )


def filter_han_text(text: str) -> str:
    return "".join(c for c in text if is_allowed_character(c))


# ------------- text extraction & cleaning ------------- #

def extract_visible_text_from_html(html: str) -> str:
    if not html:
        return ""

    soup = BeautifulSoup(html, "html.parser")

    for selector in [
        ".mw-editsection",
        ".references",
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
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = text.replace("\xa0", " ").strip()
    return text


def clean_text_for_corpus(text: str) -> str:
    """
    Structural + boilerplate cleanup, *then* apply Han-only filter for CLEAN.
    RAW stays as-is.
    """
    # Normalise full-width spaces
    text = text.replace("\u3000", " ")

    # Cut public domain boilerplate
    pd_markers = [
        "本作品在全世界都属于",
        "本作品在全世界都屬於",
        "本明朝作品在全世界都属于"
        "本明清作品在全世界都属于"
        "Public domain",
    ]
    cut_idx = len(text)
    for marker in pd_markers:
        idx = text.find(marker)
        if idx != -1 and idx < cut_idx:
            cut_idx = idx
    if cut_idx != len(text):
        text = text[:cut_idx]

    text = text.strip()
    lines = [ln.rstrip() for ln in text.splitlines()]

    # Merge vertical bracket artefacts:
    # 〈\n㑹昌二年\n〉 → 〈㑹昌二年〉
    merged_lines: List[str] = []
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s in {"〈", "《"} and i + 2 < len(lines):
            mid = lines[i + 1].strip()
            s2 = lines[i + 2].strip()
            if s2 in {"〉", "》"} and mid and len(mid) <= 20:
                merged_lines.append(f"{s}{mid}{s2}")
                i += 3
                continue
        merged_lines.append(lines[i])
        i += 1

    text = "\n".join(merged_lines)

    # Remove short editorial brackets like 【校】, 【補】 etc.
    text = re.sub(r"【[^】]{0,10}】", "", text)

    # Remove inline [1] style references
    text = re.sub(r"\[\d+\]", "", text)

    # Collapse excessive blank lines
    lines2 = [ln.rstrip() for ln in text.splitlines()]
    cleaned_lines: List[str] = []
    blank_count = 0
    for ln in lines2:
        if ln.strip():
            cleaned_lines.append(ln)
            blank_count = 0
        else:
            blank_count += 1
            if blank_count <= 2:
                cleaned_lines.append("")

    cleaned = "\n".join(cleaned_lines).strip()

    # Han-only filter for CLEAN corpus
    cleaned = filter_han_text(cleaned)

    return cleaned


# ------------- Chinese numeral helpers (for 卷 sorting) ------------- #

CHINESE_NUMERALS = {
    "零": 0,
    "〇": 0,
    "一": 1,
    "二": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
}


def chinese_numeral_to_int(s: str) -> int | None:
    s = s.strip()
    if s.isdigit():
        return int(s)

    m = re.fullmatch(r"([一二三四五六七八九])?十([一二三四五六七八九])?", s)
    if m:
        tens = CHINESE_NUMERALS.get(m.group(1), 1)
        ones = CHINESE_NUMERALS.get(m.group(2), 0)
        return tens * 10 + ones

    if all(ch in CHINESE_NUMERALS for ch in s) and len(s) == 1:
        return CHINESE_NUMERALS[s]

    return None


def juan_sort_key(full_title: str) -> Tuple[int, int, str]:
    """
    Try to sort things like .../卷一, .../第001卷, etc. Others go to the end.
    """
    t = full_title.strip()
    last_part = t.split("/", 1)[-1]

    m = re.search(r"卷([一二三四五六七八九十〇零\d]+)", last_part)
    if m:
        num = chinese_numeral_to_int(m.group(1)) or 9999
        return (0, num, t)

    if "卷上" in last_part:
        return (0, 1, t)
    if "卷中" in last_part:
        return (0, 2, t)
    if "卷下" in last_part:
        return (0, 3, t)

    # Non-juan titles: push later, but keep deterministic
    return (1, 9999, t)


# ------------- page fetching ------------- #

def fetch_html_for_page(title: str) -> str:
    params = {
        "action": "parse",
        "page": title,
        "prop": "text",
    }
    data = safe_request(params)
    try:
        html = data["parse"]["text"]
        if isinstance(html, dict):
            html = html.get("*", "") or html.get("html", "")
        return html or ""
    except Exception:
        return ""


def discover_juan_pages(root_title: str, pageid: int) -> List[str]:
    """
    From a work's main page, discover its 卷 / numbered subpages via links.
    Used only when the category does *not* explicitly list subpages.
    """
    params = {
        "action": "parse",
        "pageid": pageid,
        "prop": "links",
    }
    data = safe_request(params)
    links = data.get("parse", {}).get("links", []) or []

    root_prefix = root_title + "/"
    candidates: List[str] = []

    for lk in links:
        t = lk.get("title")
        if not t:
            continue
        if not t.startswith(root_prefix):
            continue
        last = t.split("/", 1)[-1]
        if "卷" in last or re.search(r"\d+", last):
            candidates.append(t)

    uniq = sorted(set(candidates), key=juan_sort_key)
    return uniq


# ------------- category discovery & grouping ------------- #

def discover_category_members(category_name: str) -> List[Dict[str, Any]]:
    """
    Return list of dicts {pageid, title} for all ns=0 pages in a category,
    following pagination. We keep *all* titles, including those with '/'.
    """
    if not category_name.startswith("Category:"):
        cat_title = "Category:" + category_name
    else:
        cat_title = category_name

    print(f"Discovering works in category: {cat_title} ...")
    members: Dict[int, Dict[str, Any]] = {}
    cont: str | None = None

    while True:
        params = {
            "action": "query",
            "list": "categorymembers",
            "cmtitle": cat_title,
            "cmnamespace": "0",
            "cmlimit": "max",
        }
        if cont:
            params["cmcontinue"] = cont

        data = safe_request(params)
        cms = data.get("query", {}).get("categorymembers", []) or []
        for cm in cms:
            pid = cm.get("pageid")
            title = cm.get("title")
            if pid is None or not title:
                continue
            members[pid] = {"pageid": pid, "title": title}

        cont = data.get("continue", {}).get("cmcontinue")
        if not cont:
            break

    print(f"  -> Found {len(members)} pages (including subpages) in {cat_title}")
    return sorted(members.values(), key=lambda d: d["title"])


def group_members_by_base(members: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    """
    Group category pages by base title (before '/' or '·').
    """
    groups: Dict[str, List[Dict[str, Any]]] = {}
    for m in members:
        title = m["title"]
        base = get_base_title(title)
        groups.setdefault(base, []).append(m)
    return groups


def collect_existing_work_ids(base_out: str, extra_roots: List[str]) -> set[str]:
    """
    Look at raw/ subdirs in base_out and any extra corpus roots and
    return a set of folder names that already exist (to avoid duplicates).
    """
    existing: set[str] = set()

    roots = [base_out] + list(extra_roots)
    for root in roots:
        raw_dir = os.path.join(root, "raw")
        if not os.path.isdir(raw_dir):
            continue
        for dirpath, dirnames, _ in os.walk(raw_dir):
            for d in dirnames:
                existing.add(d)
    return existing


# ------------- main scraping logic ------------- #

def scrape_category(
    category_name: str,
    base_out: str,
    sleep: float = 0.5,
    test: bool = False,
    max_works: int | None = None,
    max_juan_per_work: int | None = None,
    skip_existing_from: List[str] | None = None,
    skip_problematic: bool = False, 
) -> None:
    if skip_existing_from is None:
        skip_existing_from = []

    cat_label = category_name.split(":", 1)[-1]
    cat_dir_safe = safe_filename(cat_label)

    raw_root = os.path.join(base_out, "raw", cat_dir_safe)
    clean_root = os.path.join(base_out, "clean", cat_dir_safe)
    ensure_dir(raw_root)
    ensure_dir(clean_root)

    print("Starting category scrape.")
    print(f"  Category:   {category_name}")
    print(f"  Base out:   {base_out}")
    print(f"  RAW root:   {raw_root}")
    print(f"  CLEAN root: {clean_root}")
    print(f"  Mode:       {'TEST' if test else 'FULL'}")

    members = discover_category_members(category_name)
    groups = group_members_by_base(members)
    base_titles = sorted(groups.keys())

    if test and max_works:
        base_titles = base_titles[:max_works]

    existing_ids = collect_existing_work_ids(base_out, skip_existing_from)
    if existing_ids:
        print(f"  Existing work folders found (will skip duplicates by folder name): {len(existing_ids)}")

    index_rows: List[Dict[str, Any]] = []

    total = len(base_titles)
    for i, base_title in enumerate(base_titles, start=1):
        pages = groups[base_title]

        # Choose a representative pageid for the work (root page if present)
        root_page = next((p for p in pages if p["title"] == base_title), None)
        if root_page:
            pageid = root_page["pageid"]
        else:
            pageid = pages[0]["pageid"]

        work_id = safe_filename(base_title)

        print(f"\n### [{i}/{total}] {base_title} ###")
        if work_id in existing_ids:
            print(f"  !! Skipping {base_title}: folder '{work_id}' already exists in a corpus.")
            continue

        work_raw_dir = os.path.join(raw_root, work_id)
        work_clean_dir = os.path.join(clean_root, work_id)
        ensure_dir(work_raw_dir)
        ensure_dir(work_clean_dir)

        print(f"== Work (base): {base_title}  (group size: {len(pages)}) ==")

        # Decide whether to use category-listed children or SKQS-style juan discovery.
        # 1) If multiple pages share this base OR the single page's title already has
        #    '/' or '·', treat them as explicit parts.
        # 2) Otherwise, try discover_juan_pages on the root.
        use_category_children = False
        if len(pages) > 1:
            use_category_children = True
        else:
            only_title = pages[0]["title"]
            tail = only_title.split("/", 1)[-1]
            if "/" in only_title or "·" in tail:
                use_category_children = True

        part_titles: List[str]

        if use_category_children:
            # Children are all pages except the base-title page (if present).
            if root_page:
                child_pages = [p for p in pages if p is not root_page]
            else:
                child_pages = pages

            # Sort children by juan-sort when it makes sense, otherwise lexicographically.
            child_pages_sorted = sorted(child_pages, key=lambda m: juan_sort_key(m["title"]))
            part_titles = [p["title"] for p in child_pages_sorted]

            print(f"  Using {len(part_titles)} explicit subpages from category (/, · grouping).")
        else:
            # Just a single root-like page; try parse-based juan discovery.
            root = pages[0]
            root_title = root["title"]
            print(f"  No explicit subpages in category for {root_title}; using parse-based 卷 discovery...")
            juan_titles = discover_juan_pages(root_title, root["pageid"])
            if juan_titles:
                print(f"  Found {len(juan_titles)} 卷/part pages via parse.")
                part_titles = juan_titles
            else:
                print("  No 卷 links detected; treating main page as single text.")
                part_titles = [root_title]

        if test and max_juan_per_work is not None:
            part_titles = part_titles[:max_juan_per_work]

        for j_idx, page_title in enumerate(part_titles, start=1):
            print(f"  [{j_idx}/{len(part_titles)}] {page_title} ...")
            html = fetch_html_for_page(page_title)
            if not html:
                print(f"    !! Empty HTML returned for page: {page_title}")
                raw_text = ""
            else:
                raw_text = extract_visible_text_from_html(html)

            clean_text = clean_text_for_corpus(raw_text)

            is_empty = (clean_text.strip() == "")
            char_raw = len(raw_text)
            char_clean = len(clean_text)

            if is_empty:
                print("    !! Warning: CLEAN text is empty.")

            juan_num_str = f"{j_idx:02d}"
            base_fname = f"{safe_filename(base_title)}__juan_{juan_num_str}.txt"

            raw_path = os.path.join(work_raw_dir, base_fname)
            clean_path = os.path.join(work_clean_dir, base_fname)

            # Prepare file content with headers
            raw_content = f"# CATEGORY: {cat_label}\n# WORK_BASE_TITLE: {base_title}\n# PAGE_TITLE: {page_title}\n\n{raw_text}"
            clean_content = f"# CATEGORY: {cat_label}\n# WORK_BASE_TITLE: {base_title}\n# PAGE_TITLE: {page_title}\n\n{clean_text}"

            # Safely write files with error handling
            raw_success = safe_write_file(raw_path, raw_content)
            clean_success = safe_write_file(clean_path, clean_content)

            if not raw_success or not clean_success:
                print(f"    !! Failed to write files for {page_title}, skipping...")
                continue

            print(f"    -> Saved RAW to   {raw_path}")
            print(f"    -> Saved CLEAN to {clean_path}")

            index_rows.append(
                {
                    "category": cat_label,
                    "pageid": pageid,             # representative pageid for the work
                    "work_title": base_title,     # grouped base title
                    "page_title": page_title,     # actual wiki page used here
                    "work_folder": work_id,
                    "juan_index": j_idx,
                    "raw_path": raw_path,
                    "clean_path": clean_path,
                    "char_count_raw": char_raw,
                    "char_count_clean": char_clean,
                    "is_empty_page": 1 if is_empty else 0,
                }
            )

            time.sleep(sleep)

    # Write indexes for this category
    if index_rows:
        ensure_dir(base_out)
        csv_path = os.path.join(base_out, f"index_{cat_dir_safe}.csv")
        tsv_path = os.path.join(base_out, f"index_{cat_dir_safe}.tsv")
        json_path = os.path.join(base_out, f"index_{cat_dir_safe}.json")

        fieldnames = [
            "category",
            "pageid",
            "work_title",
            "page_title",
            "work_folder",
            "juan_index",
            "raw_path",
            "clean_path",
            "char_count_raw",
            "char_count_clean",
            "is_empty_page",
        ]

        with open(csv_path, "w", encoding="utf-8-sig", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames)
            w.writeheader()
            for row in index_rows:
                w.writerow(row)
        with open(tsv_path, "w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames, delimiter="\t")
            w.writeheader()
            for row in index_rows:
                w.writerow(row)
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(index_rows, f, ensure_ascii=False, indent=2)

        print(f"\nWrote category index:")
        print(f"  CSV : {csv_path}")
        print(f"  TSV : {tsv_path}")
        print(f"  JSON: {json_path}")
    else:
        print("\nNo pages scraped; no index written.")

    print("\nDone.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Scrape a zh.wikisource category into a corpus."
    )
    # Add this argument to the argument parser in main():
    parser.add_argument(
        "--skip-problematic",
        action="store_true",
        help="Skip works/pages that cause file system errors (e.g., long paths, special characters)",
    )
    parser.add_argument(
        "category",
        help="Category name, with or without 'Category:' prefix (e.g. 朝鮮王朝 or Category:朝鮮王朝)",
    )
    parser.add_argument(
        "base_output",
        nargs="?",
        default="category_corpus",
        help="Base output directory (default: category_corpus)",
    )
    parser.add_argument(
        "--sleep",
        type=float,
        default=0.5,
        help="Sleep between page requests in seconds (default: 0.5)",
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="TEST mode: useful together with --max-works / --max-juan-per-work",
    )
    parser.add_argument(
        "--max-works",
        type=int,
        default=None,
        help="In TEST mode, maximum number of works (base titles) to process.",
    )
    parser.add_argument(
        "--max-juan-per-work",
        type=int,
        default=None,
        help="In TEST mode, maximum number of juan/pages per work.",
    )
    parser.add_argument(
        "--skip-existing-from",
        action="append",
        default=[],
        help="Additional corpus roots (each with a raw/ subdir) to treat as sources of existing works to skip.",
    )

    args = parser.parse_args()

    scrape_category(
        category_name=args.category,
        base_out=args.base_output,
        sleep=args.sleep,
        test=args.test,
        max_works=args.max_works,
        max_juan_per_work=args.max_juan_per_work,
        skip_existing_from=args.skip_existing_from,
        skip_problematic=args.skip_problematic,
    )


if __name__ == "__main__":
    main()
