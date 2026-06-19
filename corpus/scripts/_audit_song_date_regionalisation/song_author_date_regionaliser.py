#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
song_author_date_regionaliser.py

Date-based second pass for a 宋朝 folder.

It processes only work folders under 不詳 (or another explicitly supplied
unknown-folder name) and moves a work only when author-date evidence gives a
usable 北宋 / 南宋 result.

Decision rule requested for this corpus:
  - death year <= 1127  -> 北宋
  - death year > 1127   -> 南宋
  - if death year is unavailable, birth year >= 1127 -> 南宋
  - otherwise leave the work in 不詳

Evidence order:
  1. AUTHOR metadata already in the corpus file.
  2. Author names in parenthesised work/file/page titles.
  3. Wikisource work page author links/templates, when enabled.
  4. Wikisource Author:<name> page dates/categories/intro.
  5. Chinese Wikipedia exact-title page infobox/intro/categories.

Safety:
  - dry-run by default;
  - no move without --apply;
  - no filename changes;
  - no invented folders;
  - no corpus metadata changes;
  - API evidence and caches stay in _audit_song_date_regionalisation.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple
from urllib.parse import unquote, urlparse

try:
    import requests
except ImportError:
    requests = None  # type: ignore


SCRIPT_VERSION = "song-author-date-regionaliser-2026-06-19"

WIKISOURCE_API = "https://zh.wikisource.org/w/api.php"
WIKIPEDIA_API = "https://zh.wikipedia.org/w/api.php"

DEFAULT_USER_AGENT = (
    "FanyaHanwenCorpusSongDateRegionaliser/1.0 "
    "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
    "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
)

AUDIT_DIR_NAME = "_audit_song_date_regionalisation"
UNKNOWN_FOLDER_DEFAULTS = {"不詳", "未知", "未詳"}
TARGET_FOLDERS = {"北宋", "南宋"}
CUTOFF_YEAR = 1127
PLAUSIBLE_MIN_YEAR = 900
PLAUSIBLE_MAX_YEAR = 1300

HEADER_LINE_RE = re.compile(r"^#\s*([A-Z0-9_]+)\s*:\s*(.*)\s*$")
PAREN_RE = re.compile(r"[（(]([^（）()]{1,40})[）)]")

PAGE_AUTHOR_TEMPLATE_RE = re.compile(
    r"\|\s*(?:author|作者|著者|撰者|override_author)\s*=\s*([^|\n\r}]{1,120})",
    re.IGNORECASE,
)
AUTHOR_LINK_RE = re.compile(r"\[\[(?:Author|作者):([^|\]#]+)(?:\|[^\]]*)?\]\]")

BAD_AUTHOR_VALUES = {
    "", "佚名", "不詳", "未知", "无名氏", "無名氏", "多人", "群体", "群體",
    "various", "anonymous", "unknown", "佛經", "宋詞", "詩", "詞", "樂府雅詞",
    "七言絕句", "五言絕句", "七言律詩", "五言律詩",
}
BAD_AUTHOR_SUBSTRINGS = (
    "页面不存在", "頁面不存在", "page does not exist", "維基文庫", "维基文库",
    "Category:", "分類:", "分类:",
)
PERIOD_PREFIXES = (
    "宋代", "北宋", "南宋", "宋", "金朝", "金", "遼朝", "辽朝", "遼", "辽", "西夏",
    "唐", "五代", "元", "明", "清", "漢", "汉", "魏", "晉", "晋",
)
SIMPLIFIED_NORMALISATIONS = {
    "陈": "陳", "杨": "楊", "刘": "劉", "赵": "趙", "吴": "吳", "张": "張",
    "欧阳": "歐陽", "苏": "蘇", "陆": "陸", "勋": "勳", "钱": "錢", "郑": "鄭",
    "卢": "盧", "马": "馬", "孙": "孫", "罗": "羅", "谢": "謝", "许": "許",
    "冯": "馮", "韩": "韓", "钟": "鍾", "龚": "龔", "顾": "顧", "叶": "葉",
}

SONG_MARKERS = (
    "宋朝", "宋代", "北宋", "南宋", "宋人", "宋朝作者", "宋朝人物", "宋朝政治人物",
)
DISAMBIG_MARKERS = ("消歧义", "消歧義", "消歧义页", "消歧義頁")

DEATH_CATEGORY_RE = re.compile(r"(?<!\d)(\d{3,4})年(?:逝世|去世|死亡|卒)")
BIRTH_CATEGORY_RE = re.compile(r"(?<!\d)(\d{3,4})年(?:出生|生)")
YEAR_RE = re.compile(r"(?<!\d)(\d{3,4})(?!\d)")
LIFESPAN_RE = re.compile(
    r"(?<!\d)(\d{3,4})\s*年?\s*[—–－~～至-]\s*(\d{3,4})\s*年?(?!\d)"
)

