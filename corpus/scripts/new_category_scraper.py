#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wikisource_category_scraper_vietnam_ready.py

A safer zh.wikisource category scraper for Fanya Hanwen Corpus staging.

Designed after the Japan rescrape fixes:
- category pages can be scraped directly, e.g. Category:後黎朝
- optional recursive category traversal for bigger buckets, e.g. Category:越南
- narrow corpus header only; no invented SUBJECT/SOURCE/etc.
- NATION is explicit: supplied by --nation, or by --nation-from-category
- CATEGORIES comes from source category labels unless overridden
- WS_CATEGORIES is fetched from Wikisource page categories
- clean text is extracted from rendered HTML with inline flow preserved
- Wikisource header/navigation/table furniture is removed before text extraction
- empty / failed pages are skipped, not written as blank corpus files
- optional Wenyan scorer hook writes a CSV audit without changing metadata

Dependencies:
  pip install requests beautifulsoup4

Useful examples:

  # Test scrape the direct 後黎朝 category.
  python wikisource_category_scraper_vietnam_ready.py \
    "後黎朝" \
    "./vietnam_category_review" \
    --nation-from-category \
    --test --max-works 5 --max-parts-per-work 2

  # Full direct scrape of 後黎朝.
  python wikisource_category_scraper_vietnam_ready.py \
    "後黎朝" \
    "./vietnam_category_review" \
    --nation-from-category \
    --overwrite

  # Scrape several targeted Vietnamese categories into one review output.
  python wikisource_category_scraper_vietnam_ready.py \
    "後黎朝" "阮朝" "越南漢喃銘文" "越南皇帝詔書" "越南典籍" \
    "./vietnam_category_review" \
    --test --max-works 10 --max-parts-per-work 3

  # Broad recursive crawl from 越南, with scoring only.
  python wikisource_category_scraper_vietnam_ready.py \
    "越南" \
    "./vietnam_full_category_review" \
    --recursive --max-depth 2 \
    --exclude-category-regex "越南战争|河内|越南作者" \
    --wenyan \
    --test --max-works 30 --max-parts-per-work 3

The final positional argument is always the output directory. Every earlier
positional argument is treated as a source category.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple
from urllib.parse import quote, unquote, urlparse

import requests
from bs4 import BeautifulSoup, NavigableString, Tag

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusScraper/2.0 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

VERSION = "v1-vietnam-ready-category-scraper-2026-06-04"

# Keep the file header schema narrow and explicit.
HEADER_KEYS = [
    "WORK_TITLE",
    "DISPLAY_TITLE",
    "PAGE_TITLE",
    "AUTHOR",
    "NATION",
    "CATEGORIES",
    "YEAR",
    "CHAPTER",
    "SOURCE_URL",
    "WS_CATEGORIES",
    "SCRAPED_AT_UTC",
]

PD_MARKERS = [
    "本作品在全世界都属于",
    "本作品在全世界都屬於",
    "此作品在全世界都属于",
    "此作品在全世界都屬於",
    "本作品在美国属于",
    "本作品在美國屬於",
    "Public domain Public domain false false",
    "Public domain",
]

# Real block elements. Inline elements are kept inline so titles like 《山海經》
# do not explode into 《\n山海經\n》.
BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "body", "center", "dd", "details",
    "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2",
    "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
    "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
}

DROP_CLASSES = {
    "mw-editsection", "references", "reference", "mw-navigation", "navbox", "toc",
    "catlinks", "printfooter", "licenseContainer", "ws-noexport", "noprint",
}

BRACKET_PAIRS_STRONG = [
    ("《", "》"),
    ("〈", "〉"),
    ("「", "」"),
    ("『", "』"),
]

INLINE_PUNCT_ONLY_RE = re.compile(r"^[，、。；：？！）》〉」』）]+$")

DISALLOWED_NS_PREFIXES = (
    "Author:", "作者:", "Category:", "分類:", "Help:", "Portal:", "Wikisource:",
    "MediaWiki:", "File:", "Image:", "Template:", "Talk:", "User:", "Special:",
)

CHINESE_DIGITS = {
    "零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "两": 2, "三": 3, "四": 4,
    "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
}

_session = requests.Session()


# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------


