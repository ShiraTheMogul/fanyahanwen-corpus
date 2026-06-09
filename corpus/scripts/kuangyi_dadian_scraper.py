#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kuangyi_dadian_scraper.py

Scrape 礦藝大典 / lzh.minecraft.wiki into Fanya Hanwen Corpus-style raw/clean text files.

Default output shape:
  output_root/
    raw/礦藝大典/<page-folder>/<page>.txt
    clean/礦藝大典/<page-folder>/<page>.txt
    kuangyi_dadian_index.csv
    kuangyi_dadian_index.json

Dependencies:
  pip install requests beautifulsoup4

Basic usage:
  python kuangyi_dadian_scraper.py --out ./scrape_output

Test mode:
  python kuangyi_dadian_scraper.py --out ./scrape_output --limit 20

Resume/overwrite:
  python kuangyi_dadian_scraper.py --out ./scrape_output --skip-existing
  python kuangyi_dadian_scraper.py --out ./scrape_output --overwrite

Notes:
  - Only main-namespace pages are discovered by default.
  - File/Image namespaces are not scraped.
  - The script does not request MediaWiki image/file metadata.
  - Rendered images, galleries, thumbnails, icons, and figure blocks are removed before text extraction.
  - Tables are mostly kept because glossary / technical pages may use them, but infobox/navbox/sidebar tables are removed.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple
from urllib.parse import quote

import requests
from bs4 import BeautifulSoup, NavigableString, Tag

SITE_BASE_DEFAULT = "https://lzh.minecraft.wiki"
WORK_TITLE = "礦藝大典"
AUTHOR = "礦藝大典之用戶"
FIXED_CATEGORIES = "游戲，維基"
LICENSE = "CC-BY-NC-SA-3.0 https://creativecommons.org/licenses/by-nc-sa/3.0/"
RIGHTS_NOTE = "Non-commercial reuse only; ShareAlike applies to adaptations. Images and game assets excluded unless separately licensed."

VERSION = "kuangyi-dadian-scraper-2026-06-08-r6-title-ratio-cleanup"

HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusScraper/2.1 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul)"
    )
}

# Header order is intentionally narrow and matches the user-specified schema.
HEADER_KEYS = [
    "WORK_TITLE",
    "PAGE_TITLE",
    "URL",
    "WIKI_CATEGORIES",
    "DATE",
    "SCRAPED_AT",
    "AUTHOR",
    "CATEGORIES",
    "LICENSE",
    "RIGHTS_NOTE",
]


# Han / CJK title filter. This is applied only to page titles, never page body text.
# The wiki often contains English comparison names inside useful articles; those should stay.
HAN_TITLE_RANGES = [
    (0x4E00, 0x9FFF),   # CJK Unified Ideographs
    (0x3400, 0x4DBF),   # Extension A
    (0x20000, 0x2A6DF), # Extension B
    (0x2A700, 0x2B73F), # Extension C
    (0x2B740, 0x2B81D), # Extension D
    (0x2B820, 0x2CEAD), # Extension E
    (0x2CEB0, 0x2EBE0), # Extension F
    (0x31350, 0x323AF), # Extension H
    (0x2EBF0, 0x2EE5D), # Extension I
    (0x323B0, 0x33479), # Extension J
    (0x2F800, 0x2FA1F), # CJK Compatibility/Supplement
    (0x3D000, 0x3FC3F), # Seal Script
]

# Main namespace only by default. These are just a second safety net for odd API returns.
DISALLOWED_NS_PREFIXES = (
    "Special:", "特殊:", "Project:", "Minecraft Wiki:", "Talk:", "討論:", "User:", "用戶:",
    "File:", "文件:", "Image:", "Media:", "Template:", "模板:", "Category:", "分類:",
    "Help:", "幫助:", "Module:", "模塊:", "MediaWiki:",
)

# Classes/ids that are usually wiki furniture rather than article prose.
DROP_CLASS_PARTS = (
    "mw-editsection", "toc", "catlinks", "printfooter", "navbox", "metadata",
    "ambox", "mbox", "hatnote", "noprint", "nomobile", "infobox", "sidebar",
    "mcwiki-header", "license", "footer", "redirectMsg",
)

