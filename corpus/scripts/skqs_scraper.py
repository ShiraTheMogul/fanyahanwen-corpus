#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Siku Quanshu corpus scraper for Chinese Wikisource.

Features:
- Discovers works from:
    * Category:四庫全書
    * 四庫全書 section pages: 經部, 史部, 子部, 集部
- Classifies works by:
    * section (經部 / 史部 / 史部 / 子部 / 集部)
    * category1 (e.g. 小學類)
    * category2 (e.g. 訓詁之屬)
- Scrapes each work's 卷 pages (or falls back to main page / subpages).
- Writes:
    * RAW text (lightly stripped HTML text)
    * CLEAN text (corpus-friendly)
- Handles:
    * Public-domain boilerplate cutoff
    * Vertical text bracket artefacts like:
        〈
        㑹昌二年
        〉   →  〈㑹昌二年〉
    * Full-width spaces
    * Empty pages, optionally skipping file write
- Index output:
    * index.csv (UTF-8 with BOM)
    * index.tsv (UTF-8, tab-separated)
    * index.json (UTF-8, pretty-printed)
- Metadata:
    * Best-effort extraction of author and times (dynasty/period) from {{Header}}.
"""

from __future__ import annotations

import csv
import json
import os
import re
import sys
import time
from typing import Any, Dict, Iterable, List, Optional, Tuple

import requests
from bs4 import BeautifulSoup

# --------------------- configuration --------------------- #

API_URL = "https://zh.wikisource.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "SikuCorpusScraper/0.6 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

# Sleep between page fetches (be kind to Wikisource)
SLEEP_SECONDS = 0.5

# Test mode: limit the number of works
TEST_MODE = False
MAX_WORKS = 5

# Whether to actually write files for empty pages
SCRAPE_EMPTY_PAGES = True

# SKQS category and section pages
SKQS_CATEGORY = "四庫全書"

SKQS_SECTION_PAGES = [
    "四庫全書/經部",
    "四庫全書/史部",
    "四庫全書/子部",
    "四庫全書/集部",
]

# --------------------- HTTP helper --------------------- #

_session = requests.Session()


def safe_request(params: Dict[str, Any], max_retries: int = 3) -> Dict[str, Any]:
    """
    Wrapper around requests.get with retries and basic error handling.
    Always returns a dict (possibly empty) instead of raising.
    """
    for attempt in range(1, max_retries + 1):
        try:
            time.sleep(SLEEP_SECONDS)
            r = _session.get(API_URL, params=params, headers=HEADERS, timeout=30)
            r.raise_for_status()
            data = r.json()
            if "error" in data:
                err = data["error"]
                print(f"    !! API error: {err}", file=sys.stderr)
                if attempt == max_retries:
                    return {}
                continue
            return data
        except Exception as e:
            print(f"    !! Request error (attempt {attempt}/{max_retries}): {e}", file=sys.stderr)
            if attempt == max_retries:
                return {}
    return {}


# --------------------- small utilities --------------------- #

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
    "十": 10,
}


def chinese_numeral_to_int(s: str) -> Optional[int]:
    """
    Very small helper to turn the most common juan-style numerals into integers.
    Handles:
      一, 二, ..., 九
      十, 十一, 十二, ... 十九
      二十, 二十一, ... 九十九
      01, 02, ... 99
    Returns None if we really cannot parse it.
    """
    s = s.strip()

    # Already digits?
    if re.fullmatch(r"\d+", s):
        try:
            return int(s)
        except ValueError:
            return None

    # Simple patterns:
    if s in CHINESE_NUMERALS:
        return CHINESE_NUMERALS[s]

    # 十X  (10 + X)
    m = re.fullmatch(r"十([一二三四五六七八九])", s)
    if m:
        return 10 + CHINESE_NUMERALS[m.group(1)]

    # X十Y (X*10 + Y) or X十 (X*10)
    m = re.fullmatch(r"([一二三四五六七八九])十([一二三四五六七八九])", s)
    if m:
        return CHINESE_NUMERALS[m.group(1)] * 10 + CHINESE_NUMERALS[m.group(2)]

    m = re.fullmatch(r"([一二三四五六七八九])十", s)
    if m:
        return CHINESE_NUMERALS[m.group(1)] * 10

    # Bare 十
    if s == "十":
        return 10

    return None


def juan_sort_key(full_title: str) -> Tuple[int, int, str]:
    """
    Produce a sort key for 卷 pages and other subpages.

    We want:
      - 卷 pages in numeric order
      - then 上/中/下 if relevant
      - then everything else
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

    return (1, 9999, t)