def unique_preserve_order(items: Iterable[str]) -> List[str]:
    seen: Set[str] = set()
    out: List[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def safe_filename(name: str, max_len: int = 120) -> str:
    name = (name or "").strip()
    name = re.sub(r"[\\/:*?\"<>|]", "_", name)
    name = re.sub(r"\s+", " ", name).strip()
    # Windows path kindness. Keep CJK intact, only trim very long components.
    if len(name) > max_len:
        name = name[:max_len].rstrip()
    return name or "untitled"


def title_to_wikisource_url(title: str) -> str:
    return "https://zh.wikisource.org/wiki/" + quote(title, safe="")


def normalize_category_title(raw: str) -> str:
    """Accept Category:後黎朝, https://..., or just 後黎朝."""
    s = (raw or "").strip()
    if s.startswith("http://") or s.startswith("https://"):
        u = urlparse(s)
        parts = [p for p in (u.path or "").split("/") if p]
        if parts and parts[0] == "wiki":
            s = unquote("/".join(parts[1:]))
        elif len(parts) >= 2:
            s = unquote("/".join(parts[1:]))
        elif parts:
            s = unquote(parts[0])
    if s.startswith("分類:"):
        s = "Category:" + s.split(":", 1)[1]
    if not s.startswith("Category:"):
        s = "Category:" + s
    return s


def category_label(cat_title: str) -> str:
    cat_title = normalize_category_title(cat_title)
    return cat_title.split(":", 1)[1]


def title_is_content_page(title: str) -> bool:
    t = (title or "").strip()
    if not t:
        return False
    if t.startswith(("编辑章节", "編輯章節", "Edit section")):
        return False
    for pref in DISALLOWED_NS_PREFIXES:
        if t.startswith(pref):
            return False
    if ":" in t:
        return False
    return True


def get_base_title(title: str) -> str:
    """
    Work-level grouping.

    Examples:
      藍山實錄/卷一 -> 藍山實錄
      題雲水亭八景帖·曠野行人 -> 題雲水亭八景帖
    """
    base = title.split("/", 1)[0]
    base = base.split("·", 1)[0]
    return base.strip()


def chapter_label_from_title(root_title: str, page_title: str) -> str:
    if page_title == root_title:
        return "root"
    if page_title.startswith(root_title + "/"):
        return page_title[len(root_title) + 1:]
    return page_title


# ---------------------------------------------------------------------------
# MediaWiki API helpers
# ---------------------------------------------------------------------------


def api_get(params: Dict[str, Any], *, sleep: float, retries: int = 3) -> Dict[str, Any]:
    params = dict(params)
    params.setdefault("format", "json")
    params.setdefault("formatversion", "2")

    last_error: Optional[Exception] = None
    for attempt in range(1, retries + 1):
        try:
            time.sleep(sleep)
            r = _session.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=45)
            r.raise_for_status()
            data = r.json()
            if "error" in data:
                raise RuntimeError(str(data["error"]))
            return data
        except Exception as exc:
            last_error = exc
            print(f"[warn] API request failed attempt {attempt}/{retries}: {exc}", file=sys.stderr)
            time.sleep(min(2.0, 0.4 * attempt))
    print(f"[error] API request failed after retries: {last_error}", file=sys.stderr)
    return {}


def api_text_value(node: Any) -> str:
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if isinstance(node, dict):
        return str(node.get("*") or node.get("value") or node.get("html") or node.get("wikitext") or "")
    return str(node or "")


def resolve_redirect_title(title: str, *, sleep: float) -> Optional[str]:
    data = api_get({"action": "query", "titles": title, "redirects": "1"}, sleep=sleep)
    pages = (data.get("query") or {}).get("pages") or []
    if not pages:
        return None
    pg = pages[0]
    if "missing" in pg:
        return None
    redirects = (data.get("query") or {}).get("redirects") or []
    if redirects:
        return redirects[-1].get("to") or title
    return pg.get("title") or title


def fetch_html(title: str, *, sleep: float) -> str:
    resolved = resolve_redirect_title(title, sleep=sleep)
    if resolved is None:
        return ""
    data = api_get(
        {
            "action": "parse",
            "page": resolved,
            "prop": "text",
            "disablelimitreport": 1,
            "disableeditsection": 1,
            "disabletoc": 1,
        },
        sleep=sleep,
    )
    parse = data.get("parse") or {}
    return api_text_value(parse.get("text"))


def fetch_wikitext(title: str, *, sleep: float) -> str:
    resolved = resolve_redirect_title(title, sleep=sleep)
    if resolved is None:
        return ""
    data = api_get({"action": "parse", "page": resolved, "prop": "wikitext"}, sleep=sleep)
    parse = data.get("parse") or {}
    return api_text_value(parse.get("wikitext"))


def fetch_links(title_or_pageid: str | int, *, sleep: float) -> List[str]:
    params: Dict[str, Any] = {"action": "parse", "prop": "links"}
    if isinstance(title_or_pageid, int):
        params["pageid"] = title_or_pageid
    else:
        params["page"] = title_or_pageid
    data = api_get(params, sleep=sleep)
    parse = data.get("parse") or {}
    links = parse.get("links") or []
    out: List[str] = []
    for lk in links:
        if not isinstance(lk, dict):
            continue
        t = lk.get("title") or lk.get("*")
        if t:
            out.append(str(t))
    return unique_preserve_order(out)


def fetch_categories(title: str, *, sleep: float) -> List[str]:
    resolved = resolve_redirect_title(title, sleep=sleep)
    if resolved is None:
        return []

    out: List[str] = []
    cont: Dict[str, Any] = {}
    while True:
        params: Dict[str, Any] = {
            "action": "query",
            "prop": "categories",
            "titles": resolved,
            "cllimit": "max",
            "clshow": "!hidden",
        }
        params.update(cont)
        data = api_get(params, sleep=sleep)
        pages = (data.get("query") or {}).get("pages") or []
        for pg in pages:
            if "missing" in pg:
                continue
            for c in pg.get("categories") or []:
                name = c.get("title", "")
                if name.startswith("Category:"):
                    name = name.split(":", 1)[1]
                if name:
                    out.append(name)
        nxt = data.get("continue") or {}
        if not nxt:
            break
        cont = nxt
    return unique_preserve_order(out)


def fetch_page_categories_with_root_fallback(page_title: str, root_title: str, *, sleep: float) -> Tuple[List[str], str]:
    page_cats = fetch_categories(page_title, sleep=sleep)
    root_cats: List[str] = []
    if root_title != page_title:
        root_cats = fetch_categories(root_title, sleep=sleep)
    if page_cats and root_cats:
        return unique_preserve_order(page_cats + root_cats), "page_plus_root"
    if page_cats:
        return page_cats, "page"
    if root_cats:
        return root_cats, "root_fallback"
    return [], "none"