# Explicit template/infobox fields. We inspect only the first part of the page.
DEATH_FIELD_RE = re.compile(
    r"^\s*\|\s*(?:deathyear|death_year|deathdate|death_date|died|逝世日期|死亡日期|逝世|死亡|卒年|卒)\s*=\s*(.+)$",
    re.IGNORECASE | re.MULTILINE,
)
BIRTH_FIELD_RE = re.compile(
    r"^\s*\|\s*(?:birthyear|birth_year|birthdate|birth_date|born|出生日期|出生|生年|生)\s*=\s*(.+)$",
    re.IGNORECASE | re.MULTILINE,
)


@dataclass
class FileRec:
    path: Path
    rel: str
    top_folder: str
    work_rel: str
    file_name: str
    meta: Dict[str, str]
    author_header: str
    work_title: str
    display_title: str
    page_title: str
    source_url: str

    def title_strings(self) -> List[str]:
        values = [
            self.work_rel,
            self.file_name,
            self.work_title,
            self.display_title,
            self.page_title,
            title_from_url_or_title(self.source_url),
        ]
        return [value for value in values if value]


@dataclass
class WorkGroup:
    top_folder: str
    work_rel: str
    files: List[FileRec] = field(default_factory=list)

    @property
    def key(self) -> str:
        return f"{self.top_folder}/{self.work_rel}"

    def title_strings(self) -> List[str]:
        out: List[str] = []
        for rec in self.files:
            out.extend(rec.title_strings())
        return list(dict.fromkeys(out))


@dataclass
class DateEvidence:
    author: str
    source_site: str
    page_title: str
    page_url: str
    birth_year: Optional[int]
    death_year: Optional[int]
    target: str
    decision_reason: str
    extraction_method: str
    song_context: bool
    evidence_text: str
    status: str

    def to_dict(self) -> Dict[str, Any]:
        return {
            "author": self.author,
            "source_site": self.source_site,
            "page_title": self.page_title,
            "page_url": self.page_url,
            "birth_year": self.birth_year,
            "death_year": self.death_year,
            "target": self.target,
            "decision_reason": self.decision_reason,
            "extraction_method": self.extraction_method,
            "song_context": self.song_context,
            "evidence_text": self.evidence_text,
            "status": self.status,
        }


class JsonCache:
    def __init__(self, path: Path):
        self.path = path
        self.data: Dict[str, Any] = {}
        if path.exists():
            try:
                loaded = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    self.data = loaded
            except Exception:
                self.data = {}

    def get(self, key: str) -> Any:
        return self.data.get(key)

    def set(self, key: str, value: Any) -> None:
        self.data[key] = value

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(self.path.suffix + ".tmp")
        temp.write_text(json.dumps(self.data, ensure_ascii=False, indent=2), encoding="utf-8")
        temp.replace(self.path)