# Image/media-related selectors. These are deliberately stronger than normal text cleanup.
IMAGE_MEDIA_SELECTORS = [
    "img",
    "figure",
    "figcaption",
    ".thumb",
    ".tright",
    ".tleft",
    ".gallery",
    ".gallerybox",
    ".image",
    ".image-link",
    ".mw-file-element",
    ".mw-default-size",
    ".mw-image-border",
    ".noviewer",
    "video",
    "audio",
    "source",
    "canvas",
]

# Remove only table furniture. Keep ordinary content tables because technical/glossary pages may need them.
TABLE_DROP_CLASS_PARTS = ("infobox", "navbox", "metadata", "sidebar", "ambox", "mbox")

_session = requests.Session()


# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------


def unique_preserve_order(items: Iterable[str]) -> List[str]:
    seen: set[str] = set()
    out: List[str] = []
    for item in items:
        item = str(item or "").strip()
        if item and item not in seen:
            seen.add(item)
            out.append(item)
    return out


def safe_filename(name: str, max_len: int = 120) -> str:
    """Make a Windows-safe file/folder component while keeping Han characters."""
    s = (name or "").strip()
    s = s.replace("/", "_")
    s = re.sub(r"[\\:*?\"<>|]", "_", s)
    s = re.sub(r"\s+", " ", s).strip().strip(".")
    if len(s) > max_len:
        s = s[:max_len].rstrip().strip(".")
    return s or "untitled"


def wiki_url(site_base: str, title: str) -> str:
    """Build the public short URL requested for the metadata header."""
    return site_base.rstrip("/") + "/" + quote(title.replace(" ", "_"), safe="/:()_-%")


def is_han_title_char(ch: str) -> bool:
    """True if a character belongs to the title-allowed Han/seal ranges."""
    cp = ord(ch)
    return any(start <= cp <= end for start, end in HAN_TITLE_RANGES)


def title_has_han(title: str) -> bool:
    """Require at least one Han/seal character in the page title. Body text is not filtered this way."""
    return any(is_han_title_char(ch) for ch in title or "")


def is_latin_title_char(ch: str) -> bool:
    """True for Latin letters only. Digits/punctuation are not counted as Latin."""
    return ("A" <= ch <= "Z") or ("a" <= ch <= "z")


def count_han_title_chars(title: str) -> int:
    return sum(1 for ch in title or "" if is_han_title_char(ch))


def count_latin_title_chars(title: str) -> int:
    return sum(1 for ch in title or "" if is_latin_title_char(ch))


def title_passes_han_latin_balance(title: str, *, allow_latin_heavy_titles: bool = False) -> bool:
    """Default title filter for 礦藝大典.

    Keep titles that contain Han/seal script and are not mostly Latin letters.
    This filters page titles such as SNBT範式, Villages.dat範式, and
    Movie：少年謝爾頓, without touching English comparison names inside
    article bodies.

    Digits and punctuation are ignored for the balance test. A title with
    4 Han and 3 Latin letters passes; a title with 4 Han and 5 Latin letters
    fails. Titles beginning with a Latin letter are also skipped by default,
    since in this wiki that usually marks an untranslated technical/page-name
    article rather than a 文言 page title.
    """
    if allow_latin_heavy_titles:
        return True
    han = count_han_title_chars(title)
    latin = count_latin_title_chars(title)
    stripped = (title or "").lstrip(" ._-:/：")
    starts_latin = bool(stripped) and is_latin_title_char(stripped[0])
    return han > 0 and latin <= han and not starts_latin


def is_content_title(
    title: str,
    *,
    require_han_title: bool = True,
    allow_latin_heavy_titles: bool = False,
) -> bool:
    t = (title or "").strip()
    if not t:
        return False
    if t.startswith(("Edit section", "编辑章节", "編輯章節")):
        return False
    for pref in DISALLOWED_NS_PREFIXES:
        if t.startswith(pref):
            return False
    if require_han_title and not title_passes_han_latin_balance(t, allow_latin_heavy_titles=allow_latin_heavy_titles):
        return False
    return True


def api_text_value(node: Any) -> str:
    """MediaWiki formatversion differences: text can be a string or a dict."""
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if isinstance(node, dict):
        return str(node.get("*") or node.get("value") or node.get("html") or node.get("wikitext") or "")
    return str(node or "")