# ---------------------------------------------------------------------------
# Category discovery
# ---------------------------------------------------------------------------


@dataclass
class PageHit:
    title: str
    pageid: Optional[int] = None
    source_categories: List[str] = field(default_factory=list)
    category_path: List[str] = field(default_factory=list)


def category_members(cat_title: str, *, sleep: float, cmtype: str = "page|subcat") -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Return (pages, subcats) for one category."""
    cat_title = normalize_category_title(cat_title)
    pages: List[Dict[str, Any]] = []
    subcats: List[Dict[str, Any]] = []
    cont: Dict[str, Any] = {}

    while True:
        params: Dict[str, Any] = {
            "action": "query",
            "list": "categorymembers",
            "cmtitle": cat_title,
            "cmlimit": "max",
            "cmtype": cmtype,
        }
        params.update(cont)
        data = api_get(params, sleep=sleep)
        for cm in (data.get("query") or {}).get("categorymembers") or []:
            ns = cm.get("ns")
            if ns == 0:
                pages.append(cm)
            elif ns == 14:
                subcats.append(cm)
        nxt = data.get("continue") or {}
        if not nxt:
            break
        cont = nxt
    return pages, subcats


def discover_category_tree(
    root_categories: Sequence[str],
    *,
    sleep: float,
    recursive: bool,
    max_depth: int,
    exclude_category_regex: Optional[str],
) -> List[PageHit]:
    """Collect pages from one or more categories, optionally following subcategories."""
    exclude_rx = re.compile(exclude_category_regex) if exclude_category_regex else None
    queue: List[Tuple[str, List[str], int]] = []
    for cat in root_categories:
        norm = normalize_category_title(cat)
        queue.append((norm, [category_label(norm)], 0))

    visited_cats: Set[str] = set()
    by_title: Dict[str, PageHit] = {}

    while queue:
        cat_title, path, depth = queue.pop(0)
        if cat_title in visited_cats:
            continue
        visited_cats.add(cat_title)

        label = category_label(cat_title)
        if exclude_rx and exclude_rx.search(label):
            print(f"[skip-category] {label}")
            continue

        print(f"[category] {label} depth={depth}")
        pages, subcats = category_members(cat_title, sleep=sleep)
        print(f"  pages={len(pages)} subcats={len(subcats)}")

        for pg in pages:
            title = pg.get("title") or ""
            if not title_is_content_page(title):
                continue
            hit = by_title.get(title)
            if hit is None:
                hit = PageHit(title=title, pageid=pg.get("pageid"), source_categories=[], category_path=[])
                by_title[title] = hit
            hit.source_categories = unique_preserve_order(hit.source_categories + [label])
            # Keep the shortest/deepest useful source path visible for audit.
            if not hit.category_path or len(path) > len(hit.category_path):
                hit.category_path = list(path)

        if recursive and depth < max_depth:
            for sc in subcats:
                sc_title = sc.get("title") or ""
                if not sc_title:
                    continue
                sc_label = category_label(sc_title)
                if exclude_rx and exclude_rx.search(sc_label):
                    print(f"  [skip-subcat] {sc_label}")
                    continue
                queue.append((sc_title, path + [sc_label], depth + 1))

    return sorted(by_title.values(), key=lambda h: h.title)


# ---------------------------------------------------------------------------
# Chapter discovery and sorting
# ---------------------------------------------------------------------------


def chinese_num_to_int(raw: str) -> Optional[int]:
    raw = raw.strip().replace("第", "").replace("卷", "")
    if not raw:
        return None
    if raw.isdigit():
        return int(raw)

    total = 0
    current = 0
    for ch in raw:
        if ch in CHINESE_DIGITS:
            current = CHINESE_DIGITS[ch]
        elif ch == "十":
            if current == 0:
                current = 1
            total += current * 10
            current = 0
        elif ch == "百":
            if current == 0:
                current = 1
            total += current * 100
            current = 0
        else:
            return None
    total += current
    return total if total > 0 else None


def chapter_sort_key(root_title: str, page_title: str) -> Tuple[int, int, str]:
    label = chapter_label_from_title(root_title, page_title)
    last = label.split("/")[-1]
    if page_title == root_title:
        return (0, 0, label)

    front_order = {"序": 1, "敘": 1, "原序": 2, "自序": 2, "凡例": 3, "目錄": 4, "目录": 4}
    if last in front_order:
        return (1, front_order[last], label)

    m = re.search(r"(?:第)?卷\s*([0-9]+|[零〇一二三四五六七八九十百兩两]+)", last)
    if not m:
        m = re.search(r"第\s*([0-9]+|[零〇一二三四五六七八九十百兩两]+)\s*卷", last)
    if m:
        n = chinese_num_to_int(m.group(1))
        if n is not None:
            return (2, n, label)

    if "附錄" in last or "附录" in last:
        return (3, 0, label)
    if "後序" in last or "后序" in last or last == "跋":
        return (4, 0, label)
    return (9, 0, label)


def discover_subpages_from_root_html(root_title: str, *, sleep: float) -> List[str]:
    html = fetch_html(root_title, sleep=sleep)
    if not html:
        return []
    soup = BeautifulSoup(html, "html.parser")
    body = soup.find("div", class_="mw-parser-output") or soup
    prefix = root_title + "/"
    out: List[str] = []
    for a in body.select("a[title]"):
        t = a.get("title") or ""
        if t.startswith(prefix) and title_is_content_page(t):
            out.append(t)
    return unique_preserve_order(out)


def discover_subpages_via_parse_links(root_title: str, *, sleep: float) -> List[str]:
    prefix = root_title + "/"
    return [t for t in fetch_links(root_title, sleep=sleep) if t.startswith(prefix) and title_is_content_page(t)]


def discover_subpages_via_allpages(root_title: str, *, sleep: float) -> List[str]:
    prefix = root_title + "/"
    out: List[str] = []
    cont: Dict[str, Any] = {}
    while True:
        params: Dict[str, Any] = {
            "action": "query",
            "list": "allpages",
            "apnamespace": 0,
            "apprefix": prefix,
            "aplimit": "max",
        }
        params.update(cont)
        data = api_get(params, sleep=sleep)
        for pg in (data.get("query") or {}).get("allpages") or []:
            t = pg.get("title") or ""
            if t.startswith(prefix):
                out.append(t)
        nxt = data.get("continue") or {}
        if not nxt:
            break
        cont = nxt
    return unique_preserve_order(out)


def choose_parts_for_work(
    root_title: str,
    explicit_pages: List[str],
    *,
    sleep: float,
    include_root_for_multi: bool,
    discover_subpages: bool,
    discovery: str,
) -> List[str]:
    """Pick the actual page titles to scrape for one grouped work."""
    explicit_unique = unique_preserve_order(explicit_pages)
    root_present = root_title in explicit_unique
    child_pages = [p for p in explicit_unique if p != root_title]

    parts: List[str] = []

    # If the category explicitly listed children, trust that list.
    if child_pages:
        if include_root_for_multi and root_present:
            parts.append(root_title)
        parts.extend(child_pages)
    else:
        # Single root page: try to discover parts if requested.
        discovered: List[str] = []
        if discover_subpages:
            if discovery in {"html", "both"}:
                discovered.extend(discover_subpages_from_root_html(root_title, sleep=sleep))
            if discovery in {"links", "both"}:
                discovered.extend(discover_subpages_via_parse_links(root_title, sleep=sleep))
            if discovery in {"allpages"}:
                discovered.extend(discover_subpages_via_allpages(root_title, sleep=sleep))
        discovered = unique_preserve_order(discovered)
        if discovered:
            if include_root_for_multi and root_present:
                parts.append(root_title)
            parts.extend(discovered)
        else:
            parts.append(root_title)

    parts = [p for p in unique_preserve_order(parts) if p == root_title or p.startswith(root_title + "/") or p in explicit_unique]
    return sorted(parts, key=lambda t: chapter_sort_key(root_title, t))


# ---------------------------------------------------------------------------
# Cleaning
# ---------------------------------------------------------------------------


def fix_brackets_strong(text: str, open_br: str, close_br: str) -> str:
    pattern = re.compile(re.escape(open_br) + r"(.*?)" + re.escape(close_br), re.DOTALL)

    def repl(m: re.Match[str]) -> str:
        inner = re.sub(r"[ \t\r\n]+", "", m.group(1))
        return f"{open_br}{inner}{close_br}"

    return pattern.sub(repl, text)


def apply_strong_bracket_fixes(text: str) -> str:
    for o, c in BRACKET_PAIRS_STRONG:
        text = fix_brackets_strong(text, o, c)
    return text


def repair_inline_punctuation_lines(text: str) -> str:
    lines = text.splitlines()
    out: List[str] = []
    i = 0
    while i < len(lines):
        cur = lines[i]
        stripped = cur.strip()
        if stripped and INLINE_PUNCT_ONLY_RE.fullmatch(stripped) and out:
            out[-1] = out[-1].rstrip() + stripped
            if i + 1 < len(lines) and lines[i + 1].strip():
                out[-1] += lines[i + 1].strip()
                i += 2
                continue
        else:
            out.append(cur)
        i += 1
    return "\n".join(out)


def normalize_inline_artifacts(text: str) -> str:
    text = apply_strong_bracket_fixes(text)
    text = repair_inline_punctuation_lines(text)
    text = re.sub(r"[ \t]+([，、。；：？！）》〉」』])", r"\1", text)
    text = re.sub(r"([《〈「『（(])\s+", r"\1", text)
    text = re.sub(r"\s*·\s*", "·", text)
    return text


def append_text_piece(parts: List[str], piece: str) -> None:
    if not piece:
        return
    piece = piece.replace("\xa0", " ").replace("\u3000", " ")
    if not parts:
        parts.append(piece)
    elif parts[-1].endswith("\n"):
        parts.append(piece.lstrip(" \t"))
    else:
        parts.append(piece)


def append_newline(parts: List[str], max_newlines: int = 2) -> None:
    current = "".join(parts)
    existing = len(current) - len(current.rstrip("\n"))
    if existing < max_newlines:
        parts.append("\n")


def html_to_text_inline_preserving(root: Tag) -> str:
    parts: List[str] = []

    def walk(node: Any) -> None:
        if isinstance(node, NavigableString):
            append_text_piece(parts, str(node))
            return
        if not isinstance(node, Tag):
            return
        name = (node.name or "").lower()
        if name in {"script", "style", "noscript"}:
            return
        if name in {"br", "hr"}:
            append_newline(parts, 2)
            return
        is_block = name in BLOCK_TAGS
        if is_block and parts and not "".join(parts).endswith("\n"):
            append_newline(parts, 2)
        for child in node.children:
            walk(child)
        if is_block:
            append_newline(parts, 2)

    walk(root)
    text = "".join(parts)
    text = re.sub(r"\r\n?", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = "\n".join(line.strip() for line in text.splitlines())
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _classes_and_id(tag: Any) -> Tuple[Set[str], str]:
    attrs = getattr(tag, "attrs", None)
    if attrs is None:
        return set(), ""
    classes = attrs.get("class") or []
    if isinstance(classes, str):
        classes = [classes]
    class_set = {str(c) for c in classes if c}
    ident = str(attrs.get("id", "") or "")
    return class_set, ident


def _looks_like_wikisource_header_or_nav(tag: Any) -> bool:
    attrs = getattr(tag, "attrs", None)
    if attrs is None:
        return False
    classes, ident = _classes_and_id(tag)
    haystack = " ".join(list(classes) + [ident]).lower()
    furniture_needles = [
        "wst-header", "ws-header", "wikisource-header", "headertemplate",
        "header-template", "headercontainer", "licensecontainer", "catlinks",
        "printfooter", "mw-editsection", "toc", "ws-noexport", "noprint",
    ]
    if any(needle in haystack for needle in furniture_needles):
        return True
    if getattr(tag, "name", "") in {"table", "div", "nav", "center"}:
        text = tag.get_text(" ", strip=True)
        if "◄" in text or "►" in text:
            return True
        if ("previous" in text.lower() and "next" in text.lower()) or ("上一" in text and "下一" in text):
            return True
    return False


def remove_wikisource_furniture(root: Tag) -> None:
    for selector in [
        "script", "style", "noscript", ".mw-editsection", ".references", ".reference",
        ".mw-navigation", ".navbox", ".toc", ".catlinks", ".printfooter",
        ".licenseContainer", ".ws-noexport", "table",
    ]:
        for elem in list(root.select(selector)):
            if getattr(elem, "attrs", None) is not None:
                elem.decompose()

    for tag in list(root.find_all(True)):
        if getattr(tag, "attrs", None) is None:
            continue
        classes, _ident = _classes_and_id(tag)
        if classes & DROP_CLASSES or _looks_like_wikisource_header_or_nav(tag):
            tag.decompose()


def remove_loose_navigation_lines(text: str) -> str:
    lines = text.splitlines()
    bad: Set[int] = set()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped in {"◄", "►"} or "◄" in stripped or "►" in stripped:
            bad.update(range(max(0, i - 3), min(len(lines), i + 4)))
    if not bad:
        return text
    return "\n".join(line for i, line in enumerate(lines) if i not in bad)


def strip_public_domain_footer(text: str) -> str:
    cut_idx = len(text)
    for marker in PD_MARKERS:
        idx = text.find(marker)
        if idx != -1 and idx < cut_idx:
            cut_idx = idx
    return text[:cut_idx].rstrip() if cut_idx != len(text) else text


def clean_html_to_text(html: str, *, han_only: bool = False) -> str:
    if not html:
        return ""
    soup = BeautifulSoup(html, "html.parser")
    root = soup.find(class_="mw-parser-output") or soup
    remove_wikisource_furniture(root)
    text = html_to_text_inline_preserving(root)
    text = re.sub(r"\n\s*\[\s*编辑\s*\]\s*\n", "\n", text)
    text = re.sub(r"\n\s*\[\s*編輯\s*\]\s*\n", "\n", text)
    text = remove_loose_navigation_lines(text)
    text = normalize_inline_artifacts(text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    text = strip_public_domain_footer(text).strip()
    if "{{header" in text or "{{header2" in text:
        return ""
    if han_only:
        text = filter_han_text(text)
    return text.strip() + "\n" if text.strip() else ""


def is_han_character(char: str) -> bool:
    cp = ord(char)
    return (
        0x4E00 <= cp <= 0x9FFF or 0x3400 <= cp <= 0x4DBF or 0x20000 <= cp <= 0x2A6DF
        or 0x2A700 <= cp <= 0x2B73F or 0x2B740 <= cp <= 0x2B81D or 0x2B820 <= cp <= 0x2CEAD
        or 0x2CEB0 <= cp <= 0x2EBE0 or 0x31350 <= cp <= 0x323AF or 0x2EBF0 <= cp <= 0x2EE5D
        or 0x323B0 <= cp <= 0x33479 or 0x2F800 <= cp <= 0x2FA1F
    )


def is_traditional_punctuation(char: str) -> bool:
    cp = ord(char)
    if 0x3000 <= cp <= 0x303F or 0xFE10 <= cp <= 0xFE1F or 0xFE30 <= cp <= 0xFE4F or 0xFF00 <= cp <= 0xFFEF:
        return True
    return char in set("。，、；：？！「」『』《》（）［］｛｝【】…—～・〃〄々〆〇〈〉〖〗〘〙〚〛〜〝〞〟〰〱〲〳〴〵〶〷〸〹〺\n\r\t ")


def filter_han_text(text: str) -> str:
    return "".join(c for c in text if is_han_character(c) or is_traditional_punctuation(c))


# ---------------------------------------------------------------------------
# Metadata, writing, Wenyan scorer
# ---------------------------------------------------------------------------


def build_header(meta: Dict[str, str]) -> str:
    lines = []
    for key in HEADER_KEYS:
        lines.append(f"# {key}: {meta.get(key, '') or ''}")
    lines.append("")
    return "\n".join(lines) + "\n"


def possible_year_from_categories(cats: Sequence[str]) -> str:
    """Only use an explicit year category, not '(提及)' mention categories."""
    for c in cats:
        m = re.fullmatch(r"(\d{3,4})年", c.strip())
        if m:
            return f"{m.group(1)}年"
    return ""


def ensure_wenyan_import_path() -> None:
    scripts_dir = Path(__file__).resolve().parent
    cand = scripts_dir / "wenyan_scorer"
    if cand.is_dir():
        p = str(cand)
        if p not in sys.path:
            sys.path.insert(0, p)


def score_wenyan(text: str, *, segment: str, window_size_han: int, window_stride_han: int) -> Tuple[Optional[Dict[str, Any]], str]:
    try:
        ensure_wenyan_import_path()
        from wenyan_syntax.score import score_text  # type: ignore

        res = score_text(
            text,
            segment=segment,
            window_size_han=window_size_han,
            window_stride_han=window_stride_han,
            keep_evidence=False,
        )
        return res.get("summary") or {}, ""
    except Exception as exc:
        return None, str(exc)


@dataclass
class Config:
    categories: List[str]
    out: Path
    sleep: float
    recursive: bool
    max_depth: int
    exclude_category_regex: Optional[str]
    test: bool
    max_works: Optional[int]
    max_parts_per_work: Optional[int]
    include_root_for_multi: bool
    discover_subpages: bool
    discovery: str
    overwrite: bool
    nation: str
    nation_from_category: bool
    categories_value: str
    no_source_categories_in_header: bool
    han_only_clean: bool
    wenyan: bool
    wenyan_segment: str
    wenyan_window_size_han: int
    wenyan_window_stride_han: int
    route_suspected_modern: bool
    wenyan_fail_prop_modern: float
    wenyan_fail_median: float


def make_work_groups(page_hits: List[PageHit]) -> Dict[str, List[PageHit]]:
    groups: Dict[str, List[PageHit]] = {}
    for hit in page_hits:
        groups.setdefault(get_base_title(hit.title), []).append(hit)
    return groups


def choose_header_nation(cfg: Config, hit: PageHit) -> str:
    if cfg.nation:
        return cfg.nation
    if cfg.nation_from_category and hit.source_categories:
        # Explicit user-requested behaviour. If a page came through multiple categories,
        # preserve all of them rather than choosing one silently.
        return "，".join(hit.source_categories)
    return ""


def choose_header_categories(cfg: Config, hit: PageHit) -> str:
    if cfg.categories_value:
        return cfg.categories_value
    if cfg.no_source_categories_in_header:
        return ""
    return "，".join(hit.source_categories)


def write_index_rows(out: Path, rows: List[Dict[str, Any]], filename: str) -> None:
    if not rows:
        return
    ensure_dir(out)
    fieldnames = list(rows[0].keys())
    csv_path = out / filename
    with csv_path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for row in rows:
            w.writerow(row)


def scrape_one_page(
    *,
    cfg: Config,
    root_title: str,
    page_title: str,
    seq: int,
    hit: PageHit,
    work_hit: PageHit,
) -> Dict[str, Any]:
    chapter = chapter_label_from_title(root_title, page_title)
    work_id = safe_filename(root_title)
    chapter_stub = safe_filename(chapter if chapter != "root" else "front_matter")
    fname = f"{work_id}__{seq:04d}__{chapter_stub}.txt"

    raw_dir = cfg.out / "raw" / work_id
    clean_dir = cfg.out / "clean" / work_id
    ensure_dir(raw_dir)
    ensure_dir(clean_dir)

    raw_path = raw_dir / fname
    clean_path = clean_dir / fname
    if not cfg.overwrite and (raw_path.exists() or clean_path.exists()):
        raise FileExistsError(f"Target exists: {fname}. Rerun with --overwrite.")

    html = fetch_html(page_title, sleep=cfg.sleep)
    clean_body = clean_html_to_text(html, han_only=cfg.han_only_clean) if html else ""
    wikitext = fetch_wikitext(page_title, sleep=cfg.sleep)

    ws_cats, ws_scope = fetch_page_categories_with_root_fallback(page_title, root_title, sleep=cfg.sleep)
    year = possible_year_from_categories(ws_cats)

    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    meta = {
        "WORK_TITLE": root_title,
        "DISPLAY_TITLE": root_title,
        "PAGE_TITLE": page_title,
        "AUTHOR": "",
        "NATION": choose_header_nation(cfg, work_hit),
        "CATEGORIES": choose_header_categories(cfg, work_hit),
        "YEAR": year,
        "CHAPTER": chapter,
        "SOURCE_URL": title_to_wikisource_url(page_title),
        "WS_CATEGORIES": "，".join(ws_cats),
        "SCRAPED_AT_UTC": now,
    }

    row: Dict[str, Any] = {
        "status": "saved",
        "error": "",
        "source_categories": "，".join(work_hit.source_categories),
        "category_path": " > ".join(work_hit.category_path),
        "work_title": root_title,
        "page_title": page_title,
        "chapter": chapter,
        "sequence": seq,
        "source_url": meta["SOURCE_URL"],
        "header_nation": meta["NATION"],
        "header_categories": meta["CATEGORIES"],
        "year": year,
        "ws_categories": meta["WS_CATEGORIES"],
        "ws_category_scope": ws_scope,
        "raw_path": "",
        "clean_path": "",
        "chars_raw": 0,
        "chars_clean": 0,
        "wenyan_median_default_score": "",
        "wenyan_prop_literary": "",
        "wenyan_prop_modern": "",
        "wenyan_prop_uncertain": "",
        "wenyan_suspected_modern": "",
        "wenyan_error": "",
    }

    if not clean_body.strip():
        row["status"] = "skipped_empty"
        row["error"] = "No clean rendered body text retrieved after removing Wikisource furniture. No file written."
        return row

    suspected_modern = False
    if cfg.wenyan:
        summ, err = score_wenyan(
            clean_body,
            segment=cfg.wenyan_segment,
            window_size_han=cfg.wenyan_window_size_han,
            window_stride_han=cfg.wenyan_window_stride_han,
        )
        if summ is None:
            row["wenyan_error"] = err
        else:
            props = summ.get("proportions") or {}
            median_f = float(summ.get("median_default_score", 0.0) or 0.0)
            prop_lit = float(props.get("literary_syntax", 0.0) or 0.0)
            prop_mod = float(props.get("modern_syntax", 0.0) or 0.0)
            prop_unc = float(props.get("uncertain", 0.0) or 0.0)
            suspected_modern = (prop_mod >= cfg.wenyan_fail_prop_modern) or (median_f <= cfg.wenyan_fail_median)
            row["wenyan_median_default_score"] = f"{median_f:.6f}"
            row["wenyan_prop_literary"] = f"{prop_lit:.6f}"
            row["wenyan_prop_modern"] = f"{prop_mod:.6f}"
            row["wenyan_prop_uncertain"] = f"{prop_unc:.6f}"
            row["wenyan_suspected_modern"] = "1" if suspected_modern else "0"

    if suspected_modern and cfg.route_suspected_modern:
        raw_path = cfg.out / "suspected_modern" / "raw" / work_id / fname
        clean_path = cfg.out / "suspected_modern" / "clean" / work_id / fname
        ensure_dir(raw_path.parent)
        ensure_dir(clean_path.parent)

    header = build_header(meta)
    clean_text = header + clean_body
    clean_path.write_text(clean_text, encoding="utf-8", newline="\n")
    row["clean_path"] = str(clean_path.relative_to(cfg.out))
    row["chars_clean"] = len(clean_text)

    if wikitext.strip():
        raw_text = header + wikitext.strip() + "\n"
        raw_path.write_text(raw_text, encoding="utf-8", newline="\n")
        row["raw_path"] = str(raw_path.relative_to(cfg.out))
        row["chars_raw"] = len(raw_text)

    return row


def run(cfg: Config) -> None:
    ensure_dir(cfg.out)
    print(f"Version: {VERSION}")
    print(f"Output:  {cfg.out}")
    print(f"Sources: {', '.join(cfg.categories)}")
    print(f"Recursive: {cfg.recursive} max_depth={cfg.max_depth}")
    print()

    hits = discover_category_tree(
        cfg.categories,
        sleep=cfg.sleep,
        recursive=cfg.recursive,
        max_depth=cfg.max_depth,
        exclude_category_regex=cfg.exclude_category_regex,
    )
    print(f"\nDiscovered content pages: {len(hits)}")

    groups = make_work_groups(hits)
    base_titles = sorted(groups.keys())
    if cfg.test and cfg.max_works is not None:
        base_titles = base_titles[: cfg.max_works]
    print(f"Grouped works to process: {len(base_titles)}")

    index_rows: List[Dict[str, Any]] = []
    work_summary_rows: List[Dict[str, Any]] = []

    for wi, base_title in enumerate(base_titles, start=1):
        work_hits = groups[base_title]
        explicit_titles = [h.title for h in work_hits]
        # Work-level metadata evidence: merge all category hits under this base.
        work_hit = PageHit(
            title=base_title,
            source_categories=unique_preserve_order(c for h in work_hits for c in h.source_categories),
            category_path=max((h.category_path for h in work_hits), key=len, default=[]),
        )

        print(f"\n### [{wi}/{len(base_titles)}] {base_title} ###")
        parts = choose_parts_for_work(
            base_title,
            explicit_titles,
            sleep=cfg.sleep,
            include_root_for_multi=cfg.include_root_for_multi,
            discover_subpages=cfg.discover_subpages,
            discovery=cfg.discovery,
        )
        if cfg.test and cfg.max_parts_per_work is not None:
            parts = parts[: cfg.max_parts_per_work]
        print(f"  parts={len(parts)} source_categories={','.join(work_hit.source_categories)}")

        work_summary_rows.append({
            "work_title": base_title,
            "parts": len(parts),
            "source_categories": "，".join(work_hit.source_categories),
            "category_path": " > ".join(work_hit.category_path),
        })

        for pi, page_title in enumerate(parts, start=1):
            print(f"  [{pi}/{len(parts)}] {page_title}")
            try:
                row = scrape_one_page(
                    cfg=cfg,
                    root_title=base_title,
                    page_title=page_title,
                    seq=pi,
                    hit=work_hits[0],
                    work_hit=work_hit,
                )
                index_rows.append(row)
                if row["status"] == "saved":
                    print(f"      -> saved clean {row['chars_clean']} chars")
                else:
                    print(f"      -> {row['status']}: {row['error']}")
            except Exception as exc:
                print(f"      !! failed: {exc}", file=sys.stderr)
                index_rows.append({
                    "status": "error",
                    "error": str(exc),
                    "source_categories": "，".join(work_hit.source_categories),
                    "category_path": " > ".join(work_hit.category_path),
                    "work_title": base_title,
                    "page_title": page_title,
                    "chapter": chapter_label_from_title(base_title, page_title),
                    "sequence": pi,
                    "source_url": title_to_wikisource_url(page_title),
                    "header_nation": choose_header_nation(cfg, work_hit),
                    "header_categories": choose_header_categories(cfg, work_hit),
                    "year": "",
                    "ws_categories": "",
                    "ws_category_scope": "",
                    "raw_path": "",
                    "clean_path": "",
                    "chars_raw": 0,
                    "chars_clean": 0,
                    "wenyan_median_default_score": "",
                    "wenyan_prop_literary": "",
                    "wenyan_prop_modern": "",
                    "wenyan_prop_uncertain": "",
                    "wenyan_suspected_modern": "",
                    "wenyan_error": "",
                })

    write_index_rows(cfg.out, index_rows, "category_scrape_index.csv")
    write_index_rows(cfg.out, work_summary_rows, "category_work_summary.csv")
    (cfg.out / "category_scrape_index.json").write_text(json.dumps(index_rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nWrote index: {cfg.out / 'category_scrape_index.csv'}")
    print(f"Wrote work summary: {cfg.out / 'category_work_summary.csv'}")
    print("Done.")


def parse_args(argv: Optional[Sequence[str]] = None) -> Config:
    ap = argparse.ArgumentParser(description="Scrape zh.wikisource categories into Fanya-style raw/clean review output.")
    ap.add_argument("items", nargs="+", help="One or more categories, then the output directory as the final argument.")
    ap.add_argument("--sleep", type=float, default=0.5, help="Seconds between API requests.")
    ap.add_argument("--recursive", action="store_true", help="Follow subcategories from the supplied category/categories.")
    ap.add_argument("--max-depth", type=int, default=1, help="Subcategory depth when --recursive is used.")
    ap.add_argument("--exclude-category-regex", default=None, help="Skip matching subcategories, e.g. '越南战争|河内|越南作者'.")
    ap.add_argument("--test", action="store_true", help="Test mode with --max-works / --max-parts-per-work.")
    ap.add_argument("--max-works", type=int, default=None, help="In test mode, maximum works to process.")
    ap.add_argument("--max-parts-per-work", type=int, default=None, help="In test mode, maximum pages/parts per work.")
    ap.add_argument("--include-root-for-multi", action="store_true", help="When a work has subpages, also scrape the root page.")
    ap.add_argument("--no-discover-subpages", action="store_true", help="Do not discover subpages for root-only category members.")
    ap.add_argument("--discovery", choices=["html", "links", "allpages", "both"], default="both", help="Subpage discovery method.")
    ap.add_argument("--overwrite", action="store_true", help="Overwrite existing output files.")
    ap.add_argument("--nation", default="", help="Explicit NATION value for all scraped files.")
    ap.add_argument("--nation-from-category", action="store_true", help="Set NATION from the source category label(s). Use only for dynasty/polity categories.")
    ap.add_argument("--categories", dest="categories_value", default="", help="Explicit CATEGORIES value for all files.")
    ap.add_argument("--no-source-categories-in-header", action="store_true", help="Leave # CATEGORIES blank unless --categories is supplied.")
    ap.add_argument("--han-only-clean", action="store_true", help="Strip clean body to Han + traditional punctuation only. Default keeps visible text.")
    ap.add_argument("--wenyan", action="store_true", help="Run local wenyan_syntax scorer if available; results go to the index only.")
    ap.add_argument("--wenyan-segment", choices=["paragraph", "window"], default="paragraph")
    ap.add_argument("--wenyan-window-size-han", type=int, default=320)
    ap.add_argument("--wenyan-window-stride-han", type=int, default=200)
    ap.add_argument("--route-suspected-modern", action="store_true", help="With --wenyan, route suspected modern files under suspected_modern/.")
    ap.add_argument("--wenyan-fail-prop-modern", type=float, default=0.50)
    ap.add_argument("--wenyan-fail-median", type=float, default=-2.0)
    ap.add_argument("--version", action="store_true", help="Print script version and exit.")

    args = ap.parse_args(argv)
    if args.version:
        print(VERSION)
        raise SystemExit(0)
    if len(args.items) < 2:
        raise SystemExit("Give at least one category and then an output directory.")

    out = Path(args.items[-1]).expanduser().resolve()
    cats = list(args.items[:-1])
    return Config(
        categories=cats,
        out=out,
        sleep=float(args.sleep),
        recursive=bool(args.recursive),
        max_depth=int(args.max_depth),
        exclude_category_regex=args.exclude_category_regex,
        test=bool(args.test),
        max_works=args.max_works,
        max_parts_per_work=args.max_parts_per_work,
        include_root_for_multi=bool(args.include_root_for_multi),
        discover_subpages=not bool(args.no_discover_subpages),
        discovery=str(args.discovery),
        overwrite=bool(args.overwrite),
        nation=str(args.nation or ""),
        nation_from_category=bool(args.nation_from_category),
        categories_value=str(args.categories_value or ""),
        no_source_categories_in_header=bool(args.no_source_categories_in_header),
        han_only_clean=bool(args.han_only_clean),
        wenyan=bool(args.wenyan),
        wenyan_segment=str(args.wenyan_segment),
        wenyan_window_size_han=int(args.wenyan_window_size_han),
        wenyan_window_stride_han=int(args.wenyan_window_stride_han),
        route_suspected_modern=bool(args.route_suspected_modern),
        wenyan_fail_prop_modern=float(args.wenyan_fail_prop_modern),
        wenyan_fail_median=float(args.wenyan_fail_median),
    )


if __name__ == "__main__":
    run(parse_args())