class MediaWikiClient:
    def __init__(self, endpoint: str, site_name: str, sleep_seconds: float, user_agent: str):
        if requests is None:
            raise SystemExit("Missing dependency: requests. Install with: pip install requests")
        self.endpoint = endpoint
        self.site_name = site_name
        self.sleep_seconds = sleep_seconds
        self.session = requests.Session()
        self.headers = {"User-Agent": user_agent}

    def get(self, params: Dict[str, Any], retries: int = 5) -> Dict[str, Any]:
        request_params = dict(params)
        request_params.setdefault("format", "json")
        request_params.setdefault("formatversion", "2")

        for attempt in range(1, retries + 1):
            if self.sleep_seconds > 0:
                time.sleep(self.sleep_seconds)
            try:
                response = self.session.get(
                    self.endpoint,
                    params=request_params,
                    headers=self.headers,
                    timeout=45,
                )
            except Exception as exc:
                if attempt == retries:
                    return {"_error": f"request_error: {type(exc).__name__}: {exc}"}
                time.sleep(min(15.0, attempt * 2.0))
                continue

            if response.status_code == 429:
                raw_retry = response.headers.get("Retry-After", "")
                wait = float(raw_retry) if raw_retry.isdigit() else min(90.0, attempt * 10.0)
                print(f"[warn] {self.site_name} rate-limited; sleeping {wait:.1f}s")
                time.sleep(wait)
                continue

            try:
                response.raise_for_status()
                data = response.json()
            except Exception as exc:
                if attempt == retries:
                    return {"_error": f"response_error: {type(exc).__name__}: {exc}"}
                time.sleep(min(15.0, attempt * 2.0))
                continue

            if "error" in data:
                code = str((data.get("error") or {}).get("code", ""))
                if code in {"missingtitle", "invalidtitle", "nosuchpageid"}:
                    return {"_missing": True}
                if attempt == retries:
                    return {"_error": f"api_error: {data.get('error')}"}
                time.sleep(min(15.0, attempt * 2.0))
                continue

            return data

        return {"_error": "retries_exhausted"}

    def page_bundle(self, title: str) -> Dict[str, Any]:
        """
        Fetch exact title, following redirects, with:
          - current wikitext;
          - intro plaintext;
          - categories.

        The revision content API is part of MediaWiki's action=query API.
        """
        data = self.get({
            "action": "query",
            "prop": "revisions|extracts|categories",
            "titles": title,
            "redirects": "1",
            "rvprop": "content",
            "rvslots": "main",
            "exintro": "1",
            "explaintext": "1",
            "cllimit": "max",
            "clshow": "!hidden",
        })

        # TextExtracts is available on Wikimedia sites, but keep a wikitext-only
        # fallback so an extracts-module problem does not discard the page.
        if data.get("_error"):
            data = self.get({
                "action": "query",
                "prop": "revisions|categories",
                "titles": title,
                "redirects": "1",
                "rvprop": "content",
                "rvslots": "main",
                "cllimit": "max",
                "clshow": "!hidden",
            })
        if data.get("_error") or data.get("_missing"):
            return data

        pages = (data.get("query") or {}).get("pages") or []
        if not pages:
            return {"_missing": True}

        page = pages[0]
        if "missing" in page:
            return {"_missing": True}

        revisions = page.get("revisions") or []
        wikitext = ""
        if revisions:
            slots = revisions[0].get("slots") or {}
            main_slot = slots.get("main") or {}
            wikitext = str(main_slot.get("content") or "")

        categories: List[str] = []
        for category in page.get("categories") or []:
            cat_title = str(category.get("title") or "")
            if cat_title.startswith("Category:"):
                cat_title = cat_title.split(":", 1)[1]
            if cat_title:
                categories.append(cat_title)

        return {
            "pageid": page.get("pageid"),
            "title": str(page.get("title") or title),
            "wikitext": wikitext,
            "extract": str(page.get("extract") or ""),
            "categories": categories,
        }

    def parse_work_page_authors(self, title: str) -> Dict[str, Set[str]]:
        data = self.get({
            "action": "parse",
            "page": title,
            "prop": "wikitext|links",
            "disablelimitreport": "1",
            "disableeditsection": "1",
            "disabletoc": "1",
        })
        parse = data.get("parse") or {}
        if not parse:
            return {}

        out: Dict[str, Set[str]] = defaultdict(set)
        wt_node = parse.get("wikitext")
        wikitext = str(wt_node.get("*") if isinstance(wt_node, dict) else (wt_node or ""))

        for match in PAGE_AUTHOR_TEMPLATE_RE.finditer(wikitext):
            author = canonical_author(match.group(1))
            if author:
                out[author].add("work_page_template")

        for match in AUTHOR_LINK_RE.finditer(wikitext):
            author = canonical_author(match.group(1))
            if author:
                out[author].add("work_page_author_link")

        for link in parse.get("links") or []:
            if not isinstance(link, dict):
                continue
            target = str(link.get("title") or link.get("*") or "")
            if target.startswith(("Author:", "作者:")):
                author = canonical_author(target.split(":", 1)[1])
                if author:
                    out[author].add("work_page_parse_link")

        return out


def is_windows() -> bool:
    return os.name == "nt"


def long_path(path: Path | str) -> str:
    absolute = os.path.abspath(os.fspath(path))
    if not is_windows():
        return absolute
    if absolute.startswith("\\\\?\\"):
        return absolute
    if absolute.startswith("\\\\"):
        return "\\\\?\\UNC\\" + absolute.lstrip("\\")
    return "\\\\?\\" + absolute


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def title_from_url_or_title(raw: str) -> str:
    text = (raw or "").strip()
    if not text:
        return ""
    if text.startswith("http://") or text.startswith("https://"):
        parsed = urlparse(text)
        parts = [part for part in parsed.path.split("/") if part]
        if parts and parts[0] == "wiki":
            return unquote("/".join(parts[1:]))
        if parts:
            return unquote(parts[-1])
    return text