def as_dict(value: Any) -> Dict[str, Any]:
    """Return value if it is a dict; otherwise return an empty dict.

    MediaWiki responses normally contain dicts, but defensive handling keeps
    odd/empty responses from causing `NoneType has no attribute get`.
    """
    return value if isinstance(value, dict) else {}


def build_header(meta: Dict[str, str]) -> str:
    lines = [f"# {key}: {meta.get(key, '') or ''}" for key in HEADER_KEYS]
    return "\n".join(lines) + "\n\n"


def split_header_and_body(text: str) -> Tuple[Dict[str, str], str]:
    """Used only for --skip-existing sanity checks if you extend this later."""
    meta: Dict[str, str] = {}
    lines = text.splitlines()
    body_start = 0
    for i, line in enumerate(lines):
        if not line.strip():
            body_start = i + 1
            break
        m = re.match(r"^#\s*([A-Z0-9_]+)\s*:\s*(.*)$", line)
        if not m:
            body_start = i
            break
        meta[m.group(1)] = m.group(2)
    return meta, "\n".join(lines[body_start:])


# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------


def api_get(api_endpoint: str, params: Dict[str, Any], *, sleep: float, retries: int = 4) -> Dict[str, Any]:
    params = dict(params)
    params.setdefault("format", "json")
    params.setdefault("formatversion", "2")

    last_error: Optional[Exception] = None
    for attempt in range(1, retries + 1):
        try:
            time.sleep(sleep)
            response = _session.get(api_endpoint, params=params, headers=HEADERS, timeout=45)
            response.raise_for_status()
            data = response.json()
            if "error" in data:
                raise RuntimeError(str(data["error"]))
            return data
        except Exception as exc:
            last_error = exc
            print(f"[warn] API request failed attempt {attempt}/{retries}: {exc}", file=sys.stderr)
            time.sleep(min(3.0, 0.4 * attempt))

    print(f"[error] API request failed after retries: {last_error}", file=sys.stderr)
    return {}


def detect_api_endpoint(site_base: str, explicit_api: str, *, sleep: float) -> str:
    """Try common MediaWiki API locations unless --api was supplied."""
    if explicit_api:
        return explicit_api.rstrip("/") if explicit_api.endswith("/") else explicit_api

    base = site_base.rstrip("/")
    candidates = [base + "/api.php", base + "/w/api.php"]
    for cand in candidates:
        data = api_get(
            cand,
            {"action": "query", "meta": "siteinfo", "siprop": "general"},
            sleep=sleep,
            retries=2,
        )
        if as_dict(data.get("query")).get("general"):
            print(f"[info] using API endpoint: {cand}")
            return cand

    raise SystemExit(
        "Could not detect the MediaWiki API endpoint. Try passing --api, e.g. "
        "--api https://lzh.minecraft.wiki/api.php"
    )


def resolve_redirect_title(api_endpoint: str, title: str, *, sleep: float) -> Optional[str]:
    data = api_get(
        api_endpoint,
        {"action": "query", "titles": title, "redirects": "1"},
        sleep=sleep,
    )
    pages = as_dict(data.get("query")).get("pages") or []
    if not pages:
        return None
    page = as_dict(pages[0])
    if "missing" in page:
        return None
    redirects = as_dict(data.get("query")).get("redirects") or []
    if redirects:
        redir = as_dict(redirects[-1])
        return redir.get("to") or page.get("title") or title
    return page.get("title") or title


def fetch_all_titles(
    api_endpoint: str,
    *,
    sleep: float,
    limit: Optional[int],
    prefix: str,
    include_redirects: bool,
    require_han_title: bool,
    allow_latin_heavy_titles: bool,
) -> List[str]:
    """Use list=allpages. apnamespace=0 means main article namespace."""
    titles: List[str] = []
    cont: Dict[str, Any] = {}

    while True:
        params: Dict[str, Any] = {
            "action": "query",
            "list": "allpages",
            "apnamespace": 0,
            "aplimit": "max",
        }
        if prefix:
            params["apprefix"] = prefix
        if not include_redirects:
            params["apfilterredir"] = "nonredirects"
        params.update(cont)

        data = api_get(api_endpoint, params, sleep=sleep)
        pages = as_dict(data.get("query")).get("allpages") or []
        for page in pages:
            page = as_dict(page)
            title = page.get("title") or ""
            if is_content_title(
                title,
                require_han_title=require_han_title,
                allow_latin_heavy_titles=allow_latin_heavy_titles,
            ):
                titles.append(title)
                if limit is not None and len(titles) >= limit:
                    return titles

        nxt = as_dict(data.get("continue"))
        if not nxt:
            break
        cont = nxt

    return titles


