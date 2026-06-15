#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Jin / nested-unknown regionalisation helper for Fanya Hanwen Corpus staging.

What this script is for
-----------------------
You have a folder such as:

    晉朝/
      西晉/
      東晉/
      十六國/
        不詳/
      小朝/
      不詳/

The script copies the corpus into a new output folder, removes obvious backup
files, dedupes unknown-folder copies against already regionalised copies, and
then tries to enrich unresolved unknown records.

Important safety rule
---------------------
A file inside a nested 不詳 folder is treated as unknown *inside that current
historical container*.

So:

    晉朝/十六國/不詳/...

may be moved to:

    晉朝/十六國/<configured target>/...

or, if you explicitly allow the exception, to:

    晉朝/小朝/<configured target>/...

It will NOT be moved to:

    晉朝/西晉/...
    晉朝/東晉/...

This follows your rule that nested 不詳 material should not escape to a former
or outer folder just because author/page metadata contains a broad period term.

Dependency for online enrichment:

    pip install requests beautifulsoup4

The script works without those packages if you do not use --fetch-ws-categories
or --author-lookup.

Basic use:

    python jin_unknown_regionaliser.py ".\\晉朝" ".\\晉朝_regionalised" --overwrite

With online enrichment:

    python jin_unknown_regionaliser.py ".\\晉朝" ".\\晉朝_regionalised" --overwrite --fetch-ws-categories --author-lookup

With a user-supplied mapping file:

    python jin_unknown_regionaliser.py ".\\晉朝" ".\\晉朝_regionalised" --overwrite --fetch-ws-categories --author-lookup --region-map ".\\jin_region_map.csv"

Mapping CSV format:

    target_path,aliases,scope,nation,confidence,note
    西晉,西晉|晉武帝|晉惠帝,,西晉,high,example only
    十六國/姚秦,姚秦|後秦|秦主姚興,十六國,姚秦,high,example only
    小朝/桓楚,桓楚|楚帝桓玄|桓玄,十六國,桓楚,high,example only

Only rows you supply are used for non-existing target folders. The script does
not invent a list of Sixteen Kingdoms states.

Corpus metadata schema rule
---------------------------
Output .txt headers are locked to the approved corpus schema only:

    WORK_TITLE, DISPLAY_TITLE, PAGE_TITLE, AUTHOR, NATION, CATEGORIES,
    YEAR, CHAPTER, SOURCE_URL, WS_CATEGORIES, SCRAPED_AT_UTC

