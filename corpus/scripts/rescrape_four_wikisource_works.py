#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rescrape_four_wikisource_works_v6.py

Focused Wikisource rescraper for these four works:
  - 日本國志
  - 日本訪書志
  - 曝書亭集
  - 策鳌雜摭

Output layout:
  output_dir/
    raw/<work_id>/...       raw wikitext + metadata header
    clean/<work_id>/...     cleaned plain text + metadata header
    special_index.csv       one row per scraped page
    special_index.json      same data as JSON
    special_summary.md      readable review summary

This script is deliberately copy/scrape-only. It does not touch your corpus tree.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import time
import traceback

SCRIPT_VERSION = "v7-inline-preserving-cleaner-2026-06-04"
from datetime import datetime, timezone
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple
from urllib.parse import quote

import requests
from bs4 import BeautifulSoup, NavigableString, Tag


API_ENDPOINT = "https://zh.wikisource.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusSpecialScraper/0.6 "
        "(chippy2001@live.co.uk; "
        "https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

# These are the four target works only.
# root_title must match the exact Wikisource page title.
WORKS: List[Dict[str, object]] = [
    {
        "work_id": "日本國志",
        "root_title": "日本國志",
        "display_title": "日本國志",
        "author": "黃遵憲",
        "nation": "清朝",
        "categories": "日本",
        "year": "1887年",
        "include_root": False,
        "notes": "Root page is catalogue/front matter; 序 and 後序 are linked subpages.",
    },
    {
        "work_id": "日本訪書志",
        "root_title": "日本訪書志",
        "display_title": "日本訪書志",
        "author": "楊守敬",
        "nation": "清朝",
        "categories": "日本",
        "year": "1900年",
        "include_root": True,
        "notes": "Root page contains 序、緣起、目錄 before the linked 卷 pages.",
    },
    {
        "work_id": "曝書亭集",
        "root_title": "曝書亭集",
        "display_title": "曝書亭集",
        "author": "朱彝尊",
        "nation": "清朝",
        "categories": "",
        "year": "",
        "include_root": True,
        "notes": "Root page contains 序 and 目錄 before the linked 卷 pages.",
    },
    {
        # Wikisource currently uses 鳌 in the page title; keep that exact title for API fetching.
        # The display/work folder uses 鰲 for corpus-facing traditional metadata.
        "work_id": "策鰲雜摭",
        "root_title": "策鳌雜摭",
        "display_title": "策鰲雜摭",
        "author": "葉慶頤",
        "nation": "清朝",
        "categories": "日本",
        "year": "1889年",
        "include_root": False,
        "notes": "Root page is catalogue; 卷一 to 卷八 are linked subpages.",
    },
]
PD_STOP_PATTERNS = [
    "本作品在全世界都属于",
    "本作品在全世界都屬於",
    "此清朝作品在全世界都属于",
    "此清朝作品在全世界都屬於",
    "本作品在美国属于",
    "本作品在美國屬於",
    "Public domain Public domain false false",
    "Public domain",
    "檢索自“",
    "检索自“",
]

DROP_CLASSES = {
    "mw-editsection",
    "mw-editsection-bracket",
    "noprint",
    "metadata",
    "plainlinks",
    "sisterproject",
    "sisternav",
    "printfooter",
    "catlinks",
    "licenseContainer",
    "ws-noexport",
    "ws-header",
    "wst-header",
    "wst-header-mainblock",
    "wst-header-title",
    "wst-header-notes",
    "wst-header-backlink",
    "wikisource-header",
    "headertemplate",
    "header-template",
    "ambox",
    "mbox-small",
}

# Tags that should create paragraph/line boundaries when extracting text.
# Inline tags such as <a>, <span>, <b>, <i>, <ruby> deliberately do NOT appear
# here, because get_text("\n") is what caused 《\n山海經\n》 and author-name
# linebreak artefacts.
BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "body", "center", "dd", "details",
    "div", "dl", "dt", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
    "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
    "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
}

BRACKET_PAIRS_STRONG = [
    ("《", "》"),
    ("〈", "〉"),
    ("「", "」"),
    ("『", "』"),
]

# A line made only of one of these should be glued to neighbouring prose.
# This catches older outputs and any residual parser oddities.
INLINE_PUNCT_ONLY_RE = re.compile(r"^[，、。；：？！,.!?;:）)］\]〕〉》」』]+$")

CHINESE_DIGITS = {
    "零": 0,
    "〇": 0,
    "一": 1,
    "二": 2,
    "兩": 2,
    "两": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
}