def fetch_html(api_endpoint: str, title: str, *, sleep: float) -> str:
    resolved = resolve_redirect_title(api_endpoint, title, sleep=sleep)
    if resolved is None:
        return ""
    data = api_get(
        api_endpoint,
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
    parse = as_dict(data.get("parse"))
    return api_text_value(parse.get("text"))


def fetch_page_info(api_endpoint: str, title: str, *, sleep: float) -> Tuple[List[str], str, str]:
    """Return (visible categories, latest revision timestamp, resolved title)."""
    resolved = resolve_redirect_title(api_endpoint, title, sleep=sleep)
    if resolved is None:
        return [], "", title

    categories: List[str] = []
    rev_timestamp = ""
    cont: Dict[str, Any] = {}
    first = True

    while True:
        params: Dict[str, Any] = {
            "action": "query",
            "prop": "categories|revisions",
            "titles": resolved,
            "cllimit": "max",
            "clshow": "!hidden",
            "rvprop": "timestamp",
            "rvlimit": 1,
            "redirects": "1",
        }
        params.update(cont)
        data = api_get(api_endpoint, params, sleep=sleep)
        pages = as_dict(data.get("query")).get("pages") or []

        for page in pages:
            page = as_dict(page)
            if "missing" in page:
                continue
            if first:
                resolved = page.get("title") or resolved
                revs = page.get("revisions") or []
                if revs:
                    rev0 = as_dict(revs[0])
                    rev_timestamp = rev0.get("timestamp") or ""
            for cat in page.get("categories") or []:
                cat = as_dict(cat)
                name = cat.get("title") or ""
                if name.startswith("Category:"):
                    name = name.split(":", 1)[1]
                if name:
                    categories.append(name)

        first = False
        nxt = as_dict(data.get("continue"))
        if not nxt:
            break
        cont = nxt

    return unique_preserve_order(categories), rev_timestamp, resolved


# ---------------------------------------------------------------------------
# HTML extraction / cleaning
# ---------------------------------------------------------------------------


def _class_id_text(tag: Tag) -> str:
    # BeautifulSoup tags can become half-destroyed after a parent is decomposed;
    # in that state tag.attrs may be None, and tag.get(...) can crash.
    attrs = getattr(tag, "attrs", None) or {}
    classes = attrs.get("class") or []
    if isinstance(classes, str):
        classes = [classes]
    bits = [str(c) for c in classes]
    ident = attrs.get("id")
    if ident:
        bits.append(str(ident))
    return " ".join(bits).lower()


def remove_unwanted_html(root: Tag) -> None:
    # Always drop scripts, styles, edit links, references, categories, and images/media.
    for selector in [
        "script", "style", "noscript", "sup.reference", ".reference", ".references",
        ".reflist", ".mw-editsection", "#catlinks", ".catlinks", "#toc", ".toc",
    ] + IMAGE_MEDIA_SELECTORS:
        for elem in list(root.select(selector)):
            elem.decompose()

    # Drop furniture by class/id, but do not blindly delete all tables.
    for tag in list(root.find_all(True)):
        # If an ancestor was decomposed earlier, this tag may no longer have attrs.
        if getattr(tag, "attrs", None) is None:
            continue
        haystack = _class_id_text(tag)
        if any(part in haystack for part in DROP_CLASS_PARTS):
            tag.decompose()
            continue
        if tag.name == "table" and any(part in haystack for part in TABLE_DROP_CLASS_PARTS):
            tag.decompose()
            continue

    # Drop links to file/media pages if any survive as normal anchors.
    for a in list(root.find_all("a")):
        attrs = getattr(a, "attrs", None) or {}
        href = attrs.get("href") or ""
        title = attrs.get("title") or ""
        combined = href + " " + title
        if any(mark in combined for mark in ("/File:", "/文件:", "/Image:", "File:", "文件:", "Image:")):
            a.decompose()


def html_to_text(root: Tag) -> str:
    """HTML -> visible text with table cells separated enough to be readable."""
    parts: List[str] = []

    block_tags = {
        "address", "article", "aside", "blockquote", "body", "br", "center", "dd", "details",
        "div", "dl", "dt", "fieldset", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "tbody",
        "td", "tfoot", "th", "thead", "tr", "ul",
    }

    def append_newline(max_newlines: int = 2) -> None:
        current = "".join(parts)
        existing = len(current) - len(current.rstrip("\n"))
        if existing < max_newlines:
            parts.append("\n")

    def walk(node: Any) -> None:
        if isinstance(node, NavigableString):
            s = str(node).replace("\xa0", " ").replace("\u3000", " ")
            if s:
                parts.append(s)
            return
        if not isinstance(node, Tag):
            return
        name = (node.name or "").lower()
        if name in {"script", "style", "noscript"}:
            return
        if name in {"br", "hr"}:
            append_newline(2)
            return
        if name in block_tags and parts and not "".join(parts).endswith("\n"):
            append_newline(1)
        for child in node.children:
            walk(child)
        if name in {"td", "th"}:
            parts.append("\t")
        if name in block_tags:
            append_newline(2 if name in {"table", "p", "div", "section", "ul", "ol"} else 1)

    walk(root)
    text = "".join(parts)
    text = re.sub(r"\r\n?", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = "\n".join(line.strip() for line in text.splitlines())
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


PUNCT_ONLY_LINE_RE = re.compile(r"^[，、。；：？！）》〉」』）\]\}]+$")

# Headings that become empty when images/references/navboxes are stripped.
# This removes only terminal empty headings, not sections that still have content under them.
TERMINAL_EMPTY_HEADINGS = {
    "參典", "参考", "參考", "註", "注", "圖藪", "图薮", "畫廊", "画廊",
    "繪圖", "绘图", "精技", "紋貌", "纹貌", "擬圖", "拟图", "餘者", "余者",
}

# Sections that are navigation/furniture after text extraction. Everything from the heading onward is dropped.
TERMINAL_DROP_SECTION_HEADINGS = {"津渡"}


def strip_terminal_drop_sections(text: str) -> str:
    """Drop terminal wiki furniture sections such as 津渡.

    Pattern in this wiki:
      ...
      津渡
      模板:Navbox ...

    We cut from the first exact terminal heading line. This is safer than cutting
    every heading-like word because ordinary article sections must remain.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip() in TERMINAL_DROP_SECTION_HEADINGS:
            return "\n".join(lines[:i]).rstrip()
    return text


def remove_empty_terminal_headings(text: str) -> str:
    """Remove leftover empty tail headings created by deleting refs/images/navboxes.

    Example after image/ref removal:
      ... body text ...
      畫廊
      繪圖
      精技
      紋貌
      擬圖
      餘者
      參典

    These are not useful corpus text when no content remains beneath them.
    """
    lines = text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    while lines and lines[-1].strip() in TERMINAL_EMPTY_HEADINGS:
        lines.pop()
        while lines and not lines[-1].strip():
            lines.pop()
    return "\n".join(lines).rstrip()


def repair_punctuation_only_lines(text: str) -> str:
    """Join punctuation-only lines back to the previous line.

    Example:
      庚子之歲，云已別魔贊
      。
    becomes:
      庚子之歲，云已別魔贊。
    """
    out: List[str] = []
    for line in text.splitlines():
        s = line.strip()
        if s and PUNCT_ONLY_LINE_RE.fullmatch(s) and out:
            out[-1] = out[-1].rstrip() + s
            continue
        out.append(line.rstrip())
    return "\n".join(out)


def remove_empty_link_artifacts(text: str) -> str:
    """Remove MediaWiki empty link artefacts produced by icon/recipe templates.

    The rendered text can contain repeated tokens like:
      [[|]][[|]][[|]]
      [[|]]2

    The first becomes empty; the second keeps the useful trailing quantity '2'.
    """
    # Remove repeated empty links even when they are glued together.
    text = re.sub(r"(?:\[\[\|\]\])+", "", text)
    # A rarer broken form can survive as [|].
    text = re.sub(r"(?:\[\|\])+", "", text)
    return text


def remove_dynamic_loader_lines(text: str) -> str:
    """Remove wiki/dynamic-template loader messages that are not article prose."""
    bad_exact = {
        "方載微具。若載敗，請重載此頁與確啟JavaScript也。",
    }
    kept: List[str] = []
    for line in text.splitlines():
        s = line.strip()
        if not s:
            kept.append("")
            continue
        if s in bad_exact:
            continue
        # Defensive: some skins insert the same loader sentence with minor spacing.
        if "請重載此頁" in s and "JavaScript" in s:
            continue
        kept.append(line.rstrip())
    return "\n".join(kept)


def normalize_text(text: str) -> str:
    text = text.replace("\u3000", " ").replace("\xa0", " ")
    # Remove short numeric reference markers if any survived.
    text = re.sub(r"\[\d+\]", "", text)
    text = remove_empty_link_artifacts(text)
    # Join common bracket breakage from rendered wiki HTML.
    for open_br, close_br in [("《", "》"), ("〈", "〉"), ("「", "」"), ("『", "』")]:
        pattern = re.compile(re.escape(open_br) + r"(.*?)" + re.escape(close_br), re.DOTALL)
        text = pattern.sub(lambda m: open_br + re.sub(r"[ \t\r\n]+", "", m.group(1)) + close_br, text)
    text = repair_punctuation_only_lines(text)
    # Trim wiki action/furniture phrases that sometimes survive in skins.
    junk_lines = {
        "編輯", "编辑", "閱讀", "阅读", "檢視原始碼", "查看源代码", "檢視歷史", "查看历史",
        "工具", "頁面", "页面", "討論", "讨论",
    }
    kept: List[str] = []
    for line in text.splitlines():
        s = line.strip()
        if not s:
            kept.append("")
            continue
        if s in junk_lines:
            continue
        if s.startswith("模板:Navbox") or s.startswith("Template:Navbox"):
            continue
        kept.append(line.rstrip())
    text = "\n".join(kept)
    text = remove_dynamic_loader_lines(text)
    text = strip_terminal_drop_sections(text)
    text = remove_empty_terminal_headings(text)
    # Remove whitespace-only lines and collapse big gaps.
    text = "\n".join(line.rstrip() for line in text.splitlines())
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def rendered_html_to_text(html: str) -> Tuple[str, str]:
    """Return (raw_visible_text, clean_text)."""
    if not html:
        return "", ""
    soup = BeautifulSoup(html, "html.parser")
    root = soup.find(class_="mw-parser-output") or soup
    remove_unwanted_html(root)
    raw_text = html_to_text(root)
    clean_text = normalize_text(raw_text)
    return raw_text.strip(), clean_text.strip()


# ---------------------------------------------------------------------------
# Saving / index
# ---------------------------------------------------------------------------


@dataclass
class SaveConfig:
    site_base: str
    api_endpoint: str
    out: Path
    sleep: float
    limit: Optional[int]
    prefix: str
    include_redirects: bool
    require_han_title: bool
    allow_latin_heavy_titles: bool
    overwrite: bool
    skip_existing: bool
    flat: bool
    debug_traceback: bool


def output_paths(cfg: SaveConfig, title: str) -> Tuple[Path, Path]:
    page_stub = safe_filename(title)
    if cfg.flat:
        fname = page_stub + ".txt"
        return cfg.out / "raw" / WORK_TITLE / fname, cfg.out / "clean" / WORK_TITLE / fname
    # Page-in-folder default: raw/礦藝大典/<Page>/<Page>.txt
    fname = page_stub + ".txt"
    return cfg.out / "raw" / WORK_TITLE / page_stub / fname, cfg.out / "clean" / WORK_TITLE / page_stub / fname


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def scrape_one_page(cfg: SaveConfig, title: str) -> Dict[str, Any]:
    raw_path, clean_path = output_paths(cfg, title)
    if not cfg.overwrite and cfg.skip_existing and clean_path.exists():
        return {
            "status": "skipped_existing",
            "error": "",
            "page_title": title,
            "resolved_title": "",
            "url": wiki_url(cfg.site_base, title),
            "date": "",
            "wiki_categories": "",
            "raw_path": str(raw_path.relative_to(cfg.out)),
            "clean_path": str(clean_path.relative_to(cfg.out)),
            "chars_raw": 0,
            "chars_clean": 0,
        }
    if not cfg.overwrite and (raw_path.exists() or clean_path.exists()) and not cfg.skip_existing:
        raise FileExistsError(f"Target exists. Use --overwrite or --skip-existing: {clean_path}")

    categories, revision_ts, resolved_title = fetch_page_info(cfg.api_endpoint, title, sleep=cfg.sleep)
    html = fetch_html(cfg.api_endpoint, resolved_title, sleep=cfg.sleep)
    raw_body, clean_body = rendered_html_to_text(html)

    if not clean_body.strip():
        return {
            "status": "skipped_empty",
            "error": "No clean rendered body text after image/media/furniture removal. No file written.",
            "page_title": title,
            "resolved_title": resolved_title,
            "url": wiki_url(cfg.site_base, resolved_title),
            "date": revision_ts,
            "wiki_categories": "，".join(categories),
            "raw_path": "",
            "clean_path": "",
            "chars_raw": 0,
            "chars_clean": 0,
        }

    scraped_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    meta = {
        "WORK_TITLE": WORK_TITLE,
        "PAGE_TITLE": resolved_title,
        "URL": wiki_url(cfg.site_base, resolved_title),
        "WIKI_CATEGORIES": "，".join(categories),
        "DATE": revision_ts,
        "SCRAPED_AT": scraped_at,
        "AUTHOR": AUTHOR,
        "CATEGORIES": FIXED_CATEGORIES,
        "LICENSE": LICENSE,
        "RIGHTS_NOTE": RIGHTS_NOTE,
    }
    header = build_header(meta)
    raw_text = header + raw_body.strip() + "\n"
    clean_text = header + clean_body.strip() + "\n"

    # If a redirect changed the title, use the resolved title for output path unless the old path exists.
    raw_path, clean_path = output_paths(cfg, resolved_title)
    if not cfg.overwrite and cfg.skip_existing and clean_path.exists():
        return {
            "status": "skipped_existing",
            "error": "",
            "page_title": title,
            "resolved_title": resolved_title,
            "url": meta["URL"],
            "date": revision_ts,
            "wiki_categories": meta["WIKI_CATEGORIES"],
            "raw_path": str(raw_path.relative_to(cfg.out)),
            "clean_path": str(clean_path.relative_to(cfg.out)),
            "chars_raw": 0,
            "chars_clean": 0,
        }

    write_text(raw_path, raw_text)
    write_text(clean_path, clean_text)

    return {
        "status": "saved",
        "error": "",
        "page_title": title,
        "resolved_title": resolved_title,
        "url": meta["URL"],
        "date": revision_ts,
        "wiki_categories": meta["WIKI_CATEGORIES"],
        "raw_path": str(raw_path.relative_to(cfg.out)),
        "clean_path": str(clean_path.relative_to(cfg.out)),
        "chars_raw": len(raw_text),
        "chars_clean": len(clean_text),
    }


def write_index(out: Path, rows: List[Dict[str, Any]]) -> None:
    out.mkdir(parents=True, exist_ok=True)
    csv_path = out / "kuangyi_dadian_index.csv"
    json_path = out / "kuangyi_dadian_index.json"
    fieldnames = [
        "status", "error", "page_title", "resolved_title", "url", "date", "wiki_categories",
        "raw_path", "clean_path", "chars_raw", "chars_clean",
    ]
    with csv_path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fieldnames})
    json_path.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[info] wrote index: {csv_path}")
    print(f"[info] wrote index: {json_path}")


def run(cfg: SaveConfig) -> None:
    cfg.out.mkdir(parents=True, exist_ok=True)
    print(f"Version: {VERSION}")
    print(f"Site:    {cfg.site_base}")
    print(f"API:     {cfg.api_endpoint}")
    print(f"Output:  {cfg.out}")
    print(f"Mode:    {'flat files' if cfg.flat else 'page folders'}")
    if cfg.require_han_title:
        if cfg.allow_latin_heavy_titles:
            title_mode = "Han/seal title filter on; Latin-heavy titles allowed"
        else:
            title_mode = "Han/seal title filter on; Latin-heavy titles skipped"
    else:
        title_mode = "Han/seal title filter off"
    print(f"Titles:  {title_mode}")
    print()

    titles = fetch_all_titles(
        cfg.api_endpoint,
        sleep=cfg.sleep,
        limit=cfg.limit,
        prefix=cfg.prefix,
        include_redirects=cfg.include_redirects,
        require_han_title=cfg.require_han_title,
        allow_latin_heavy_titles=cfg.allow_latin_heavy_titles,
    )
    print(f"[info] discovered mainspace pages: {len(titles)}")

    rows: List[Dict[str, Any]] = []
    for i, title in enumerate(titles, start=1):
        print(f"[{i}/{len(titles)}] {title}")
        try:
            row = scrape_one_page(cfg, title)
        except Exception as exc:
            if cfg.debug_traceback:
                import traceback
                traceback.print_exc()
            print(f"  [warn] failed: {exc}", file=sys.stderr)
            row = {
                "status": "error",
                "error": str(exc),
                "page_title": title,
                "resolved_title": "",
                "url": wiki_url(cfg.site_base, title),
                "date": "",
                "wiki_categories": "",
                "raw_path": "",
                "clean_path": "",
                "chars_raw": 0,
                "chars_clean": 0,
            }
        rows.append(row)
        if row["status"] == "saved":
            print(f"  -> saved clean {row['chars_clean']} chars")
        else:
            print(f"  -> {row['status']}")

    write_index(cfg.out, rows)
    print("[done]")


def parse_args(argv: Optional[Sequence[str]] = None) -> SaveConfig:
    ap = argparse.ArgumentParser(description="Scrape lzh.minecraft.wiki / 礦藝大典 into Fanya corpus raw/clean text files.")
    ap.add_argument("--out", default="", help="Output folder. Creates raw/礦藝大典 and clean/礦藝大典 under it.")
    ap.add_argument("--site", default=SITE_BASE_DEFAULT, help=f"Public site base URL. Default: {SITE_BASE_DEFAULT}")
    ap.add_argument("--api", default="", help="Explicit MediaWiki API endpoint if auto-detection fails.")
    ap.add_argument("--sleep", type=float, default=0.6, help="Seconds between API requests.")
    ap.add_argument("--limit", type=int, default=None, help="Limit number of pages for testing.")
    ap.add_argument("--prefix", default="", help="Only scrape mainspace titles beginning with this prefix.")
    ap.add_argument("--include-redirects", action="store_true", help="Include redirect pages in allpages discovery. Default skips redirects.")
    ap.add_argument("--allow-nonhan-titles", action="store_true", help="Do not require a Han/seal character in page titles. Default skips untranslated/Latin-only titles.")
    ap.add_argument("--allow-latin-heavy-titles", action="store_true", help="Keep titles where Latin letters outnumber Han/seal characters. Default skips these page titles.")
    ap.add_argument("--overwrite", action="store_true", help="Overwrite existing output files.")
    ap.add_argument("--skip-existing", action="store_true", help="Skip files already present in clean output.")
    ap.add_argument("--flat", action="store_true", help="Use raw/礦藝大典/Page.txt instead of page folders.")
    ap.add_argument("--debug-traceback", action="store_true", help="Print full Python tracebacks for page-level errors.")
    ap.add_argument("--version", action="store_true", help="Print version and exit.")
    args = ap.parse_args(argv)

    if args.version:
        print(VERSION)
        raise SystemExit(0)

    if not args.out:
        raise SystemExit("error: --out is required unless using --version")

    site_base = str(args.site or SITE_BASE_DEFAULT).rstrip("/")
    api_endpoint = detect_api_endpoint(site_base, str(args.api or ""), sleep=float(args.sleep))

    return SaveConfig(
        site_base=site_base,
        api_endpoint=api_endpoint,
        out=Path(args.out).expanduser().resolve(),
        sleep=float(args.sleep),
        limit=args.limit,
        prefix=str(args.prefix or ""),
        include_redirects=bool(args.include_redirects),
        require_han_title=not bool(args.allow_nonhan_titles),
        allow_latin_heavy_titles=bool(args.allow_latin_heavy_titles),
        overwrite=bool(args.overwrite),
        skip_existing=bool(args.skip_existing),
        flat=bool(args.flat),
        debug_traceback=bool(args.debug_traceback),
    )


if __name__ == "__main__":
    run(parse_args())