def canonical_author(raw: str) -> str:
    text = unquote((raw or "").strip())
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"\{\{[^{}]{0,160}\}\}", "", text)
    text = text.replace("[[", "").replace("]]", "")
    text = text.replace("Author:", "").replace("作者:", "")

    if "|" in text:
        text = text.split("|", 1)[0]

    text = re.sub(
        r"[（(]\s*(?:页面不存在|頁面不存在|page does not exist).*?[）)]",
        "",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"\s*(?:页面不存在|頁面不存在|page does not exist).*$",
        "",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(r"\s+", "", text)

    for prefix in PERIOD_PREFIXES:
        if text.startswith(prefix) and len(text) > len(prefix) + 1:
            text = text[len(prefix):]
            break

    text = re.split(r"[，,；;、/／]", text, maxsplit=1)[0]
    text = text.strip("：:[]（）()《》「」『』· ")

    for simplified, traditional in SIMPLIFIED_NORMALISATIONS.items():
        text = text.replace(simplified, traditional)

    if not text or text.lower() in BAD_AUTHOR_VALUES:
        return ""
    if any(fragment.lower() in text.lower() for fragment in BAD_AUTHOR_SUBSTRINGS):
        return ""
    if len(text) > 8:
        return ""
    if re.search(r"[。！？!?：:\n\r\t]", text):
        return ""
    return text


def extract_parenthetical_authors(text: str) -> Dict[str, Set[str]]:
    out: Dict[str, Set[str]] = defaultdict(set)
    for match in PAREN_RE.finditer(text or ""):
        author = canonical_author(match.group(1))
        if author:
            out[author].add("title_parentheses")
    return out


def parse_header(text: str) -> Dict[str, str]:
    metadata: Dict[str, str] = {}
    for line in text.splitlines():
        if line.strip() == "":
            break
        match = HEADER_LINE_RE.match(line)
        if not match:
            break
        metadata[match.group(1)] = match.group(2)
    return metadata


def scan_unknown_groups(root: Path, unknown_folders: Set[str], audit_dir_name: str) -> List[WorkGroup]:
    groups: Dict[Tuple[str, str], WorkGroup] = {}

    for path in root.rglob("*.txt"):
        try:
            relative = path.relative_to(root)
        except ValueError:
            continue

        parts = relative.parts
        if len(parts) < 3:
            continue
        if parts[0].startswith("_audit") or parts[0] == audit_dir_name:
            continue
        if parts[0] not in unknown_folders:
            continue

        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = path.read_text(encoding="utf-8", errors="replace")

        meta = parse_header(text)
        record = FileRec(
            path=path,
            rel="/".join(parts),
            top_folder=parts[0],
            work_rel="/".join(parts[1:-1]),
            file_name=parts[-1],
            meta=meta,
            author_header=canonical_author(meta.get("AUTHOR", "")),
            work_title=meta.get("WORK_TITLE", ""),
            display_title=meta.get("DISPLAY_TITLE", ""),
            page_title=meta.get("PAGE_TITLE", ""),
            source_url=meta.get("SOURCE_URL", ""),
        )
        key = (record.top_folder, record.work_rel)
        if key not in groups:
            groups[key] = WorkGroup(top_folder=record.top_folder, work_rel=record.work_rel)
        groups[key].files.append(record)

    return list(groups.values())


def local_author_candidates(group: WorkGroup) -> Dict[str, Set[str]]:
    out: Dict[str, Set[str]] = defaultdict(set)

    for record in group.files:
        if record.author_header:
            out[record.author_header].add("metadata_AUTHOR")

    for value in group.title_strings():
        extracted = extract_parenthetical_authors(value)
        for author, sources in extracted.items():
            out[author].update(sources)

    return out


def plausible_year(year: Optional[int]) -> Optional[int]:
    if year is None:
        return None
    if PLAUSIBLE_MIN_YEAR <= year <= PLAUSIBLE_MAX_YEAR:
        return year
    return None


def first_year(text: str) -> Optional[int]:
    match = YEAR_RE.search(text or "")
    if not match:
        return None
    return plausible_year(int(match.group(1)))


def year_from_field(pattern: re.Pattern[str], wikitext: str) -> Tuple[Optional[int], str]:
    match = pattern.search(wikitext[:16000])
    if not match:
        return None, ""
    raw_value = match.group(1).strip()
    year = first_year(raw_value)
    return year, raw_value[:240]


def years_from_categories(categories: Iterable[str]) -> Tuple[Optional[int], Optional[int], str]:
    birth: Optional[int] = None
    death: Optional[int] = None
    evidence: List[str] = []

    for category in categories:
        death_match = DEATH_CATEGORY_RE.search(category)
        if death_match:
            candidate = plausible_year(int(death_match.group(1)))
            if candidate is not None:
                death = candidate
                evidence.append(category)

        birth_match = BIRTH_CATEGORY_RE.search(category)
        if birth_match:
            candidate = plausible_year(int(birth_match.group(1)))
            if candidate is not None:
                birth = candidate
                evidence.append(category)

    return birth, death, "；".join(evidence)


def years_from_lifespan(text: str) -> Tuple[Optional[int], Optional[int], str]:
    match = LIFESPAN_RE.search((text or "")[:1800])
    if not match:
        return None, None, ""
    birth = plausible_year(int(match.group(1)))
    death = plausible_year(int(match.group(2)))
    if birth is None and death is None:
        return None, None, ""
    return birth, death, match.group(0)


def extract_years(bundle: Dict[str, Any]) -> Tuple[Optional[int], Optional[int], str, str]:
    """
    Combine evidence without throwing away a death year just because a category
    supplied only the birth year.

    Fill missing values in this order:
      1. explicit categories;
      2. explicit infobox/template fields;
      3. lifespan in first paragraph/intro;
      4. lifespan near the start of wikitext.
    """
    categories = [str(value) for value in (bundle.get("categories") or [])]
    wikitext = str(bundle.get("wikitext") or "")
    extract = str(bundle.get("extract") or "")

    birth: Optional[int] = None
    death: Optional[int] = None
    methods: List[str] = []
    evidence_parts: List[str] = []

    cat_birth, cat_death, cat_text = years_from_categories(categories)
    if cat_birth is not None:
        birth = cat_birth
    if cat_death is not None:
        death = cat_death
    if cat_birth is not None or cat_death is not None:
        methods.append("categories")
        if cat_text:
            evidence_parts.append(cat_text)

    death_field, death_raw = year_from_field(DEATH_FIELD_RE, wikitext)
    birth_field, birth_raw = year_from_field(BIRTH_FIELD_RE, wikitext)
    field_used = False
    if birth is None and birth_field is not None:
        birth = birth_field
        field_used = True
    if death is None and death_field is not None:
        death = death_field
        field_used = True
    if field_used:
        methods.append("infobox_or_template_field")
        evidence_parts.extend(value for value in (birth_raw, death_raw) if value)

    intro_birth, intro_death, intro_text = years_from_lifespan(extract)
    intro_used = False
    if birth is None and intro_birth is not None:
        birth = intro_birth
        intro_used = True
    if death is None and intro_death is not None:
        death = intro_death
        intro_used = True
    if intro_used:
        methods.append("intro_lifespan")
        if intro_text:
            evidence_parts.append(intro_text)

    wiki_birth, wiki_death, wiki_text = years_from_lifespan(wikitext[:5000])
    wiki_used = False
    if birth is None and wiki_birth is not None:
        birth = wiki_birth
        wiki_used = True
    if death is None and wiki_death is not None:
        death = wiki_death
        wiki_used = True
    if wiki_used:
        methods.append("wikitext_lifespan")
        if wiki_text:
            evidence_parts.append(wiki_text)

    if birth is None and death is None:
        return None, None, "no_dates", ""

    return birth, death, "+".join(methods), " | ".join(dict.fromkeys(evidence_parts))


def has_song_context(bundle: Dict[str, Any]) -> bool:
    categories = " ".join(str(value) for value in (bundle.get("categories") or []))
    extract = str(bundle.get("extract") or "")[:1400]
    wikitext = str(bundle.get("wikitext") or "")[:8000]
    combined = categories + " " + extract + " " + wikitext

    if any(marker in combined for marker in DISAMBIG_MARKERS):
        return False
    return any(marker in combined for marker in SONG_MARKERS)


def decide_target(birth_year: Optional[int], death_year: Optional[int]) -> Tuple[str, str]:
    if death_year is not None:
        if death_year <= CUTOFF_YEAR:
            return "北宋", f"death_year_{death_year}_le_{CUTOFF_YEAR}"
        return "南宋", f"death_year_{death_year}_gt_{CUTOFF_YEAR}"

    if birth_year is not None and birth_year >= CUTOFF_YEAR:
        return "南宋", f"birth_year_{birth_year}_ge_{CUTOFF_YEAR}_death_unknown"

    return "", "insufficient_date_evidence"


def bundle_page_url(site: str, page_title: str) -> str:
    from urllib.parse import quote
    domain = "zh.wikisource.org" if site == "wikisource" else "zh.wikipedia.org"
    return f"https://{domain}/wiki/{quote(page_title.replace(' ', '_'), safe=':_-/')}"


def evidence_from_bundle(author: str, site: str, bundle: Dict[str, Any]) -> DateEvidence:
    if bundle.get("_missing"):
        return DateEvidence(
            author=author, source_site=site, page_title="", page_url="", birth_year=None,
            death_year=None, target="", decision_reason="", extraction_method="",
            song_context=False, evidence_text="", status="missing_page",
        )
    if bundle.get("_error"):
        return DateEvidence(
            author=author, source_site=site, page_title="", page_url="", birth_year=None,
            death_year=None, target="", decision_reason="", extraction_method="",
            song_context=False, evidence_text=str(bundle.get("_error")), status="api_error",
        )

    page_title = str(bundle.get("title") or "")
    song_context = has_song_context(bundle)
    birth_year, death_year, method, evidence_text = extract_years(bundle)

    if not song_context:
        return DateEvidence(
            author=author, source_site=site, page_title=page_title,
            page_url=bundle_page_url(site, page_title), birth_year=birth_year,
            death_year=death_year, target="", decision_reason="not_song_context",
            extraction_method=method, song_context=False, evidence_text=evidence_text,
            status="rejected_non_song_or_disambiguation",
        )

    target, reason = decide_target(birth_year, death_year)
    return DateEvidence(
        author=author,
        source_site=site,
        page_title=page_title,
        page_url=bundle_page_url(site, page_title),
        birth_year=birth_year,
        death_year=death_year,
        target=target,
        decision_reason=reason,
        extraction_method=method,
        song_context=True,
        evidence_text=evidence_text,
        status="resolved" if target else "no_usable_date",
    )


def date_evidence_from_cache(raw: Dict[str, Any]) -> DateEvidence:
    return DateEvidence(
        author=str(raw.get("author") or ""),
        source_site=str(raw.get("source_site") or ""),
        page_title=str(raw.get("page_title") or ""),
        page_url=str(raw.get("page_url") or ""),
        birth_year=raw.get("birth_year"),
        death_year=raw.get("death_year"),
        target=str(raw.get("target") or ""),
        decision_reason=str(raw.get("decision_reason") or ""),
        extraction_method=str(raw.get("extraction_method") or ""),
        song_context=bool(raw.get("song_context")),
        evidence_text=str(raw.get("evidence_text") or ""),
        status=str(raw.get("status") or ""),
    )


def resolve_author_date(
    author: str,
    wikisource: MediaWikiClient,
    wikipedia: MediaWikiClient,
    cache: JsonCache,
    refresh_cache: bool,
) -> Tuple[DateEvidence, List[DateEvidence]]:
    cache_key = canonical_author(author)
    cached = cache.get(cache_key)
    if cached and not refresh_cache:
        final_raw = cached.get("final") if isinstance(cached, dict) else None
        attempts_raw = cached.get("attempts") if isinstance(cached, dict) else None
        if isinstance(final_raw, dict):
            final = date_evidence_from_cache(final_raw)
            # Do not make a transient API failure permanent in the cache.
            if final.status != "api_error":
                attempts = [date_evidence_from_cache(item) for item in attempts_raw or [] if isinstance(item, dict)]
                return final, attempts

    attempts: List[DateEvidence] = []

    # Wikisource first. Try the English namespace spelling used in the URL, then
    # Chinese spelling for older/local namespace aliases.
    ws_result: Optional[DateEvidence] = None
    for title in (f"Author:{author}", f"作者:{author}"):
        evidence = evidence_from_bundle(author, "wikisource", wikisource.page_bundle(title))
        attempts.append(evidence)
        if evidence.status != "missing_page":
            ws_result = evidence
            break

    if ws_result and ws_result.target:
        final = ws_result
    else:
        # Wikipedia fallback: exact title only, redirects allowed. No search-result
        # guessing, because a wrong homonym is worse than leaving the item in 不詳.
        wp_result = evidence_from_bundle(author, "wikipedia", wikipedia.page_bundle(author))
        attempts.append(wp_result)
        final = wp_result if wp_result.target else (ws_result or wp_result)

    cache.set(cache_key, {
        "checked_at_utc": now_utc(),
        "final": final.to_dict(),
        "attempts": [attempt.to_dict() for attempt in attempts],
    })
    return final, attempts


def title_for_work_lookup(record: FileRec) -> str:
    return record.page_title or title_from_url_or_title(record.source_url) or record.work_title or record.work_rel


def fetch_work_authors(
    group: WorkGroup,
    client: MediaWikiClient,
    cache: JsonCache,
    refresh_cache: bool,
) -> Dict[str, Set[str]]:
    out: Dict[str, Set[str]] = defaultdict(set)
    titles = list(dict.fromkeys(title_for_work_lookup(record) for record in group.files if title_for_work_lookup(record)))

    for title in titles[:3]:
        cache_key = title
        cached = cache.get(cache_key)
        if isinstance(cached, dict) and not refresh_cache:
            for author, sources in cached.get("authors", {}).items():
                clean = canonical_author(author)
                if clean:
                    out[clean].update(str(source) for source in sources)
            continue

        found = client.parse_work_page_authors(title)
        serialisable = {author: sorted(sources) for author, sources in found.items()}
        cache.set(cache_key, {
            "checked_at_utc": now_utc(),
            "authors": serialisable,
        })
        for author, sources in found.items():
            out[author].update(sources)

    return out


def write_csv(path: Path, rows: List[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return

    fields: List[str] = []
    seen: Set[str] = set()
    for row in rows:
        for key in row:
            if key not in seen:
                seen.add(key)
                fields.append(key)

    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fields})


def move_group(
    root: Path,
    group: WorkGroup,
    target: str,
    apply: bool,
    merge_existing: bool,
) -> Tuple[str, str]:
    source_dir = root / group.top_folder / Path(group.work_rel)
    target_dir = root / target / Path(group.work_rel)

    if not source_dir.exists():
        return "skipped", "source_dir_missing"

    if target_dir.exists() and not merge_existing:
        return "review", "target_work_folder_exists"

    if not apply:
        return ("would_merge", "dry_run") if target_dir.exists() else ("would_move", "dry_run")

    if not target_dir.exists():
        target_dir.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(long_path(source_dir), long_path(target_dir))
        return "moved", ""

    collisions: List[str] = []
    moved_any = False
    for source_path in sorted(source_dir.rglob("*")):
        if source_path.is_dir():
            continue
        relative = source_path.relative_to(source_dir)
        destination = target_dir / relative
        if destination.exists():
            collisions.append(str(relative).replace("\\", "/"))
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(long_path(source_path), long_path(destination))
        moved_any = True

    for dirpath, _dirnames, _filenames in os.walk(long_path(source_dir), topdown=False):
        try:
            if not os.listdir(dirpath):
                os.rmdir(dirpath)
        except OSError:
            pass

    if collisions:
        return "merged_with_collisions", "collisions: " + " | ".join(collisions[:20])
    if moved_any:
        return "merged", ""
    return "review", "target_exists_no_files_moved"


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Use author birth/death years to split 宋朝/不詳 into 北宋 and 南宋."
    )
    parser.add_argument("root", nargs="?", default=".", help="宋朝 folder. Default: current folder.")
    parser.add_argument("--unknown-folder", action="append", default=[], help="Unknown folder name. Default includes 不詳.")
    parser.add_argument("--apply", action="store_true", help="Actually move work folders. Default is dry-run.")
    parser.add_argument("--merge-existing", action="store_true", help="Merge into an existing same-named work folder when file paths do not collide.")
    parser.add_argument("--no-fetch-work-authors", action="store_true", help="Do not fetch Wikisource work pages when local author metadata/title parsing finds no author.")
    parser.add_argument("--sleep", type=float, default=1.5, help="Seconds between Wikimedia API requests. Default: 1.5")
    parser.add_argument("--user-agent", default=os.environ.get("FANYA_WIKIMEDIA_USER_AGENT", DEFAULT_USER_AGENT))
    parser.add_argument("--audit-dir", default=AUDIT_DIR_NAME)
    parser.add_argument("--refresh-cache", action="store_true", help="Ignore saved author/date and work-author cache entries.")
    parser.add_argument("--progress-every", type=int, default=25)
    parser.add_argument("--version", action="version", version=SCRIPT_VERSION)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)

    root = Path(args.root).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        print(f"[error] Root is not a folder: {root}", file=sys.stderr)
        return 2

    unknown_folders = set(UNKNOWN_FOLDER_DEFAULTS)
    unknown_folders.update(args.unknown_folder)

    missing_targets = [name for name in sorted(TARGET_FOLDERS) if not (root / name).is_dir()]
    if missing_targets:
        print(f"[error] Required existing target folders are missing: {', '.join(missing_targets)}", file=sys.stderr)
        return 2

    audit_dir = root / args.audit_dir
    audit_dir.mkdir(parents=True, exist_ok=True)

    date_cache = JsonCache(audit_dir / "author_date_cache.json")
    work_author_cache = JsonCache(audit_dir / "work_author_cache.json")

    wikisource = MediaWikiClient(WIKISOURCE_API, "Wikisource", args.sleep, args.user_agent)
    wikipedia = MediaWikiClient(WIKIPEDIA_API, "Wikipedia", args.sleep, args.user_agent)

    groups = scan_unknown_groups(root, unknown_folders, args.audit_dir)

    print(f"[version] {SCRIPT_VERSION}")
    print(f"[root] {root}")
    print(f"[mode] {'APPLY' if args.apply else 'DRY RUN'}")
    print(f"[unknown folders] {', '.join(sorted(unknown_folders))}")
    print(f"[targets] 北宋, 南宋")
    print(f"[rule] death <= {CUTOFF_YEAR}: 北宋; death > {CUTOFF_YEAR}: 南宋; no death + birth >= {CUTOFF_YEAR}: 南宋")
    print(f"[work-page author fallback] {not args.no_fetch_work_authors}")
    print(f"[scan] unknown work groups={len(groups):,}")
    print()

    move_rows: List[Dict[str, Any]] = []
    unresolved_rows: List[Dict[str, Any]] = []
    author_candidate_rows: List[Dict[str, Any]] = []
    date_lookup_rows: List[Dict[str, Any]] = []
    date_attempt_rows: List[Dict[str, Any]] = []

    date_results: Dict[str, Tuple[DateEvidence, List[DateEvidence]]] = {}
    requests_since_save = 0

    for index, group in enumerate(groups, start=1):
        if args.progress_every and index % args.progress_every == 0:
            print(f"[process] {index}/{len(groups)}")
            date_cache.save()
            work_author_cache.save()

        candidates = local_author_candidates(group)

        if not candidates and not args.no_fetch_work_authors:
            fetched = fetch_work_authors(
                group=group,
                client=wikisource,
                cache=work_author_cache,
                refresh_cache=args.refresh_cache,
            )
            for author, sources in fetched.items():
                candidates[author].update(sources)
            requests_since_save += 1

        for author, sources in sorted(candidates.items()):
            author_candidate_rows.append({
                "work_key": group.key,
                "author": author,
                "sources": "，".join(sorted(sources)),
            })

        if not candidates:
            unresolved_rows.append({
                "priority": "low",
                "reason": "no_author_candidate",
                "work_key": group.key,
                "titles": " | ".join(group.title_strings()[:6]),
                "file_count": len(group.files),
            })
            continue

        author_targets: Dict[str, DateEvidence] = {}
        unresolved_authors: List[str] = []

        for author in sorted(candidates):
            if author not in date_results:
                final, attempts = resolve_author_date(
                    author=author,
                    wikisource=wikisource,
                    wikipedia=wikipedia,
                    cache=date_cache,
                    refresh_cache=args.refresh_cache,
                )
                date_results[author] = (final, attempts)
                requests_since_save += 1
            final, attempts = date_results[author]

            date_lookup_rows.append({
                "work_key": group.key,
                **final.to_dict(),
            })
            for attempt in attempts:
                date_attempt_rows.append({
                    "work_key": group.key,
                    **attempt.to_dict(),
                })

            if final.target:
                author_targets[author] = final
            else:
                unresolved_authors.append(author)

        if unresolved_authors:
            unresolved_rows.append({
                "priority": "low",
                "reason": "one_or_more_authors_have_no_usable_date",
                "work_key": group.key,
                "authors": "，".join(sorted(candidates)),
                "unresolved_authors": "，".join(unresolved_authors),
                "resolved_targets": " | ".join(f"{author}->{evidence.target}" for author, evidence in sorted(author_targets.items())),
                "file_count": len(group.files),
            })
            continue

        targets = {evidence.target for evidence in author_targets.values()}
        if len(targets) != 1:
            unresolved_rows.append({
                "priority": "medium",
                "reason": "authors_date_to_multiple_targets",
                "work_key": group.key,
                "authors": "，".join(sorted(candidates)),
                "targets": " | ".join(f"{author}->{evidence.target}" for author, evidence in sorted(author_targets.items())),
                "file_count": len(group.files),
            })
            continue

        target = next(iter(targets))
        status, note = move_group(
            root=root,
            group=group,
            target=target,
            apply=args.apply,
            merge_existing=args.merge_existing,
        )

        evidence_summary = " | ".join(
            f"{author}:{evidence.source_site}:{evidence.death_year or ''}:{evidence.birth_year or ''}:{evidence.decision_reason}"
            for author, evidence in sorted(author_targets.items())
        )

        move_rows.append({
            "status": status,
            "note": note,
            "source_folder": group.top_folder,
            "target_folder": target,
            "work_rel": group.work_rel,
            "source_path": group.key,
            "target_path": f"{target}/{group.work_rel}",
            "authors": "，".join(sorted(author_targets)),
            "date_evidence": evidence_summary,
            "file_count": len(group.files),
        })

        if status in {"review", "merged_with_collisions"}:
            unresolved_rows.append({
                "priority": "high",
                "reason": status,
                "work_key": group.key,
                "target": target,
                "authors": "，".join(sorted(author_targets)),
                "note": note,
                "file_count": len(group.files),
            })

    date_cache.save()
    work_author_cache.save()

    write_csv(audit_dir / "move_plan.csv", move_rows)
    write_csv(audit_dir / "unresolved.csv", unresolved_rows)
    write_csv(audit_dir / "author_candidates.csv", author_candidate_rows)
    write_csv(audit_dir / "date_lookup_final.csv", date_lookup_rows)
    write_csv(audit_dir / "date_lookup_attempts.csv", date_attempt_rows)

    summary = {
        "script_version": SCRIPT_VERSION,
        "root": str(root),
        "mode": "apply" if args.apply else "dry_run",
        "created_at_utc": now_utc(),
        "cutoff_year": CUTOFF_YEAR,
        "decision_rule": {
            "death_year_lte_1127": "北宋",
            "death_year_gt_1127": "南宋",
            "death_unknown_birth_year_gte_1127": "南宋",
            "otherwise": "leave_in_不詳",
        },
        "unknown_work_groups": len(groups),
        "unique_authors_looked_up": len(date_results),
        "move_plan_rows": len(move_rows),
        "review_or_unresolved_rows": len(unresolved_rows),
        "work_page_author_fallback": not args.no_fetch_work_authors,
        "merge_existing": bool(args.merge_existing),
        "metadata_policy": "No corpus metadata is changed.",
        "date_source_order": ["Wikisource Author page", "Chinese Wikipedia exact-title page"],
    }
    (audit_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print()
    print(f"[done] move_plan_rows={len(move_rows):,}")
    print(f"[done] unresolved/review_rows={len(unresolved_rows):,}")
    print(f"[done] unique_authors_looked_up={len(date_results):,}")
    print(f"[audit] {audit_dir}")
    if not args.apply:
        print("[dry-run] No folders were moved.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