def safe_filename(name: str) -> str:
    """
    Make a string safe for use as a Windows filename / directory component.
    """
    name = name.strip()
    return re.sub(r'[\\/:*?"<>|]', "_", name)


def extract_visible_text_from_html(html: str) -> str:
    """
    Take HTML returned by action=parse&prop=text and extract a plain-text body.
    We keep headings and paragraphs, but drop navigation, edit links, templates, etc.
    """
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
    Heuristic "clean" pass for corpus use.
    - Normalise full-width spaces.
    - Strip public-domain boilerplate.
    - Normalise vertical-text bracket artefacts like:
        〈
        㑹昌二年
        〉
      into: 〈㑹昌二年〉
    - Strip leading/trailing whitespace.
    - Collapse many blank lines.
    - Remove some common annotation patterns.
    """
    text = text.replace("\u3000", " ")

    # --- CUT PUBLIC DOMAIN NOTICE ---
    pd_markers = [
        "本作品在全世界都属于",
        "本作品在全世界都屬於",
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

    # --- Normalise vertical-text bracket artefacts ---
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

    # Remove inline [1], [2] style references:
    text = re.sub(r"\[\d+\]", "", text)

    # Collapse excessive blank lines.
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

    return "\n".join(cleaned_lines).strip()


def normalize_display_title(title: str) -> str:
    """
    Strip the '（四庫全書本）' / '(四庫全書本)' suffix (full-width or ASCII) from
    a work title so that directory and file names are nicer, and trim
    any leftover whitespace.
    """
    stripped = re.sub(r"[（(]四庫全書本[)）]\s*$", "", title)
    return stripped.strip()


# --------------------- metadata from {{Header}} --------------------- #

HEADER_RE = re.compile(r"\{\{Header.*?\}\}", re.S)


def _clean_wiki_value(value: str) -> str:
    """
    Lightly strip wiki markup from a header field value.
    """
    v = value.strip()

    # Strip HTML comments
    v = re.sub(r"<!--.*?-->", "", v, flags=re.S)

    # Replace links [[a|b]] or [[a]] with the displayed part
    def _sub_link(m: re.Match) -> str:
        inner = m.group(1)
        parts = inner.split("|", 1)
        return parts[-1]

    v = re.sub(r"\[\[([^]]+)\]\]", _sub_link, v)

    # Strip templates {{...}} → keep inner text (very rough)
    v = re.sub(r"\{\{([^{}]+)\}\}", r"\1", v)

    return v.strip()


def get_header_metadata(pageid: int) -> Dict[str, str]:
    """
    Try to extract title/author/times from the {{Header}} template
    on the work's main page. Returns possibly empty dict with keys:
      - "title"
      - "author"
      - "times"
    Only uses the header template; no guesswork from body text.
    """
    params = {
        "action": "parse",
        "format": "json",
        "pageid": pageid,
        "prop": "wikitext",
        "formatversion": "2",
    }
    data = safe_request(params)
    parse = data.get("parse") or {}
    wikitext = parse.get("wikitext", "")
    if not wikitext:
        return {}

    m = HEADER_RE.search(wikitext)
    if not m:
        return {}

    header_block = m.group(0)

    def _extract_field(name: str) -> str:
        # | name = value\n| other = ...
        pat = rf"\|\s*{name}\s*=\s*(.*?)(?:\n\||\n\}}\}})"
        m2 = re.search(pat, header_block, flags=re.S)
        if not m2:
            return ""
        raw_val = m2.group(1)
        return _clean_wiki_value(raw_val)

    meta: Dict[str, str] = {}
    for key in ("title", "author", "times"):
        val = _extract_field(key)
        if val:
            meta[key] = val

    return meta


# --------------------- SKQS work discovery --------------------- #

def get_skqs_works(limit: Optional[int] = None) -> List[Dict[str, Any]]:
    """
    Discover "works" which are pages in Category:四庫全書.
    Returns list of dicts: {"pageid": int, "title": str}

    Option B: we treat *only* root work pages as works, so we
    skip any category members whose title contains '/' (i.e. subpages).
    """
    print("Discovering works in SKQS category...")

    works: List[Dict[str, Any]] = []
    cmcontinue: Optional[str] = None

    while True:
        params = {
            "action": "query",
            "format": "json",
            "list": "categorymembers",
            "cmtitle": f"Category:{SKQS_CATEGORY}",
            "cmlimit": "max",
            "cmnamespace": 0,
            "cmtype": "page",
        }
        if cmcontinue:
            params["cmcontinue"] = cmcontinue

        data = safe_request(params)
        if not data:
            break

        members = data.get("query", {}).get("categorymembers", [])
        for m in members:
            title = m.get("title", "")
            if not title:
                continue
            # ---- Option B: skip subpages like "絜齋集/卷17" ----
            if "/" in title:
                continue

            works.append(
                {
                    "pageid": int(m["pageid"]),
                    "title": title,
                    "source": "category",
                }
            )
            if limit and len(works) >= limit:
                break

        if limit and len(works) >= limit:
            break

        cmcontinue = data.get("continue", {}).get("cmcontinue")
        if not cmcontinue:
            break

    print(f"  -> Found {len(works)} works in Category:{SKQS_CATEGORY}")
    return works


def get_section_works(limit: Optional[int] = None) -> List[Dict[str, Any]]:
    """
    Discover works from the 四庫全書 section pages (經部, 史部, 子部, 集部),
    and attach:
      - section (經部 / 史部 / 子部 / 集部)
      - category1 (e.g. 小學類)
      - category2 (e.g. 訓詁之屬)
    """
    all_title_meta: List[Tuple[str, str, str, str]] = []
    seen_titles: set[str] = set()

    for section_page in SKQS_SECTION_PAGES:
        print(f"Discovering works from section page: {section_page} ...")
        params = {
            "action": "parse",
            "format": "json",
            "page": section_page,
            "prop": "text",
            "formatversion": "2",
        }
        data = safe_request(params)
        parse = data.get("parse")
        if not parse:
            print(f"  !! Could not parse section page: {section_page}")
            continue

        html = parse.get("text", "")
        if not html:
            print(f"  !! Empty HTML for section page: {section_page}")
            continue

        soup = BeautifulSoup(html, "html.parser")
        content = soup.find("div", class_="mw-parser-output") or soup

        section_label = section_page.split("/", 1)[-1]

        current_cat1 = ""
        current_cat2 = ""

        for elem in content.descendants:
            if not hasattr(elem, "name") or elem.name is None:
                continue

            if elem.name in ("h2", "h3", "h4"):
                headline = elem.get_text(strip=True)
                if elem.name in ("h2", "h3"):
                    current_cat1 = headline
                    current_cat2 = ""
                elif elem.name == "h4":
                    current_cat2 = headline
                continue

            if elem.name == "a":
                title = elem.get("title") or elem.get_text(strip=True)
                if not title:
                    continue
                if "四庫全書本" not in title:
                    continue
                if title in seen_titles:
                    continue

                seen_titles.add(title)
                all_title_meta.append((title, section_label, current_cat1, current_cat2))

                if limit and len(all_title_meta) >= limit:
                    break

        count_for_section = sum(1 for t in all_title_meta if t[1] == section_label)
        print(f"  -> Found {count_for_section} SKQS-edition titles in {section_page}")

        if limit and len(all_title_meta) >= limit:
            break

    if not all_title_meta:
        return []

    title_to_meta: Dict[str, Tuple[str, str, str]] = {}
    for title, section_label, cat1, cat2 in all_title_meta:
        title_to_meta.setdefault(title, (section_label, cat1, cat2))

    titles = list(title_to_meta.keys())
    print(f"Resolving {len(titles)} SKQS section titles to pageids...")

    works: List[Dict[str, Any]] = []
    batch_size = 50
    for i in range(0, len(titles), batch_size):
        chunk = titles[i: i + batch_size]
        params = {
            "action": "query",
            "format": "json",
            "titles": "|".join(chunk),
        }
        data = safe_request(params)
        pages = data.get("query", {}).get("pages", {})
        for pg in pages.values():
            if "missing" in pg:
                continue
            title = pg.get("title")
            if not title:
                continue
            meta = title_to_meta.get(title)
            if not meta:
                continue
            section_label, cat1, cat2 = meta
            works.append(
                {
                    "pageid": int(pg["pageid"]),
                    "title": title,
                    "section": section_label,
                    "category1": cat1,
                    "category2": cat2,
                    "source": "section",
                }
            )

    print(f"  -> Resolved {len(works)} section-page works with pageids.")
    return works


def discover_all_works(limit: Optional[int] = None) -> List[Dict[str, Any]]:
    """
    Combine category-based discovery and section-page discovery into a unified
    list of works keyed by pageid.
    """
    cat_works = get_skqs_works(None)
    sec_works = get_section_works(None)

    works_by_id: Dict[int, Dict[str, Any]] = {}

    for w in cat_works:
        pid = int(w["pageid"])
        title = w["title"]
        works_by_id[pid] = {
            "pageid": pid,
            "title": title,
            "display_title": normalize_display_title(title),
            "section": "",
            "category1": "",
            "category2": "",
            "sources": ["category"],
        }

    for w in sec_works:
        pid = int(w["pageid"])
        title = w["title"]
        section = w.get("section", "")
        cat1 = w.get("category1", "")
        cat2 = w.get("category2", "")

        if pid not in works_by_id:
            works_by_id[pid] = {
                "pageid": pid,
                "title": title,
                "display_title": normalize_display_title(title),
                "section": section,
                "category1": cat1,
                "category2": cat2,
                "sources": ["section"],
            }
        else:
            rec = works_by_id[pid]
            rec["sources"].append("section")
            if not rec.get("section") and section:
                rec["section"] = section
            if not rec.get("category1") and cat1:
                rec["category1"] = cat1
            if not rec.get("category2") and cat2:
                rec["category2"] = cat2

    works = list(works_by_id.values())
    works.sort(
        key=lambda w: (
            w.get("section", ""),
            w.get("category1", ""),
            w.get("category2", ""),
            w.get("display_title", w.get("title", "")),
        )
    )

    if limit is not None and len(works) > limit:
        works = works[:limit]

    print(f"Discovered {len(works)} works to process.")
    return works


# --------------------- 卷 / subpage discovery --------------------- #

def get_juan_links_from_main_page(work_title: str, pageid: int) -> List[str]:
    """
    Get all subpage links from the main work page that look like 卷 pages.
    """
    params = {
        "action": "parse",
        "format": "json",
        "pageid": pageid,
        "prop": "links",
        "formatversion": "2",
    }
    data = safe_request(params)
    parse = data.get("parse") or {}
    links = parse.get("links") or []

    titles = []
    for lnk in links:
        t = lnk.get("title", "")
        if not t:
            continue
        if "/" not in t:
            continue
        if not t.startswith(work_title + "/"):
            continue
        if "卷" not in t:
            continue
        titles.append(t)

    titles = sorted(set(titles), key=juan_sort_key)
    return titles


def get_all_subpages(work_title: str) -> List[str]:
    """
    Discover all subpages of a work by prefix search: WORK_TITLE/...
    """
    prefix = work_title + "/"
    params = {
        "action": "query",
        "format": "json",
        "generator": "allpages",
        "gapnamespace": 0,
        "gapprefix": prefix,
        "gaplimit": "max",
    }

    subpages: List[str] = []
    gapcontinue: Optional[str] = None

    while True:
        if gapcontinue:
            params["gapcontinue"] = gapcontinue
        data = safe_request(params)
        pages = data.get("query", {}).get("pages", {})
        for pg in pages.values():
            t = pg.get("title")
            if t:
                subpages.append(t)
        gapcontinue = data.get("continue", {}).get("gapcontinue")
        if not gapcontinue:
            break

    return sorted(set(subpages))


def classify_and_sort_subpages(work_title: str, subpages: Iterable[str]) -> List[str]:
    """
    Given a list of subpages for a work, pick out juan-like pages and
    sort them nicely.
    """
    candidates: List[Tuple[int, int, str]] = []

    for full in set(subpages):
        last_part = full.split("/", 1)[-1]

        if "卷" in last_part:
            after = last_part.split("卷", 1)[1].strip()
            num = chinese_numeral_to_int(after)
            if num is None:
                num = 9999
            candidates.append((0, num, full))
        else:
            candidates.append((1, 9999, full))

    candidates.sort(key=lambda x: (x[0], x[1], x[2]))
    return [full for (_, _, full) in candidates]


def discover_juan_pages(work_title: str, pageid: int) -> List[str]:
    """
    Unified entry:
      1) Try to get 卷 links from main work page.
      2) If none, try subpage discovery.
    """
    juans = get_juan_links_from_main_page(work_title, pageid)
    if juans:
        return juans

    print("  No 卷 links on main page; trying subpages...")
    subs = get_all_subpages(work_title)
    if not subs:
        return []

    juans = classify_and_sort_subpages(work_title, subs)
    return juans


# --------------------- text fetching --------------------- #

def _build_fallback_titles_for_page(
    title: str,
    work_title_full: Optional[str],
) -> List[str]:
    """
    Build a list of alternative titles to try if the first one fails.

    Main goal: fix things like:
        title:          今獻備遺/卷24
        work_title_full:今獻備遺 (四庫全書本)

    So we can try:
        今獻備遺 (四庫全書本)/卷24
    """
    titles: List[str] = [title]

    if not work_title_full:
        return titles

    work_full = work_title_full.strip()
    suffix_pattern = r"[（(]四庫全書本[)）]"

    if not re.search(suffix_pattern, work_full):
        return titles

    base_work = re.sub(suffix_pattern, "", work_full).strip()

    if base_work and title.startswith(base_work) and not re.search(suffix_pattern, title):
        rest = title[len(base_work):]
        candidate = work_full + rest
        titles.append(candidate)

    if "/" in title:
        _, sub = title.split("/", 1)
        candidate2 = f"{work_full}/{sub}"
        if candidate2 not in titles:
            titles.append(candidate2)

    return titles


def get_page_html_by_title(title: str, work_title_full: Optional[str] = None) -> str:
    """
    Fetch page HTML via action=parse for a given title.

    If the first attempt returns nothing (missingtitle or other issue),
    and we know the 'work_title_full' (with 四庫全書本, etc.), we try
    some alternative SKQS-flavoured titles before giving up.
    """
    titles_to_try = _build_fallback_titles_for_page(title, work_title_full)

    for candidate in titles_to_try:
        params = {
            "action": "parse",
            "format": "json",
            "page": candidate,
            "prop": "text",
            "formatversion": "2",
        }
        data = safe_request(params)
        parse = data.get("parse") or {}
        html = parse.get("text", "")
        if html:
            if candidate != title:
                print(f"    !! Note: requested '{title}', using '{candidate}' instead.")
            return html

    print(f"    !! Empty HTML returned for page (after fallbacks): {title}")
    return ""


# --------------------- main scraping logic --------------------- #

def scrape_work(
    work: Dict[str, Any],
    out_raw_dir: str,
    out_clean_dir: str,
    index_rows: List[Dict[str, Any]],
) -> None:
    work_title_full = work["title"]
    display_title = work.get("display_title") or normalize_display_title(work_title_full)
    pageid = work["pageid"]

    section = work.get("section", "")
    category1 = work.get("category1", "")
    category2 = work.get("category2", "")

    # Metadata from {{Header}}
    header_meta = get_header_metadata(pageid)
    author = header_meta.get("author", "")
    times_str = header_meta.get("times", "")
    header_title = header_meta.get("title")
    if header_title:
        # Don't override display_title used for dirs, but it can be nice to log.
        pass

    print(f"== Work: {work_title_full}  (pageid {pageid}) ==")
    if section or category1 or category2:
        print(f"  Section: {section} | Cat1: {category1} | Cat2: {category2}")
    if author or times_str:
        print(f"  Author: {author} | Times: {times_str}")

    juan_titles = discover_juan_pages(work_title_full, pageid)

    if not juan_titles:
        print("  !! No 卷 pages found via links or subpages; treating main page as single text.")
        juan_titles = [work_title_full]
    else:
        print(f"  Found {len(juan_titles)} 卷 pages.")

    path_parts = [
        p for p in (section, category1, category2, display_title) if p.strip()
    ]
    dir_suffix = [safe_filename(p) for p in path_parts]

    work_raw_dir = os.path.join(out_raw_dir, *dir_suffix) if dir_suffix else out_raw_dir
    work_clean_dir = os.path.join(out_clean_dir, *dir_suffix) if dir_suffix else out_clean_dir
    os.makedirs(work_raw_dir, exist_ok=True)
    os.makedirs(work_clean_dir, exist_ok=True)

    for idx, title in enumerate(juan_titles, start=1):
        print(f"  [{idx}/{len(juan_titles)}] {title} ...")
        html = get_page_html_by_title(title, work_title_full=work_title_full)

        raw_text = extract_visible_text_from_html(html)
        is_empty = (raw_text.strip() == "")
        if is_empty:
            print("    !! Warning: extracted RAW text is empty.")

        clean_text = clean_text_for_corpus(raw_text) if raw_text else ""
        char_count_raw = len(raw_text)
        char_count_clean = len(clean_text)

        if is_empty and not SCRAPE_EMPTY_PAGES:
            print("    -> Empty page skipped (no files written).")
            index_rows.append(
                {
                    "pageid": pageid,
                    "work_title": work_title_full,
                    "display_title": display_title,
                    "section": section,
                    "category1": category1,
                    "category2": category2,
                    "author": author,
                    "times": times_str,
                    "page_title": title,
                    "juan_index": idx,
                    "raw_path": "",
                    "clean_path": "",
                    "char_count_raw": char_count_raw,
                    "char_count_clean": char_count_clean,
                    "is_empty_page": 1,
                }
            )
            continue

        juan_num_str = f"{idx:02d}"
        base_filename = f"{safe_filename(display_title)}__juan_{juan_num_str}.txt"

        raw_path = os.path.join(work_raw_dir, base_filename)
        clean_path = os.path.join(work_clean_dir, base_filename)

        with open(raw_path, "w", encoding="utf-8") as f:
            f.write(f"# WORK_TITLE: {work_title_full}\n")
            f.write(f"# DISPLAY_TITLE: {display_title}\n")
            f.write(f"# AUTHOR: {author}\n")
            f.write(f"# TIMES: {times_str}\n")
            f.write(f"# PAGE_TITLE: {title}\n\n")
            f.write(raw_text)

        with open(clean_path, "w", encoding="utf-8") as f:
            f.write(f"# WORK_TITLE: {work_title_full}\n")
            f.write(f"# DISPLAY_TITLE: {display_title}\n")
            f.write(f"# AUTHOR: {author}\n")
            f.write(f"# TIMES: {times_str}\n")
            f.write(f"# PAGE_TITLE: {title}\n\n")
            f.write(clean_text)

        print(f"    -> Saved RAW to   {raw_path}")
        print(f"    -> Saved CLEAN to {clean_path}")

        index_rows.append(
            {
                "pageid": pageid,
                "work_title": work_title_full,
                "display_title": display_title,
                "section": section,
                "category1": category1,
                "category2": category2,
                "author": author,
                "times": times_str,
                "page_title": title,
                "juan_index": idx,
                "raw_path": raw_path,
                "clean_path": clean_path,
                "char_count_raw": char_count_raw,
                "char_count_clean": char_count_clean,
                "is_empty_page": 1 if is_empty else 0,
            }
        )


def write_indexes(base_out: str, index_rows: List[Dict[str, Any]]) -> None:
    if not index_rows:
        print("No index rows to write.")
        return

    fieldnames = [
        "pageid",
        "work_title",
        "display_title",
        "section",
        "category1",
        "category2",
        "author",
        "times",
        "page_title",
        "juan_index",
        "raw_path",
        "clean_path",
        "char_count_raw",
        "char_count_clean",
        "is_empty_page",
    ]

    csv_path = os.path.join(base_out, "index.csv")
    tsv_path = os.path.join(base_out, "index.tsv")
    json_path = os.path.join(base_out, "index.json")

    with open(csv_path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in index_rows:
            writer.writerow(row)
    print(f"Writing CSV index to {csv_path}")

    with open(tsv_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        for row in index_rows:
            writer.writerow(row)
    print(f"Writing TSV index to {tsv_path}")

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(index_rows, f, ensure_ascii=False, indent=2)
    print(f"Writing JSON index to {json_path}")


def main() -> None:
    base_out = "siku_quanshu_corpus"
    raw_dir = os.path.join(base_out, "raw")
    clean_dir = os.path.join(base_out, "clean")
    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(clean_dir, exist_ok=True)

    mode = "TEST" if TEST_MODE else "FULL"
    print("Starting Siku Quanshu scrape.")
    print(f"  Base output: {base_out}")
    print(f"  RAW dir:      {raw_dir}")
    print(f"  CLEAN dir:    {clean_dir}")
    print(f"  sleep={SLEEP_SECONDS}s | {mode} mode")

    max_works = MAX_WORKS if TEST_MODE else None
    works = discover_all_works(limit=max_works)

    index_rows: List[Dict[str, Any]] = []

    for i, work in enumerate(works, start=1):
        display_title = work.get("display_title") or normalize_display_title(work["title"])
        print()
        print(f"### [{i}/{len(works)}] {display_title}  ###")
        try:
            scrape_work(work, raw_dir, clean_dir, index_rows)
        except Exception as e:
            print(f"!! Error while scraping {display_title} : {e}", file=sys.stderr)

    print()
    write_indexes(base_out, index_rows)
    print("\nDone.")


if __name__ == "__main__":
    main()
