#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wikisource_author_scraper.py

Dependencies:
  pip install requests beautifulsoup4

Examples:
  # scrape only 梁啟超's 文 section, and split into 清/民國 folders using year>=1912
  python wikisource_author_scraper.py scrape-author 作者:梁啟超 ../scrape_output --section 文 --era-divider qing_roc

  # normal scrape behavior (categorymembers / whole author page, no era divider)
  python wikisource_author_scraper.py scrape-author 作者:林紓 ../scrape_output

  # Refresh WS categories in an existing corpus
  python wikisource_author_scraper.py enrich-categories ./corpus --promote-category-to-nation
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import unquote, urlparse

import requests
from bs4 import BeautifulSoup, Tag

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusScraper/1.1 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

# Public-domain cutoff markers (CLEAN output only)
PD_MARKERS = [
    "本作品在全世界都属于",
    "本作品在全世界都屬於",
    "Public domain",
]

# Heuristic: titles in these namespaces are not content pages.
# (MediaWiki uses ":" to separate namespaces.)
DISALLOWED_NS_PREFIXES = (
    "Author:",
    "作者:",
    "Category:",
    "分類:",
    "Help:",
    "Portal:",
    "Wikisource:",
    "MediaWiki:",
    "File:",
    "Image:",
    "Template:",
    "Talk:",
    "User:",
    "Special:",
)

ROC_START_YEAR = 1912

# -----------------------------
# HTTP / MediaWiki API helpers
# -----------------------------

_session = requests.Session()


def safe_request(params: Dict[str, Any], *, sleep: float = 0.5, max_retries: int = 3) -> Dict[str, Any]:
    """GET zh.wikisource.org/w/api.php with retries, returning {} on failure."""
    params = dict(params)
    params.setdefault("format", "json")
    for attempt in range(1, max_retries + 1):
        try:
            time.sleep(sleep)
            r = _session.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=30)
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


def resolve_title(s: str) -> str:
    """
    Accept either:
      - "Author:嚴復" / "作者:嚴復"
      - "https://zh.wikisource.org/wiki/Author:%E5%9A%B4%E5%BE%A9"
      - "https://zh.wikisource.org/zh-hant/Author%3A%E5%9A%B4%E5%BE%A9"
    and return a MediaWiki title like "Author:嚴復".
    """
    s = s.strip()
    if s.startswith("http://") or s.startswith("https://"):
        u = urlparse(s)
        path = u.path or ""
        parts = [p for p in path.split("/") if p]
        if not parts:
            return s
        if parts[0] == "wiki":
            title_enc = "/".join(parts[1:])
        else:
            title_enc = "/".join(parts[1:]) if len(parts) >= 2 else parts[0]
        return unquote(title_enc)
    return s


def title_is_content_page(title: str) -> bool:
    """Reject obvious non-content namespaces (anything with a disallowed prefix)."""
    t = title.strip()

    # Reject edit-section UI titles (full-width colon is common here)
    if t.startswith(("编辑章节", "編輯章節", "Edit section")):
        return False

    for pref in DISALLOWED_NS_PREFIXES:
        if t.startswith(pref):
            return False

    # Also exclude any other namespaces we didn't list.
    # MediaWiki namespaces have a colon early on; mainspace titles usually don't.
    # Include full-width colon too.
    if (":" in t) or ("：" in t):
        return False

    return True


def get_pageid(title: str, *, sleep: float) -> Optional[int]:
    """Resolve a title -> pageid, or None if missing."""
    data = safe_request({"action": "query", "titles": title}, sleep=sleep)
    pages = (data.get("query") or {}).get("pages") or {}
    if not pages:
        return None
    pg = next(iter(pages.values()))
    if "missing" in pg:
        return None
    pid = pg.get("pageid")
    return int(pid) if pid is not None else None