# ---------------------------------------------------------------------------
# Small filesystem / string helpers
# ---------------------------------------------------------------------------


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def normalise_title_for_path(title: str) -> str:
    """Keep CJK text, but remove path-hostile characters."""
    title = title.strip()
    title = title.replace("/", "_")
    title = title.replace("\\", "_")
    title = re.sub(r"[\r\n\t]+", " ", title)
    title = re.sub(r"\s+", " ", title).strip()
    # Windows-hostile characters
    title = re.sub(r'[<>:"|?*]', "_", title)
    return title


def title_to_wikisource_url(title: str) -> str:
    return "https://zh.wikisource.org/wiki/" + quote(title.replace(" ", "_"), safe="/_")


def strip_public_domain_footer(text: str) -> str:
    for pat in PD_STOP_PATTERNS:
        idx = text.find(pat)
        if idx != -1:
            return text[:idx].rstrip()
    return text.rstrip()


def clean_vertical_weirdness(text: str) -> str:
    """Fix simple vertical bracket blocks like 〈\n某年\n〉 -> 〈某年〉."""
    lines = text.splitlines()
    cleaned: List[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == "〈" and i + 2 < len(lines) and lines[i + 2].strip() == "〉":
            cleaned.append(f"〈{lines[i + 1].strip()}〉")
            i += 3
            continue
        cleaned.append(line)
        i += 1
    return "\n".join(cleaned)



def fix_brackets_strong(text: str, open_br: str, close_br: str) -> str:
    """
    Join bracketed spans back into a single inline token by removing whitespace
    inside the bracket pair.

    This is deliberately global because cited titles occur many times inside a
    single paragraph, e.g. 《山海經》, 《史記·封禪書》, 《論衡》.
    """
    if not text:
        return text
    pattern = re.compile(re.escape(open_br) + r"(.*?)" + re.escape(close_br), re.DOTALL)

    def repl(m: re.Match) -> str:
        inner = m.group(1)
        inner = re.sub(r"[ \t\r\n]+", "", inner)
        return f"{open_br}{inner}{close_br}"

    return pattern.sub(repl, text)


def apply_strong_bracket_fixes(text: str) -> str:
    for open_br, close_br in BRACKET_PAIRS_STRONG:
        text = fix_brackets_strong(text, open_br, close_br)
    return text


def repair_inline_punctuation_lines(text: str) -> str:
    """
    Repair residue from older MediaWiki extraction where punctuation gets forced
    onto its own line:

        松龕徐氏\n、\n默深魏氏

    becomes:

        松龕徐氏、默深魏氏

    This is conservative: only punctuation-only lines are glued.
    """
    lines = text.splitlines()
    out: List[str] = []
    i = 0
    while i < len(lines):
        cur = lines[i]
        stripped = cur.strip()
        if stripped and INLINE_PUNCT_ONLY_RE.fullmatch(stripped) and out:
            # Attach punctuation to previous non-empty line.
            out[-1] = out[-1].rstrip() + stripped
            # If the next line is non-empty prose, attach it too. This catches
            # punctuation that was separated between two inline spans.
            if i + 1 < len(lines) and lines[i + 1].strip():
                out[-1] += lines[i + 1].strip()
                i += 2
                continue
        else:
            out.append(cur)
        i += 1
    return "\n".join(out)


def normalize_inline_artifacts(text: str) -> str:
    """Post-extraction cleanup for inline artefacts, not paragraph logic."""
    text = apply_strong_bracket_fixes(text)
    text = repair_inline_punctuation_lines(text)
    # Remove spaces before/after Chinese punctuation introduced by extraction.
    text = re.sub(r"[ \t]+([，、。；：？！）》〉」』])", r"\1", text)
    text = re.sub(r"([《〈「『（(])\s+", r"\1", text)
    # Collapse spaces around middle dot inside titles/names: 史記 · 封禪書 -> 史記·封禪書
    text = re.sub(r"\s*·\s*", "·", text)
    return text


def append_text_piece(parts: List[str], piece: str) -> None:
    """Append a text piece while avoiding accidental double spaces."""
    if not piece:
        return
    piece = piece.replace("\xa0", " ").replace("\u3000", " ")
    if not parts:
        parts.append(piece)
        return
    prev = parts[-1]
    if prev.endswith("\n"):
        parts.append(piece.lstrip(" \t"))
    else:
        parts.append(piece)


def append_newline(parts: List[str], max_newlines: int = 2) -> None:
    """Append at most max_newlines consecutive newlines."""
    current = "".join(parts)
    existing = len(current) - len(current.rstrip("\n"))
    needed = max(0, max_newlines - existing)
    if needed:
        parts.append("\n" * min(1, needed))


def html_to_text_inline_preserving(root: Tag) -> str:
    """
    Extract visible text while preserving inline flow.

    BeautifulSoup's get_text("\n") inserts newlines between every inline node.
    That is the source of artefacts such as:

        《\n山海經\n》
        松龕徐氏\n、\n默深魏氏

    This walker only inserts newlines around real block tags and <br>/<hr>.
    """
    parts: List[str] = []

    def walk(node) -> None:
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
    # Compress spaces/tabs but not newlines.
    text = re.sub(r"[ \t]+", " ", text)
    # Strip spaces at line edges.
    text = "\n".join(line.strip() for line in text.splitlines())
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def unique_preserve_order(items: Iterable[str]) -> List[str]:
    seen: Set[str] = set()
    out: List[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


# ---------------------------------------------------------------------------
# MediaWiki API helpers
# ---------------------------------------------------------------------------


def api_get(params: Dict[str, object], retries: int = 3, sleep_sec: float = 1.0) -> Dict:
    params = dict(params)
    params["format"] = "json"

    last_error: Optional[Exception] = None
    for attempt in range(1, retries + 1):
        try:
            resp = requests.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=45)
            resp.raise_for_status()
            data = resp.json()
            if "error" in data:
                raise RuntimeError(f"API error: {data['error']}")
            return data
        except Exception as exc:  # requests exceptions + JSON/API exceptions
            last_error = exc
            if attempt < retries:
                time.sleep(sleep_sec * attempt)
            else:
                break

    raise RuntimeError(f"API request failed after {retries} attempts: {last_error}")



def api_text_value(node: object) -> str:
    """
    Return text from MediaWiki API fields without assuming one exact shape.

    The original scraper usually did data["parse"]["text"]["*"].  That works
    when the API returns the expected dict, but this helper also tolerates a
    plain string or None.
    """
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if isinstance(node, dict):
        value = node.get("*")
        if value is None:
            value = node.get("value") or node.get("html") or node.get("wikitext")
        return str(value or "")
    return str(node or "")


def fetch_html_for_page(title: str) -> str:
    """
    Original-scraper-compatible HTML fetch.

    Try parse->text first, exactly like the old working prototype.  If that
    fails or returns an odd/empty shape, fall back to query extracts.  This
    function should not kill the whole page scrape; it returns an empty string
    on failure so the wikitext/raw side can still be saved.
    """
    try:
        data = api_get({
            "action": "parse",
            "page": title,
            "prop": "text",
            "disablelimitreport": 1,
            "disableeditsection": 1,
            "disabletoc": 1,
        })
        parse = data.get("parse") if isinstance(data, dict) else None
        if isinstance(parse, dict):
            html = api_text_value(parse.get("text"))
            if html:
                return html
    except Exception as exc:
        print(f"    !! API error (parse text) for {title}: {exc}")

    # Same fallback idea as the original scraper.
    try:
        data = api_get({
            "action": "query",
            "prop": "extracts",
            "explaintext": 0,
            "titles": title,
        })
        query = data.get("query") if isinstance(data, dict) else None
        pages = query.get("pages") if isinstance(query, dict) else None
        if isinstance(pages, dict):
            for page in pages.values():
                if isinstance(page, dict):
                    extract = page.get("extract")
                    if extract:
                        return str(extract)
    except Exception as exc:
        print(f"    !! API error (extracts fallback) for {title}: {exc}")

    print(f"    !! Empty HTML returned for page after fallbacks: {title}")
    return ""


def fetch_wikitext_for_page(title: str) -> str:
    """
    Fetch raw wikitext using the same simple parse->wikitext idea as the
    original scraper, but without assuming the response can never be odd.
    """
    try:
        data = api_get({
            "action": "parse",
            "page": title,
            "prop": "wikitext",
        })
        parse = data.get("parse") if isinstance(data, dict) else None
        if isinstance(parse, dict):
            return api_text_value(parse.get("wikitext"))
    except Exception as exc:
        print(f"    !! API error (wikitext) for {title}: {exc}")
    return ""


def _fetch_categories_direct(title: str) -> List[str]:
    """Fetch categories attached directly to one Wikisource page."""
    cats: List[str] = []
    cont: Dict[str, object] = {}
    while True:
        try:
            params: Dict[str, object] = {
                "action": "query",
                "prop": "categories",
                "titles": title,
                "cllimit": "max",
            }
            params.update(cont)
            data = api_get(params)
        except Exception as exc:
            print(f"    !! API error (categories) for {title}: {exc}")
            break

        query = data.get("query") if isinstance(data, dict) else None
        pages = query.get("pages") if isinstance(query, dict) else None
        if isinstance(pages, dict):
            for page in pages.values():
                if not isinstance(page, dict):
                    continue
                # A missing page may appear here; do not treat that as categories.
                if "missing" in page:
                    continue
                categories = page.get("categories") or []
                if not isinstance(categories, list):
                    continue
                for cat in categories:
                    if not isinstance(cat, dict):
                        continue
                    cat_title = str(cat.get("title", "") or "")
                    if cat_title.startswith("Category:"):
                        cat_title = cat_title[len("Category:"):]
                    if cat_title:
                        cats.append(cat_title)

        next_continue = data.get("continue") if isinstance(data, dict) else None
        if not isinstance(next_continue, dict):
            break
        cont = next_continue
    return unique_preserve_order(cats)


def fetch_categories_for_page(title: str, root_title: Optional[str] = None) -> Tuple[List[str], str]:
    """
    Fetch Wikisource categories for a page.

    Subpages often carry no categories of their own; the root work page does.
    For corpus metadata, use page categories first and root categories as a
    fallback/augmentation, so 卷 pages do not end up with blank WS_CATEGORIES
    merely because Wikisource stores categories on the table-of-contents page.

    Returns (categories, scope), where scope is useful in the audit index.
    """
    page_cats = _fetch_categories_direct(title)
    root_cats: List[str] = []
    if root_title and root_title != title:
        root_cats = _fetch_categories_direct(root_title)

    if page_cats and root_cats:
        return unique_preserve_order(page_cats + root_cats), "page_plus_root"
    if page_cats:
        return page_cats, "page"
    if root_cats:
        return root_cats, "root_fallback"
    return [], "none"

def extract_links_from_page(title: str) -> List[str]:
    """
    Original-scraper-compatible link extraction.

    The old scraper did not require ns == 0.  Keep that looser behaviour because
    it worked for these Wikisource tables of contents; filtering happens later
    by prefix anyway.
    """
    links: List[str] = []
    try:
        data = api_get({
            "action": "parse",
            "page": title,
            "prop": "links",
        })
        parse = data.get("parse") if isinstance(data, dict) else None
        link_items = parse.get("links") if isinstance(parse, dict) else []
        if not isinstance(link_items, list):
            return links
        for item in link_items:
            if not isinstance(item, dict):
                continue
            target = item.get("*")
            if target:
                links.append(str(target))
    except Exception as exc:
        print(f"    !! API error while extracting links from {title}: {exc}")
    return unique_preserve_order(links)


def discover_allpages_prefix(prefix: str) -> List[str]:
    titles: List[str] = []
    cont: Dict[str, object] = {}
    while True:
        params: Dict[str, object] = {
            "action": "query",
            "list": "allpages",
            "apnamespace": 0,
            "apprefix": prefix,
            "aplimit": "max",
        }
        params.update(cont)
        data = api_get(params)
        for page in data.get("query", {}).get("allpages", []) or []:
            title = page.get("title")
            if title:
                titles.append(title)
        if "continue" not in data:
            break
        cont = data["continue"]
    return unique_preserve_order(titles)


# ---------------------------------------------------------------------------
# Discovery + ordering
# ---------------------------------------------------------------------------


def chinese_num_to_int(raw: str) -> Optional[int]:
    raw = raw.strip()
    if not raw:
        return None
    if raw.isdigit():
        return int(raw)

    # Remove common wrappers/noise.
    raw = raw.replace("第", "").replace("卷", "").strip()

    # Simple positional support for up to 999.
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
            # Unknown character: bail out rather than guess.
            return None
    total += current
    return total if total > 0 else None


def chapter_label_from_title(root_title: str, page_title: str) -> str:
    if page_title == root_title:
        return "root"
    if page_title.startswith(root_title + "/"):
        return page_title[len(root_title) + 1:]
    return page_title


def chapter_sort_key(root_title: str, page_title: str) -> Tuple[int, int, str]:
    """
    Sort front matter, volumes, appendix/postface in a stable human order.

    Buckets:
      0 root/front matter on root page
      1 pre-volume front matter subpages, e.g. 序, 緣起, 目錄
      2 numbered volumes
      3 appendices
      4 postfaces / late extras
      9 unknown, but still retained
    """
    label = chapter_label_from_title(root_title, page_title)
    last = label.split("/")[-1]

    if page_title == root_title:
        return (0, 0, label)

    # Dedicated front matter.
    front_order = {
        "序": 1,
        "敘": 1,
        "原序": 2,
        "自序": 2,
        "緣起": 3,
        "凡例": 4,
        "目錄": 5,
        "目录": 5,
    }
    if last in front_order:
        return (1, front_order[last], label)

    # Numbered volume pages: 卷一, 卷二十一, 第001卷, 卷00480, etc.
    m = re.search(r"(?:第)?卷\s*([0-9]+|[零〇一二三四五六七八九十百兩两]+)", last)
    if not m:
        m = re.search(r"卷\s*([0-9]+|[零〇一二三四五六七八九十百兩两]+)", last)
    if m:
        n = chinese_num_to_int(m.group(1))
        if n is not None:
            return (2, n, label)

    # Some pages are simply 第001卷.
    m = re.search(r"第\s*([0-9]+|[零〇一二三四五六七八九十百兩两]+)\s*卷", last)
    if m:
        n = chinese_num_to_int(m.group(1))
        if n is not None:
            return (2, n, label)

    if "附錄" in last or "附录" in last:
        return (3, 0, label)

    if "後序" in last or "后序" in last or "跋" == last:
        return (4, 0, label)

    return (9, 0, label)


def discover_pages_for_work(work: Dict[str, object], discovery: str = "both") -> List[str]:
    root_title = str(work["root_title"])
    include_root = bool(work.get("include_root", False))
    prefix = root_title + "/"

    found: List[str] = []
    if include_root:
        found.append(root_title)

    if discovery in {"links", "both"}:
        try:
            found.extend(t for t in extract_links_from_page(root_title) if t.startswith(prefix))
        except Exception as exc:
            print(f"  !! Link discovery failed for {root_title}: {exc}")

    if discovery in {"allpages", "both"}:
        try:
            found.extend(discover_allpages_prefix(prefix))
        except Exception as exc:
            print(f"  !! allpages discovery failed for {root_title}: {exc}")

    found = unique_preserve_order(found)

    # Keep only root or subpages under root.
    found = [t for t in found if t == root_title or t.startswith(prefix)]

    # Avoid obvious non-content/support pages if any appear under the prefix.
    bad_tail_patterns = ["/doc", "/sandbox", "/沙盒"]
    found = [t for t in found if not any(t.endswith(pat) for pat in bad_tail_patterns)]

    found = sorted(found, key=lambda t: chapter_sort_key(root_title, t))
    return found


# ---------------------------------------------------------------------------
# Text cleaning + saving
# ---------------------------------------------------------------------------



def _classes_and_id(tag) -> Tuple[Set[str], str]:
    """Return a safe (classes, id) pair for a BeautifulSoup tag."""
    attrs = getattr(tag, "attrs", None)
    if attrs is None:
        return set(), ""
    classes = attrs.get("class") or []
    if isinstance(classes, str):
        classes = [classes]
    class_set = {str(c) for c in classes if c}
    ident = str(attrs.get("id", "") or "")
    return class_set, ident


def _looks_like_wikisource_header_or_nav(tag) -> bool:
    """
    Identify Wikisource page furniture before calling get_text().

    The annoying output like:
        卷四... ◄ 曝書亭集 卷五... ► 卷六...
    is usually the rendered {{header2}} navigation block, not corpus text.
    Removing its DOM node is much safer than trying to patch the text later.
    """
    attrs = getattr(tag, "attrs", None)
    if attrs is None:
        return False

    classes, ident = _classes_and_id(tag)
    haystack = " ".join(list(classes) + [ident]).lower()

    # Class/id based detection. Keep this deliberately focused on page furniture.
    furniture_needles = [
        "wst-header",
        "ws-header",
        "wikisource-header",
        "headertemplate",
        "header-template",
        "headercontainer",
        "licensecontainer",
        "catlinks",
        "printfooter",
        "mw-editsection",
        "toc",
        "ws-noexport",
        "noprint",
    ]
    if any(needle in haystack for needle in furniture_needles):
        return True

    # Text based detection for rendered previous/next navigation tables.
    if getattr(tag, "name", "") in {"table", "div", "nav", "center"}:
        text = tag.get_text(" ", strip=True)
        if "◄" in text or "►" in text:
            return True
        # Some skins/templates render prev/next without symbols.
        if ("previous" in text.lower() and "next" in text.lower()) or ("上一" in text and "下一" in text):
            return True

    return False


def _remove_wikisource_furniture(root) -> None:
    """Remove templates/navigation/license/edit boxes from a parsed Wikisource page."""
    # Remove broad non-content first. These four target works are prose/poetry;
    # tables in the rendered page are overwhelmingly Wikisource furniture/TOC.
    for selector in [
        "script", "style", "noscript",
        ".mw-editsection", ".references", ".reference",
        ".mw-navigation", ".navbox", ".toc", ".catlinks",
        ".printfooter", ".licenseContainer", ".ws-noexport",
        "table",
    ]:
        for elem in list(root.select(selector)):
            if getattr(elem, "attrs", None) is not None:
                elem.decompose()

    # Then remove any surviving Wikisource header/nav blocks. Use a top-down
    # pass over a frozen list so parent nodes are removed before child oddities
    # can confuse BeautifulSoup state.
    for tag in list(root.find_all(True)):
        if getattr(tag, "attrs", None) is None:
            continue
        classes, _ident = _classes_and_id(tag)
        if classes & DROP_CLASSES or _looks_like_wikisource_header_or_nav(tag):
            tag.decompose()


def _remove_loose_navigation_lines(text: str) -> str:
    """
    Last-resort cleanup for navigation text that survived DOM removal.

    This removes a small window around standalone ◄ / ► lines. It is intentionally
    narrow: it should not rewrite real body text unless a Wikisource nav marker is
    present.
    """
    lines = text.splitlines()
    bad: Set[int] = set()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped in {"◄", "►"} or "◄" in stripped or "►" in stripped:
            start = max(0, i - 3)
            end = min(len(lines), i + 4)
            bad.update(range(start, end))
    if not bad:
        return text
    kept = [line for i, line in enumerate(lines) if i not in bad]
    return "\n".join(kept)

def clean_html_to_text(html: str) -> str:
    """
    Convert MediaWiki HTML to corpus text.

    Important rule for this scraper: CLEAN output must never be made from raw
    wikitext. Wikisource templates such as {{header2 ...}} are page furniture,
    not corpus text. We fetch rendered HTML, remove header/navigation/license
    furniture from the DOM, then extract text.
    """
    soup = BeautifulSoup(html, "html.parser")

    # API parse returns the content inside this block. Fall back to whole soup.
    root = soup.find(class_="mw-parser-output") or soup

    _remove_wikisource_furniture(root)

    text = html_to_text_inline_preserving(root)

    # Remove common MediaWiki edit-label debris.
    text = re.sub(r"\n\s*\[\s*编辑\s*\]\s*\n", "\n", text)
    text = re.sub(r"\n\s*\[\s*編輯\s*\]\s*\n", "\n", text)

    # Last-resort nav cleanup for header templates not caught structurally.
    text = _remove_loose_navigation_lines(text)

    # Inline repairs: fix 《\n山海經\n》 and punctuation-only lines.
    text = normalize_inline_artifacts(text)

    # Collapse excessive blank lines, but preserve paragraph breaks.
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = text.strip()
    text = clean_vertical_weirdness(text)
    text = strip_public_domain_footer(text)

    # Do not allow raw template source to leak into clean files.
    if "{{header" in text or "{{header2" in text:
        # This means we accidentally cleaned wikitext, not rendered body text.
        return ""

    return text.strip() + "\n" if text.strip() else ""

def make_header(meta: Dict[str, object]) -> str:
    """Create the corpus header. Keep this schema narrow and explicit."""
    ordered_keys = [
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
    lines = []
    for key in ordered_keys:
        value = str(meta.get(key, "") or "")
        lines.append(f"# {key}: {value}")
    lines.append("")
    return "\n".join(lines) + "\n"

def save_page_pair(
    base_output: str,
    work: Dict[str, object],
    page_title: str,
    seq: int,
    overwrite: bool = False,
) -> Dict[str, object]:
    root_title = str(work["root_title"])
    work_id = str(work["work_id"])
    chapter = chapter_label_from_title(root_title, page_title)
    chapter_stub = normalise_title_for_path(chapter)
    if chapter_stub == "root":
        chapter_stub = "front_matter"

    filename = f"{work_id}__{seq:04d}__{chapter_stub}.txt"

    raw_dir = os.path.join(base_output, "raw", work_id)
    clean_dir = os.path.join(base_output, "clean", work_id)
    ensure_dir(raw_dir)
    ensure_dir(clean_dir)

    raw_path = os.path.join(raw_dir, filename)
    clean_path = os.path.join(clean_dir, filename)

    if not overwrite and (os.path.exists(raw_path) or os.path.exists(clean_path)):
        raise FileExistsError(f"Target already exists: {filename}; rerun with --overwrite")

    html = fetch_html_for_page(page_title)
    wikitext = fetch_wikitext_for_page(page_title)
    categories, category_scope = fetch_categories_for_page(page_title, root_title=root_title)

    clean_body = clean_html_to_text(html) if html else ""
    raw_body = wikitext.strip() + "\n" if wikitext and wikitext.strip() else ""

    # Corpus-facing clean files must come from rendered HTML only. Do not fall
    # back to wikitext, because raw Wikisource templates like {{header2}} are
    # page furniture and will pollute the corpus.
    clean_source = "html" if clean_body.strip() else "empty_or_navigation_only_html"

    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    meta = {
        "WORK_TITLE": work.get("display_title") or work.get("root_title"),
        "DISPLAY_TITLE": work.get("display_title") or work.get("root_title"),
        "PAGE_TITLE": page_title,
        "AUTHOR": work.get("author", ""),
        "NATION": work.get("nation", ""),
        "CATEGORIES": work.get("categories", ""),
        "YEAR": work.get("year", ""),
        "CHAPTER": chapter,
        "SOURCE_URL": title_to_wikisource_url(page_title),
        "WS_CATEGORIES": "，".join(categories),
        "SCRAPED_AT_UTC": now,
    }
    header = make_header(meta)

    base_row = {
        "status": "saved",
        "error": "",
        "root_title": root_title,
        "work_id": work_id,
        "work_title": str(meta["WORK_TITLE"]),
        "display_title": str(meta["DISPLAY_TITLE"]),
        "page_title": page_title,
        "author": str(meta["AUTHOR"]),
        "nation": str(meta["NATION"]),
        "categories": str(meta["CATEGORIES"]),
        "year": str(meta["YEAR"]),
        "mode": "four_work_rescrape",
        "chapter": chapter,
        "sequence": seq,
        "source_url": str(meta["SOURCE_URL"]),
        "ws_categories": str(meta["WS_CATEGORIES"]),
        "ws_category_scope": category_scope,
        "clean_source": clean_source,
        "raw_path": "",
        "clean_path": "",
        "chars_raw": 0,
        "chars_clean": 0,
    }

    # Do not save header-only files.  This prevents redlinks, failed retrievals,
    # and pages whose rendered output is only Wikisource furniture from becoming
    # blank corpus texts. Raw wikitext alone is not enough to save a page.
    if not clean_body.strip():
        base_row["status"] = "skipped_empty"
        base_row["error"] = "No clean rendered body text retrieved after removing Wikisource furniture. No file written."
        return base_row

    clean_text = header + clean_body
    with open(clean_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(clean_text)

    raw_rel = ""
    raw_chars = 0
    if raw_body.strip():
        raw_text = header + raw_body
        with open(raw_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(raw_text)
        raw_rel = os.path.relpath(raw_path, base_output)
        raw_chars = len(raw_text)

    base_row.update({
        "raw_path": raw_rel,
        "clean_path": os.path.relpath(clean_path, base_output),
        "chars_raw": raw_chars,
        "chars_clean": len(clean_text),
    })
    return base_row

# ---------------------------------------------------------------------------
# Runner + output indices
# ---------------------------------------------------------------------------


def select_works(requested: Optional[str]) -> List[Dict[str, object]]:
    if not requested:
        return WORKS
    wanted = {x.strip() for x in requested.split(",") if x.strip()}
    selected: List[Dict[str, object]] = []
    for work in WORKS:
        names = {
            str(work["work_id"]),
            str(work["root_title"]),
            str(work.get("display_title", "")),
        }
        if names & wanted:
            selected.append(work)
    missing = wanted - {str(w["work_id"]) for w in selected} - {str(w["root_title"]) for w in selected} - {str(w.get("display_title", "")) for w in selected}
    if missing:
        raise ValueError(f"Requested works not found in script WORKS list: {', '.join(sorted(missing))}")
    return selected


def write_indices(base_output: str, rows: List[Dict[str, object]], summary_lines: List[str]) -> None:
    csv_path = os.path.join(base_output, "special_index.csv")
    json_path = os.path.join(base_output, "special_index.json")
    summary_path = os.path.join(base_output, "special_summary.md")

    fieldnames = [
        "status",
        "error",
        "root_title",
        "work_id",
        "work_title",
        "display_title",
        "page_title",
        "author",
        "nation",
        "categories",
        "year",
        "mode",
        "chapter",
        "sequence",
        "source_url",
        "ws_categories",
        "ws_category_scope",
        "clean_source",
        "raw_path",
        "clean_path",
        "chars_raw",
        "chars_clean",
    ]
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)

    with open(summary_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(summary_lines).rstrip() + "\n")


def run(
    output_dir: str,
    sleep_sec: float,
    max_pages_per_work: Optional[int],
    test: bool,
    discovery: str,
    overwrite: bool,
    requested_works: Optional[str],
    debug: bool = False,
) -> None:
    selected = select_works(requested_works)

    ensure_dir(output_dir)
    ensure_dir(os.path.join(output_dir, "raw"))
    ensure_dir(os.path.join(output_dir, "clean"))

    rows: List[Dict[str, object]] = []
    summary: List[str] = []
    summary.append("# Four-work Wikisource rescrape summary")
    summary.append("")
    summary.append(f"Run time UTC: {datetime.now(timezone.utc).replace(microsecond=0).isoformat()}")
    summary.append(f"Mode: {'TEST' if test else 'FULL'}")
    summary.append(f"Discovery: {discovery}")
    summary.append(f"Output directory: {os.path.abspath(output_dir)}")
    summary.append("")

    print(f"Starting four-work Wikisource rescrape ({SCRIPT_VERSION}).")
    print(f"  Output:   {os.path.abspath(output_dir)}")
    print(f"  Discovery: {discovery}")
    print(f"  Sleep:    {sleep_sec:.2f}s")
    print(f"  Mode:     {'TEST' if test else 'FULL'}")
    print()

    for wi, work in enumerate(selected, start=1):
        root_title = str(work["root_title"])
        display_title = str(work.get("display_title", root_title))
        print(f"### [{wi}/{len(selected)}] {display_title} ({root_title}) ###")

        try:
            pages = discover_pages_for_work(work, discovery=discovery)
        except Exception as exc:
            print(f"  !! Discovery failed for {root_title}: {exc}")
            summary.append(f"## {display_title}")
            summary.append(f"- DISCOVERY FAILED: {exc}")
            summary.append("")
            continue

        if test:
            cap = max_pages_per_work if max_pages_per_work is not None else 3
            pages = pages[:cap]
        elif max_pages_per_work is not None:
            pages = pages[:max_pages_per_work]

        print(f"  -> {len(pages)} pages selected")
        summary.append(f"## {display_title}")
        summary.append(f"- Root title: {root_title}")
        summary.append(f"- Author: {work.get('author', '')}")
        summary.append(f"- Nation: {work.get('nation', '')}")
        summary.append(f"- Categories: {work.get('categories', '')}")
        summary.append(f"- Include root page: {bool(work.get('include_root', False))}")
        summary.append(f"- Pages selected: {len(pages)}")
        if work.get("notes"):
            summary.append(f"- Notes: {work.get('notes')}")
        summary.append("")

        for j, page_title in enumerate(pages, start=1):
            print(f"  [{j}/{len(pages)}] {page_title}")
            try:
                row = save_page_pair(
                    base_output=output_dir,
                    work=work,
                    page_title=page_title,
                    seq=j,
                    overwrite=overwrite,
                )
            except Exception as exc:
                print(f"    !! Failed: {exc}")
                if debug:
                    traceback.print_exc()
                summary.append(f"  - FAILED: {page_title}: {exc}")
                continue

            rows.append(row)
            if row.get("status") == "skipped_empty":
                print("    -> skipped_empty; no file written")
            else:
                print(f"    -> clean/{row['clean_path']} ({row['chars_clean']} chars)")
            time.sleep(sleep_sec)

        print()

    # Add counts to summary after rows exist.
    summary.append("## Totals")
    saved_count = sum(1 for row in rows if row.get("status") == "saved")
    skipped_count = sum(1 for row in rows if row.get("status") == "skipped_empty")
    summary.append(f"- Pages successfully saved: {saved_count}")
    summary.append(f"- Pages skipped as empty: {skipped_count}")
    by_work: Dict[str, int] = {}
    for row in rows:
        if row.get("status") != "saved":
            continue
        by_work[str(row["work_id"])] = by_work.get(str(row["work_id"]), 0) + 1
    for work_id, count in sorted(by_work.items()):
        summary.append(f"- {work_id}: {count}")

    write_indices(output_dir, rows, summary)
    print("Wrote special_index.csv, special_index.json, and special_summary.md")
    print("Done.")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: Sequence[str]) -> None:
    parser = argparse.ArgumentParser(
        description="Focused rescrape for 日本國志, 日本訪書志, 曝書亭集, and 策鰲雜摭 from zh.wikisource."
    )
    parser.add_argument(
        "output_dir",
        nargs="?",
        default="four_work_rescrape_output",
        help="Base output directory. Default: four_work_rescrape_output",
    )
    parser.add_argument(
        "--sleep",
        type=float,
        default=0.5,
        help="Sleep between page saves, in seconds. Default: 0.5",
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Scrape only the first few discovered pages per work. Default cap is 3 unless --max-pages-per-work is set.",
    )
    parser.add_argument(
        "--max-pages-per-work",
        type=int,
        default=None,
        help="Optional cap on pages per work. Useful for testing.",
    )
    parser.add_argument(
        "--discovery",
        choices=["links", "allpages", "both"],
        default="both",
        help="How to discover subpages. Default: both.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing output files. Without this, existing targets cause that page to fail safely.",
    )
    parser.add_argument(
        "--works",
        default=None,
        help="Comma-separated subset by work_id/root/display title, e.g. 日本國志,策鰲雜摭",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Print Python tracebacks when an individual page fails.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=SCRIPT_VERSION,
        help="Print script version and exit.",
    )

    args = parser.parse_args(argv[1:])
    run(
        output_dir=args.output_dir,
        sleep_sec=args.sleep,
        max_pages_per_work=args.max_pages_per_work,
        test=args.test,
        discovery=args.discovery,
        overwrite=args.overwrite,
        requested_works=args.works,
        debug=args.debug,
    )


if __name__ == "__main__":
    main(sys.argv)