Anything else, including author-page URLs, candidate source, lookup confidence,
routing reason, scraper diagnostics, and missing-part provenance, is audit-only
and goes under _audit/*.csv or _audit/*.json.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple
from urllib.parse import quote, unquote, urlparse

try:
    import requests  # type: ignore
except Exception:  # pragma: no cover
    requests = None  # type: ignore

try:
    from bs4 import BeautifulSoup  # type: ignore
except Exception:  # pragma: no cover
    BeautifulSoup = None  # type: ignore

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"
DEFAULT_USER_AGENT = (
    "FanyaHanwenCorpusMetadataHelper/1.2 "
    "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
    "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
)

USER_AGENT = os.environ.get("FANYA_WIKISOURCE_USER_AGENT", DEFAULT_USER_AGENT)
SCRIPT_VERSION = "current-dropin-2026-06-15-preserve-folder-skeleton"

UNKNOWN_LABEL = "不詳"
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

# Output corpus headers are deliberately locked. Do not add evidence/provenance
# keys here. Put those in _audit CSV/JSON files instead.
HEADER_KEY_SET = set(HEADER_KEYS)
AUDIT_ONLY_METADATA_KEYS = {
    "AUTHOR_PAGE",
    "AUTHOR_SOURCE",
    "LOOKUP_SOURCE",
    "LOOKUP_CONFIDENCE",
    "ROUTING_REASON",
    "SCRAPE_ERROR",
    "SOURCE_CATEGORY",
    "SOURCE_CATEGORIES",
}


def sanitize_header_meta(meta: Dict[str, str]) -> Dict[str, str]:
    """Return only approved corpus header keys, preserving HEADER_KEYS order.

    This is the guardrail against accidentally propagating audit/provenance
    evidence into text-file headers. The script may keep extra values in local
    variables or audit rows, but build_header() will never write them.
    """
    return {key: str(meta.get(key, "") or "") for key in HEADER_KEYS}


def assert_approved_header_only(text: str) -> None:
    """Fail loudly if a generated corpus text has a non-schema header key."""
    for line in text.splitlines():
        if not line.strip():
            return
        m = re.match(r"^#\s*([A-Z0-9_]+)\s*:", line)
        if not m:
            continue
        key = m.group(1)
        if key not in HEADER_KEY_SET:
            raise ValueError(f"Non-schema corpus header key generated: {key}")


def log_progress(args: object, message: str, *, verbose_only: bool = False) -> None:
    """Print progress lines.

    Normal mode prints coarse stage markers.
    --verbose prints per-group/per-fetch detail.
    flush=True matters on Windows PowerShell, because long API waits otherwise
    look like the script has frozen.
    """
    if verbose_only and not bool(getattr(args, "verbose", False)):
        return
    print(message, flush=True)


def progress_tick(args: object, current: int, total: int, label: str) -> None:
    """Print every N items during long loops, plus the first and last item."""
    every = int(getattr(args, "progress_every", 100) or 100)
    if bool(getattr(args, "verbose", False)) or current == 1 or current == total or current % every == 0:
        print(f"[{label}] {current}/{total}", flush=True)

OLD_TO_NEW_KEYS = {
    "WORK_BASE_TITLE": "WORK_TITLE",
    "WORK_TITLE": "WORK_TITLE",
    "DISPLAY_TITLE": "DISPLAY_TITLE",
    "PAGE_TITLE": "PAGE_TITLE",
    "AUTHOR": "AUTHOR",
    "NATION": "NATION",
    "CATEGORIES": "CATEGORIES",
    "YEAR": "YEAR",
    "CHAPTER": "CHAPTER",
    "SOURCE_URL": "SOURCE_URL",
    "URL": "SOURCE_URL",
    "WS_CATEGORIES": "WS_CATEGORIES",
    "SCRAPED_AT_UTC": "SCRAPED_AT_UTC",
}

BACKUP_SUFFIXES = (".bak", ".bak2", ".bak3", ".orig")
AUTHOR_NS_PREFIXES = ("Author:", "作者:")
HAN_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\U00020000-\U0002a6df\U0002a700-\U0002b73f\U0002b740-\U0002b81f\U0002b820-\U0002ceaf\U0002ceb0-\U0002ebef]+")
PLACE_PERSON_RE = re.compile(r"([一-龥]{1,8})(?:（[^）]{1,30}）)?人")
HEADER_PAIR_RE = re.compile(r"#\s*([A-Z_]+)\s*:\s*(.*?)(?=\s*#\s*[A-Z_]+\s*:|\n(?!#)|\Z)", re.S)


PD_MARKERS = [
    "本作品在全世界都属于",
    "本作品在全世界都屬於",
    "此作品在全世界都属于",
    "此作品在全世界都屬於",
    "本作品在美国属于",
    "本作品在美國屬於",
    "Public domain Public domain false false",
    "Public domain",
    "檢索自“",
    "检索自“",
]

BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "body", "center", "dd", "details",
    "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2",
    "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
    "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
}

DROP_CLASSES = {
    "mw-editsection", "references", "reference", "mw-navigation", "navbox", "toc",
    "catlinks", "printfooter", "licenseContainer", "ws-noexport", "noprint",
    "metadata", "plainlinks", "sisterproject", "sisternav", "ambox", "mbox-small",
    "ws-header", "wst-header", "wikisource-header", "headertemplate", "header-template",
}

BRACKET_PAIRS_STRONG = [("《", "》"), ("〈", "〉"), ("「", "」"), ("『", "』")]
INLINE_PUNCT_ONLY_RE = re.compile(r"^[，、。；：？！,.!?;:）)］\]〕〉》」』]+$")

CHINESE_DIGITS = {
    "零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "两": 2, "三": 3, "四": 4,
    "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
}

CONTENTS_HINT_RE = re.compile(r"(目錄|目录|凡例|卷[一二三四五六七八九十百兩两〇零0-9]|第[0-9一二三四五六七八九十百兩两〇零]+卷)")



def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def safe_filename(name: str, max_len: int = 120) -> str:
    name = (name or "").strip()
    name = re.sub(r"[\\/:*?\"<>|]", "_", name)
    name = re.sub(r"\s+", " ", name).strip()
    if len(name) > max_len:
        name = name[:max_len].rstrip()
    return name or "untitled"


def norm_title(s: str) -> str:
    """A conservative title key for grouping duplicates. Does not use OpenCC.

    Parenthetical disambiguators are deliberately preserved. For example,
    水賦 (吳淑) and 水賦 (王彪之) are not duplicates and must not be merged.
    """
    s = (s or "").strip()
    s = re.sub(r"\s+", "", s)
    # Tiny high-value normalisations only. This is not a general s2t converter.
    s = s.replace("国", "國").replace("晋", "晉").replace("阳", "陽")
    s = s.replace("陈", "陳").replace("寿", "壽")
    return s


def split_meta_list(value: str) -> List[str]:
    if not value:
        return []
    parts = re.split(r"[;；,，|｜]", value)
    return [p.strip() for p in parts if p.strip()]


def title_to_wikisource_url(title: str) -> str:
    return "https://zh.wikisource.org/wiki/" + quote(title, safe="")


def wikisource_url_to_title(url: str) -> str:
    if not url:
        return ""
    try:
        u = urlparse(url)
        parts = [p for p in (u.path or "").split("/") if p]
        if parts and parts[0] == "wiki":
            return unquote("/".join(parts[1:]))
    except Exception:
        return ""
    return ""


def read_text_file(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write_text_file(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def parse_header_and_body(text: str) -> Tuple[Dict[str, str], str]:
    """Parse old/new Fanya-style # KEY: headers and return normalised keys."""
    # Header area is normally the leading comment block. Some old files have two
    # fields on one line, so parse the first 5000 chars rather than one line at a time.
    head_chunk = text[:5000]
    meta: Dict[str, str] = {}
    for m in HEADER_PAIR_RE.finditer(head_chunk):
        old_key = m.group(1).strip()
        key = OLD_TO_NEW_KEYS.get(old_key, old_key)
        value = m.group(2).strip()
        value = re.sub(r"\s+", " ", value)
        if key in HEADER_KEYS and value and not meta.get(key):
            meta[key] = value

    lines = text.splitlines()
    i = 0
    while i < len(lines):
        stripped = lines[i].lstrip()
        if stripped.startswith("#") or not stripped.strip():
            i += 1
            continue
        break
    body = "\n".join(lines[i:]).strip()
    if body:
        body += "\n"
    return meta, body


def build_header(meta: Dict[str, str]) -> str:
    meta2 = sanitize_header_meta(meta)
    rows = []
    for key in HEADER_KEYS:
        rows.append(f"# {key}: {meta2.get(key, '') or ''}")
    rows.append("")
    header = "\n".join(rows) + "\n"
    assert_approved_header_only(header)
    return header


def infer_chapter(work_title: str, page_title: str, rel_file_name: str) -> str:
    if page_title and work_title and page_title.startswith(work_title + "/"):
        return page_title[len(work_title) + 1:]
    if page_title and page_title == work_title:
        return ""
    m = re.search(r"__juan_([0-9]+)", rel_file_name)
    if m:
        return f"juan_{m.group(1)}"
    return page_title or ""


def sha1_text(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", errors="ignore")).hexdigest()


@dataclass
class RegionRule:
    target_path: str
    aliases: List[str]
    scope: str = ""
    nation: str = ""
    confidence: str = ""
    note: str = ""
    source: str = ""


@dataclass
class FileRec:
    rel_path: str
    parts: List[str]
    text: str
    meta: Dict[str, str]
    body: str
    work_title: str
    page_title: str
    work_dir: str
    : str
    unknown_index: Optional[int]
    context_rel: str
    group_rel: str
    body_chars: int
    sha1: str
    is_unknown: bool
    source_mtime_sort: float = 0.0
    source_mtime_utc: str = ""


@dataclass
class WorkGroup:
    key: str
    group_rel: str
    files: List[FileRec] = field(default_factory=list)

    @property
    def total_body_chars(self) -> int:
        return sum(f.body_chars for f in self.files)

    @property
    def file_count(self) -> int:
        return len(self.files)

    @property
    def metadata_score(self) -> int:
        score = 0
        for f in self.files:
            for k in ["AUTHOR", "SOURCE_URL", "WS_CATEGORIES", "YEAR", "SCRAPED_AT_UTC"]:
                if f.meta.get(k):
                    score += 1
        return score

    @property
    def quality_tuple(self) -> Tuple[int, int, int]:
        # File count first prevents one huge noisy page from beating a real full scrape.
        return (self.file_count, self.total_body_chars, self.metadata_score)


def parse_timestamp_to_epoch(raw: str) -> Optional[float]:
    """Parse corpus SCRAPED_AT_UTC-like strings into an epoch value.

    If an old scrape lacks this field, callers should fall back to the source
    file timestamp. A naive timestamp is treated as UTC because corpus scrape
    fields are meant to be UTC-ish audit values, not local historical data.
    """
    s = (raw or "").strip()
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except Exception:
        return None


def file_mtime_to_iso(ts: float) -> str:
    try:
        return datetime.fromtimestamp(float(ts), timezone.utc).replace(microsecond=0).isoformat()
    except Exception:
        return ""


def zipinfo_mtime(info: zipfile.ZipInfo) -> Tuple[float, str]:
    """Return comparable timestamp for a zip member.

    Zip member times are stored without timezone. For recency comparison inside
    one archive, treating them as UTC is enough and avoids using the temporary
    extraction time, which would be wrong for old scrapes.
    """
    try:
        dt = datetime(*info.date_time, tzinfo=timezone.utc)
        return dt.timestamp(), dt.replace(microsecond=0).isoformat()
    except Exception:
        return 0.0, ""


def rec_recency(rec: FileRec) -> Tuple[float, str, str]:
    """Return (sort_value, source, display_value) for newest-scrape choice."""
    header_ts = parse_timestamp_to_epoch(rec.meta.get("SCRAPED_AT_UTC", ""))
    if header_ts is not None:
        return header_ts, "SCRAPED_AT_UTC", rec.meta.get("SCRAPED_AT_UTC", "")
    return float(rec.source_mtime_sort or 0.0), "file_mtime", rec.source_mtime_utc


def group_newest_recency(group: WorkGroup) -> Tuple[float, str, str]:
    if not group.files:
        return 0.0, "none", ""
    vals = [rec_recency(r) for r in group.files]
    vals.sort(key=lambda x: x[0], reverse=True)
    return vals[0]


def group_newest_sort_key(group: WorkGroup) -> Tuple[float, int, int, int]:
    newest, _source, _display = group_newest_recency(group)
    return (newest, group.file_count, group.total_body_chars, group.metadata_score)


def canonical_page_key_for_rec(rec: FileRec) -> str:
    raw = rec.page_title or rec.meta.get("CHAPTER") or rec.parts[-1]
    return norm_title(raw)


def group_page_signature(group: WorkGroup) -> Tuple[str, ...]:
    return tuple(sorted(canonical_page_key_for_rec(r) for r in group.files))


def group_hash_signature(group: WorkGroup) -> Tuple[Tuple[str, str], ...]:
    return tuple(sorted((canonical_page_key_for_rec(r), r.sha1) for r in group.files))


def compact_group_pages(group: WorkGroup, limit: int = 12) -> str:
    pages = list(group_page_signature(group))
    if len(pages) > limit:
        return "，".join(pages[:limit]) + f"，…(+{len(pages) - limit})"
    return "，".join(pages)


def duplicate_discrepancy_reason(groups: Sequence[WorkGroup]) -> str:
    if len(groups) < 2:
        return ""
    file_counts = {g.file_count for g in groups}
    if len(file_counts) > 1:
        return "file_count_mismatch"
    page_sigs = {group_page_signature(g) for g in groups}
    if len(page_sigs) > 1:
        return "page_title_or_chapter_mismatch"
    hash_sigs = {group_hash_signature(g) for g in groups}
    if len(hash_sigs) > 1:
        return "body_hash_mismatch"
    return ""


def source_url_for_group(group: WorkGroup) -> str:
    for rec in group.files:
        if rec.meta.get("SOURCE_URL"):
            return rec.meta["SOURCE_URL"]
    if group.files:
        return title_to_wikisource_url(choose_page_title_for_fetch(group.files[0]))
    return ""


def work_title_for_group(group: WorkGroup) -> str:
    return group.files[0].work_title if group.files else group.key


def make_duplicate_review_row(
    *,
    review_type: str,
    priority: str,
    title_key: str,
    unknown_group: WorkGroup,
    named_groups: Sequence[WorkGroup],
    reason: str,
    suggested_action: str,
) -> Dict[str, object]:
    candidates = [unknown_group] + list(named_groups)
    newest = max(candidates, key=group_newest_sort_key) if candidates else unknown_group
    newest_ts, newest_source, newest_display = group_newest_recency(newest)
    return {
        "review_type": review_type,
        "priority": priority,
        "suggested_action": suggested_action,
        "title_key": title_key,
        "work_title": work_title_for_group(unknown_group),
        "unknown_group": unknown_group.group_rel,
        "named_groups": " | ".join(g.group_rel for g in named_groups),
        "candidate_groups": " | ".join(g.group_rel for g in candidates),
        "newest_candidate_group": newest.group_rel,
        "newest_timestamp": newest_display,
        "newest_timestamp_source": newest_source,
        "reason": reason,
        "unknown_files": unknown_group.file_count,
        "unknown_chars": unknown_group.total_body_chars,
        "named_file_counts": " | ".join(str(g.file_count) for g in named_groups),
        "named_chars": " | ".join(str(g.total_body_chars) for g in named_groups),
        "unknown_pages": compact_group_pages(unknown_group),
        "named_pages": " || ".join(compact_group_pages(g) for g in named_groups),
        "source_url": source_url_for_group(unknown_group),
    }


class WikiClient:
    def __init__(self, sleep: float = 1.2, user_agent: str = USER_AGENT):
        if requests is None:
            raise RuntimeError("requests is not installed. Run: pip install requests beautifulsoup4")
        self.sleep = sleep
        self.user_agent = user_agent or USER_AGENT
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": self.user_agent,
            "Accept": "application/json",
            "Accept-Encoding": "gzip, deflate, br",
        })
        self.cache: Dict[str, dict] = {}
        self.missing_titles: set[str] = set()
        self.last_author_candidate_sources: List[Dict[str, str]] = []

    def api_get(self, params: Dict[str, str], retries: int = 5) -> dict:
        """Call the MediaWiki API with caching and non-noisy missing-page handling.

        Two cases need different treatment:

        1. A genuine network/server/rate-limit problem should be retried.
        2. A normal MediaWiki "missingtitle" response means "that page does not exist".
           That is not a failure and should not be retried three times.
        """
        params = dict(params)
        params.setdefault("format", "json")
        params.setdefault("formatversion", "2")
        key = json.dumps(params, ensure_ascii=False, sort_keys=True)
        if key in self.cache:
            return self.cache[key]

        last: Optional[Exception] = None
        for attempt in range(1, retries + 1):
            try:
                time.sleep(self.sleep)
                r = self.session.get(API_ENDPOINT, params=params, timeout=45)
                if r.status_code == 429:
                    retry_after = r.headers.get("Retry-After")
                    try:
                        wait = float(retry_after) if retry_after else max(10.0, self.sleep * (2 ** attempt))
                    except ValueError:
                        wait = max(10.0, self.sleep * (2 ** attempt))
                    print(f"[warn] API rate-limited; sleeping {wait:.1f}s before retry {attempt}/{retries}", file=sys.stderr)
                    time.sleep(wait)
                    continue
                r.raise_for_status()
                data = r.json()
                err = data.get("error") if isinstance(data, dict) else None
                if err:
                    code = str(err.get("code") or "")
                    # This commonly happens for missing Author: pages or stale/odd work URLs.
                    # Cache it and let the caller treat it as "no data".
                    if code in {"missingtitle", "invalidtitle", "nosuchrevid"}:
                        self.cache[key] = data
                        return data
                    raise RuntimeError(str(err))
                self.cache[key] = data
                return data
            except Exception as exc:  # pragma: no cover - online only
                last = exc
                print(f"[warn] API failed {attempt}/{retries}: {exc}", file=sys.stderr)
                time.sleep(min(30.0, max(2.0, self.sleep * (2 ** attempt))))
        raise RuntimeError(f"API failed after retries: {last}")

    @staticmethod
    def is_missing_response(data: dict) -> bool:
        err = data.get("error") if isinstance(data, dict) else None
        return bool(err and str(err.get("code") or "") in {"missingtitle", "invalidtitle", "nosuchrevid"})

    def page_exists(self, title: str) -> bool:
        if title in self.missing_titles:
            return False
        data = self.api_get({"action": "query", "titles": title, "redirects": "1"})
        pages = (data.get("query") or {}).get("pages") or []
        exists = bool(pages and "missing" not in pages[0])
        if not exists:
            self.missing_titles.add(title)
        return exists

    def page_exists_many(self, titles: Sequence[str]) -> Dict[str, bool]:
        """Return existence for many MediaWiki titles using one query per 50 titles.

        This is mainly for Author:<name> probes. It prevents the script from
        spending one API request per candidate name. Missing titles are cached.
        """
        clean_titles: List[str] = []
        for title in titles:
            title = (title or "").strip()
            if not title:
                continue
            if title in self.missing_titles:
                continue
            if title not in clean_titles:
                clean_titles.append(title)

        result: Dict[str, bool] = {t: False for t in titles if t}
        for i in range(0, len(clean_titles), 50):
            chunk = clean_titles[i:i + 50]
            data = self.api_get({"action": "query", "titles": "|".join(chunk), "redirects": "1"})
            pages = (data.get("query") or {}).get("pages") or []
            redirects = (data.get("query") or {}).get("redirects") or []

            existing_final_titles = {str(pg.get("title") or "") for pg in pages if "missing" not in pg}
            redirect_from_to = {str(r.get("from") or ""): str(r.get("to") or "") for r in redirects}

            for title in chunk:
                exists = title in existing_final_titles
                if not exists and title in redirect_from_to:
                    exists = redirect_from_to[title] in existing_final_titles
                result[title] = bool(exists)
                if not exists:
                    self.missing_titles.add(title)
        return result

    def fetch_categories(self, title: str) -> List[str]:
        if not title:
            return []
        out: List[str] = []
        cont: Dict[str, str] = {}
        while True:
            params = {
                "action": "query",
                "prop": "categories",
                "titles": title,
                "cllimit": "max",
                "clshow": "!hidden",
            }
            params.update(cont)
            data = self.api_get(params)
            pages = (data.get("query") or {}).get("pages") or []
            for pg in pages:
                if "missing" in pg:
                    self.missing_titles.add(title)
                    continue
                for c in pg.get("categories") or []:
                    name = c.get("title", "")
                    if name.startswith("Category:"):
                        name = name.split(":", 1)[1]
                    if name and name not in out:
                        out.append(name)
            nxt = data.get("continue") or {}
            if not nxt:
                break
            cont = {str(k): str(v) for k, v in nxt.items()}
        return out

    def fetch_parse_bundle(self, title: str) -> Dict[str, Any]:
        """Fetch rendered HTML, wikitext, and links with one parse request.

        MediaWiki action=parse accepts multiple props. This keeps author-link
        discovery from doing three separate API calls for the same page.
        """
        empty = {"html": "", "wikitext": "", "links": []}
        if not title or title in self.missing_titles:
            return empty
        data = self.api_get({
            "action": "parse",
            "page": title,
            "prop": "text|wikitext|links",
            "disabletoc": "1",
        })
        if self.is_missing_response(data):
            self.missing_titles.add(title)
            return empty
        parse = data.get("parse") or {}

        text_node = parse.get("text")
        if isinstance(text_node, dict):
            html = str(text_node.get("*") or text_node.get("html") or "")
        else:
            html = str(text_node or "")

        wt_node = parse.get("wikitext")
        if isinstance(wt_node, dict):
            wikitext = str(wt_node.get("*") or wt_node.get("wikitext") or "")
        else:
            wikitext = str(wt_node or "")

        links: List[str] = []
        for lk in parse.get("links") or []:
            if not isinstance(lk, dict):
                continue
            t = lk.get("title") or lk.get("*")
            if t and str(t) not in links:
                links.append(str(t))

        return {"html": html, "wikitext": wikitext, "links": links}

    def fetch_wikitext(self, title: str) -> str:
        if not title or title in self.missing_titles:
            return ""
        data = self.api_get({"action": "parse", "page": title, "prop": "wikitext"})
        if self.is_missing_response(data):
            self.missing_titles.add(title)
            return ""
        parse = data.get("parse") or {}
        node = parse.get("wikitext")
        if isinstance(node, dict):
            return str(node.get("*") or node.get("wikitext") or "")
        return str(node or "")

    def fetch_links(self, title: str) -> List[str]:
        if not title or title in self.missing_titles:
            return []
        data = self.api_get({"action": "parse", "page": title, "prop": "links"})
        if self.is_missing_response(data):
            self.missing_titles.add(title)
            return []
        parse = data.get("parse") or {}
        out: List[str] = []
        for lk in parse.get("links") or []:
            if not isinstance(lk, dict):
                continue
            t = lk.get("title") or lk.get("*")
            if t and str(t) not in out:
                out.append(str(t))
        return out

    def fetch_html(self, title: str) -> str:
        if not title or title in self.missing_titles:
            return ""
        data = self.api_get({"action": "parse", "page": title, "prop": "text", "disabletoc": "1"})
        if self.is_missing_response(data):
            self.missing_titles.add(title)
            return ""
        parse = data.get("parse") or {}
        node = parse.get("text")
        if isinstance(node, dict):
            return str(node.get("*") or node.get("html") or "")
        return str(node or "")

    def fetch_pageid(self, title: str) -> Optional[int]:
        if not title or title in self.missing_titles:
            return None
        data = self.api_get({"action": "query", "titles": title, "redirects": "1"})
        pages = (data.get("query") or {}).get("pages") or []
        if not pages or "missing" in pages[0]:
            self.missing_titles.add(title)
            return None
        pid = pages[0].get("pageid")
        try:
            return int(pid)
        except Exception:
            return None

    def fetch_allpages_prefix(self, prefix: str) -> List[str]:
        out: List[str] = []
        cont: Dict[str, str] = {}
        while True:
            params = {
                "action": "query",
                "list": "allpages",
                "apnamespace": "0",
                "apprefix": prefix,
                "aplimit": "max",
            }
            params.update(cont)
            data = self.api_get(params)
            for pg in (data.get("query") or {}).get("allpages") or []:
                t = pg.get("title") or ""
                if t.startswith(prefix):
                    out.append(str(t))
            nxt = data.get("continue") or {}
            if not nxt:
                break
            cont = {str(k): str(v) for k, v in nxt.items()}
        return sorted(set(out), key=lambda t: chapter_sort_key(prefix.rstrip("/"), t))

    def discover_subpages_from__html(self, _title: str) -> List[str]:
        html = self.fetch_html(_title)
        if not html or BeautifulSoup is None:
            return []
        soup = BeautifulSoup(html, "html.parser")
        body = soup.find("div", class_="mw-parser-output") or soup
        prefix = _title + "/"
        out: List[str] = []
        # Prefer ordered table-of-contents list links first.
        for container in body.select("ol, ul"):
            for a in container.select("a[title]"):
                t = a.get("title") or ""
                if t.startswith(prefix) and t not in out:
                    out.append(t)
        # Some old Wikisource pages do not use ol/ul around the contents.
        for a in body.select("a[title]"):
            t = a.get("title") or ""
            if t.startswith(prefix) and t not in out:
                out.append(t)
        return sorted(out, key=lambda t: chapter_sort_key(_title, t))

    def discover_work_parts(self, _title: str, *, method: str = "both") -> List[str]:
        _title = canonical__from_title(_title)
        prefix = _title + "/"
        out: List[str] = []
        if method in {"html", "both", "full"}:
            out.extend(self.discover_subpages_from__html(_title))
        if method in {"links", "both", "full"}:
            out.extend(t for t in self.fetch_links(_title) if t.startswith(prefix))
        if method in {"allpages", "full"}:
            out.extend(self.fetch_allpages_prefix(prefix))
        clean: List[str] = []
        bad_tail_patterns = ("/doc", "/sandbox", "/沙盒")
        for t in sorted(set(out), key=lambda x: chapter_sort_key(_title, x)):
            if not t.startswith(prefix):
                continue
            if any(t.endswith(pat) for pat in bad_tail_patterns):
                continue
            if t not in clean:
                clean.append(t)
        return clean

    def fetch_rescraped_clean_page(self, page_title: str) -> Tuple[str, List[str]]:
        html = self.fetch_html(page_title)
        clean = clean_html_to_text(html) if html else ""
        cats = self.fetch_categories(page_title)
        return clean, cats

    def _add_author_candidate(self, pairs: List[Tuple[str, str]], raw: str, source: str) -> None:
        if not raw:
            return
        names = extract_names_from_wiki_value(raw)
        if not names:
            names = [raw]
        for name in names:
            name = cleanup_author_name(name)
            if not name:
                continue
            if name.startswith(("Category:", "分類:")):
                continue
            if not any(existing == name for existing, _src in pairs):
                pairs.append((name, source))

    def find_author_candidates_for_page(self, page_title: str, local_meta: Dict[str, str]) -> List[str]:
        """Return verified Author-page candidates, prioritising local metadata.

        Evidence order:
          1. local # AUTHOR field
          2. author/translator fields in the page wikitext
          3. explicit Author:/作者: links in wikitext, API links, and rendered HTML
          4. cautious short-name category fallback

        Author-page titles are runtime/audit evidence only. They are never
        written to corpus headers, because AUTHOR_PAGE is not part of the
        corpus metadata schema.
        """
        raw_pairs: List[Tuple[str, str]] = []

        # Layer 1: local corpus metadata. If this gives us a real Author page,
        # stop here. This saves requests and honours the local-first rule.
        self._add_author_candidate(raw_pairs, local_meta.get("AUTHOR", ""), "metadata:AUTHOR")
        if raw_pairs:
            titles = [f"Author:{cleanup_author_name(c)}" for c, _src in raw_pairs if cleanup_author_name(c)]
            exists_map = self.page_exists_many(titles)
            clean_local: List[str] = []
            sources: List[Dict[str, str]] = []
            for c, source in raw_pairs:
                c = cleanup_author_name(c)
                if not c or c in clean_local:
                    continue
                title = f"Author:{c}"
                exists = exists_map.get(title, False)
                sources.append({"candidate": c, "source": source, "author_page": title, "exists": "1" if exists else "0"})
                if exists:
                    clean_local.append(c)
            if clean_local:
                self.last_author_candidate_sources = sources
                return clean_local

        # Layer 2-3: fetch the page once and mine wikitext + links + HTML.
        try:
            bundle = self.fetch_parse_bundle(page_title)
        except Exception:
            bundle = {"html": "", "wikitext": "", "links": []}

        wikitext = str(bundle.get("wikitext") or "")
        if wikitext:
            field_names = ["author", "作者", "override_author", "translator", "譯者", "译者"]
            for field in field_names:
                pat = r"\|\s*" + re.escape(field) + r"\s*=\s*([^\n|{}]+)"
                for m in re.finditer(pat, wikitext, re.I):
                    self._add_author_candidate(raw_pairs, m.group(1).strip(), f"wikitext:{field}")
            for m in re.finditer(r"\[\[(?:Author:|作者:)([^\]|]+)(?:\|([^\]]+))?\]\]", wikitext):
                self._add_author_candidate(raw_pairs, m.group(2) or m.group(1), "wikitext:author-link")

        links = list(bundle.get("links") or [])
        for link in links:
            for pref in AUTHOR_NS_PREFIXES:
                if str(link).startswith(pref):
                    self._add_author_candidate(raw_pairs, str(link).split(":", 1)[1].strip(), "parse-links:author-link")

        html = str(bundle.get("html") or "")
        if html and BeautifulSoup is not None:
            soup = BeautifulSoup(html, "html.parser")
            for a in soup.select("a[title]"):
                t = a.get("title") or ""
                for pref in AUTHOR_NS_PREFIXES:
                    if t.startswith(pref):
                        self._add_author_candidate(raw_pairs, t.split(":", 1)[1].strip(), "html:author-link")

        # Layer 4: local WS category fallback only. This is deliberately narrow.
        for cat in split_meta_list(local_meta.get("WS_CATEGORIES", "")):
            if is_plausible_author_candidate(cat):
                self._add_author_candidate(raw_pairs, cat, "metadata:WS_CATEGORIES:cautious-name")

        clean: List[str] = []
        sources: List[Dict[str, str]] = []
        title_for_candidate: Dict[str, str] = {}
        for c, _source in raw_pairs:
            c = cleanup_author_name(c)
            if c and c not in title_for_candidate:
                title_for_candidate[c] = f"Author:{c}"
        exists_map = self.page_exists_many(list(title_for_candidate.values()))

        for c, source in raw_pairs:
            c = cleanup_author_name(c)
            if not c:
                continue
            title = title_for_candidate.get(c, f"Author:{c}")
            exists = exists_map.get(title, False)
            sources.append({"candidate": c, "source": source, "author_page": title, "exists": "1" if exists else "0"})
            if exists and c not in clean:
                clean.append(c)
        self.last_author_candidate_sources = sources
        return clean

    def fetch_author_description(self, author: str) -> str:
        title = f"Author:{author}"
        html = self.fetch_html(title)
        if not html:
            return ""
        if BeautifulSoup is None:
            text = re.sub(r"<[^>]+>", " ", html)
            return compact_author_description(text)
        soup = BeautifulSoup(html, "html.parser")
         = soup.find(class_="mw-parser-output") or soup
        for bad in .select("script, style, table, .mw-editsection, .toc, .catlinks, .printfooter, .ws-noexport, .noprint"):
            bad.decompose()
        text = .get_text(" ", strip=True)
        return compact_author_description(text)




def chinese_num_to_int(raw: str) -> Optional[int]:
    raw = (raw or "").strip().replace("第", "").replace("卷", "")
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


def chapter_sort_key(_title: str, page_title: str) -> Tuple[int, int, str]:
    if page_title == _title:
        return (0, 0, "")
    label = page_title[len(_title) + 1:] if page_title.startswith(_title + "/") else page_title
    last = label.split("/")[-1]
    front_order = {"序": 1, "敘": 1, "原序": 2, "自序": 2, "緣起": 3, "凡例": 4, "目錄": 5, "目录": 5}
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


def html_to_text_inline_preserving(: Any) -> str:
    parts: List[str] = []

    def walk(node: Any) -> None:
        if BeautifulSoup is None:
            return
        from bs4 import NavigableString, Tag  # type: ignore
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

    walk()
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
    return {str(c) for c in classes if c}, str(attrs.get("id", "") or "")


def _looks_like_wikisource_header_or_nav(tag: Any) -> bool:
    attrs = getattr(tag, "attrs", None)
    if attrs is None:
        return False
    classes, ident = _classes_and_id(tag)
    haystack = " ".join(list(classes) + [ident]).lower()
    furniture_needles = [
        "wst-header", "ws-header", "wikisource-header", "headertemplate", "header-template",
        "headercontainer", "licensecontainer", "catlinks", "printfooter", "mw-editsection",
        "toc", "ws-noexport", "noprint",
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


def remove_wikisource_furniture(: Any) -> None:
    for selector in [
        "script", "style", "noscript", ".mw-editsection", ".references", ".reference",
        ".mw-navigation", ".navbox", ".toc", ".catlinks", ".printfooter",
        ".licenseContainer", ".ws-noexport", "table",
    ]:
        for elem in list(.select(selector)):
            if getattr(elem, "attrs", None) is not None:
                elem.decompose()
    for tag in list(.find_all(True)):
        if getattr(tag, "attrs", None) is None:
            continue
        classes, _ident = _classes_and_id(tag)
        if classes & DROP_CLASSES or _looks_like_wikisource_header_or_nav(tag):
            tag.decompose()


def strip_public_domain_footer(text: str) -> str:
    cut_idx = len(text)
    for marker in PD_MARKERS:
        idx = text.find(marker)
        if idx != -1 and idx < cut_idx:
            cut_idx = idx
    return text[:cut_idx].rstrip() if cut_idx != len(text) else text


def fix_brackets_strong(text: str, open_br: str, close_br: str) -> str:
    pattern = re.compile(re.escape(open_br) + r"(.*?)" + re.escape(close_br), re.DOTALL)
    def repl(m: re.Match[str]) -> str:
        inner = re.sub(r"[ \t\r\n]+", "", m.group(1))
        return f"{open_br}{inner}{close_br}"
    return pattern.sub(repl, text)


def normalize_inline_artifacts(text: str) -> str:
    for open_br, close_br in BRACKET_PAIRS_STRONG:
        text = fix_brackets_strong(text, open_br, close_br)
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
    text = "\n".join(out)
    text = re.sub(r"[ \t]+([，、。；：？！）》〉」』])", r"\1", text)
    text = re.sub(r"([《〈「『（(])\s+", r"\1", text)
    text = re.sub(r"\s*·\s*", "·", text)
    return text


def clean_html_to_text(html: str) -> str:
    if not html:
        return ""
    if BeautifulSoup is None:
        text = re.sub(r"<[^>]+>", " ", html)
        return strip_public_domain_footer(re.sub(r"\s+", " ", text).strip()) + "\n"
    soup = BeautifulSoup(html, "html.parser")
     = soup.find(class_="mw-parser-output") or soup
    remove_wikisource_furniture()
    text = html_to_text_inline_preserving()
    text = re.sub(r"\n\s*\[\s*编辑\s*\]\s*\n", "\n", text)
    text = re.sub(r"\n\s*\[\s*編輯\s*\]\s*\n", "\n", text)
    text = normalize_inline_artifacts(text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    text = strip_public_domain_footer(text).strip()
    if "{{header" in text or "{{header2" in text:
        return ""
    return text + "\n" if text else ""


def looks_like_contents_body(body: str) -> bool:
    lines = [ln.strip() for ln in (body or "").splitlines() if ln.strip()]
    if not lines:
        return False
    head = "\n".join(lines[:80])
    hints = len(CONTENTS_HINT_RE.findall(head))
    short_lines = sum(1 for ln in lines[:80] if 1 <= len(ln) <= 18)
    return ("目錄" in head or "目录" in head or hints >= 3) and short_lines >= min(8, len(lines))


def canonical__from_title(title: str) -> str:
    title = (title or "").strip()
    if "/" in title:
        return title.split("/", 1)[0]
    return title


def existing_titles_for_group(group: WorkGroup) -> Set[str]:
    titles: Set[str] = set()
    for rec in group.files:
        for t in [rec.meta.get("PAGE_TITLE", ""), rec.page_title, wikisource_url_to_title(rec.meta.get("SOURCE_URL", ""))]:
            if t:
                titles.add(t)
    return titles


def choose__title_for_discovery(group: WorkGroup) -> str:
    sample = group.files[0]
    # SOURCE_URL and PAGE_TITLE are usually the most faithful Wikisource identifiers.
    for raw in [wikisource_url_to_title(sample.meta.get("SOURCE_URL", "")), sample.page_title, sample.work_title]:
        raw = (raw or "").strip()
        if raw:
            return canonical__from_title(raw)
    return canonical__from_title(work_folder_name_from_group(group))


def should_discover_missing_parts(group: WorkGroup, mode: str, max_existing_files: int) -> bool:
    if mode == "all":
        return True
    if group.file_count <= max_existing_files:
        return True
    return any(looks_like_contents_body(f.body) for f in group.files[:3])


def discovered_part_filename(_title: str, page_title: str, seq: int) -> str:
    chapter = page_title[len(_title) + 1:] if page_title.startswith(_title + "/") else page_title
    if not chapter or chapter == _title:
        chapter = "front_matter"
    return f"{safe_filename(_title)}__rescraped_{seq:04d}__{safe_filename(chapter)}.txt"

def is_plausible_author_candidate(name: str) -> bool:
    """Return True for short human-name-like strings only.

    This stops the script from probing Author:<every Wikisource category>, which
    caused many pointless missing-page lookups and helped trigger 429s.
    """
    name = cleanup_author_name(name)
    if not name:
        return False
    if not re.fullmatch(r"[一-龥·]{2,6}", name):
        return False
    bad_terms = [
        "維基", "文庫", "中國", "作品", "詩", "文", "賦", "傳", "書", "集", "卷", "年", "朝",
        "晉朝", "西晉", "東晉", "十六國", "小朝", "不詳", "公有領域", "作者", "譯者",
    ]
    return not any(term in name for term in bad_terms)


def cleanup_author_name(name: str) -> str:
    name = re.sub(r"\[\[(?:Author:|作者:)?([^\]|]+)(?:\|[^\]]+)?\]\]", r"\1", name)
    name = re.sub(r"<[^>]+>", "", name)
    name = re.sub(r"[{}\[\]#*'\"]", "", name)
    name = name.strip()
    name = re.sub(r"\s+", "", name)
    for prefix in ["Author:", "作者:"]:
        if name.startswith(prefix):
            name = name.split(":", 1)[1]
    return name.strip()


def extract_names_from_wiki_value(raw: str) -> List[str]:
    out: List[str] = []
    for m in re.finditer(r"\[\[(?:Author:|作者:)?([^\]|]+)(?:\|([^\]]+))?\]\]", raw):
        out.append(m.group(2) or m.group(1))
    if not out:
        raw = re.sub(r"\{\{.*?\}\}", "", raw)
        out.extend(re.split(r"[、,，;；/／]", raw))
    return [cleanup_author_name(x) for x in out if cleanup_author_name(x)]


def compact_author_description(text: str) -> str:
    text = re.sub(r"\s+", " ", text or "").strip()
    # Author pages often become: "作者:劉楨 ... 字公幹，漢魏文學家... 作品 ..."
    for marker in ["作品", "著作", "子页面", "子頁面", "維基文庫", "Wikisource"]:
        idx = text.find(marker)
        if 20 < idx < 800:
            text = text[:idx]
            break
    return text[:800].strip()


def load_region_rules(path: Optional[Path], discovered_target_paths: Iterable[str]) -> List[RegionRule]:
    rules: List[RegionRule] = []

    # Auto-rules only use folder names that already exist locally. This is safe:
    # it does not create new categories, it only recognises names already present.
    for target in sorted(set(discovered_target_paths)):
        if not target or UNKNOWN_LABEL in target.split("/"):
            continue
        last = target.split("/")[-1]
        rules.append(RegionRule(
            target_path=target,
            aliases=[target, last],
            nation=last,
            confidence="folder-name",
            source="auto-existing-folder",
        ))

    if not path:
        return rules
    if not path.exists():
        raise FileNotFoundError(path)

    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        needed = {"target_path", "aliases"}
        if not reader.fieldnames or not needed.issubset(set(reader.fieldnames)):
            raise SystemExit("region-map CSV needs at least: target_path, aliases")
        for row in reader:
            target = (row.get("target_path") or "").strip().strip("/")
            aliases_raw = (row.get("aliases") or "").strip()
            if not target or not aliases_raw:
                continue
            aliases = [a.strip() for a in re.split(r"[|｜;；]", aliases_raw) if a.strip()]
            rules.append(RegionRule(
                target_path=target,
                aliases=aliases,
                scope=(row.get("scope") or "").strip().strip("/"),
                nation=(row.get("nation") or target.split("/")[-1]).strip(),
                confidence=(row.get("confidence") or "user-map").strip(),
                note=(row.get("note") or "").strip(),
                source="user-map",
            ))
    return rules


def discover_existing_target_paths(records: Sequence[FileRec]) -> List[str]:
    targets = set()
    for r in records:
        rel_without_ = "/".join(r.parts[1:-2]) if len(r.parts) >= 3 else ""
        if rel_without_ and UNKNOWN_LABEL not in rel_without_.split("/"):
            targets.add(rel_without_)
    return sorted(targets)


def _add_parent_dirs(out: Set[str], parts: Sequence[str]) -> None:
    """Add every parent directory represented by parts to out.

    parts should already be in output-relative form, for example:

        ["晉朝", "十六國", "前趙", "某書"]

    This stores:

        晉朝
        晉朝/十六國
        晉朝/十六國/前趙
        晉朝/十六國/前趙/某書
    """
    clean = [p for p in parts if p]
    for i in range(1, len(clean) + 1):
        out.add("/".join(clean[:i]))


def _source_entry_parts_for_skeleton(input_path: Path) -> Tuple[List[Tuple[List[str], bool]], bool]:
    """Return (parts, is_dir) entries from either a folder or a zip.

    This deliberately reads directory entries from zip files as well as file
    paths. Empty state folders are normally represented only by directory
    entries, so a file-only scan loses important corpus structure.
    """
    entries: List[Tuple[List[str], bool]] = []
    if input_path.is_file() and input_path.suffix.lower() == ".zip":
        with zipfile.ZipFile(input_path) as z:
            for info in z.infolist():
                raw = PurePosixPath(info.filename).as_posix().strip("/")
                if not raw:
                    continue
                entries.append((list(PurePosixPath(raw).parts), bool(info.is_dir())))
        return entries, True

    for child in input_path.rglob("*"):
        try:
            rel = child.relative_to(input_path).as_posix().strip("/")
        except Exception:
            continue
        if not rel:
            continue
        entries.append((list(PurePosixPath(rel).parts), child.is_dir()))
    return entries, False


def collect_preservable_dir_skeleton(input_path: Path, _name: str) -> Set[str]:
    """Collect structural directories that should be recreated in output.

    Why this exists:
      - The regionalisation output is meant to replace the old formation.
      - Empty state folders are meaningful placeholders, not junk.
      - If they are missing from the replacement zip, extraction/merge becomes
        unsafe because old 不詳 folders can remain and absorb duplicate material.

    The rule is intentionally practical:
      - preserve container/state directories;
      - do not preserve ordinary work folders that directly contain .txt files.

    A work folder is identified by having direct .txt children. This matches the
    corpus layout: /period-or-state/work/file.txt.
    """
    entries, _is_zip = _source_entry_parts_for_skeleton(input_path)
    if not entries:
        return {_name}

    top_parts = {parts[0] for parts, _is_dir in entries if parts}
    if len(top_parts) == 1 and next(iter(top_parts)) == _name:
        rel_parts_mode = "already_has_"
    else:
        rel_parts_mode = "prefix_input_name"

    all_dirs: Set[str] = set()
    dirs_with_direct_txt: Set[str] = set()

    for raw_parts, is_dir in entries:
        if not raw_parts:
            continue
        if rel_parts_mode == "already_has_":
            parts = raw_parts
        else:
            parts = [_name] + raw_parts

        if is_dir:
            _add_parent_dirs(all_dirs, parts)
            continue

        # File entry: preserve its parent containers, but remember direct text
        # parents as work folders so they can be excluded from the skeleton.
        parent_parts = parts[:-1]
        if parent_parts:
            _add_parent_dirs(all_dirs, parent_parts)
        file_name = parts[-1]
        if file_name.lower().endswith(".txt") and not file_name.endswith(BACKUP_SUFFIXES):
            dirs_with_direct_txt.add("/".join(parent_parts))

    # Keep /container/state dirs, but do not recreate every old work folder
    # as an empty shell after its files are moved or deduped.
    return {d for d in all_dirs if d and d not in dirs_with_direct_txt}


def load_records(input_path: Path) -> Tuple[str, List[FileRec]]:
    tmp_dir: Optional[tempfile.TemporaryDirectory[str]] = None
    source_: Path
    zip_mtime_by_rel: Dict[str, Tuple[float, str]] = {}
    if input_path.is_file() and input_path.suffix.lower() == ".zip":
        tmp_dir = tempfile.TemporaryDirectory(prefix="jin_regionalise_")
        with zipfile.ZipFile(input_path) as z:
            for info in z.infolist():
                if info.is_dir():
                    continue
                rel_name = PurePosixPath(info.filename).as_posix()
                zip_mtime_by_rel[rel_name] = zipinfo_mtime(info)
            z.extractall(tmp_dir.name)
        source_ = Path(tmp_dir.name)
    else:
        source_ = input_path

    txt_paths = [p for p in source_.rglob("*.txt") if not p.name.endswith(BACKUP_SUFFIXES)]
    if not txt_paths:
        raise SystemExit(f"No .txt files found under {input_path}")

    raw_rels = [p.relative_to(source_) for p in txt_paths]
    top_parts = {r.parts[0] for r in raw_rels if r.parts}

    # Two supported input shapes:
    #   1. input is a container holding 晉朝/...          -> keep the existing top component
    #   2. input is the 晉朝 folder itself                 -> prefix rel paths with input folder name
    if len(top_parts) == 1 and (source_ / next(iter(top_parts))).is_dir():
        _name = next(iter(top_parts))
        rel_parts_mode = "already_has_"
    else:
        _name = input_path.stem if input_path.is_file() else input_path.name
        rel_parts_mode = "prefix_input_name"

    records: List[FileRec] = []
    for p in sorted(txt_paths):
        rel_from_source = p.relative_to(source_).as_posix()
        raw_parts = list(PurePosixPath(rel_from_source).parts)
        if rel_parts_mode == "already_has_":
            parts = raw_parts
            rel = rel_from_source
        else:
            parts = [_name] + raw_parts
            rel = "/".join(parts)
        candidate_ = _name

        text = read_text_file(p)
        meta, body = parse_header_and_body(text)
        work_dir = parts[-2] if len(parts) >= 2 else safe_filename(meta.get("WORK_TITLE", p.stem))
        work_title = meta.get("WORK_TITLE") or work_dir
        page_title = meta.get("PAGE_TITLE") or work_title
        if not meta.get("WORK_TITLE"):
            meta["WORK_TITLE"] = work_title
        if not meta.get("DISPLAY_TITLE"):
            meta["DISPLAY_TITLE"] = work_title
        if not meta.get("PAGE_TITLE"):
            meta["PAGE_TITLE"] = page_title

        unknown_index = None
        for idx, part in enumerate(parts[:-2]):
            if part == UNKNOWN_LABEL:
                unknown_index = idx
                break
        is_unknown = unknown_index is not None
        if is_unknown:
            context_parts = parts[1:unknown_index] if unknown_index is not None else parts[1:-2]
        else:
            context_parts = parts[1:-2]
        context_rel = "/".join(context_parts)
        group_rel = "/".join(parts[:-1])
        if rel_from_source in zip_mtime_by_rel:
            source_mtime_sort, source_mtime_utc = zip_mtime_by_rel[rel_from_source]
        else:
            try:
                source_mtime_sort = float(p.stat().st_mtime)
                source_mtime_utc = file_mtime_to_iso(source_mtime_sort)
            except Exception:
                source_mtime_sort, source_mtime_utc = 0.0, ""
        records.append(FileRec(
            rel_path=rel,
            parts=parts,
            text=text,
            meta=meta,
            body=body,
            work_title=work_title,
            page_title=page_title,
            work_dir=work_dir,
            =candidate_,
            unknown_index=unknown_index,
            context_rel=context_rel,
            group_rel=group_rel,
            body_chars=len(body),
            sha1=sha1_text(body),
            is_unknown=is_unknown,
            source_mtime_sort=source_mtime_sort,
            source_mtime_utc=source_mtime_utc,
        ))

    # Keep temporary directory alive by copying data into memory already. It can close now.
    if tmp_dir is not None:
        tmp_dir.cleanup()
    return _name or input_path.name, records


def make_work_groups(records: Sequence[FileRec]) -> Dict[Tuple[str, str], WorkGroup]:
    groups: Dict[Tuple[str, str], WorkGroup] = {}
    for rec in records:
        key = (rec.group_rel, norm_title(rec.work_title))
        if key not in groups:
            groups[key] = WorkGroup(key=key[1], group_rel=rec.group_rel)
        groups[key].files.append(rec)
    return groups


def top_rel_after_(group_rel: str) -> str:
    parts = group_rel.split("/")
    return "/".join(parts[1:-1]) if len(parts) >= 2 else ""


def work_folder_name_from_group(group: WorkGroup) -> str:
    return group.group_rel.split("/")[-1]


def allowed_target_for_unknown(rec: FileRec, target_path: str, *, minor_folder: str, allow_minor_from: str) -> Tuple[bool, str]:
    target_path = target_path.strip("/")
    target_parts = target_path.split("/") if target_path else []
    context = rec.context_rel.strip("/")

    # -level 不詳, e.g. 晉朝/不詳, may move to any target below the .
    if not context:
        return True, "-unknown"

    # Nested 不詳 may move inside its own context.
    if target_path == context or target_path.startswith(context + "/"):
        return True, "inside-current-container"

    # Explicit 小朝 exception, controlled by command options.
    if allow_minor_from and context == allow_minor_from and target_parts and target_parts[0] == minor_folder:
        return True, "minor-exception"

    return False, "blocked-by-nested-unknown-rule"


def derive_from_text_evidence(
    text: str,
    rules: Sequence[RegionRule],
    rec: FileRec,
    *,
    minor_folder: str,
    allow_minor_from: str,
) -> Tuple[str, str, str, str, str]:
    """Return target_path, nation, reason, matched_alias, confidence."""
    hay = text or ""
    matches: List[Tuple[int, RegionRule, str, str]] = []
    for rule in rules:
        if rule.scope and rec.context_rel and rule.scope != rec.context_rel and not rec.context_rel.startswith(rule.scope + "/"):
            # Scope is intentionally conservative. Blank scope applies anywhere.
            continue
        ok, why = allowed_target_for_unknown(rec, rule.target_path, minor_folder=minor_folder, allow_minor_from=allow_minor_from)
        if not ok:
            continue
        for alias in rule.aliases:
            if alias and alias in hay:
                # Longer aliases beat shorter aliases. User-map beats auto folder-name.
                source_bonus = 1000 if rule.source == "user-map" else 0
                matches.append((source_bonus + len(alias), rule, alias, why))
    if not matches:
        return "", "", "", "", ""
    matches.sort(key=lambda x: x[0], reverse=True)
    _score, rule, alias, why = matches[0]
    return rule.target_path, (rule.nation or rule.target_path.split("/")[-1]), why, alias, rule.confidence


def local_evidence_text(rec: FileRec) -> str:
    bits: List[str] = []
    for key in ["NATION", "CATEGORIES", "WS_CATEGORIES", "AUTHOR", "WORK_TITLE", "DISPLAY_TITLE", "PAGE_TITLE", "SOURCE_URL"]:
        if rec.meta.get(key):
            bits.append(rec.meta[key])
    # Include a small opening slice: Buddhist translations often state 姚秦三藏...
    bits.append(rec.body[:800])
    return "\n".join(bits)


def choose_page_title_for_fetch(rec: FileRec) -> str:
    if rec.meta.get("SOURCE_URL"):
        t = wikisource_url_to_title(rec.meta["SOURCE_URL"])
        if t:
            return t
    return rec.page_title or rec.work_title


def normalised_output_text(rec: FileRec, *, nation: str, author: str = "", ws_categories: str = "", source_url: str = "") -> str:
    meta = dict(rec.meta)
    work_title = meta.get("WORK_TITLE") or rec.work_title
    page_title = meta.get("PAGE_TITLE") or rec.page_title or work_title
    meta["WORK_TITLE"] = work_title
    meta["DISPLAY_TITLE"] = meta.get("DISPLAY_TITLE") or work_title
    meta["PAGE_TITLE"] = page_title
    meta["AUTHOR"] = author or meta.get("AUTHOR", "")
    meta["NATION"] = nation or meta.get("NATION", "")
    meta["CATEGORIES"] = meta.get("CATEGORIES", "")
    meta["YEAR"] = meta.get("YEAR", "")
    meta["CHAPTER"] = meta.get("CHAPTER") or infer_chapter(work_title, page_title, rec.parts[-1])
    meta["SOURCE_URL"] = source_url or meta.get("SOURCE_URL") or title_to_wikisource_url(page_title)
    meta["WS_CATEGORIES"] = ws_categories or meta.get("WS_CATEGORIES", "")
    meta["SCRAPED_AT_UTC"] = meta.get("SCRAPED_AT_UTC", "")
    text_out = build_header(meta) + (rec.body.strip() + "\n" if rec.body.strip() else "")
    assert_approved_header_only(text_out)
    return text_out


def output_rel_for_rec(_name: str, target_path: str, work_folder: str, file_name: str) -> str:
    parts = [_name]
    if target_path:
        parts.extend([p for p in target_path.split("/") if p])
    parts.append(safe_filename(work_folder))
    parts.append(file_name)
    return "/".join(parts)


def write_csv(path: Path, rows: List[Dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fieldnames: List[str] = []
    for row in rows:
        for k in row.keys():
            if k not in fieldnames:
                fieldnames.append(k)
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for row in rows:
            w.writerow(row)


def normalise_manual_review_rows(rows: List[Dict[str, object]]) -> List[Dict[str, object]]:
    """Return a stable, spreadsheet-friendly manual review queue.

    Rows come from several sources (duplicate discrepancy, blocked duplicate,
    unresolved unknown), so this flattens them into one predictable set of
    columns and sorts high-priority work to the top.
    """
    preferred = [
        "priority",
        "review_type",
        "suggested_action",
        "reason",
        "work_title",
        "title_key",
        "group",
        "unknown_group",
        "named_groups",
        "target",
        "newest_candidate_group",
        "newest_timestamp",
        "newest_timestamp_source",
        "context",
        "page_title",
        "source_url",
        "files",
        "chars",
        "unknown_files",
        "unknown_chars",
        "named_file_counts",
        "named_chars",
        "pages",
        "unknown_pages",
        "named_pages",
        "ws_categories",
        "author_candidates",
        "author",
    ]
    priority_rank = {"high": 0, "medium": 1, "low": 2}
    out: List[Dict[str, object]] = []
    for row in rows:
        fixed = {key: row.get(key, "") for key in preferred}
        # Keep any extra columns at the end rather than silently dropping audit evidence.
        for key, value in row.items():
            if key not in fixed:
                fixed[key] = value
        out.append(fixed)
    out.sort(key=lambda r: (priority_rank.get(str(r.get("priority", "medium")), 9), str(r.get("review_type", "")), str(r.get("work_title", "")), str(r.get("group", "") or r.get("unknown_group", ""))))
    return out


def make_zip_from_dir(src_dir: Path, zip_path: Path) -> None:
    """Zip an output directory, preserving empty directories.

    zipfile.write() on files alone loses empty folders. For this corpus work,
    empty region/state folders are part of the replacement structure, so we
    explicitly write directory entries too.
    """
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for p in sorted(src_dir.rglob("*")):
            rel = p.relative_to(src_dir.parent).as_posix()
            if p.is_dir():
                z.writestr(rel.rstrip("/") + "/", "")
            elif p.is_file():
                z.write(p, rel)


def create_blank_map(path: Path, existing_targets: Sequence[str]) -> None:
    rows = []
    for target in existing_targets:
        if UNKNOWN_LABEL in target.split("/"):
            continue
        rows.append({
            "target_path": target,
            "aliases": target.split("/")[-1],
            "scope": "",
            "nation": target.split("/")[-1],
            "confidence": "starter",
            "note": "auto-created from existing folder; edit aliases before using",
        })
    write_csv(path, rows)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Regionalise nested 不詳 folders with local-first metadata and optional Wikisource author lookup.")
    ap.add_argument("--version", action="version", version=SCRIPT_VERSION, help="Print script version and exit.")
    ap.add_argument("input", help="Input corpus folder or .zip")
    ap.add_argument("output", help="Output folder to create")
    ap.add_argument("--overwrite", action="store_true", help="Delete output folder first if it already exists.")
    ap.add_argument("--no-preserve-empty-dirs", dest="preserve_empty_dirs", action="store_false", help="Do not recreate the input container/state folder skeleton. Default preserves it so the output can safely replace the old formation.")
    ap.set_defaults(preserve_empty_dirs=True)
    ap.add_argument("--dry-run", action="store_true", help="Write audits only; do not write copied corpus files.")
    ap.add_argument("--verbose", action="store_true", help="Print detailed stage-by-stage progress, including per-group decisions and Wikisource lookup activity.")
    ap.add_argument("--progress-every", type=int, default=100, help="In normal mode, print one progress line every N groups/files during long loops. Default: 100.")
    ap.add_argument("--region-map", type=Path, default=None, help="CSV mapping aliases to target_path. See script docstring.")
    ap.add_argument("--init-region-map", type=Path, default=None, help="Write a starter map from existing local folders and exit.")
    ap.add_argument("--fetch-ws-categories", action="store_true", help="Fetch missing page categories from zh.wikisource.")
    ap.add_argument("--author-lookup", action="store_true", help="When still unresolved, follow Author: pages and parse the description.")
    ap.add_argument("--always-fetch-author", action="store_true", help="Fetch author page even when local/page categories already resolve the target. Useful for audit enrichment.")
    ap.add_argument("--discover-missing-parts", action="store_true", help="Check /table-of-contents pages for missing Wikisource subpages and scrape them into the output.")
    ap.add_argument("--discover-parts-scope", choices=["unknown", "all"], default="unknown", help="Which work groups to test for missing subpages. Default: unknown only.")
    ap.add_argument("--discover-parts-mode", choices=["smart", "all"], default="smart", help="smart checks small/contents-like groups; all checks every group in scope.")
    ap.add_argument("--discover-parts-method", choices=["html", "links", "allpages", "both", "full"], default="both", help="How to discover missing subpages. full also tries allpages prefix.")
    ap.add_argument("--discover-parts-max-existing-files", type=int, default=2, help="In smart mode, only auto-check groups with this many existing files or fewer unless they look contents-like.")
    ap.add_argument("--max-discovered-parts-per-work", type=int, default=300, help="Safety cap for newly discovered parts per work.")
    ap.add_argument("--sleep", type=float, default=1.2, help="Seconds between Wikisource API requests. Default is deliberately polite to avoid 429 rate limits.")
    ap.add_argument("--user-agent", default=USER_AGENT, help="Wikimedia API User-Agent. Default uses the project contact string; can also be set with FANYA_WIKISOURCE_USER_AGENT.")
    ap.add_argument("--minor-folder", default="小朝", help="Relative folder name used for small/minor court exceptions.")
    ap.add_argument("--allow-minor-from", default="十六國", help="Nested context allowed to move to --minor-folder. Blank disables this exception.")
    ap.add_argument("--partial-overlap-ratio", type=float, default=5.0, help="If unknown duplicate has this many times more files than named duplicate, do not dedupe automatically.")
    ap.add_argument("--partial-overlap-min-gap", type=int, default=10, help="Minimum file-count gap before partial-overlap protection triggers.")
    ap.add_argument("--allow-large-coverage-move", action="store_true", help="Disable partial-overlap protection.")
    ap.add_argument("--make-zip", action="store_true", help="Also write OUTPUT.zip next to the output folder.")
    args = ap.parse_args(argv)

    log_progress(args, f"[start] {SCRIPT_VERSION}")
    log_progress(args, f"[mode] dry_run={args.dry_run} overwrite={args.overwrite} make_zip={args.make_zip}")
    log_progress(args, f"[online] fetch_ws_categories={args.fetch_ws_categories} author_lookup={args.author_lookup} always_fetch_author={args.always_fetch_author} discover_missing_parts={args.discover_missing_parts}")
    log_progress(args, f"[throttle] sleep={args.sleep}s")
    log_progress(args, f"[schema] corpus headers locked to: {', '.join(HEADER_KEYS)}", verbose_only=True)

    input_path = Path(args.input).expanduser().resolve()
    out_dir = Path(args.output).expanduser().resolve()
    audit_dir = out_dir / "_audit"

    log_progress(args, f"[input] {input_path}")
    log_progress(args, f"[output] {out_dir}")
    _name, records = load_records(input_path)
    input_dir_skeleton = collect_preservable_dir_skeleton(input_path, _name)
    existing_targets = discover_existing_target_paths(records)
    log_progress(args, f"[load] ={_name} records={len(records)} existing_target_paths={len(existing_targets)} skeleton_dirs={len(input_dir_skeleton)}")

    if args.init_region_map:
        create_blank_map(args.init_region_map.expanduser().resolve(), existing_targets)
        print(f"Wrote starter map: {args.init_region_map}")
        return 0

    rules = load_region_rules(args.region_map.expanduser().resolve() if args.region_map else None, existing_targets)
    log_progress(args, f"[rules] loaded_alias_rules={len(rules)} region_map={args.region_map or '(auto from folders)'}")

    if out_dir.exists():
        if args.overwrite:
            log_progress(args, f"[output] removing existing output folder: {out_dir}")
            shutil.rmtree(out_dir)
        else:
            raise SystemExit(f"Output exists: {out_dir}. Use --overwrite or choose another output folder.")
    out_dir.mkdir(parents=True, exist_ok=True)
    audit_dir.mkdir(parents=True, exist_ok=True)

    preserved_dir_rows: List[Dict[str, object]] = []
    preserved_dirs: Set[str] = set()
    if args.preserve_empty_dirs:
        preserved_dirs.update(input_dir_skeleton)
        # Region-map targets are user-supplied structural folders, so preserve
        # them too even if no file lands there in this run. This does not add
        # metadata or invent categories; it only creates directories.
        for rule in rules:
            if rule.target_path:
                preserved_dirs.add("/".join([_name] + [p for p in rule.target_path.split("/") if p]))
        for rel_dir in sorted(preserved_dirs):
            if not args.dry_run:
                (out_dir / rel_dir).mkdir(parents=True, exist_ok=True)
            preserved_dir_rows.append({
                "rel_dir": rel_dir,
                "status": "would_create" if args.dry_run else "created_or_already_present",
                "reason": "input_container_or_state_skeleton_or_region_map_target",
            })
        log_progress(args, f"[skeleton] preserved_dirs={len(preserved_dirs)}" + (" (dry-run audit only)" if args.dry_run else ""))
    else:
        log_progress(args, "[skeleton] disabled by --no-preserve-empty-dirs")

    log_progress(args, f"[audit] {audit_dir}")

    wiki: Optional[WikiClient] = None
    if args.fetch_ws_categories or args.author_lookup or args.always_fetch_author or args.discover_missing_parts:
        wiki = WikiClient(sleep=args.sleep, user_agent=args.user_agent)
        log_progress(args, f"[api] Wikisource client enabled; user_agent={args.user_agent}", verbose_only=True)
    else:
        log_progress(args, "[api] offline/local-only mode")

    groups_by_path = make_work_groups(records)
    groups_by_rel: Dict[str, WorkGroup] = {g.group_rel: g for g in groups_by_path.values()}
    groups_by_title: Dict[str, List[WorkGroup]] = {}
    for group in groups_by_path.values():
        groups_by_title.setdefault(group.key, []).append(group)
    unknown_group_count = sum(1 for g in groups_by_path.values() if any(f.is_unknown for f in g.files))
    log_progress(args, f"[group] work_groups={len(groups_by_path)} title_keys={len(groups_by_title)} unknown_groups={unknown_group_count}")

    written_paths: Dict[str, str] = {}
    skipped_group_rels = set()
    decisions: List[Dict[str, object]] = []
    partial_rows: List[Dict[str, object]] = []
    rescrape_rows: List[Dict[str, object]] = []
    manual_review_rows: List[Dict[str, object]] = []
    unresolved_rows: List[Dict[str, object]] = []
    file_audit_rows: List[Dict[str, object]] = []
    author_rows: List[Dict[str, object]] = []
    place_rows: List[Dict[str, object]] = []
    discovered_part_rows: List[Dict[str, object]] = []

    # First pass: dedupe unknown groups against named duplicates.
    log_progress(args, "[pass 1/4] dedupe unknown groups: newest identical scrape wins; discrepancies go to rescrape/manual review")
    target_for_group: Dict[str, Tuple[str, str, str]] = {}  # group_rel -> target_path, nation, reason
    enrichment_for_group: Dict[str, Dict[str, str]] = {}  # group_rel -> fetched metadata to write back
    for title_i, (title_key, same_title_groups) in enumerate(groups_by_title.items(), start=1):
        progress_tick(args, title_i, len(groups_by_title), "dedupe-title-keys")
        unknown_groups = [g for g in same_title_groups if any(f.is_unknown for f in g.files)]
        named_groups = [g for g in same_title_groups if not any(f.is_unknown for f in g.files)]
        if not unknown_groups or not named_groups:
            continue

        for unk in unknown_groups:
            sample = unk.files[0]
            allowed_named: List[WorkGroup] = []
            blocked_named: List[Tuple[WorkGroup, str, str]] = []
            for named in named_groups:
                named_target = top_rel_after_(named.group_rel)
                ok, why_allowed = allowed_target_for_unknown(sample, named_target, minor_folder=args.minor_folder, allow_minor_from=args.allow_minor_from)
                if ok:
                    allowed_named.append(named)
                else:
                    blocked_named.append((named, named_target, why_allowed))

            if not allowed_named:
                for named, named_target, why_allowed in blocked_named:
                    log_progress(args, f"[dedupe:block] {unk.group_rel} -> {named_target} blocked: {why_allowed}", verbose_only=True)
                decisions.append({
                    "decision": "blocked_duplicate_target",
                    "title_key": title_key,
                    "unknown_group": unk.group_rel,
                    "named_groups": " | ".join(g.group_rel for g in named_groups),
                    "reason": "all named duplicate targets blocked by nested-unknown rule",
                })
                manual_review_rows.append(make_duplicate_review_row(
                    review_type="blocked_duplicate_target",
                    priority="medium",
                    title_key=title_key,
                    unknown_group=unk,
                    named_groups=named_groups,
                    reason="all named duplicate targets blocked by nested-unknown rule",
                    suggested_action="manual_check_container; do_not_move_out_of_nested_unknown",
                ))
                continue

            allowed_targets = sorted({top_rel_after_(g.group_rel) for g in allowed_named})
            if len(allowed_targets) > 1:
                reason = "multiple_allowed_named_targets"
                log_progress(args, f"[dedupe:review] {unk.group_rel}; same title appears in multiple allowed targets: {allowed_targets}", verbose_only=True)
                row = make_duplicate_review_row(
                    review_type="duplicate_multiple_named_targets",
                    priority="high",
                    title_key=title_key,
                    unknown_group=unk,
                    named_groups=allowed_named,
                    reason=reason,
                    suggested_action="manual_review_before_merge; possible homonymous works or bad old regionalisation",
                )
                manual_review_rows.append(row)
                rescrape_rows.append(dict(row, rescrape_reason=reason))
                continue

            named_target = allowed_targets[0]
            duplicate_set = [unk] + allowed_named
            discrepancy = duplicate_discrepancy_reason(duplicate_set)
            if discrepancy:
                reason = f"duplicate_discrepancy:{discrepancy}"
                log_progress(args, f"[dedupe:rescrape] {unk.group_rel}; {reason}", verbose_only=True)
                row = make_duplicate_review_row(
                    review_type="duplicate_discrepancy_rescrape",
                    priority="high",
                    title_key=title_key,
                    unknown_group=unk,
                    named_groups=allowed_named,
                    reason=reason,
                    suggested_action="rescrape_from_wikisource_then_replace_duplicates; keep both local copies until reviewed",
                )
                manual_review_rows.append(row)
                rescrape_rows.append(dict(row, target=named_target, rescrape_reason=reason))
                partial_rows.append({
                    "title_key": title_key,
                    "unknown_group": unk.group_rel,
                    "unknown_files": unk.file_count,
                    "unknown_chars": unk.total_body_chars,
                    "named_group": " | ".join(g.group_rel for g in allowed_named),
                    "named_files": " | ".join(str(g.file_count) for g in allowed_named),
                    "named_chars": " | ".join(str(g.total_body_chars) for g in allowed_named),
                    "suggestion": "rescrape_before_dedupe",
                    "reason": reason,
                    "unknown_pages": compact_group_pages(unk),
                    "named_pages": " || ".join(compact_group_pages(g) for g in allowed_named),
                })
                continue

            winner = max(duplicate_set, key=group_newest_sort_key)
            newest_ts, newest_source, newest_display = group_newest_recency(winner)
            if winner.group_rel == unk.group_rel:
                log_progress(args, f"[dedupe:move-newest] newest unknown scrape wins: {unk.group_rel} -> {named_target}", verbose_only=True)
                target_for_group[unk.group_rel] = (named_target, named_target.split("/")[-1], f"duplicate_newest_scrape_wins:{newest_source}={newest_display}")
                for named in allowed_named:
                    skipped_group_rels.add(named.group_rel)
                decisions.append({
                    "decision": "move_unknown_newest_to_named_target",
                    "title_key": title_key,
                    "unknown_group": unk.group_rel,
                    "named_group": " | ".join(g.group_rel for g in allowed_named),
                    "target": named_target,
                    "newest_group": winner.group_rel,
                    "newest_timestamp": newest_display,
                    "newest_timestamp_source": newest_source,
                    "duplicate_signature": "same_page_and_body_hash_signature",
                })
            else:
                log_progress(args, f"[dedupe:skip-old] newest named scrape wins; skip unknown {unk.group_rel}; keep {winner.group_rel}", verbose_only=True)
                skipped_group_rels.add(unk.group_rel)
                for named in allowed_named:
                    if named.group_rel != winner.group_rel:
                        skipped_group_rels.add(named.group_rel)
                decisions.append({
                    "decision": "keep_newest_named_skip_unknown",
                    "title_key": title_key,
                    "unknown_group": unk.group_rel,
                    "named_group": " | ".join(g.group_rel for g in allowed_named),
                    "target": named_target,
                    "newest_group": winner.group_rel,
                    "newest_timestamp": newest_display,
                    "newest_timestamp_source": newest_source,
                    "duplicate_signature": "same_page_and_body_hash_signature",
                })

    log_progress(args, f"[pass 1/4 done] decisions={len(decisions)} discrepancy_rescrape={len(rescrape_rows)} manual_review={len(manual_review_rows)} skipped_groups={len(skipped_group_rels)} pre_resolved_targets={len(target_for_group)}")

    # Second pass: resolve remaining unknown groups from local/page/author evidence.
    log_progress(args, "[pass 2/4] resolve remaining unknown groups from local metadata, Wikisource categories, and author pages")
    unknown_candidates = [g for g in groups_by_path.values() if any(f.is_unknown for f in g.files) and g.group_rel not in skipped_group_rels and g.group_rel not in target_for_group]
    for unknown_i, group in enumerate(unknown_candidates, start=1):
        progress_tick(args, unknown_i, len(unknown_candidates), "resolve-unknown-groups")
        if group.group_rel in skipped_group_rels or group.group_rel in target_for_group:
            continue
        if not any(f.is_unknown for f in group.files):
            continue
        sample = group.files[0]
        evidence = "\n".join(local_evidence_text(f) for f in group.files[:3])
        target, nation, reason, alias, confidence = derive_from_text_evidence(
            evidence, rules, sample, minor_folder=args.minor_folder, allow_minor_from=args.allow_minor_from
        )
        ws_categories: List[str] = []
        author = ""
        author_desc = ""
        author_candidates: List[str] = []
        derived_stage = "local"
        if target:
            log_progress(args, f"[resolve:local] {group.group_rel} -> {target} via {reason} alias={alias}", verbose_only=True)
        else:
            log_progress(args, f"[resolve:local] {group.group_rel} unresolved locally", verbose_only=True)

        if not target and args.fetch_ws_categories and wiki is not None:
            page_title = choose_page_title_for_fetch(sample)
            log_progress(args, f"[ws-categories] fetching {page_title} for {group.group_rel}", verbose_only=True)
            try:
                ws_categories = wiki.fetch_categories(page_title)
            except Exception as exc:
                ws_categories = []
                decisions.append({"decision": "ws_category_fetch_error", "group": group.group_rel, "page_title": page_title, "error": str(exc)})
            if ws_categories:
                target, nation, reason, alias, confidence = derive_from_text_evidence(
                    "\n".join(ws_categories), rules, sample, minor_folder=args.minor_folder, allow_minor_from=args.allow_minor_from
                )
                if target:
                    derived_stage = "wikisource_categories"
                    log_progress(args, f"[resolve:ws-categories] {group.group_rel} -> {target}; cats={len(ws_categories)}", verbose_only=True)
                else:
                    log_progress(args, f"[resolve:ws-categories] {group.group_rel} still unresolved; cats={len(ws_categories)}", verbose_only=True)

        needs_author = (not target and args.author_lookup) or args.always_fetch_author
        if needs_author and wiki is not None:
            page_title = choose_page_title_for_fetch(sample)
            log_progress(args, f"[author] probing candidates for {page_title} ({group.group_rel})", verbose_only=True)
            try:
                author_candidates = wiki.find_author_candidates_for_page(page_title, sample.meta)
                for src in wiki.last_author_candidate_sources:
                    author_rows.append({
                        "group": group.group_rel,
                        "page_title": page_title,
                        "author": src.get("candidate", ""),
                        "candidate_source": src.get("source", ""),
                        "author_page": src.get("author_page", ""),
                        "candidate_exists": src.get("exists", ""),
                        "status": "candidate_probe",
                    })
            except Exception as exc:
                author_candidates = []
                decisions.append({"decision": "author_candidate_error", "group": group.group_rel, "page_title": page_title, "error": str(exc)})
            log_progress(args, f"[author] candidates for {group.group_rel}: {', '.join(author_candidates[:5]) if author_candidates else '(none)'}", verbose_only=True)
            for cand in author_candidates[:5]:
                log_progress(args, f"[author] fetching description: Author:{cand}", verbose_only=True)
                try:
                    desc = wiki.fetch_author_description(cand)
                except Exception as exc:
                    author_rows.append({
                        "group": group.group_rel,
                        "page_title": page_title,
                        "author": cand,
                        "status": "description_fetch_error",
                        "error": str(exc),
                    })
                    continue
                if desc:
                    author = cand
                    author_desc = desc
                    places = [m.group(1) for m in PLACE_PERSON_RE.finditer(desc)]
                    for place in places:
                        place_rows.append({"group": group.group_rel, "author": cand, "place_term": place, "description": desc})
                    atarget, anation, areason, aalias, aconf = derive_from_text_evidence(
                        desc, rules, sample, minor_folder=args.minor_folder, allow_minor_from=args.allow_minor_from
                    )
                    author_rows.append({
                        "group": group.group_rel,
                        "page_title": page_title,
                        "author": cand,
                        "description": desc,
                        "derived_target": atarget,
                        "matched_alias": aalias,
                        "confidence": aconf,
                    })
                    if atarget and not target:
                        log_progress(args, f"[resolve:author] {group.group_rel} -> {atarget}; author={cand} alias={aalias}", verbose_only=True)
                        target, nation, reason, alias, confidence = atarget, anation, areason, aalias, aconf
                        derived_stage = "author_page_description"
                    elif not atarget:
                        log_progress(args, f"[resolve:author] {group.group_rel} no target from author={cand}", verbose_only=True)
                    break

        if ws_categories or author:
            enrichment_for_group[group.group_rel] = {
                "WS_CATEGORIES": "，".join(ws_categories),
                "AUTHOR": author,
            }

        if target:
            log_progress(args, f"[resolve:done] {group.group_rel} -> {target} ({derived_stage})", verbose_only=True)
            target_for_group[group.group_rel] = (target, nation or target.split("/")[-1], f"{derived_stage}:{reason}:matched={alias}:confidence={confidence}")
        else:
            log_progress(args, f"[resolve:unresolved] {group.group_rel} kept in-place", verbose_only=True)
            # Keep unknown inside its current path. Nation stays as its container, not invented.
            keep_target = top_rel_after_(group.group_rel)
            if UNKNOWN_LABEL in keep_target.split("/"):
                # Drop the unknown segment to get the container nation; output path itself remains unchanged later.
                container_parts = [p for p in keep_target.split("/") if p and p != UNKNOWN_LABEL]
                keep_nation = container_parts[-1] if container_parts else sample.
            else:
                keep_nation = keep_target.split("/")[-1] if keep_target else sample.
            unresolved_rows.append({
                "group": group.group_rel,
                "work_title": sample.work_title,
                "page_title": sample.page_title,
                "context": sample.context_rel,
                "kept_in_unknown": "yes",
                "existing_nation": sample.meta.get("NATION", ""),
                "ws_categories": "，".join(ws_categories),
                "author_candidates": "，".join(author_candidates),
                "author": author,
                "author_description": author_desc,
                "reason": "no allowed target derived from local/page/author evidence",
            })
            newest_ts, newest_source, newest_display = group_newest_recency(group)
            manual_review_rows.append({
                "review_type": "unresolved_unknown",
                "priority": "medium",
                "suggested_action": "manual_assign_region_or_leave_unknown",
                "group": group.group_rel,
                "work_title": sample.work_title,
                "page_title": sample.page_title,
                "context": sample.context_rel,
                "reason": "no allowed target derived from local/page/author evidence",
                "ws_categories": "，".join(ws_categories),
                "author_candidates": "，".join(author_candidates),
                "author": author,
                "source_url": source_url_for_group(group),
                "files": group.file_count,
                "chars": group.total_body_chars,
                "pages": compact_group_pages(group),
                "newest_candidate_group": group.group_rel,
                "newest_timestamp": newest_display,
                "newest_timestamp_source": newest_source,
            })
            # Mark explicitly as unresolved by not adding to target_for_group.

    log_progress(args, f"[pass 2/4 done] resolved_targets_total={len(target_for_group)} unresolved={len(unresolved_rows)} author_audit_rows={len(author_rows)}")

    # Third pass: write records.
    log_progress(args, "[pass 3/4] write copied/regionalised corpus files" + (" (dry-run: audits only)" if args.dry_run else ""))
    written_files = 0
    skipped_files = 0
    sorted_write_groups = sorted(groups_by_path.values(), key=lambda g: g.group_rel)
    for write_i, group in enumerate(sorted_write_groups, start=1):
        progress_tick(args, write_i, len(sorted_write_groups), "write-groups")
        if group.group_rel in skipped_group_rels:
            log_progress(args, f"[write:skip-group] {group.group_rel} files={group.file_count}", verbose_only=True)
            skipped_files += group.file_count
            continue

        target_info = target_for_group.get(group.group_rel)
        if target_info:
            target_path, nation, reason = target_info
        else:
            target_path = top_rel_after_(group.group_rel)
            # Keep unresolved unknowns exactly in their unknown folder.
            nation = ""
            reason = "kept_original_path"

        log_progress(args, f"[write:group] {group.group_rel} -> {target_path} files={group.file_count} reason={reason}", verbose_only=True)
        for rec in sorted(group.files, key=lambda r: r.rel_path):
            if rec.is_unknown and not target_info:
                # Preserve unresolved unknown path exactly.
                out_rel = rec.rel_path
                container_parts = [p for p in rec.context_rel.split("/") if p]
                nation_for_header = rec.meta.get("NATION") or (container_parts[-1] if container_parts else rec.)
            else:
                out_rel = output_rel_for_rec(_name, target_path, work_folder_name_from_group(group), rec.parts[-1])
                nation_for_header = nation or rec.meta.get("NATION") or (target_path.split("/")[-1] if target_path else rec.)

            # Avoid output collisions by suffixing. This prevents silent overwrite.
            final_rel = out_rel
            if final_rel in written_paths and written_paths[final_rel] != rec.sha1:
                stem, suffix = os.path.splitext(final_rel)
                n = 2
                while f"{stem}__dup{n}{suffix}" in written_paths:
                    n += 1
                final_rel = f"{stem}__dup{n}{suffix}"

            enrich = enrichment_for_group.get(group.group_rel, {})
            text_out = normalised_output_text(
                rec,
                nation=nation_for_header,
                author=enrich.get("AUTHOR", ""),
                ws_categories=enrich.get("WS_CATEGORIES", ""),
            )
            if not args.dry_run:
                write_text_file(out_dir / final_rel, text_out)
            written_paths[final_rel] = rec.sha1
            written_files += 1
            file_audit_rows.append({
                "source_rel": rec.rel_path,
                "output_rel": final_rel,
                "work_title": rec.work_title,
                "page_title": rec.page_title,
                "source_unknown": "1" if rec.is_unknown else "0",
                "source_nation": rec.meta.get("NATION", ""),
                "output_nation": nation_for_header,
                "target_reason": reason,
                "body_chars": rec.body_chars,
                "scraped_at_utc": rec.meta.get("SCRAPED_AT_UTC", ""),
                "source_file_mtime_utc": rec.source_mtime_utc,
                "recency_source": rec_recency(rec)[1],
                "recency_value": rec_recency(rec)[2],
                "ws_categories": enrichment_for_group.get(group.group_rel, {}).get("WS_CATEGORIES", rec.meta.get("WS_CATEGORIES", "")),
                "author_enriched": enrichment_for_group.get(group.group_rel, {}).get("AUTHOR", ""),
            })

    log_progress(args, f"[pass 3/4 done] files_written_or_planned={written_files} skipped_files={skipped_files} audit_rows={len(file_audit_rows)}")

    # Fourth pass: optional /table-of-contents discovery for missing subpages.
    # This is intentionally separate from regionalisation: it only adds pages under
    # the same Wikisource  title, e.g. WORK/卷一, WORK/卷二. It does not follow
    # arbitrary links.
    if args.discover_missing_parts and wiki is not None:
        log_progress(args, "[pass 4/4] discover missing Wikisource subpages under same  titles")
        discovery_groups = sorted(groups_by_path.values(), key=lambda g: g.group_rel)
        checked_discovery_groups = 0
        for discover_i, group in enumerate(discovery_groups, start=1):
            progress_tick(args, discover_i, len(discovery_groups), "discover-groups")
            if group.group_rel in skipped_group_rels:
                continue
            group_is_unknown = any(f.is_unknown for f in group.files)
            if args.discover_parts_scope == "unknown" and not group_is_unknown:
                continue
            if not should_discover_missing_parts(group, args.discover_parts_mode, args.discover_parts_max_existing_files):
                continue

            sample = group.files[0]
            _title = choose__title_for_discovery(group)
            if not _title:
                log_progress(args, f"[discover:skip] {group.group_rel}; no  title", verbose_only=True)
                continue
            checked_discovery_groups += 1
            existing_titles = existing_titles_for_group(group)
            log_progress(args, f"[discover] {group.group_rel}; ={_title}; existing_titles={len(existing_titles)} method={args.discover_parts_method}", verbose_only=True)
            try:
                discovered = wiki.discover_work_parts(_title, method=args.discover_parts_method)
                log_progress(args, f"[discover] {_title}: discovered={len(discovered)}", verbose_only=True)
            except Exception as exc:
                discovered_part_rows.append({
                    "group": group.group_rel,
                    "_title": _title,
                    "status": "discovery_error",
                    "error": str(exc),
                })
                continue

            missing = [t for t in discovered if t not in existing_titles]
            log_progress(args, f"[discover] {_title}: missing={len(missing)}", verbose_only=True)
            if args.max_discovered_parts_per_work and len(missing) > args.max_discovered_parts_per_work:
                discovered_part_rows.append({
                    "group": group.group_rel,
                    "_title": _title,
                    "status": "capped",
                    "discovered_count": len(discovered),
                    "missing_count_before_cap": len(missing),
                    "cap": args.max_discovered_parts_per_work,
                })
                missing = missing[: args.max_discovered_parts_per_work]

            if not missing:
                discovered_part_rows.append({
                    "group": group.group_rel,
                    "_title": _title,
                    "status": "no_missing_parts",
                    "discovered_count": len(discovered),
                    "existing_titles": "，".join(sorted(existing_titles)),
                })
                continue

            target_info = target_for_group.get(group.group_rel)
            if target_info:
                target_path, nation, reason = target_info
            else:
                target_path = top_rel_after_(group.group_rel)
                nation = ""
                reason = "kept_original_path:discovered_missing_parts"

            if group_is_unknown and not target_info:
                container_parts = [p for p in sample.context_rel.split("/") if p]
                nation_for_header = sample.meta.get("NATION") or (container_parts[-1] if container_parts else sample.)
            else:
                nation_for_header = nation or sample.meta.get("NATION") or (target_path.split("/")[-1] if target_path else sample.)

            enrich = enrichment_for_group.get(group.group_rel, {})
            for idx, page_title in enumerate(missing, start=1):
                if args.dry_run:
                    log_progress(args, f"[discover:dry-run] would save {page_title}", verbose_only=True)
                    discovered_part_rows.append({
                        "group": group.group_rel,
                        "_title": _title,
                        "page_title": page_title,
                        "status": "would_save_dry_run",
                        "output_nation": nation_for_header,
                        "target_reason": reason,
                    })
                    continue
                log_progress(args, f"[discover:scrape] fetching missing part {page_title}", verbose_only=True)
                try:
                    clean_body, cats = wiki.fetch_rescraped_clean_page(page_title)
                    if not cats and page_title != _title:
                        cats = wiki.fetch_categories(_title)
                except Exception as exc:
                    discovered_part_rows.append({
                        "group": group.group_rel,
                        "_title": _title,
                        "page_title": page_title,
                        "status": "scrape_error",
                        "error": str(exc),
                    })
                    continue
                if not clean_body.strip():
                    discovered_part_rows.append({
                        "group": group.group_rel,
                        "_title": _title,
                        "page_title": page_title,
                        "status": "skipped_empty",
                    })
                    continue

                fname = discovered_part_filename(_title, page_title, idx)
                out_rel = output_rel_for_rec(_name, target_path, work_folder_name_from_group(group), fname)
                final_rel = out_rel
                body_sha = sha1_text(clean_body)
                if final_rel in written_paths and written_paths[final_rel] != body_sha:
                    stem, suffix = os.path.splitext(final_rel)
                    n = 2
                    while f"{stem}__dup{n}{suffix}" in written_paths:
                        n += 1
                    final_rel = f"{stem}__dup{n}{suffix}"

                meta = dict(sample.meta)
                meta["WORK_TITLE"] = _title
                meta["DISPLAY_TITLE"] = meta.get("DISPLAY_TITLE") or _title
                meta["PAGE_TITLE"] = page_title
                meta["AUTHOR"] = enrich.get("AUTHOR", "") or meta.get("AUTHOR", "")
                meta["NATION"] = nation_for_header
                meta["CATEGORIES"] = meta.get("CATEGORIES", "")
                meta["YEAR"] = meta.get("YEAR", "")
                meta["CHAPTER"] = page_title[len(_title) + 1:] if page_title.startswith(_title + "/") else page_title
                meta["SOURCE_URL"] = title_to_wikisource_url(page_title)
                meta["WS_CATEGORIES"] = "，".join(cats) or enrich.get("WS_CATEGORIES", "") or meta.get("WS_CATEGORIES", "")
                meta["SCRAPED_AT_UTC"] = now_utc()

                text_out = build_header(meta) + clean_body
                assert_approved_header_only(text_out)
                if not args.dry_run:
                    write_text_file(out_dir / final_rel, text_out)
                written_paths[final_rel] = body_sha
                written_files += 1

                discovered_part_rows.append({
                    "group": group.group_rel,
                    "_title": _title,
                    "page_title": page_title,
                    "status": "saved",
                    "output_rel": final_rel,
                    "output_nation": nation_for_header,
                    "target_reason": reason,
                    "chars_clean": len(text_out),
                    "ws_categories": meta["WS_CATEGORIES"],
                })
                file_audit_rows.append({
                    "source_rel": "[wikisource_missing_part]",
                    "output_rel": final_rel,
                    "work_title": _title,
                    "page_title": page_title,
                    "source_unknown": "1" if group_is_unknown else "0",
                    "source_nation": sample.meta.get("NATION", ""),
                    "output_nation": nation_for_header,
                    "target_reason": reason,
                    "body_chars": len(clean_body),
                    "ws_categories": meta["WS_CATEGORIES"],
                    "author_enriched": meta["AUTHOR"],
                })

    if args.discover_missing_parts and wiki is not None:
        log_progress(args, f"[pass 4/4 done] discovery_audit_rows={len(discovered_part_rows)}")
    else:
        log_progress(args, "[pass 4/4 skipped] discover_missing_parts=False")

    summary = {
        "input": str(input_path),
        "output": str(out_dir),
        "_name": _name,
        "records_loaded": len(records),
        "files_written": written_files,
        "files_skipped_as_duplicates": skipped_files,
        "work_groups": len(groups_by_path),
        "unknown_work_groups": sum(1 for g in groups_by_path.values() if any(f.is_unknown for f in g.files)),
        "resolved_unknown_groups": len([k for k in target_for_group if k in groups_by_rel and any(f.is_unknown for f in groups_by_rel[k].files)]),
        "unresolved_unknown_groups": len(unresolved_rows),
        "partial_overlap_review_items": len(partial_rows),
        "duplicate_discrepancy_rescrape_items": len(rescrape_rows),
        "manual_review_items": len(manual_review_rows),
        "preserve_empty_dirs": bool(args.preserve_empty_dirs),
        "preserved_folder_skeleton_dirs": len(preserved_dirs),
        "discovered_missing_parts": len(discovered_part_rows),
        "online_ws_categories": bool(args.fetch_ws_categories),
        "online_author_lookup": bool(args.author_lookup),
        "api_user_agent": args.user_agent,
        "created_at_utc": now_utc(),
        "corpus_header_keys": HEADER_KEYS,
        "audit_only_metadata_keys": sorted(AUDIT_ONLY_METADATA_KEYS),
    }

    manual_review_rows = normalise_manual_review_rows(manual_review_rows)
    log_progress(args, "[audit] writing audit CSV/JSON files")
    write_csv(audit_dir / "work_decisions.csv", decisions)
    write_csv(audit_dir / "partial_overlap_review.csv", partial_rows)
    write_csv(audit_dir / "rescrape_queue.csv", rescrape_rows)
    write_csv(audit_dir / "manual_review_queue.csv", manual_review_rows)
    write_csv(audit_dir / "preserved_folder_skeleton.csv", preserved_dir_rows)
    write_csv(audit_dir / "unresolved_unknown.csv", unresolved_rows)
    write_csv(audit_dir / "file_metadata_audit.csv", file_audit_rows)
    write_csv(audit_dir / "author_lookup_audit.csv", author_rows)
    write_csv(audit_dir / "author_place_terms.csv", place_rows)
    write_csv(audit_dir / "discovered_missing_parts.csv", discovered_part_rows)
    (audit_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    log_progress(args, f"[audit] wrote: {audit_dir / 'summary.json'}")
    log_progress(args, f"[audit] key files: manual_review_queue.csv, rescrape_queue.csv, preserved_folder_skeleton.csv, work_decisions.csv, unresolved_unknown.csv, author_lookup_audit.csv, discovered_missing_parts.csv", verbose_only=True)

    if args.make_zip and not args.dry_run:
        zip_path = out_dir.with_suffix(".zip")
        make_zip_from_dir(out_dir, zip_path)
        print(f"Wrote zip: {zip_path}")

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"Audit folder: {audit_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