def fetch_html(title: str, *, sleep: float) -> str:
    """Fetch HTML for a title via action=parse&prop=text."""
    data = safe_request(
        {"action": "parse", "page": title, "prop": "text", "formatversion": "2"},
        sleep=sleep,
    )
    parse = data.get("parse") or {}
    html = parse.get("text") or ""
    if isinstance(html, dict):
        html = html.get("*", "") or html.get("html", "")
    return html or ""


def fetch_links(title_or_pageid: str | int, *, sleep: float) -> List[str]:
    """
    Return list of MediaWiki link targets from a page.
    Uses action=parse&prop=links. (No context, but canonical titles.)
    """
    params: Dict[str, Any] = {"action": "parse", "prop": "links", "formatversion": "2"}
    if isinstance(title_or_pageid, int):
        params["pageid"] = title_or_pageid
    else:
        params["page"] = title_or_pageid

    data = safe_request(params, sleep=sleep)
    parse = data.get("parse") or {}
    links = parse.get("links") or []
    out: List[str] = []
    for lk in links:
        t = lk.get("title") or lk.get("*")
        if t:
            out.append(t)
    return out


def fetch_categories(title: str, *, sleep: float) -> List[str]:
    """
    Return non-hidden categories for a page as plain titles (without 'Category:').
    Uses action=query&prop=categories with clshow=!hidden.
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
    pg = pages[0]
    cats = pg.get("categories") or []
    out = []
    for c in cats:
        name = c.get("title", "")
        if name.startswith("Category:"):
            name = name.split(":", 1)[1]
        if name:
            out.append(name)
    return sorted(set(out))


# -----------------------------
# Text extraction / cleaning
# -----------------------------

def extract_visible_text_from_html(html: str) -> str:
    """Convert MediaWiki HTML to plain text, dropping common nav/table/toc clutter."""
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
    text = re.sub(r"\r\n?", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = text.replace("\xa0", " ").strip()
    return text


def cut_public_domain(text: str) -> str:
    """Cut at the earliest PD marker (CLEAN only)."""
    cut_idx = len(text)
    for marker in PD_MARKERS:
        idx = text.find(marker)
        if idx != -1 and idx < cut_idx:
            cut_idx = idx
    return text[:cut_idx] if cut_idx != len(text) else text


def clean_text_for_corpus(text: str) -> str:
    """
    Conservative clean pass:
    - Normalise full-width spaces.
    - Cut public-domain boilerplate.
    - Fix bracket artefacts: 〈\nX\n〉 -> 〈X〉 and 《\nX\n》 -> 《X〉
    - Remove short editorial 【...】 (<=10 chars) and inline [1] refs.
    - Collapse excessive blank lines.
    """
    text = text.replace("\u3000", " ")
    text = cut_public_domain(text).strip()

    lines = [ln.rstrip() for ln in text.splitlines()]

    merged_lines: List[str] = []
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s in {"〈", "《"} and i + 2 < len(lines):
            mid = lines[i + 1].strip()
            s2 = lines[i + 2].strip()
            if s2 in {"〉", "》"} and mid and len(mid) <= 50:
                merged_lines.append(f"{s}{mid}{s2}")
                i += 3
                continue
        merged_lines.append(lines[i])
        i += 1

    text = "\n".join(merged_lines)
    text = re.sub(r"【[^】]{0,10}】", "", text)
    text = re.sub(r"\[\d+\]", "", text)

    cleaned_lines: List[str] = []
    blank = 0
    for ln in text.splitlines():
        if ln.strip():
            cleaned_lines.append(ln.rstrip())
            blank = 0
        else:
            blank += 1
            if blank <= 2:
                cleaned_lines.append("")
    return "\n".join(cleaned_lines).strip()


def safe_filename(name: str) -> str:
    """Windows-safe path component (keeps CJK, removes forbidden chars)."""
    name = name.strip()
    return re.sub(r'[\\/:*?"<>|]', "_", name)


# -----------------------------
# Ordering / TOC heuristics
# -----------------------------

CHINESE_NUMERALS = {
    "零": 0, "〇": 0,
    "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
    "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
}


def chinese_numeral_to_int(s: str) -> Optional[int]:
    s = s.strip()
    if re.fullmatch(r"\d+", s):
        try:
            return int(s)
        except ValueError:
            return None
    if s in CHINESE_NUMERALS:
        return CHINESE_NUMERALS[s]
    m = re.fullmatch(r"十([一二三四五六七八九])", s)
    if m:
        return 10 + CHINESE_NUMERALS[m.group(1)]
    m = re.fullmatch(r"([一二三四五六七八九])十([一二三四五六七八九])", s)
    if m:
        return CHINESE_NUMERALS[m.group(1)] * 10 + CHINESE_NUMERALS[m.group(2)]
    m = re.fullmatch(r"([一二三四五六七八九])十", s)
    if m:
        return CHINESE_NUMERALS[m.group(1)] * 10
    if s == "十":
        return 10
    return None


def juan_sort_key(full_title: str) -> Tuple[int, int, str]:
    t = full_title.strip()
    last = t.split("/", 1)[-1]

    m = re.search(r"卷([一二三四五六七八九十〇零\d]+)", last)
    if m:
        num = chinese_numeral_to_int(m.group(1)) or 9999
        return (0, num, t)

    m = re.search(r"第0*([0-9]+)卷", last)
    if m:
        return (0, int(m.group(1)), t)

    if "卷上" in last:
        return (0, 1, t)
    if "卷中" in last:
        return (0, 2, t)
    if "卷下" in last:
        return (0, 3, t)

    return (1, 9999, t)


def discover_parts_from_toc_html(work_title: str, *, sleep: float) -> List[str]:
    html = fetch_html(work_title, sleep=sleep)
    if not html:
        return []

    soup = BeautifulSoup(html, "html.parser")
    body = soup.find("div", class_="mw-parser-output") or soup

    prefix = work_title + "/"
    ordered: List[str] = []
    seen: set[str] = set()

    for li in body.select("ol li, ul li"):
        for a in li.select("a[title]"):
            t = a.get("title") or ""
            if not t:
                continue
            if not title_is_content_page(t):
                continue
            if t.startswith(prefix):
                if t not in seen:
                    ordered.append(t)
                    seen.add(t)

    if len(ordered) >= 2:
        return ordered

    return []


def discover_parts_via_parse_links(work_title: str, pageid: int, *, sleep: float) -> List[str]:
    prefix = work_title + "/"
    links = fetch_links(pageid, sleep=sleep)
    parts = [t for t in links if t.startswith(prefix)]
    return sorted(set(parts), key=juan_sort_key)


def discover_parts_via_allpages_prefix(work_title: str, *, sleep: float) -> List[str]:
    prefix = work_title + "/"
    parts: List[str] = []
    gapcontinue: Optional[str] = None
    while True:
        params: Dict[str, Any] = {
            "action": "query",
            "generator": "allpages",
            "gapnamespace": 0,
            "gapprefix": prefix,
            "gaplimit": "max",
            "formatversion": "2",
        }
        if gapcontinue:
            params["gapcontinue"] = gapcontinue
        data = safe_request(params, sleep=sleep)
        pages = (data.get("query") or {}).get("pages") or []
        for pg in pages:
            t = pg.get("title", "")
            if t.startswith(prefix):
                parts.append(t)
        gapcontinue = (data.get("continue") or {}).get("gapcontinue")
        if not gapcontinue:
            break
    return sorted(set(parts), key=juan_sort_key)


def discover_work_parts(work_title: str, *, sleep: float) -> List[str]:
    pid = get_pageid(work_title, sleep=sleep)
    if pid is None:
        return []

    toc_parts = discover_parts_from_toc_html(work_title, sleep=sleep)
    if toc_parts:
        return toc_parts

    parts = discover_parts_via_parse_links(work_title, pid, sleep=sleep)
    if parts:
        return parts

    parts = discover_parts_via_allpages_prefix(work_title, sleep=sleep)
    if parts:
        return parts

    return [work_title]


# -----------------------------
# Section-only discovery + era divider support
# -----------------------------

def _heading_level(tag: Tag) -> Optional[int]:
    if not isinstance(tag, Tag) or not tag.name:
        return None
    m = re.fullmatch(r"h([1-6])", tag.name.lower())
    if not m:
        return None
    return int(m.group(1))


def _norm(s: str) -> str:
    s = (s or "").replace("\xa0", " ")
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def is_editsection_link(a: Tag) -> bool:
    if not isinstance(a, Tag):
        return False
    if a.find_parent(class_="mw-editsection") is not None:
        return True
    href = a.get("href") or ""
    if "action=edit" in href and "section=" in href:
        return True
    title = (a.get("title") or "").strip()
    if title.startswith(("编辑章节", "編輯章節", "Edit section")):
        return True
    return False


_YEAR_RE = re.compile(r"(18\d{2}|19\d{2}|20\d{2})")


def _extract_year_from_text(s: str) -> Optional[int]:
    """
    Pull a 4-digit year from the surrounding list item text, if present.
    This is how we split 梁啟超 into 清/民國 without touching metadata.
    """
    s = s or ""
    m = _YEAR_RE.search(s)
    if not m:
        return None
    try:
        return int(m.group(1))
    except ValueError:
        return None


@dataclass
class WorkRef:
    title: str
    year: Optional[int] = None


def discover_works_from_author_section(author_title: str, section_name: str, *, sleep: float) -> List[WorkRef]:
    """
    Discover works ONLY from a specific heading section on the Author page.
    Also tries to capture a year from the list item text for era-divider use.

    IMPORTANT DETAIL:
    On Wikisource, headings are often wrapped like:
      <div class="mw-heading"><h2>...</h2><span class="mw-editsection">...</span></div>
    The section content is a sibling of the *mw-heading div*, not a sibling of the h2.
    So we anchor on the wrapper div when present.
    """
    html = fetch_html(author_title, sleep=sleep)
    if not html:
        return []

    soup = BeautifulSoup(html, "html.parser")
    body = soup.find("div", class_="mw-parser-output") or soup

    wanted = _norm(section_name)

    found_h: Optional[Tag] = None
    for h in body.find_all(re.compile(r"^h[1-6]$")):
        if _norm(h.get_text(" ", strip=True)) == wanted:
            found_h = h
            break

    if found_h is None:
        print(f"!! Could not find section heading '{section_name}' on {author_title}", file=sys.stderr)
        return []

    # Anchor on wrapper div if present (this is the core fix)
    anchor: Tag = found_h
    parent = found_h.parent
    if isinstance(parent, Tag) and parent.name == "div" and "mw-heading" in (parent.get("class") or []):
        anchor = parent

    start_level = _heading_level(found_h) or 2

    works: List[WorkRef] = []
    seen: set[str] = set()

    for sib in anchor.next_siblings:
        if not isinstance(sib, Tag):
            continue

        # Stop when we hit the next heading of same or higher level
        # (usually another div.mw-heading that contains an h2/h3...)
        for h in sib.find_all(re.compile(r"^h[1-6]$"), recursive=True):
            lvl = _heading_level(h)
            if lvl is not None and lvl <= start_level:
                return works

        # We want list items because the year is usually in the li text.
        for li in sib.select("li"):
            li_text = li.get_text(" ", strip=True)
            li_year = _extract_year_from_text(li_text)

            for a in li.select("a[title]"):
                if is_editsection_link(a):
                    continue
                t = (a.get("title") or "").strip()
                if not t:
                    continue
                if not title_is_content_page(t):
                    continue
                if t.startswith("Author:") or t.startswith("作者:"):
                    continue
                if t not in seen:
                    works.append(WorkRef(title=t, year=li_year))
                    seen.add(t)

    return works


def era_folder_for_year(year: Optional[int], mode: Optional[str]) -> Optional[str]:
    """
    mode == 'qing_roc' -> return 清 / 民國 / 未詳
    """
    if mode is None:
        return None
    if mode != "qing_roc":
        return None
    if year is None:
        return "未詳"
    return "民國" if year >= ROC_START_YEAR else "清"


# -----------------------------
# Scraping orchestration
# -----------------------------

@dataclass
class SaveConfig:
    base_out: Path
    sleep: float
    skip_existing_from: List[str]
    test: bool = False
    max_works: Optional[int] = None
    max_parts_per_work: Optional[int] = None
    author_section: Optional[str] = None
    era_divider: Optional[str] = None  # e.g. qing_roc


def ensure_dir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def write_text(path: Path, content: str) -> None:
    ensure_dir(path.parent)
    path.write_text(content, encoding="utf-8")


def build_header(meta: Dict[str, str]) -> str:
    """
    Build a metadata header '# KEY: value' — this is the format you rely on.
    We keep it exactly.
    """
    lines = []
    for k, v in meta.items():
        if v is None:
            continue
        v2 = str(v).strip()
        if v2 == "":
            continue
        lines.append(f"# {k}: {v2}")
    return "\n".join(lines) + "\n\n"


def scrape_one_page(
    page_title: str,
    *,
    out_raw_path: Path,
    out_clean_path: Path,
    meta: Dict[str, str],
    sleep: float,
) -> Tuple[int, int]:
    """Fetch -> extract text -> write RAW and CLEAN with identical headers."""
    html = fetch_html(page_title, sleep=sleep)
    raw_body = extract_visible_text_from_html(html) if html else ""
    clean_body = clean_text_for_corpus(raw_body) if raw_body else ""

    header = build_header(meta)
    write_text(out_raw_path, header + raw_body)
    write_text(out_clean_path, header + clean_body)

    return len(raw_body), len(clean_body)


def discover_works_from_author(author_title: str, *, sleep: float) -> List[str]:
    """
    Prefer Category:<name> if it exists (usually the most complete).
    Fallback: parse HTML and collect mainspace links from list items.
    """
    name = author_title.split(":", 1)[-1].strip()
    cat_title = f"Category:{name}"

    data = safe_request(
        {
            "action": "query",
            "list": "categorymembers",
            "cmtitle": cat_title,
            "cmnamespace": 0,
            "cmlimit": "max",
            "formatversion": "2",
        },
        sleep=sleep,
    )
    members = (data.get("query") or {}).get("categorymembers") or []
    if members:
        works = []
        for m in members:
            t = m.get("title", "")
            if not t:
                continue
            if t.startswith("Author:") or t.startswith("作者:"):
                continue
            if title_is_content_page(t):
                works.append(t)
        return sorted(set(works))

    html = fetch_html(author_title, sleep=sleep)
    if not html:
        return []

    soup = BeautifulSoup(html, "html.parser")
    body = soup.find("div", class_="mw-parser-output") or soup

    works: List[str] = []
    seen: set[str] = set()
    for li in body.select("ol li, ul li"):
        for a in li.select("a[title]"):
            if is_editsection_link(a):
                continue
            t = (a.get("title") or "").strip()
            if not t:
                continue
            if not title_is_content_page(t):
                continue
            if t.startswith("Author:") or t.startswith("作者:"):
                continue
            if t not in seen:
                works.append(t)
                seen.add(t)
    return works


def scrape_author(author_title_or_url: str, cfg: SaveConfig) -> None:
    author_title = resolve_title(author_title_or_url)
    if not (author_title.startswith("Author:") or author_title.startswith("作者:")):
        print(f"!! Warning: '{author_title}' doesn't look like an Author: page. Continuing anyway.")

    author_name = author_title.split(":", 1)[-1].strip()
    author_dir = safe_filename(author_name)

    # Discover works
    work_refs: List[WorkRef] = []
    if cfg.author_section:
        work_refs = discover_works_from_author_section(author_title, cfg.author_section, sleep=cfg.sleep)
    else:
        work_refs = [WorkRef(title=t) for t in discover_works_from_author(author_title, sleep=cfg.sleep)]

    if cfg.test and cfg.max_works is not None:
        work_refs = work_refs[: cfg.max_works]

    # Print header
    print(f"Author page: {author_title}")
    if cfg.author_section:
        print(f"Section:    {cfg.author_section}")
    if cfg.era_divider == "qing_roc":
        print(f"Era divider: 清 (<{ROC_START_YEAR}) / 民國 (≥{ROC_START_YEAR}) / 未詳")
    print(f"Resolved works: {len(work_refs)}")

    # We no longer use the old "existing_ids" heuristic here, because with era
    # folders it becomes ambiguous. We instead skip based on exact target path existence.
    print()

    for wi, wr in enumerate(work_refs, start=1):
        work_title = wr.title
        work_id = safe_filename(work_title)

        era_folder = era_folder_for_year(wr.year, cfg.era_divider)
        raw_root = cfg.base_out / "raw" / author_dir
        clean_root = cfg.base_out / "clean" / author_dir
        if era_folder:
            raw_root = raw_root / era_folder
            clean_root = clean_root / era_folder

        ensure_dir(raw_root)
        ensure_dir(clean_root)

        print(f"== [{wi}/{len(work_refs)}] Work: {work_title} ==")
        if era_folder:
            yr = wr.year if wr.year is not None else "unknown"
            print(f"  -> era folder: {era_folder} (year={yr})")

        # Work folder per base title (this is what your annotation pipeline needs)
        work_raw_dir = raw_root / work_id
        work_clean_dir = clean_root / work_id

        # Skip if already scraped (either side exists)
        if work_raw_dir.exists() or work_clean_dir.exists():
            print("  !! Skipping: work folder already exists")
            continue

        ensure_dir(work_raw_dir)
        ensure_dir(work_clean_dir)

        parts = discover_work_parts(work_title, sleep=cfg.sleep)
        if cfg.test and cfg.max_parts_per_work is not None:
            parts = parts[: cfg.max_parts_per_work]

        print(f"  Parts/pages: {len(parts)}")

        for pi, page_title in enumerate(parts, start=1):
            print(f"    [{pi}/{len(parts)}] {page_title}")

            cats = fetch_categories(page_title, sleep=cfg.sleep)
            cat_str = ";".join(cats)

            # IMPORTANT: metadata preserved in your exact old format
            meta = {
                "AUTHOR": author_name,
                "AUTHOR_PAGE": author_title,
                "WORK_BASE_TITLE": work_title,
                "PAGE_TITLE": page_title,
                "WS_CATEGORIES": cat_str,
            }

            fname = f"{safe_filename(work_title)}__juan_{pi:02d}.txt"
            out_raw = work_raw_dir / fname
            out_clean = work_clean_dir / fname

            try:
                cr, cc = scrape_one_page(
                    page_title,
                    out_raw_path=out_raw,
                    out_clean_path=out_clean,
                    meta=meta,
                    sleep=cfg.sleep,
                )
                print(f"      -> wrote {fname} (raw {cr} chars, clean {cc} chars)")
            except Exception as e:
                print(f"      !! Error scraping {page_title}: {e}", file=sys.stderr)


# -----------------------------
# Corpus enrichment (categories)
# -----------------------------

HEADER_LINE_RE = re.compile(r"^#\s*([A-Z0-9_]+)\s*:\s*(.*)\s*$")


def parse_header(text: str) -> Tuple[Dict[str, str], str]:
    """Split into (header_dict, body_text)."""
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
        key, val = m.group(1), m.group(2)
        meta[key] = val

    body = "\n".join(lines[body_start:]) if body_start < len(lines) else ""
    return meta, body


def rebuild_file(meta: Dict[str, str], body: str) -> str:
    header = build_header(meta)
    return header + body.lstrip("\n")


def enrich_categories(corpus_root: str, *, sleep: float, promote_category_to_nation: bool) -> None:
    """
    Walk .txt files; for each:
      - read # PAGE_TITLE
      - query WS categories
      - write/replace # WS_CATEGORIES
      - optionally promote CATEGORY->NATION by path heuristic
    """
    root = Path(corpus_root).expanduser().resolve()
    if not root.exists():
        raise SystemExit(f"Corpus root does not exist: {root}")

    txt_files = list(root.rglob("*.txt"))
    print(f"Found {len(txt_files)} .txt files under {root}")

    updated = 0
    skipped = 0

    for p in txt_files:
        try:
            text = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = p.read_text(encoding="utf-8", errors="replace")

        meta, body = parse_header(text)
        page_title = meta.get("PAGE_TITLE", "").strip()
        if not page_title:
            skipped += 1
            continue

        cats = fetch_categories(page_title, sleep=sleep)
        meta["WS_CATEGORIES"] = ";".join(cats)

        if promote_category_to_nation:
            rel_parts = p.relative_to(root).parts
            try:
                idx = rel_parts.index("raw")
            except ValueError:
                try:
                    idx = rel_parts.index("clean")
                except ValueError:
                    idx = -1
            if idx != -1 and idx + 1 < len(rel_parts):
                first_dir = rel_parts[idx + 1]
                cat = (meta.get("CATEGORY") or "").strip()
                if cat and cat == first_dir:
                    meta["NATION"] = first_dir

        new_text = rebuild_file(meta, body)
        if new_text != text:
            p.write_text(new_text, encoding="utf-8")
            updated += 1

    print(f"Done. Updated {updated} files. Skipped {skipped} files (no PAGE_TITLE).")


# -----------------------------
# CLI
# -----------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="Unified zh.wikisource author/work scraper + category enricher.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    ap_a = sub.add_parser("scrape-author", help="Scrape an Author: page into per-work folders.")
    ap_a.add_argument("author", help="Author: title or URL (e.g. 作者:梁啟超)")
    ap_a.add_argument("out", help="Output folder (will create raw/ and clean/ under it)")
    ap_a.add_argument("--sleep", type=float, default=0.5, help="Seconds between requests")
    ap_a.add_argument("--skip-existing-from", action="append", default=[], help="(kept for compatibility; unused in era mode)")
    ap_a.add_argument("--section", type=str, default=None, help="Only scrape works listed under a specific heading (e.g. 文).")
    ap_a.add_argument("--era-divider", type=str, default=None, choices=["qing_roc"],
                      help="Split output into era folders based on year in the author list (qing_roc uses 1912).")
    ap_a.add_argument("--test", action="store_true", help="Test mode (limit works/parts)")
    ap_a.add_argument("--max-works", type=int, default=5, help="Test mode: max works")
    ap_a.add_argument("--max-parts", type=int, default=10, help="Test mode: max parts per work")

    ap_e = sub.add_parser("enrich-categories", help="Add/refresh # WS_CATEGORIES in an existing corpus.")
    ap_e.add_argument("corpus_root", help="Root folder containing your .txt corpus")
    ap_e.add_argument("--sleep", type=float, default=0.5, help="Seconds between requests")
    ap_e.add_argument("--promote-category-to-nation", action="store_true",
                      help="If path is .../(raw|clean)/X/... and # CATEGORY: X, also set # NATION: X")

    args = ap.parse_args()

    if args.cmd == "scrape-author":
        cfg = SaveConfig(
            base_out=Path(args.out).expanduser().resolve(),
            sleep=float(args.sleep),
            skip_existing_from=list(args.skip_existing_from),
            test=bool(args.test),
            max_works=int(args.max_works) if args.test else None,
            max_parts_per_work=int(args.max_parts) if args.test else None,
            author_section=(args.section.strip() if args.section else None),
            era_divider=args.era_divider,
        )
        ensure_dir(cfg.base_out)
        scrape_author(args.author, cfg)
        return

    if args.cmd == "enrich-categories":
        enrich_categories(
            args.corpus_root,
            sleep=float(args.sleep),
            promote_category_to_nation=bool(args.promote_category_to_nation),
        )
        return


if __name__ == "__main__":
    main()
