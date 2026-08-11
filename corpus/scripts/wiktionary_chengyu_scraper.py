#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wiktionary_chengyu_scraper.py

Stage Wikimedia/Wiktionary data for the Fanya Hanwen Corpus Chengyu/Jielong work.

This script deliberately DOES NOT write to the Rails database and DOES NOT try
final deduplication. Wiktionary formatting varies too much for a one-pass
"scrape and declare truth" workflow. Instead it preserves the source evidence
and produces audit-friendly CSVs that can be inspected before the later
normalizer/importer is written.

Sources currently covered (the sources agreed for the Chengyu project):

  English Wiktionary
    - Category:Chinese chengyu
      - also walks its immediate subcategories (literary-source categories)
    - Category:Chengyu by language
      - walks its immediate language-specific subcategories
    - Category:Japanese yojijukugo
    - Category:Korean four-character idioms

  Chinese Wiktionary
    - Category:漢語成語
      - also walks its immediate literary-source subcategories

  Japanese Wiktionary
    - カテゴリ:四字熟語

  Korean Wiktionary
    - 분류:한국어 한자성어

The Wikipedia yojijukugo/sajaseong-eo pages are contextual references rather
than bulk lexical sources, so they are recorded in the run manifest but are not
scraped as dictionary-entry inventories.

Output layout
-------------

  <output>/
    run_manifest.json
    manifest.csv                     one row per unique source page
    category_memberships.csv         all category memberships together
    category_memberships/            one CSV per category (diagnostic-friendly)
    raw/<site>/<pageid>.json          raw latest revision + categories + wikitext
    pages/<site>.csv                  one extracted summary row per page
    sections/<site>.csv               one row per wikitext heading section
    definitions/<site>.csv            one row per definition/relation line
    relations/<site>.csv              explicit form/non-lemma relationships
    pronunciations/<site>.csv         pronunciation evidence such as POJ zh-see pages
    templates/<site>.csv              one row per template invocation
    diagnostics/source_summary.csv
    diagnostics/heading_frequency.csv
    diagnostics/template_frequency.csv
    diagnostics/extraction_warnings.csv   parser/format problems worth fixing
    diagnostics/source_gaps.csv           source pages that genuinely omit useful data
    diagnostics/script_titles.csv

The raw JSON is the important safety net: extraction rules can be improved and
rerun without hitting Wikimedia again.

Examples
--------

  # Small live pilot across every configured source. Sampling is spread
  # deterministically across each full category inventory rather than taking
  # the first N alphabetically.
  python corpus/scripts/wiktionary_chengyu_scraper.py \
    ./wiktionary_chengyu_staging --test --limit-per-source 25

  # Full harvest + extraction + diagnostics.
  python corpus/scripts/wiktionary_chengyu_scraper.py \
    ./wiktionary_chengyu_staging

  # Only harvest two sources.
  python corpus/scripts/wiktionary_chengyu_scraper.py \
    ./wiktionary_chengyu_staging \
    --source en_chinese_chengyu --source ko_hanja_idioms

  # Re-run extraction/diagnostics from cached raw JSON without networking.
  python corpus/scripts/wiktionary_chengyu_scraper.py \
    ./wiktionary_chengyu_staging --stage extract

  python corpus/scripts/wiktionary_chengyu_scraper.py \
    ./wiktionary_chengyu_staging --stage diagnose

Dependencies
------------

  pip install requests

API behaviour
-------------

The harvester identifies itself with a project-specific User-Agent containing
contact details, sends requests serially, uses Wikimedia's maxlag=5 convention,
uses continuation correctly, batches page revision requests, honours Retry-After
where supplied, and caches raw pages locally. This follows Wikimedia Action API
etiquette and avoids repeatedly downloading pages during parser development.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
import time
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Optional, Sequence, Set, Tuple
from urllib.parse import quote

import requests


VERSION = "1.3.0"
USER_AGENT = (
    f"FanyaHanwenCorpusWiktionaryChengyuScraper/{VERSION} "
    "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
    "https://en.wikisource.org/wiki/User:Shira_the_Mogul) requests"
)

CONTEXT_URLS = [
    "https://en.wikipedia.org/wiki/Yojijukugo",
    "https://en.wikipedia.org/wiki/Sajaseong-eo",
]

CSV_DIALECT = {
    "encoding": "utf-8-sig",  # Excel/Windows-friendly while remaining UTF-8.
    "newline": "",
}


@dataclass(frozen=True)
class Site:
    key: str
    api: str
    base_url: str


SITES: Dict[str, Site] = {
    "enwiktionary": Site("enwiktionary", "https://en.wiktionary.org/w/api.php", "https://en.wiktionary.org/wiki/"),
    "zhwiktionary": Site("zhwiktionary", "https://zh.wiktionary.org/w/api.php", "https://zh.wiktionary.org/wiki/"),
    "jawiktionary": Site("jawiktionary", "https://ja.wiktionary.org/w/api.php", "https://ja.wiktionary.org/wiki/"),
    "kowiktionary": Site("kowiktionary", "https://ko.wiktionary.org/w/api.php", "https://ko.wiktionary.org/wiki/"),
}


@dataclass(frozen=True)
class SourceSeed:
    key: str
    site_key: str
    category: str
    label: str
    recurse_depth: int = 0
    role: str = "lexical"


SOURCE_SEEDS: Tuple[SourceSeed, ...] = (
    SourceSeed(
        "en_chinese_chengyu",
        "enwiktionary",
        "Category:Chinese chengyu",
        "English Wiktionary Chinese chengyu",
        recurse_depth=1,
    ),
    SourceSeed(
        "en_chengyu_by_language",
        "enwiktionary",
        "Category:Chengyu by language",
        "English Wiktionary Chengyu by language",
        recurse_depth=1,
    ),
    SourceSeed(
        "zh_han_chengyu",
        "zhwiktionary",
        "Category:漢語成語",
        "Chinese Wiktionary 漢語成語",
        recurse_depth=1,
    ),
    SourceSeed(
        "en_japanese_yojijukugo",
        "enwiktionary",
        "Category:Japanese yojijukugo",
        "English Wiktionary Japanese yojijukugo",
    ),
    SourceSeed(
        "ja_yojijukugo",
        "jawiktionary",
        "カテゴリ:四字熟語",
        "Japanese Wiktionary 四字熟語",
    ),
    SourceSeed(
        "en_korean_four_character",
        "enwiktionary",
        "Category:Korean four-character idioms",
        "English Wiktionary Korean four-character idioms",
    ),
    SourceSeed(
        "ko_hanja_idioms",
        "kowiktionary",
        "분류:한국어 한자성어",
        "Korean Wiktionary 한국어 한자성어",
    ),
)

SOURCE_BY_KEY = {source.key: source for source in SOURCE_SEEDS}


# ---------------------------------------------------------------------------
# Generic utilities
# ---------------------------------------------------------------------------


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def stable_unique(values: Iterable[str]) -> List[str]:
    seen: Set[str] = set()
    out: List[str] = []
    for value in values:
        value = str(value)
        if value in seen:
            continue
        seen.add(value)
        out.append(value)
    return out


def safe_filename(text: str, max_len: int = 130) -> str:
    # Preserve CJK/Hangul/Kana so diagnostic files remain human-readable, while
    # removing the characters Windows forbids in path components.
    value = re.sub(r'[\\/:*?"<>|\x00-\x1F]', "_", text.strip())
    value = re.sub(r"\s+", "_", value)
    value = re.sub(r"_+", "_", value).strip("._-")
    if not value:
        value = hashlib.sha1(text.encode("utf-8")).hexdigest()[:16]
    if len(value) > max_len:
        suffix = hashlib.sha1(text.encode("utf-8")).hexdigest()[:10]
        value = value[: max_len - 11].rstrip("_") + "_" + suffix
    return value


def page_url(site: Site, title: str) -> str:
    return site.base_url + quote(title.replace(" ", "_"), safe="/:()'-,._~")


def write_csv(path: Path, rows: Sequence[Dict[str, Any]], fieldnames: Sequence[str]) -> None:
    ensure_dir(path.parent)
    with path.open("w", **CSV_DIALECT) as handle:
        writer = csv.DictWriter(handle, fieldnames=list(fieldnames), extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            encoded = {}
            for key in fieldnames:
                value = row.get(key, "")
                if isinstance(value, (list, tuple, set)):
                    value = " || ".join(str(item) for item in value)
                elif isinstance(value, dict):
                    value = json.dumps(value, ensure_ascii=False, sort_keys=True)
                encoded[key] = value
            writer.writerow(encoded)


def read_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


# ---------------------------------------------------------------------------
# Wikimedia Action API client
# ---------------------------------------------------------------------------


class WikimediaClient:
    def __init__(
        self,
        site: Site,
        *,
        sleep_seconds: float = 0.40,
        timeout: int = 45,
        max_retries: int = 6,
        maxlag: int = 5,
        verbose: bool = True,
    ) -> None:
        self.site = site
        self.sleep_seconds = max(0.0, sleep_seconds)
        self.timeout = timeout
        self.max_retries = max_retries
        self.maxlag = maxlag
        self.verbose = verbose
        self.session = requests.Session()
        self.session.headers.update(
            {
                "User-Agent": USER_AGENT,
                "Accept": "application/json",
                "Accept-Encoding": "gzip",
            }
        )
        self.request_count = 0

    def request(self, params: Dict[str, Any]) -> Dict[str, Any]:
        request_params = {
            "format": "json",
            "formatversion": 2,
            "maxlag": self.maxlag,
            **params,
        }

        delay = self.sleep_seconds
        for attempt in range(1, self.max_retries + 1):
            try:
                if self.request_count and delay:
                    time.sleep(delay)
                response = self.session.get(self.site.api, params=request_params, timeout=self.timeout)
                self.request_count += 1

                if response.status_code == 429:
                    retry_after = response.headers.get("Retry-After")
                    wait = float(retry_after) if retry_after and retry_after.isdigit() else max(5.0, delay * 2 or 5.0)
                    if self.verbose:
                        print(f"[{self.site.key}] HTTP 429; waiting {wait:.1f}s", file=sys.stderr)
                    time.sleep(wait)
                    delay = min(max(wait, delay * 2), 60.0)
                    continue

                response.raise_for_status()
                payload = response.json()
                error = payload.get("error")
                if error:
                    code = str(error.get("code", ""))
                    if code in {"maxlag", "ratelimited", "readonly"}:
                        wait = max(5.0, delay * 2 or 5.0)
                        if self.verbose:
                            print(f"[{self.site.key}] API {code}; waiting {wait:.1f}s", file=sys.stderr)
                        time.sleep(wait)
                        delay = min(wait * 1.5, 60.0)
                        continue
                    raise RuntimeError(f"Wikimedia API error {code}: {error}")

                return payload
            except (requests.RequestException, ValueError, RuntimeError) as exc:
                if attempt >= self.max_retries:
                    raise
                wait = max(1.0, delay * 2 or 1.0)
                if self.verbose:
                    print(
                        f"[{self.site.key}] request failed {attempt}/{self.max_retries}: {exc}; waiting {wait:.1f}s",
                        file=sys.stderr,
                    )
                time.sleep(wait)
                delay = min(wait * 1.5, 60.0)

        raise RuntimeError("unreachable API retry state")

    def iter_query(self, params: Dict[str, Any]) -> Iterator[Dict[str, Any]]:
        continuation: Dict[str, Any] = {}
        while True:
            payload = self.request({**params, **continuation})
            yield payload
            continuation = payload.get("continue") or {}
            if not continuation:
                break

    def category_members(self, category: str) -> List[Dict[str, Any]]:
        members: List[Dict[str, Any]] = []
        params = {
            "action": "query",
            "list": "categorymembers",
            "cmtitle": category,
            "cmlimit": "max",
            "cmprop": "ids|title|type|timestamp",
            "cmtype": "page|subcat",
        }
        for payload in self.iter_query(params):
            members.extend(payload.get("query", {}).get("categorymembers", []))
        return members

    def fetch_pages(self, pageids: Sequence[int]) -> Dict[int, Dict[str, Any]]:
        """Fetch latest raw wikitext + resolved categories for up to 50 pages."""
        if not pageids:
            return {}
        if len(pageids) > 50:
            raise ValueError("fetch_pages accepts at most 50 page IDs")

        merged: Dict[int, Dict[str, Any]] = {}
        params = {
            "action": "query",
            "pageids": "|".join(str(value) for value in pageids),
            "prop": "info|revisions|categories",
            "rvprop": "ids|timestamp|sha1|content",
            "rvslots": "main",
            "cllimit": "max",
            "clprop": "hidden|sortkey",
        }

        for payload in self.iter_query(params):
            for page in payload.get("query", {}).get("pages", []):
                pageid = int(page.get("pageid", 0) or 0)
                if not pageid:
                    continue
                target = merged.setdefault(pageid, {})
                for key, value in page.items():
                    if key == "categories":
                        existing = target.setdefault("categories", [])
                        seen = {item.get("title") for item in existing}
                        for category in value or []:
                            if category.get("title") not in seen:
                                existing.append(category)
                                seen.add(category.get("title"))
                    elif key == "revisions":
                        # The latest revision is repeated across category continuation pages.
                        if value and not target.get("revisions"):
                            target["revisions"] = value
                    else:
                        target[key] = value
        return merged


# ---------------------------------------------------------------------------
# Harvest stage
# ---------------------------------------------------------------------------


@dataclass
class PageInventory:
    site_key: str
    pageid: int
    title: str
    ns: int
    source_keys: Set[str] = field(default_factory=set)
    source_categories: Set[str] = field(default_factory=set)
    category_depths: Dict[str, int] = field(default_factory=dict)


CATEGORY_FIELDS = [
    "source_key",
    "site",
    "seed_category",
    "category_title",
    "category_depth",
    "member_type",
    "member_pageid",
    "member_ns",
    "member_title",
    "member_timestamp",
    "member_url",
]

MANIFEST_FIELDS = [
    "site",
    "pageid",
    "ns",
    "title",
    "url",
    "source_keys",
    "source_categories",
    "raw_path",
]


def deterministic_spread_sample(items: Sequence[PageInventory], limit: Optional[int]) -> List[PageInventory]:
    """Return a reproducible sample spread across the complete source inventory.

    Pilot runs used to keep the first N category members.  Wiktionary categories
    are sorted, so that can accidentally sample one script/form convention only
    (the first Chinese-Wiktionary pilot was almost entirely POJ soft redirects).
    Sorting the unique page inventory and selecting evenly spaced positions gives
    us a much more useful parser diagnostic without introducing randomness.
    """
    ordered = sorted(items, key=lambda item: (unicodedata.normalize("NFKC", item.title).casefold(), item.pageid))
    if limit is None or limit >= len(ordered):
        return ordered
    if limit <= 0 or not ordered:
        return []
    if limit == 1:
        return [ordered[len(ordered) // 2]]

    positions = [round(index * (len(ordered) - 1) / (limit - 1)) for index in range(limit)]
    positions = list(dict.fromkeys(positions))
    return [ordered[position] for position in positions]


def merge_page_inventory(target: PageInventory, source: PageInventory, source_key: str) -> None:
    target.source_keys.add(source_key)
    target.source_categories.update(source.source_categories)
    for category, depth in source.category_depths.items():
        old_depth = target.category_depths.get(category)
        target.category_depths[category] = depth if old_depth is None else min(old_depth, depth)


def harvest_source(
    client: WikimediaClient,
    source: SourceSeed,
    *,
    output_dir: Path,
    inventory: Dict[Tuple[str, int], PageInventory],
    all_memberships: List[Dict[str, Any]],
    limit_per_source: Optional[int],
) -> None:
    site = SITES[source.site_key]
    category_dir = output_dir / "category_memberships"
    visited: Set[str] = set()

    # Collect the complete unique page inventory first.  Sampling happens only
    # after category traversal, so --test never means "the first N pages".
    candidates: Dict[int, PageInventory] = {}

    def walk(category: str, depth: int) -> None:
        if category in visited:
            return
        visited.add(category)
        print(f"[{source.key}] category depth={depth}: {category}")
        members = client.category_members(category)
        category_rows: List[Dict[str, Any]] = []

        for member in members:
            member_type = member.get("type") or ("subcat" if int(member.get("ns", -1)) == 14 else "page")
            row = {
                "source_key": source.key,
                "site": source.site_key,
                "seed_category": source.category,
                "category_title": category,
                "category_depth": depth,
                "member_type": member_type,
                "member_pageid": member.get("pageid", ""),
                "member_ns": member.get("ns", ""),
                "member_title": member.get("title", ""),
                "member_timestamp": member.get("timestamp", ""),
                "member_url": page_url(site, str(member.get("title", ""))),
            }
            category_rows.append(row)
            all_memberships.append(row)

            if member_type == "page" and int(member.get("ns", -1)) == 0:
                pageid = int(member.get("pageid", 0) or 0)
                if not pageid:
                    continue
                page = candidates.setdefault(
                    pageid,
                    PageInventory(
                        site_key=source.site_key,
                        pageid=pageid,
                        title=str(member.get("title", "")),
                        ns=int(member.get("ns", 0)),
                    ),
                )
                page.source_categories.add(category)
                old_depth = page.category_depths.get(category)
                page.category_depths[category] = depth if old_depth is None else min(old_depth, depth)

        category_name = safe_filename(f"{source.site_key}__{category}") + ".csv"
        write_csv(category_dir / category_name, category_rows, CATEGORY_FIELDS)

        if depth >= source.recurse_depth:
            return

        for member in members:
            member_type = member.get("type") or ("subcat" if int(member.get("ns", -1)) == 14 else "page")
            if member_type != "subcat":
                continue
            walk(str(member.get("title", "")), depth + 1)

    walk(source.category, 0)

    selected = deterministic_spread_sample(list(candidates.values()), limit_per_source)
    for page in selected:
        key = (source.site_key, page.pageid)
        merged = inventory.setdefault(
            key,
            PageInventory(
                site_key=page.site_key,
                pageid=page.pageid,
                title=page.title,
                ns=page.ns,
            ),
        )
        merge_page_inventory(merged, page, source.key)

    if limit_per_source is not None:
        print(f"[{source.key}] pilot sample={len(selected)}/{len(candidates)} unique pages (deterministic spread)")

def batch(values: Sequence[int], size: int = 50) -> Iterator[Sequence[int]]:
    for index in range(0, len(values), size):
        yield values[index : index + size]


def revision_content(page: Dict[str, Any]) -> Tuple[Dict[str, Any], str]:
    revisions = page.get("revisions") or []
    revision = revisions[0] if revisions else {}
    slots = revision.get("slots") or {}
    main = slots.get("main") or {}
    content = main.get("content")
    if content is None:
        # Older/back-compat shape, useful if a non-Wikimedia MediaWiki is ever used.
        content = revision.get("content", "")
    return revision, str(content or "")


def harvest_pages(
    clients: Dict[str, WikimediaClient],
    inventory: Dict[Tuple[str, int], PageInventory],
    *,
    output_dir: Path,
    refresh: bool,
) -> None:
    by_site: Dict[str, List[PageInventory]] = defaultdict(list)
    for page in inventory.values():
        by_site[page.site_key].append(page)

    for site_key, pages in sorted(by_site.items()):
        client = clients[site_key]
        raw_dir = output_dir / "raw" / site_key
        ensure_dir(raw_dir)
        pages.sort(key=lambda item: item.pageid)

        missing: List[int] = []
        for page in pages:
            raw_path = raw_dir / f"{page.pageid}.json"
            if refresh or not raw_path.exists():
                missing.append(page.pageid)

        print(f"[{site_key}] pages={len(pages)} fetch={len(missing)} cached={len(pages)-len(missing)}")

        for chunk_index, chunk in enumerate(batch(missing, 50), start=1):
            fetched = client.fetch_pages(chunk)
            for pageid in chunk:
                inv = inventory[(site_key, pageid)]
                page = fetched.get(pageid)
                if not page:
                    print(f"[{site_key}] warning: pageid={pageid} was not returned", file=sys.stderr)
                    continue

                revision, content = revision_content(page)
                categories = [
                    {
                        "title": category.get("title", ""),
                        "hidden": bool(category.get("hidden")),
                        "sortkey": category.get("sortkey", ""),
                    }
                    for category in page.get("categories", [])
                ]
                payload = {
                    "scraper_version": VERSION,
                    "scraped_at_utc": now_utc(),
                    "site": site_key,
                    "api": client.site.api,
                    "pageid": pageid,
                    "ns": page.get("ns", inv.ns),
                    "title": page.get("title", inv.title),
                    "url": page_url(client.site, str(page.get("title", inv.title))),
                    "source_keys": sorted(inv.source_keys),
                    "source_categories": sorted(inv.source_categories),
                    "categories": categories,
                    "revision": {
                        "revid": revision.get("revid"),
                        "parentid": revision.get("parentid"),
                        "timestamp": revision.get("timestamp"),
                        "sha1": revision.get("sha1"),
                        "contentmodel": (revision.get("slots") or {}).get("main", {}).get("contentmodel"),
                        "contentformat": (revision.get("slots") or {}).get("main", {}).get("contentformat"),
                    },
                    "wikitext": content,
                }
                write_json(raw_dir / f"{pageid}.json", payload)

            print(f"[{site_key}] fetched batch {chunk_index}: {len(chunk)} pages")


def write_inventory(output_dir: Path, inventory: Dict[Tuple[str, int], PageInventory]) -> None:
    rows: List[Dict[str, Any]] = []
    for page in sorted(inventory.values(), key=lambda item: (item.site_key, item.title, item.pageid)):
        site = SITES[page.site_key]
        rows.append(
            {
                "site": page.site_key,
                "pageid": page.pageid,
                "ns": page.ns,
                "title": page.title,
                "url": page_url(site, page.title),
                "source_keys": sorted(page.source_keys),
                "source_categories": sorted(page.source_categories),
                "raw_path": str(Path("raw") / page.site_key / f"{page.pageid}.json"),
            }
        )
    write_csv(output_dir / "manifest.csv", rows, MANIFEST_FIELDS)


# ---------------------------------------------------------------------------
# Wikitext structural parser
# ---------------------------------------------------------------------------


HEADING_RE = re.compile(r"^(={2,6})\s*(.*?)\s*\1\s*$", re.MULTILINE)
REDIRECT_RE = re.compile(r"^\s*#(?:REDIRECT|重定向|転送|転送先|넘겨주기)\s*:?\s*\[\[([^\]|#]+)", re.IGNORECASE)

LANGUAGE_MAP = {
    # English Wiktionary headings
    "Chinese": "zh",
    "Mandarin": "cmn",
    "Cantonese": "yue",
    "Hokkien": "nan",
    "Hakka": "hak",
    "Wu": "wuu",
    "Gan": "gan",
    "Xiang": "hsn",
    "Jin": "cjy",
    "Middle Chinese": "ltc",
    "Old Chinese": "och",
    "Japanese": "ja",
    "Korean": "ko",
    "Vietnamese": "vi",
    # Chinese Wiktionary
    "漢語": "zh",
    "汉语": "zh",
    "官話": "cmn",
    "官话": "cmn",
    "粵語": "yue",
    "粤语": "yue",
    "閩南語": "nan",
    "闽南语": "nan",
    "泉漳話": "nan",
    "泉漳话": "nan",
    "客家語": "hak",
    "客家语": "hak",
    "吳語": "wuu",
    "吴语": "wuu",
    "贛語": "gan",
    "赣语": "gan",
    "湘語": "hsn",
    "湘语": "hsn",
    "日語": "ja",
    "日语": "ja",
    "韓語": "ko",
    "韩语": "ko",
    "越南語": "vi",
    "越南语": "vi",
    # Japanese Wiktionary
    "日本語": "ja",
    "中国語": "zh",
    "中國語": "zh",
    "朝鮮語": "ko",
    "朝鲜语": "ko",
    "韓国語": "ko",
    "韓國語": "ko",
    "ベトナム語": "vi",
    # Korean Wiktionary
    "한국어": "ko",
    "중국어": "zh",
    "일본어": "ja",
    "베트남어": "vi",
}

SECTION_KIND_MAP: Dict[str, Set[str]] = {
    "etymology": {
        "Etymology",
        "Origin",
        "詞源",
        "词源",
        "語源",
        "语源",
        "由来",
        "어원",
    },
    "pronunciation": {
        "Pronunciation",
        "發音",
        "发音",
        "讀音",
        "读音",
        "発音",
        "발음",
    },
    "alternative_forms": {
        "Alternative forms",
        "Alternative form",
        "Alternative spellings",
        "Alternative spelling",
        "Variants",
        "Variant forms",
        "異體",
        "异体",
        "異體字",
        "异体字",
        "別表記",
        "別綴り",
        "대체 표기",
    },
    "definitions": {
        "Idiom",
        "Phrase",
        "Proverb",
        "Noun",
        "Adjective",
        "Verb",
        "Adverb",
        "Adjective noun",
        "Proper noun",
        "Interjection",
        "Root",
        "成語",
        "成语",
        "成句",
        "俗語",
        "俗语",
        "諺語",
        "谚语",
        "釋義",
        "释义",
        "短語",
        "短语",
        "片語",
        "片语",
        "動詞",
        "动词",
        "形容詞",
        "形容词",
        "副詞",
        "副词",
        "形容動詞",
        "專有名詞",
        "专有名词",
        "感嘆詞",
        "感叹词",
        "熟語",
        "熟语",
        "四字熟語",
        "慣用句",
        "名詞",
        "名词",
        "명사",
        "부사",
        "동사",
        "형용사",
        "어구",
        "관용구",
        "어근",
    },
    "descendants": {"Descendants", "Derived terms", "派生語", "派生词", "派生詞", "후손"},
    "synonyms": {"Synonyms", "同義詞", "同义词", "類義語", "유의어"},
    "antonyms": {"Antonyms", "反義詞", "反义词", "반의어"},
    "related_terms": {"Related terms", "関連語", "關聯詞", "关联词", "관련 어휘"},
    "translations": {"Translations", "翻訳", "翻譯", "번역"},
    "inflection": {"Inflection", "Conjugation", "活用", "活用形"},
    "references": {"References", "Reference", "參考資料", "参考资料", "脚注", "註釋", "주석"},
}


HEADING_TEMPLATE_LABELS = {
    "idiom": "Idiom",
    "noun": "Noun",
    "verb": "Verb",
    "adv": "Adverb",
    "adverb": "Adverb",
    "adjective": "Adjective",
    "adjectivenoun": "Adjective",
    "alter": "Alternative forms",
    "alternative forms": "Alternative forms",
    "pron": "Pronunciation",
    "pronunciation": "Pronunciation",
    "etym": "Etymology",
    "etymology": "Etymology",
    "syn": "Synonyms",
    "ant": "Antonyms",
    "rel": "Related terms",
    "trans": "Translations",
    "conjug": "Conjugation",
    "prov": "Proverb",
    "name": "Proper noun",
    "interjection": "Interjection",
}

HEADING_LANGUAGE_TEMPLATE_CODES = {
    "zh": "Chinese",
    "ja": "Japanese",
    "ko": "Korean",
    "vi": "Vietnamese",
}


def heading_template_label(raw_template: str) -> str:
    name, args = parse_template(raw_template)
    key = name.strip().lower()
    if key == "l":
        return HEADING_LANGUAGE_TEMPLATE_CODES.get(args.get("1", "").strip().lower(), "")
    if key in HEADING_LANGUAGE_TEMPLATE_CODES:
        return HEADING_LANGUAGE_TEMPLATE_CODES[key]
    return HEADING_TEMPLATE_LABELS.get(key, "")


def normalized_heading(text: str) -> str:
    value = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL).strip()

    # Japanese Wiktionary commonly puts semantic information *inside* heading
    # templates, e.g. =={{L|ja}}== and ==={{idiom}}===.  Removing templates here
    # destroys the heading. Resolve known heading templates first, while keeping
    # raw_heading separately in Section for auditability.
    whole = re.fullmatch(r"\{\{(.*)\}\}", value, flags=re.DOTALL)
    if whole:
        label = heading_template_label(whole.group(1))
        if label:
            return label

    def replace_template(match: re.Match[str]) -> str:
        return heading_template_label(match.group(1))

    value = re.sub(r"\{\{([^{}]+)\}\}", replace_template, value)
    value = re.sub(r"\{\{.*?\}\}", "", value)
    return re.sub(r"\s+", " ", value).strip()


def section_kind(heading: str) -> str:
    clean = normalized_heading(heading)
    for kind, names in SECTION_KIND_MAP.items():
        if clean in names:
            return kind
    # English Wiktionary frequently numbers repeated sections: Etymology 1, Noun 2.
    without_number = re.sub(r"\s+\d+$", "", clean)
    for kind, names in SECTION_KIND_MAP.items():
        if without_number in names:
            return kind

    # Japanese Wiktionary often combines several parts of speech in one heading,
    # e.g. {{noun}}・{{adjectivenoun}} or 名詞・形容動詞.  The section is still a
    # definition-bearing section; do not require an exact whole-heading match.
    parts = [part.strip() for part in re.split(r"[・／/]", without_number) if part.strip()]
    if len(parts) > 1:
        definition_names = SECTION_KIND_MAP["definitions"]
        if any(part in definition_names for part in parts):
            return "definitions"

    return "other"


@dataclass
class Section:
    level: int
    raw_heading: str
    heading: str
    path: List[str]
    raw_path: List[str]
    body: str
    language_heading: str
    language_tag: str
    kind: str


SOURCE_LANGUAGE_MAP = {
    # A few older Chinese-Wiktionary entries use ==漢字== as their Chinese
    # language heading. Treat that convention only on that source; the same
    # heading can mean something else on another Wiktionary.
    "zhwiktionary": {"漢字": "zh", "汉字": "zh"},
}


def language_tag_for_heading(heading: str, site_key: str = "") -> str:
    return SOURCE_LANGUAGE_MAP.get(site_key, {}).get(heading, "") or LANGUAGE_MAP.get(heading, "")


def parse_sections(wikitext: str, site_key: str = "") -> List[Section]:
    matches = list(HEADING_RE.finditer(wikitext))
    if not matches:
        return []

    stack: Dict[int, str] = {}
    raw_stack: Dict[int, str] = {}
    sections: List[Section] = []
    current_language_heading = ""
    current_language_tag = ""
    for index, match in enumerate(matches):
        level = len(match.group(1))
        raw_heading = re.sub(r"\s+", " ", match.group(2)).strip()
        heading = normalized_heading(raw_heading)
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(wikitext)
        body = wikitext[start:end].strip()

        # Remove this level and everything deeper before adding current heading.
        for old_level in sorted([key for key in stack if key >= level], reverse=True):
            stack.pop(old_level, None)
            raw_stack.pop(old_level, None)
        stack[level] = heading
        raw_stack[level] = raw_heading
        path = [stack[key] for key in sorted(stack)]
        raw_path = [raw_stack[key] for key in sorted(raw_stack)]

        level_two_heading = stack.get(2, "")
        level_two_tag = language_tag_for_heading(level_two_heading, site_key)
        if level == 2 and level_two_tag:
            current_language_heading = level_two_heading
            current_language_tag = level_two_tag

        # Some older Wiktionary pages incorrectly use level-2 headings for POS
        # or references after a valid language heading. Keep the last explicit
        # language context instead of relabelling `==名詞==` / `==명사==` /
        # `==脚注==` as a language.
        language_heading = current_language_heading
        language_tag = current_language_tag
        sections.append(
            Section(
                level=level,
                raw_heading=raw_heading,
                heading=heading,
                path=path,
                raw_path=raw_path,
                body=body,
                language_heading=language_heading,
                language_tag=language_tag,
                kind=section_kind(heading),
            )
        )
    return sections


# ---------------------------------------------------------------------------
# Minimal balanced template parser for diagnostics
# ---------------------------------------------------------------------------


def split_top_level(text: str, delimiter: str = "|") -> List[str]:
    parts: List[str] = []
    buf: List[str] = []
    brace = 0
    bracket = 0
    paren = 0
    index = 0
    while index < len(text):
        pair = text[index : index + 2]
        if pair == "{{":
            brace += 1
            buf.append(pair)
            index += 2
            continue
        if pair == "}}" and brace:
            brace -= 1
            buf.append(pair)
            index += 2
            continue
        if pair == "[[":
            bracket += 1
            buf.append(pair)
            index += 2
            continue
        if pair == "]]" and bracket:
            bracket -= 1
            buf.append(pair)
            index += 2
            continue
        ch = text[index]
        if ch == "(":
            paren += 1
        elif ch == ")" and paren:
            paren -= 1
        if ch == delimiter and brace == 0 and bracket == 0 and paren == 0:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        index += 1
    parts.append("".join(buf))
    return parts


def iter_template_strings(text: str) -> Iterator[str]:
    stack: List[int] = []
    index = 0
    while index < len(text) - 1:
        pair = text[index : index + 2]
        if pair == "{{":
            stack.append(index)
            index += 2
            continue
        if pair == "}}" and stack:
            start = stack.pop()
            # Yield every template, including nested ones; this is useful for frequency audits.
            yield text[start + 2 : index]
            index += 2
            continue
        index += 1


def parse_template(template_text: str) -> Tuple[str, Dict[str, str]]:
    parts = split_top_level(template_text)
    if not parts:
        return "", {}
    name = re.sub(r"\s+", " ", parts[0]).strip()
    args: Dict[str, str] = {}
    positional = 1
    for raw in parts[1:]:
        split = split_top_level(raw, delimiter="=")
        if len(split) > 1 and re.fullmatch(r"[^{}\[\]|]+", split[0].strip()):
            key = split[0].strip()
            value = "=".join(split[1:]).strip()
            args[key] = value
        else:
            args[str(positional)] = raw.strip()
            positional += 1
    return name, args


# ---------------------------------------------------------------------------
# Lightweight plain-text / signal extraction
# ---------------------------------------------------------------------------


CJK_LINK_RE = re.compile(r"\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\]")
EXTERNAL_LINK_RE = re.compile(r"\[(?:https?://\S+)(?:\s+([^\]]+))?\]")
TAG_RE = re.compile(r"<[^>]+>")
COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
REF_RE = re.compile(r"<ref\b[^>]*>.*?</ref>|<ref\b[^>]*/>", re.DOTALL | re.IGNORECASE)


def strip_templates_best_effort(text: str) -> str:
    value = text
    # Remove balanced templates iteratively from innermost outward.
    for _ in range(10):
        previous = value
        value = re.sub(r"\{\{[^{}]*\}\}", "", value)
        if value == previous:
            break
    return value


PLAIN_TEXT_TEMPLATE_ARGS = {
    "n-g": "1",
    "ng": "1",
    "zh-m": "1",
    "zh-l": "1",
    "non-gloss": "1",
    "gloss": "1",
    "gl": "1",
}


def expand_plain_templates_best_effort(text: str) -> str:
    """Expand a small set of display templates before stripping the rest.

    This is intentionally conservative: staging should recover text that the
    source explicitly supplies, not attempt to emulate Wiktionary's Lua stack.
    """
    value = text
    for _ in range(12):
        previous = value

        def repl(match: re.Match[str]) -> str:
            name, args = parse_template(match.group(1))
            key = normalized_template_name(name)
            if key in PLAIN_TEXT_TEMPLATE_ARGS:
                return args.get(PLAIN_TEXT_TEMPLATE_ARGS[key], "")
            if key in {"l", "link", "m", "mention"}:
                return args.get("alt", "") or args.get("2", "") or ""
            if key in {"w", "wikipedia"}:
                return args.get("2", "") or args.get("1", "") or ""
            if key in {"lb", "label", "qual", "qualifier", "q"}:
                return ""
            return match.group(0)

        value = re.sub(r"\{\{([^{}]*)\}\}", repl, value)
        if value == previous:
            break
    return value


def wikitext_to_plain(text: str) -> str:
    value = COMMENT_RE.sub("", text)
    value = REF_RE.sub("", value)
    value = expand_plain_templates_best_effort(value)
    value = CJK_LINK_RE.sub(lambda match: match.group(2) or match.group(1), value)
    value = EXTERNAL_LINK_RE.sub(lambda match: match.group(1) or "", value)
    value = strip_templates_best_effort(value)
    value = TAG_RE.sub("", value)
    value = value.replace("'''", "").replace("''", "")
    value = re.sub(r"^[:;*#]+\s*", "", value, flags=re.MULTILINE)
    value = re.sub(r"\s+", " ", value)
    return value.strip()


DEFINITION_RELATION_TEMPLATES = {
    "syn of": "synonym_of",
    "synonym of": "synonym_of",
    "initialism of": "initialism_of",
    "hanja form of": "hanja_form_of",
    "zh-erhua form of": "erhua_form_of",
    "alt form": "alternative_form_of",
    "alt form of": "alternative_form_of",
    "alternative form of": "alternative_form_of",
    "vi-han form of": "han_form_of",
    "之同義詞": "synonym_of",
    "之同义词": "synonym_of",
    "之反義詞": "antonym_of",
    "之反义词": "antonym_of",
    "zh-misspelling": "misspelling_of",
    "zh-misspelling of": "misspelling_of",
    "misspelling of": "misspelling_of",
    "misconstruction of": "misconstruction_of",
    "uncommon form of": "uncommon_form_of",
    "short for": "short_for",
    "zh-short": "short_for",
    "zh-short-comp": "short_for",
    "zh-alt-form": "alternative_form_of",
    "zh-alt form": "alternative_form_of",
    "alternative spelling of": "alternative_form_of",
    "kyujitai of": "alternative_form_of",
    "ja-kyujitai spelling of": "alternative_form_of",
}


def normalized_template_name(name: str) -> str:
    return re.sub(r"\s+", " ", name).strip().lower()


def definition_template_relation(
    name: str,
    args: Dict[str, str],
    default_language: str = "",
) -> Dict[str, str]:
    key = normalized_template_name(name)
    relation_type = DEFINITION_RELATION_TEMPLATES.get(key, "")
    if not relation_type:
        return {}

    if key == "hanja form of":
        return {
            "relation_template": name,
            "relation_type": relation_type,
            "relation_language": "ko",
            "relation_target": args.get("1", "").strip(),
        }
    if key == "zh-erhua form of":
        return {
            "relation_template": name,
            "relation_type": relation_type,
            "relation_language": "zh",
            # The target is often implicit in this template. Do not guess it.
            "relation_target": args.get("1", "").strip(),
        }
    if key == "vi-han form of":
        return {
            "relation_template": name,
            "relation_type": relation_type,
            "relation_language": "vi",
            "relation_target": args.get("1", "").strip(),
        }
    if key in {
        "alt form", "alt form of", "alternative form of", "alternative spelling of",
        "misspelling of", "misconstruction of", "uncommon form of", "short for",
    }:
        first = args.get("1", "").strip()
        second = args.get("2", "").strip()
        if second and re.fullmatch(r"[a-z]{2,3}(?:-[a-z0-9]+)?", first, flags=re.IGNORECASE):
            language = first.lower()
            target = second
        else:
            language = default_language
            target = first
        return {
            "relation_template": name,
            "relation_type": relation_type,
            "relation_language": language,
            "relation_target": target,
        }

    if key in {
        "zh-misspelling", "zh-misspelling of", "zh-short", "zh-short-comp",
        "zh-alt-form", "zh-alt form", "kyujitai of", "ja-kyujitai spelling of",
    }:
        return {
            "relation_template": name,
            "relation_type": relation_type,
            "relation_language": default_language,
            "relation_target": args.get("1", "").strip(),
        }

    return {
        "relation_template": name,
        "relation_type": relation_type,
        "relation_language": args.get("1", "").strip(),
        "relation_target": args.get("2", "").strip(),
    }


def definition_evidence(section: Section, site_key: str = "") -> List[Dict[str, str]]:
    """Extract local definition evidence without mistaking page furniture for glosses.

    Definitions may be ordinary ``#`` lines or formal relation templates. Korean
    Wiktionary has several older conventions: an empty ``#`` followed by ``:*``;
    an occasional plain prose line; and large ``{{외국어|...}}`` translation blocks
    embedded directly inside the POS section.  The latter must never become fake
    definitions such as ``독일어(de):``.
    """
    if section.kind != "definitions":
        # A small number of older Korean Wiktionary entries put the numbered
        # definition directly under ==한국어== with no POS subheading at all.
        # Accept that specific source convention, but do not generalise it to
        # arbitrary non-definition sections on the other wikis.
        if not (site_key == "kowiktionary" and section.level == 2 and section.language_tag == "ko"):
            return []

    # For Korean Wiktionary, remove templates *for the line scan only*. This
    # deletes multiline translation/pronunciation furniture while preserving
    # surrounding prose such as ``# {{lb|ko|한자성어}} 실제 정의``. The original
    # section remains untouched in sections/*.csv.
    scan_body = strip_templates_best_effort(section.body) if site_key == "kowiktionary" else section.body

    out: List[Dict[str, str]] = []
    pending_empty_hash = False
    for line in scan_body.splitlines():
        stripped = line.lstrip()

        if site_key == "kowiktionary" and stripped == "#":
            pending_empty_hash = True
            continue

        raw_definition = ""
        if site_key == "kowiktionary" and pending_empty_hash and stripped.startswith(":*"):
            raw_definition = re.sub(r"^:\*\s*", "", stripped)
            pending_empty_hash = False
        elif stripped.startswith("#") and not stripped.startswith(("#*", "#:", "##")):
            raw_definition = re.sub(r"^#+\s*", "", stripped)
            pending_empty_hash = False
        else:
            if stripped:
                pending_empty_hash = False
            continue

        # On non-Korean sites use the original definition line so relation
        # templates remain available. Korean scan_body intentionally removed
        # templates; local Korean relation templates are not needed to recover
        # these sampled Hanja idiom glosses.
        templates = [parse_template(raw) for raw in iter_template_strings(raw_definition)]
        templates = [(name, args) for name, args in templates if name]
        relation: Dict[str, str] = {}
        for name, args in templates:
            relation = definition_template_relation(name, args, section.language_tag)
            if relation:
                break

        plain = wikitext_to_plain(raw_definition)
        if not plain:
            for name, args in templates:
                if normalized_template_name(name) == "non-gloss":
                    plain = wikitext_to_plain(args.get("1", ""))
                    break

        if plain or relation:
            out.append(
                {
                    "raw_definition": raw_definition.strip(),
                    "plain_definition": plain,
                    "relation_template": relation.get("relation_template", ""),
                    "relation_type": relation.get("relation_type", ""),
                    "relation_language": relation.get("relation_language", ""),
                    "relation_target": relation.get("relation_target", ""),
                }
            )

    if site_key == "kowiktionary" and not out:
        # Older ko.wiktionary drafts sometimes put the gloss in a plain bullet
        # or as unmarked prose before the etymology line. Work from template-free
        # text so translation tables can never be mistaken for definitions.
        cleaned_lines = scan_body.splitlines()
        for line in cleaned_lines:
            stripped = line.strip()
            if not stripped:
                continue

            candidate = ""
            if stripped.startswith("*"):
                candidate = stripped[1:].strip()
                if re.match(r"^(?:어원|동사|형용사|부사|관련\s*어휘)\s*[:：]", candidate):
                    continue
            elif not stripped.startswith(("[", "{", "#", ":", "|", "<")) and stripped not in {"}}", "{{"}:
                candidate = stripped

            if not candidate:
                continue
            if re.match(r"^(?:독일어|러시아어|영어|일본어|중국어|프랑스어)\s*\([^)]*\)\s*[:：]?$", candidate):
                continue
            plain = wikitext_to_plain(candidate)
            if not plain:
                continue
            out.append(
                {
                    "raw_definition": candidate,
                    "plain_definition": plain,
                    "relation_template": "",
                    "relation_type": "",
                    "relation_language": "",
                    "relation_target": "",
                }
            )
            break
    return out


def definition_lines(section: Section, site_key: str = "") -> List[str]:
    return [
        row["plain_definition"]
        for row in definition_evidence(section, site_key)
        if row.get("plain_definition")
    ]


HAN_RANGES = (
    (0x3400, 0x4DBF),
    (0x4E00, 0x9FFF),
    (0xF900, 0xFAFF),
    (0x20000, 0x2A6DF),
    (0x2A700, 0x2B73F),
    (0x2B740, 0x2B81F),
    (0x2B820, 0x2CEAF),
    (0x2CEB0, 0x2EBEF),
    (0x2EBF0, 0x2EE5F),
    (0x2F800, 0x2FA1F),
    (0x30000, 0x3134F),
    (0x31350, 0x323AF),
    (0x323B0, 0x3347F),
)


def is_han(ch: str) -> bool:
    cp = ord(ch)
    return any(start <= cp <= end for start, end in HAN_RANGES)


def is_hangul(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x1100 <= cp <= 0x11FF
        or 0x3130 <= cp <= 0x318F
        or 0xA960 <= cp <= 0xA97F
        or 0xAC00 <= cp <= 0xD7AF
        or 0xD7B0 <= cp <= 0xD7FF
    )


def is_kana(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x3040 <= cp <= 0x30FF
        or 0x31F0 <= cp <= 0x31FF
        or 0x1B000 <= cp <= 0x1B16F
        or 0x1AFF0 <= cp <= 0x1AFFF
    )


def is_latin_or_ascii(ch: str) -> bool:
    if ch.isascii():
        return True
    try:
        return "LATIN" in unicodedata.name(ch)
    except ValueError:
        return False


def title_script_class(title: str) -> str:
    visible = [ch for ch in title if not ch.isspace()]
    if not visible:
        return "empty"
    if all(is_han(ch) for ch in visible):
        return "han"
    if all(is_hangul(ch) for ch in visible):
        return "hangul"
    if all(is_kana(ch) for ch in visible):
        return "kana"
    if all(is_latin_or_ascii(ch) for ch in visible):
        return "latin_or_ascii"
    scripts: Set[str] = set()
    for ch in visible:
        if is_han(ch):
            scripts.add("han")
        elif is_hangul(ch):
            scripts.add("hangul")
        elif is_kana(ch):
            scripts.add("kana")
        elif is_latin_or_ascii(ch):
            scripts.add("latin_or_ascii")
        else:
            scripts.add("other")
    return "+".join(sorted(scripts))


def only_han_sequences(text: str, min_len: int = 2) -> List[str]:
    sequences: List[str] = []
    buf: List[str] = []
    for ch in text:
        if is_han(ch):
            buf.append(ch)
        else:
            if len(buf) >= min_len:
                sequences.append("".join(buf))
            buf = []
    if len(buf) >= min_len:
        sequences.append("".join(buf))
    return sequences


def only_hangul_sequences(text: str, min_len: int = 2) -> List[str]:
    sequences: List[str] = []
    buf: List[str] = []
    for ch in text:
        if is_hangul(ch):
            buf.append(ch)
        else:
            if len(buf) >= min_len:
                sequences.append("".join(buf))
            buf = []
    if len(buf) >= min_len:
        sequences.append("".join(buf))
    return sequences


HANJA_PATTERNS = [
    re.compile(r"\bhanja\b\s*[:=]?\s*([\u3400-\u9FFF\U00020000-\U0003347F]{2,})", re.IGNORECASE),
    re.compile(r"한자(?:성어|어)?\s*[:：'‘’\"]?\s*([\u3400-\u9FFF\U00020000-\U0003347F]{2,})"),
    re.compile(r"\(\s*hanja\s+([\u3400-\u9FFF\U00020000-\U0003347F]{2,})\s*\)", re.IGNORECASE),
]

HANGUL_PATTERNS = [
    re.compile(r"\bhangeul\b\s*[:=]?\s*([\u1100-\u11FF\u3130-\u318F\uAC00-\uD7AF]{2,})", re.IGNORECASE),
    re.compile(r"한글\s*[:：]?\s*([\u1100-\u11FF\u3130-\u318F\uAC00-\uD7AF]{2,})"),
]


def explicit_sequences(patterns: Sequence[re.Pattern[str]], text: str) -> List[str]:
    found: List[str] = []
    for pattern in patterns:
        found.extend(match.group(1) for match in pattern.finditer(text))
    return stable_unique(found)



def explicit_hanja_sequences(wikitext: str, parsed_templates: Sequence[Tuple[str, Dict[str, str]]] = ()) -> List[str]:
    # Direct Korean pages often write 한자 [[刻骨難忘]]. Unwrap links before
    # applying the ordinary Hanja patterns.
    unlinked = CJK_LINK_RE.sub(lambda match: match.group(2) or match.group(1), wikitext)
    found = explicit_sequences(HANJA_PATTERNS, unlinked)

    # Korean Wiktionary also uses {{어원|古今東西|고금동서|...|형태=한자어 독음}}.
    for name, args in parsed_templates:
        if normalized_template_name(name) not in {"어원", "etymology"}:
            continue
        form = (args.get("형태", "") or args.get("type", "")).strip()
        candidate = args.get("1", "").strip()
        if "한자" not in form:
            continue
        if candidate and all(is_han(ch) for ch in candidate):
            found.append(candidate)

    # Templates frequently carry the Hanja in a named parameter, e.g.
    # {{표제어|언어=한국어|한자=漁夫之利}}, {{한국어 명사|한자=薄利多賣}},
    # or {{ko-pos|어구|한자=不言實行}}. The parameter itself is explicit source
    # evidence, so it is safe to accept regardless of the surrounding template.
    for name, args in parsed_templates:
        key = normalized_template_name(name)
        candidates: List[str] = []
        if key == "ko-etym-sino":
            candidates.append(args.get("1", "").strip())
        candidates.append((args.get("한자", "") or args.get("hanja", "")).strip())
        for candidate in candidates:
            if candidate and all(is_han(ch) for ch in candidate):
                found.append(candidate)

    # Older Korean-Wiktionary pages may simply write '* 어원: [[權謀術數]]'
    # without the word 한자.  A Han sequence explicitly placed in an etymology
    # line is still strong source evidence for the Hangul headword's Hanja.
    for line in wikitext.splitlines():
        if not re.match(r"^\s*[*:#;]*\s*어원\s*[:：]", line):
            continue
        plain = CJK_LINK_RE.sub(lambda match: match.group(2) or match.group(1), line)
        # If the line explicitly says `한자 ...`, the dedicated patterns above
        # already captured that form. Do not also swallow Han citations, source
        # titles, or quoted Classical Chinese later on the same etymology line.
        if "한자" in plain:
            continue
        found.extend(only_han_sequences(plain))
    return stable_unique(found)


ZH_SEE_TYPES: Dict[str, Tuple[str, str]] = {
    "s": ("variant", "simplified"),
    "simp": ("variant", "simplified"),
    "simplified": ("variant", "simplified"),
    "v": ("variant", "modern_variant"),
    "var": ("variant", "modern_variant"),
    "vt": ("variant", "modern_variant_traditional"),
    "o": ("variant", "obsolete_variant"),
    "a": ("variant", "ancient_variant"),
    "hv": ("variant", "historical_variant"),
    "sv": ("variant", "simplified_and_variant"),
    "svt": ("variant", "simplified_and_variant_traditional"),
    "ss": ("variant", "second_round_simplified"),
    "ns": ("variant", "nonstandard_simplified"),
    "poj": ("pronunciation", "peh_oe_ji"),
    "trc": ("variant", "taiwanese_hokkien_recommended_form"),
    "is": ("variant", "internet_slang"),
    "err": ("variant", "erroneous_form"),
}


def zh_see_evidence(
    title: str,
    parsed_templates: Sequence[Tuple[str, Dict[str, str]]],
) -> Tuple[List[Dict[str, str]], List[Dict[str, str]]]:
    """Return explicit non-lemma relations and pronunciation evidence.

    {{zh-see}} is a soft redirect for non-lemma Chinese forms.  We keep the
    relationship but do not promote the page to a separate Chengyu lexical
    candidate.  An omitted type is deliberately *not* guessed here: Wiktionary
    can auto-detect it from the target page, which this staging parser may not
    have resolved yet.  POJ is different: a romanized page title is useful as
    pronunciation evidence for the Han target.
    """
    relations: List[Dict[str, str]] = []
    pronunciations: List[Dict[str, str]] = []
    for name, args in parsed_templates:
        if normalized_template_name(name) != "zh-see":
            continue
        target = args.get("1", "").strip()
        type_code = args.get("2", "").strip().lower()
        relation_kind, cause = ZH_SEE_TYPES.get(type_code, ("variant", "")) if type_code else ("variant", "")
        gloss = args.get("3", "").strip()

        relations.append(
            {
                "relation_template": name,
                "relation_kind": relation_kind,
                "relation_cause": cause,
                "relation_type_code": type_code,
                "source_form": title,
                "target_form": target,
                "gloss": gloss,
                "normalizer_action": "pronunciation" if relation_kind == "pronunciation" else "ignore_nonlemma_form",
            }
        )

        if relation_kind == "pronunciation" and type_code == "poj" and title_script_class(title) == "latin_or_ascii":
            pronunciations.append(
                {
                    "target_form": target,
                    "reading": title,
                    "language_tag": "nan",
                    "language_label": "Hokkien",
                    "system": "poj",
                    "system_label": "Pe̍h-ōe-jī",
                    "source_template": name,
                    "source_type_code": type_code,
                }
            )
    return relations, pronunciations


ZH_PRON_READINGS: Dict[str, Tuple[str, str, str, str]] = {
    "m": ("cmn", "Mandarin", "pinyin", "Hanyu Pinyin"),
    "m-s": ("zhx-sic", "Sichuanese", "zh-pron:m-s", "Sichuanese romanization"),
    "m-x": ("cmn", "Xi'an Mandarin", "zh-pron:m-x", "Xi'an Mandarin romanization"),
    "m-nj": ("cmn", "Nanjing Mandarin", "zh-pron:m-nj", "Nanjing Mandarin romanization"),
    "dg": ("dng", "Dungan", "zh-pron:dg", "Dungan transcription"),
    "c": ("yue", "Cantonese", "jyutping", "Jyutping"),
    "c-dg": ("yue", "Dongguan Cantonese", "zh-pron:c-dg", "Dongguan Cantonese transcription"),
    "c-t": ("zhx-tai", "Taishanese", "zh-pron:c-t", "Taishanese transcription"),
    "c-yj": ("yue", "Yangjiang Cantonese", "zh-pron:c-yj", "Yangjiang Cantonese transcription"),
    "g": ("gan", "Gan", "zh-pron:g", "Wiktionary Gan romanization"),
    "h": ("hak", "Hakka", "zh-pron:h", "Hakka pronunciation data"),
    "j": ("cjy", "Jin", "zh-pron:j", "Wiktionary Jin romanization"),
    "mb": ("mnp", "Northern Min", "kcr", "Kienning Colloquial Romanized"),
    "md": ("cdo", "Eastern Min", "buc", "Bàng-uâ-cê"),
    "mn": ("nan", "Hokkien", "poj", "Pe̍h-ōe-jī"),
    "mn-t": ("nan-tws", "Teochew", "pengim", "Peng'im"),
    "mn-l": ("luh", "Leizhou Min", "leizhou_pinyin", "Leizhou Pinyin"),
    "px": ("cpx", "Puxian Min", "pinging", "Pouseng Ping'ing"),
    "sp": ("csp", "Southern Pinghua", "jyutping_plus", "Jyutping++"),
    "w": ("wuu", "Wu", "wugniu", "Wugniu"),
    "w-j": ("wuu-jih", "Jinhua Wu", "wugniu", "Wugniu"),
    "x": ("hsn", "Xiang", "zh-pron:x", "Wiktionary Xiang romanization"),
    "x-l": ("hsn-lou", "Loudi Xiang", "zh-pron:x-l", "Wiktionary Loudi Xiang romanization"),
    "x-h": ("hsn-hya", "Hengyang Xiang", "zh-pron:x-h", "Wiktionary Hengyang Xiang romanization"),
}


def is_kana_string(value: str) -> bool:
    chars = [ch for ch in value if not ch.isspace() and ch not in {"・", "･", "-", "‐"}]
    return bool(chars) and all(is_kana(ch) for ch in chars)


def nonlemma_see_evidence(
    title: str,
    parsed_templates: Sequence[Tuple[str, Dict[str, str]]],
) -> List[Dict[str, str]]:
    """Keep Japanese soft redirects as explicit form evidence.

    Like zh-see, ja-see means the current page is not the lexical entry we
    should promote independently. Do not invent a reason beyond what the
    template itself states.
    """
    out: List[Dict[str, str]] = []
    for name, args in parsed_templates:
        if normalized_template_name(name) != "ja-see":
            continue
        target = args.get("1", "").strip()
        if not target:
            continue
        out.append(
            {
                "relation_template": name,
                "relation_kind": "variant",
                "relation_cause": "",
                "relation_type_code": "",
                "source_form": title,
                "target_form": target,
                "gloss": "",
                "normalizer_action": "ignore_nonlemma_form",
            }
        )
    return out


def pronunciation_evidence(
    title: str,
    parsed_templates: Sequence[Tuple[str, Dict[str, str]]],
    explicit_hanja: Sequence[str] = (),
) -> List[Dict[str, str]]:
    """Extract source-supplied orthographic/romanized readings conservatively.

    We keep zh-pron values raw instead of trying to emulate its Lua modules.
    That gives the normalizer real pronunciation evidence while preserving
    regional prefixes and multiple readings for a later dedicated parser.
    """
    target = explicit_hanja[0] if title_script_class(title) == "hangul" and len(explicit_hanja) == 1 else title
    rows: List[Dict[str, str]] = []

    def add(reading: str, language_tag: str, language_label: str, system: str, system_label: str, source_template: str, source_type_code: str = "") -> None:
        reading = reading.strip()
        if not reading:
            return
        row = {
            "target_form": target,
            "reading": reading,
            "language_tag": language_tag,
            "language_label": language_label,
            "system": system,
            "system_label": system_label,
            "source_template": source_template,
            "source_type_code": source_type_code,
        }
        if row not in rows:
            rows.append(row)

    # A Hangul headword is itself direct Korean reading evidence for a uniquely
    # identified Hanja form. This is preferable to pretending we can reproduce
    # ko-IPA's generated romanizations locally.
    if title_script_class(title) == "hangul":
        add(title, "ko", "Korean", "hangul", "Hangul", "page_title")

    saw_ja_pron = False
    for name, args in parsed_templates:
        key = normalized_template_name(name)
        if key == "zh-pron":
            for arg_key, meta in ZH_PRON_READINGS.items():
                value = args.get(arg_key, "").strip()
                if value:
                    add(value, *meta, name, arg_key)
            continue

        if key in {"ja-pron", "ja-ipa"}:
            saw_ja_pron = True
            for pos in range(1, 6):
                value = args.get(str(pos), "").strip()
                if value and is_kana_string(value):
                    add(value, "ja", "Japanese", "kana", "Kana", name, str(pos))
            continue

        # Hanja-form definition templates explicitly give the Korean Hangul
        # reading of the Han-script page.
        if key in {"hanja form of", "ko-hanja form of"}:
            value = args.get("1", "").strip()
            if value and all(is_hangul(ch) or ch.isspace() for ch in value):
                add(value, "ko", "Korean", "hangul", "Hangul", name, "1")
            continue

        # Japanese headword templates often carry the reading even when a page
        # has no separate {{ja-pron}} block.  Record only explicit kana fields;
        # do not derive a reading from the Kanji ourselves.
        if key in {
            "ja-idiom", "ja-noun", "ja-noun-suru", "ja-verb", "ja-verb-suru",
            "ja-adj", "ja-adjectival noun", "ja-adv", "ja-adverb", "ja-na",
            "ja-suru", "ja-phrase", "ja-name",
        }:
            for pos in range(1, 5):
                value = args.get(str(pos), "").strip()
                if value and is_kana_string(value):
                    add(value, "ja", "Japanese", "kana", "Kana", name, str(pos))
            continue

        # {{ja-pos|idiom|がしん しょうたん}}: parameter 1 is the POS, later
        # positional parameters are source-supplied kana forms/readings.
        if key == "ja-pos":
            for pos in range(2, 6):
                value = args.get(str(pos), "").strip()
                if value and is_kana_string(value):
                    add(value, "ja", "Japanese", "kana", "Kana", name, str(pos))
            continue

    # ja-kanjitab often contains the only source-supplied kana in older pages.
    # Use it only when ja-pron did not already provide a reading.
    if not saw_ja_pron:
        for name, args in parsed_templates:
            if normalized_template_name(name) != "ja-kanjitab":
                continue
            pieces: List[str] = []
            for pos in range(1, 9):
                value = args.get(str(pos), "").strip()
                if value and is_kana_string(value):
                    pieces.append(value)
            if pieces:
                add("".join(pieces), "ja", "Japanese", "kana", "Kana", name, "joined")
                break

    return rows


def category_titles(raw: Dict[str, Any]) -> List[str]:
    return [str(item.get("title", "")) for item in raw.get("categories", []) if item.get("title")]


def chengyu_signals(raw: Dict[str, Any], sections: Sequence[Section], templates: Sequence[Tuple[str, Dict[str, str]]]) -> Dict[str, bool]:
    categories = "\n".join(category_titles(raw) + raw.get("source_categories", []))
    headings = "\n".join(section.heading for section in sections)
    template_names = "\n".join(name for name, _args in templates)
    combined = f"{categories}\n{headings}\n{template_names}".lower()
    return {
        "chengyu": ("chengyu" in combined or "成語" in combined or "成语" in combined),
        "yojijukugo": ("yojijukugo" in combined or "四字熟語" in combined),
        "sajaseongeo": ("four-character idiom" in combined or "한자성어" in combined or "사자성어" in combined),
    }


CATEGORY_LANGUAGE_MARKERS: Tuple[Tuple[str, str, str], ...] = (
    ("Mandarin chengyu", "Mandarin", "cmn"),
    ("Cantonese chengyu", "Cantonese", "yue"),
    ("Hokkien chengyu", "Hokkien", "nan"),
    ("泉漳話成語", "Hokkien", "nan"),
    ("泉漳话成语", "Hokkien", "nan"),
    ("Hakka chengyu", "Hakka", "hak"),
    ("Wu chengyu", "Wu", "wuu"),
    ("Gan chengyu", "Gan", "gan"),
    ("Xiang chengyu", "Xiang", "hsn"),
    ("Jin chengyu", "Jin", "cjy"),
    ("Middle Chinese chengyu", "Middle Chinese", "ltc"),
    ("Old Chinese chengyu", "Old Chinese", "och"),
    ("Eastern Min chengyu", "Eastern Min", "cdo"),
    ("Northern Min chengyu", "Northern Min", "mnp"),
    ("Puxian Min chengyu", "Puxian Min", "cpx"),
    ("Dungan chengyu", "Dungan", "dng"),
    ("Southern Pinghua chengyu", "Southern Pinghua", "csp"),
    ("Chinese chengyu", "Chinese", "zh"),
    ("漢語成語", "Chinese", "zh"),
    ("Japanese yojijukugo", "Japanese", "ja"),
    ("四字熟語", "Japanese", "ja"),
    ("Korean four-character idioms", "Korean", "ko"),
    ("한국어 한자성어", "Korean", "ko"),
)

INLINE_ETYMOLOGY_RE = re.compile(
    r"^\s*[*:#;]*\s*(?:Etymology|Origin|詞源|词源|語源|语源|由来|어원)\s*[:：]\s*(.+?)\s*$",
    re.IGNORECASE | re.MULTILINE,
)


def category_language_signals(categories: Sequence[str]) -> Tuple[List[str], List[str]]:
    labels: List[str] = []
    tags: List[str] = []
    joined = "\n".join(categories)
    for marker, label, tag in CATEGORY_LANGUAGE_MARKERS:
        if marker in joined:
            labels.append(label)
            tags.append(tag)
    return stable_unique(labels), stable_unique(tags)


def provenance_categories(categories: Sequence[str]) -> List[str]:
    out = []
    for category in categories:
        lower = category.lower()
        if (
            "derived from" in lower
            or "terms derived from" in lower
            or "來自《" in category
            or "来自《" in category
        ):
            out.append(category)
    return stable_unique(out)


def inline_etymologies(wikitext: str) -> List[str]:
    out: List[str] = []
    for match in INLINE_ETYMOLOGY_RE.finditer(wikitext):
        plain = wikitext_to_plain(match.group(1))
        if plain:
            out.append(plain)
    return stable_unique(out)


PAGE_FIELDS = [
    "site",
    "pageid",
    "title",
    "url",
    "revision_id",
    "revision_timestamp",
    "revision_sha1",
    "source_keys",
    "source_categories",
    "categories",
    "title_script",
    "title_codepoints",
    "is_redirect",
    "redirect_target",
    "language_headings",
    "language_tags",
    "category_language_labels",
    "category_language_tags",
    "attestation_tags",
    "provenance_categories",
    "chengyu_signal",
    "yojijukugo_signal",
    "sajaseongeo_signal",
    "definition_count",
    "definition_evidence_count",
    "definition_relation_count",
    "definitions",
    "etymology_count",
    "etymologies",
    "pronunciation_section_count",
    "alternative_form_section_count",
    "explicit_hanja",
    "explicit_hangul",
    "has_zh_see",
    "category_meta_term",
    "han_sequences",
    "hangul_sequences",
    "template_count",
    "raw_path",
    "source_gaps",
    "warnings",
]

SECTION_FIELDS = [
    "site",
    "pageid",
    "title",
    "language_heading",
    "language_tag",
    "level",
    "raw_heading",
    "heading",
    "raw_heading_path",
    "heading_path",
    "section_kind",
    "plain_text",
    "raw_wikitext",
]

DEFINITION_FIELDS = [
    "site", "pageid", "title", "language_heading", "language_tag",
    "heading_path", "section_kind", "raw_definition", "plain_definition",
    "relation_template", "relation_type", "relation_language", "relation_target",
]

RELATION_FIELDS = [
    "site", "pageid", "title", "url", "relation_template", "relation_kind",
    "relation_cause", "relation_type_code", "source_form", "target_form", "gloss",
    "normalizer_action",
]

PRONUNCIATION_FIELDS = [
    "site", "pageid", "title", "url", "target_form", "reading", "language_tag",
    "language_label", "system", "system_label", "source_template", "source_type_code",
]

TEMPLATE_FIELDS = [
    "site",
    "pageid",
    "title",
    "language_heading",
    "language_tag",
    "heading_path",
    "section_kind",
    "template_name",
    "args_json",
    "raw_template",
]


CATEGORY_META_TERMS = {
    ("jawiktionary", "四字熟語"),
}


def template_etymologies(parsed_templates: Sequence[Tuple[str, Dict[str, str]]]) -> List[str]:
    out: List[str] = []
    for name, args in parsed_templates:
        key = normalized_template_name(name)
        if key not in {"어원", "ko-etym-sino"}:
            continue
        source = wikitext_to_plain(args.get("1", ""))
        reading = wikitext_to_plain(args.get("2", "")) if key == "어원" else ""
        if source and reading:
            out.append(f"{source} ({reading})")
        elif source:
            out.append(source)
    return stable_unique(out)


def extract_one(
    raw: Dict[str, Any],
    raw_rel_path: str,
) -> Tuple[
    Dict[str, Any],
    List[Dict[str, Any]],
    List[Dict[str, Any]],
    List[Dict[str, Any]],
    List[Dict[str, Any]],
    List[Dict[str, Any]],
]:
    site_key = str(raw.get("site", ""))
    pageid = int(raw.get("pageid", 0) or 0)
    title = str(raw.get("title", ""))
    wikitext = str(raw.get("wikitext", ""))
    sections = parse_sections(wikitext, site_key=site_key)

    parsed_templates = [parse_template(text) for text in iter_template_strings(wikitext)]
    parsed_templates = [(name, args) for name, args in parsed_templates if name]

    redirect_match = REDIRECT_RE.search(wikitext)
    redirect_target = redirect_match.group(1).strip() if redirect_match else ""

    definition_rows: List[Dict[str, Any]] = []
    definition_evidences: List[Dict[str, str]] = []
    for section in sections:
        for evidence in definition_evidence(section, site_key):
            definition_evidences.append(evidence)
            definition_rows.append(
                {
                    "site": site_key,
                    "pageid": pageid,
                    "title": title,
                    "language_heading": section.language_heading,
                    "language_tag": section.language_tag,
                    "heading_path": " > ".join(section.path),
                    "section_kind": section.kind,
                    **evidence,
                }
            )

    definitions = stable_unique(
        evidence["plain_definition"]
        for evidence in definition_evidences
        if evidence.get("plain_definition")
    )
    etymologies = stable_unique(
        list(
            wikitext_to_plain(section.body)
            for section in sections
            if section.kind == "etymology" and wikitext_to_plain(section.body)
        )
        + inline_etymologies(wikitext)
        + template_etymologies(parsed_templates)
    )

    explicit_hanja = explicit_hanja_sequences(wikitext, parsed_templates)
    zh_relations, zh_see_pronunciations = zh_see_evidence(title, parsed_templates)
    ja_relations = nonlemma_see_evidence(title, parsed_templates)
    form_relations = zh_relations + ja_relations
    has_zh_see = bool(zh_relations)
    has_nonlemma_relation = bool(form_relations)

    relation_rows = [
        {
            "site": site_key,
            "pageid": pageid,
            "title": title,
            "url": raw.get("url", ""),
            **relation,
        }
        for relation in form_relations
    ]
    all_pronunciations = pronunciation_evidence(title, parsed_templates, explicit_hanja) + zh_see_pronunciations
    pronunciation_rows = [
        {
            "site": site_key,
            "pageid": pageid,
            "title": title,
            "url": raw.get("url", ""),
            **pronunciation,
        }
        for pronunciation in all_pronunciations
    ]

    language_headings = stable_unique(section.language_heading for section in sections if section.language_heading)
    language_tags = stable_unique(section.language_tag for section in sections if section.language_tag)
    all_categories = category_titles(raw) + list(raw.get("source_categories", []))
    category_language_labels, category_language_tags = category_language_signals(all_categories)
    attestation_tags = stable_unique(language_tags + category_language_tags)
    source_provenance_categories = provenance_categories(all_categories)
    signals = chengyu_signals(raw, sections, parsed_templates)
    explicit_hangul = explicit_sequences(HANGUL_PATTERNS, CJK_LINK_RE.sub(lambda m: m.group(2) or m.group(1), wikitext))
    category_meta_term = (site_key, title) in CATEGORY_META_TERMS

    warnings: List[str] = []
    source_gaps: List[str] = []
    if not sections and wikitext.strip() and not redirect_target and not has_nonlemma_relation:
        warnings.append("no_headings")
    if (
        title_script_class(title) == "latin_or_ascii"
        and not all_pronunciations
        and not any(evidence.get("relation_type") for evidence in definition_evidences)
    ):
        warnings.append("latin_or_ascii_title_without_pronunciation_or_form_relation")
    if title_script_class(title) == "hangul" and not explicit_hanja:
        source_gaps.append("hangul_title_without_explicit_hanja")
    if not definition_evidences and not redirect_target and not has_nonlemma_relation and not category_meta_term:
        source_gaps.append("source_page_without_definition_evidence")
    # Unknown zh-see type codes are preserved as raw source evidence, but are
    # not parser warnings. zh-see already tells us this is a Chinese non-lemma
    # form; if Wiktionary does not give us a reason we understand, the correct
    # action is to ignore the duplicate form and leave relation_cause blank.

    han_sequences = stable_unique(only_han_sequences(wikitext))
    hangul_sequences = stable_unique(only_hangul_sequences(wikitext))

    revision = raw.get("revision") or {}
    page_row = {
        "site": site_key,
        "pageid": pageid,
        "title": title,
        "url": raw.get("url", ""),
        "revision_id": revision.get("revid", ""),
        "revision_timestamp": revision.get("timestamp", ""),
        "revision_sha1": revision.get("sha1", ""),
        "source_keys": raw.get("source_keys", []),
        "source_categories": raw.get("source_categories", []),
        "categories": category_titles(raw),
        "title_script": title_script_class(title),
        "title_codepoints": len(title),
        "is_redirect": bool(redirect_target),
        "redirect_target": redirect_target,
        "language_headings": language_headings,
        "language_tags": language_tags,
        "category_language_labels": category_language_labels,
        "category_language_tags": category_language_tags,
        "attestation_tags": attestation_tags,
        "provenance_categories": source_provenance_categories,
        "chengyu_signal": signals["chengyu"],
        "yojijukugo_signal": signals["yojijukugo"],
        "sajaseongeo_signal": signals["sajaseongeo"],
        "definition_count": len(definitions),
        "definition_evidence_count": len(definition_evidences),
        "definition_relation_count": sum(1 for evidence in definition_evidences if evidence.get("relation_type")),
        "definitions": definitions,
        "etymology_count": len(etymologies),
        "etymologies": etymologies,
        "pronunciation_section_count": sum(1 for section in sections if section.kind == "pronunciation"),
        "alternative_form_section_count": sum(1 for section in sections if section.kind == "alternative_forms"),
        "explicit_hanja": explicit_hanja,
        "explicit_hangul": explicit_hangul,
        "has_zh_see": has_zh_see,
        "category_meta_term": category_meta_term,
        "han_sequences": han_sequences[:100],
        "hangul_sequences": hangul_sequences[:100],
        "template_count": len(parsed_templates),
        "raw_path": raw_rel_path,
        "source_gaps": source_gaps,
        "warnings": warnings,
    }

    section_rows: List[Dict[str, Any]] = []
    template_rows: List[Dict[str, Any]] = []
    for section in sections:
        section_rows.append(
            {
                "site": site_key,
                "pageid": pageid,
                "title": title,
                "language_heading": section.language_heading,
                "language_tag": section.language_tag,
                "level": section.level,
                "raw_heading": section.raw_heading,
                "heading": section.heading,
                "raw_heading_path": " > ".join(section.raw_path),
                "heading_path": " > ".join(section.path),
                "section_kind": section.kind,
                "plain_text": wikitext_to_plain(section.body),
                "raw_wikitext": section.body,
            }
        )
        for raw_template in iter_template_strings(section.body):
            name, args = parse_template(raw_template)
            if not name:
                continue
            template_rows.append(
                {
                    "site": site_key,
                    "pageid": pageid,
                    "title": title,
                    "language_heading": section.language_heading,
                    "language_tag": section.language_tag,
                    "heading_path": " > ".join(section.path),
                    "section_kind": section.kind,
                    "template_name": name,
                    "args_json": json.dumps(args, ensure_ascii=False, sort_keys=True),
                    "raw_template": "{{" + raw_template + "}}",
                }
            )

    return page_row, section_rows, template_rows, definition_rows, relation_rows, pronunciation_rows

def extract_all(output_dir: Path) -> None:
    raw_root = output_dir / "raw"
    pages_dir = output_dir / "pages"
    sections_dir = output_dir / "sections"
    definitions_dir = output_dir / "definitions"
    relations_dir = output_dir / "relations"
    pronunciations_dir = output_dir / "pronunciations"
    templates_dir = output_dir / "templates"
    for directory in (pages_dir, sections_dir, definitions_dir, relations_dir, pronunciations_dir, templates_dir):
        ensure_dir(directory)

    for site_key in SITES:
        site_raw = raw_root / site_key
        if not site_raw.exists():
            continue
        page_rows: List[Dict[str, Any]] = []
        section_rows: List[Dict[str, Any]] = []
        template_rows: List[Dict[str, Any]] = []
        definition_rows: List[Dict[str, Any]] = []
        relation_rows: List[Dict[str, Any]] = []
        pronunciation_rows: List[Dict[str, Any]] = []
        paths = sorted(site_raw.glob("*.json"), key=lambda path: int(path.stem) if path.stem.isdigit() else path.stem)
        for index, path in enumerate(paths, start=1):
            raw = read_json(path)
            rel_path = str(path.relative_to(output_dir))
            page_row, page_sections, page_templates, page_definitions, page_relations, page_pronunciations = extract_one(raw, rel_path)
            page_rows.append(page_row)
            section_rows.extend(page_sections)
            template_rows.extend(page_templates)
            definition_rows.extend(page_definitions)
            relation_rows.extend(page_relations)
            pronunciation_rows.extend(page_pronunciations)
            if index % 1000 == 0:
                print(f"[{site_key}] extracted {index}/{len(paths)} pages")

        write_csv(pages_dir / f"{site_key}.csv", page_rows, PAGE_FIELDS)
        write_csv(sections_dir / f"{site_key}.csv", section_rows, SECTION_FIELDS)
        write_csv(definitions_dir / f"{site_key}.csv", definition_rows, DEFINITION_FIELDS)
        write_csv(relations_dir / f"{site_key}.csv", relation_rows, RELATION_FIELDS)
        write_csv(pronunciations_dir / f"{site_key}.csv", pronunciation_rows, PRONUNCIATION_FIELDS)
        write_csv(templates_dir / f"{site_key}.csv", template_rows, TEMPLATE_FIELDS)
        print(
            f"[{site_key}] extraction complete pages={len(page_rows)} sections={len(section_rows)} "
            f"definitions={len(definition_rows)} relations={len(relation_rows)} "
            f"pronunciations={len(pronunciation_rows)} templates={len(template_rows)}"
        )


# ---------------------------------------------------------------------------
# Diagnostic stage
# ---------------------------------------------------------------------------


def read_csv(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def diagnose(output_dir: Path) -> None:
    diagnostics = output_dir / "diagnostics"
    ensure_dir(diagnostics)

    source_summary: List[Dict[str, Any]] = []
    heading_counter: Counter[Tuple[str, str, str, str, str]] = Counter()
    template_counter: Counter[Tuple[str, str, str, str]] = Counter()
    warning_rows: List[Dict[str, Any]] = []
    source_gap_rows: List[Dict[str, Any]] = []
    script_rows: List[Dict[str, Any]] = []

    for site_key in SITES:
        pages = read_csv(output_dir / "pages" / f"{site_key}.csv")
        sections = read_csv(output_dir / "sections" / f"{site_key}.csv")
        definitions = read_csv(output_dir / "definitions" / f"{site_key}.csv")
        relations = read_csv(output_dir / "relations" / f"{site_key}.csv")
        pronunciations = read_csv(output_dir / "pronunciations" / f"{site_key}.csv")
        templates = read_csv(output_dir / "templates" / f"{site_key}.csv")
        if not pages and not sections and not templates:
            continue

        source_summary.append(
            {
                "site": site_key,
                "pages": len(pages),
                "redirects": sum(row.get("is_redirect") == "True" for row in pages),
                "han_titles": sum(row.get("title_script") == "han" for row in pages),
                "hangul_titles": sum(row.get("title_script") == "hangul" for row in pages),
                "latin_or_ascii_titles": sum(row.get("title_script") == "latin_or_ascii" for row in pages),
                "pages_with_definitions": sum(int(row.get("definition_count") or 0) > 0 for row in pages),
                "pages_with_definition_evidence": sum(int(row.get("definition_evidence_count") or 0) > 0 for row in pages),
                "pages_with_etymology": sum(int(row.get("etymology_count") or 0) > 0 for row in pages),
                "sections": len(sections),
                "definitions": len(definitions),
                "relations": len(relations),
                "pronunciations": len(pronunciations),
                "source_gaps": sum(1 for row in pages if (row.get("source_gaps") or "").strip()),
                "templates": len(templates),
            }
        )

        for row in pages:
            warnings = [part.strip() for part in (row.get("warnings") or "").split(" || ") if part.strip()]
            for warning in warnings:
                warning_rows.append(
                    {
                        "site": site_key,
                        "pageid": row.get("pageid", ""),
                        "title": row.get("title", ""),
                        "warning": warning,
                        "url": row.get("url", ""),
                    }
                )
            source_gaps = [part.strip() for part in (row.get("source_gaps") or "").split(" || ") if part.strip()]
            for gap in source_gaps:
                source_gap_rows.append(
                    {
                        "site": site_key,
                        "pageid": row.get("pageid", ""),
                        "title": row.get("title", ""),
                        "source_gap": gap,
                        "url": row.get("url", ""),
                    }
                )
            script_rows.append(
                {
                    "site": site_key,
                    "pageid": row.get("pageid", ""),
                    "title": row.get("title", ""),
                    "title_script": row.get("title_script", ""),
                    "explicit_hanja": row.get("explicit_hanja", ""),
                    "explicit_hangul": row.get("explicit_hangul", ""),
                    "source_categories": row.get("source_categories", ""),
                    "url": row.get("url", ""),
                }
            )

        for row in sections:
            key = (
                site_key,
                row.get("language_heading", ""),
                row.get("section_kind", ""),
                row.get("heading", ""),
                row.get("raw_heading", ""),
            )
            heading_counter[key] += 1

        for row in templates:
            key = (
                site_key,
                row.get("language_heading", ""),
                row.get("section_kind", ""),
                row.get("template_name", ""),
            )
            template_counter[key] += 1

    write_csv(
        diagnostics / "source_summary.csv",
        source_summary,
        [
            "site",
            "pages",
            "redirects",
            "han_titles",
            "hangul_titles",
            "latin_or_ascii_titles",
            "pages_with_definitions",
            "pages_with_definition_evidence",
            "pages_with_etymology",
            "sections",
            "definitions",
            "relations",
            "pronunciations",
            "source_gaps",
            "templates",
        ],
    )

    heading_rows = [
        {
            "site": site,
            "language_heading": language,
            "section_kind": kind,
            "heading": heading,
            "raw_heading": raw_heading,
            "count": count,
        }
        for (site, language, kind, heading, raw_heading), count in heading_counter.most_common()
    ]
    write_csv(
        diagnostics / "heading_frequency.csv",
        heading_rows,
        ["site", "language_heading", "section_kind", "heading", "raw_heading", "count"],
    )

    template_rows = [
        {
            "site": site,
            "language_heading": language,
            "section_kind": kind,
            "template_name": template,
            "count": count,
        }
        for (site, language, kind, template), count in template_counter.most_common()
    ]
    write_csv(
        diagnostics / "template_frequency.csv",
        template_rows,
        ["site", "language_heading", "section_kind", "template_name", "count"],
    )
    write_csv(
        diagnostics / "extraction_warnings.csv",
        warning_rows,
        ["site", "pageid", "title", "warning", "url"],
    )
    write_csv(
        diagnostics / "source_gaps.csv",
        source_gap_rows,
        ["site", "pageid", "title", "source_gap", "url"],
    )
    write_csv(
        diagnostics / "script_titles.csv",
        script_rows,
        ["site", "pageid", "title", "title_script", "explicit_hanja", "explicit_hangul", "source_categories", "url"],
    )

    print(
        f"[diagnostics] sites={len(source_summary)} warnings={len(warning_rows)} source_gaps={len(source_gap_rows)} "
        f"headings={len(heading_rows)} templates={len(template_rows)}"
    )


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def selected_sources(keys: Sequence[str]) -> List[SourceSeed]:
    if not keys:
        return list(SOURCE_SEEDS)
    out: List[SourceSeed] = []
    for key in keys:
        if key not in SOURCE_BY_KEY:
            raise SystemExit(
                f"Unknown source {key!r}. Available: {', '.join(sorted(SOURCE_BY_KEY))}"
            )
        out.append(SOURCE_BY_KEY[key])
    return out


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Stage Wiktionary Chengyu/yojijukugo/sajaseong-eo data into audit CSVs.")
    p.add_argument("output", type=Path, help="Staging output directory")
    p.add_argument(
        "--stage",
        choices=("all", "harvest", "extract", "diagnose"),
        default="all",
        help="Run the full pipeline or one cached stage (default: all)",
    )
    p.add_argument(
        "--source",
        action="append",
        default=[],
        help="Only use this configured source key; may be repeated",
    )
    p.add_argument("--test", action="store_true", help="Pilot mode; defaults to 25 unique pages per source")
    p.add_argument(
        "--limit-per-source",
        type=int,
        default=None,
        help="Maximum unique main-namespace pages retained from each seed (diagnostic/pilot runs)",
    )
    p.add_argument("--refresh", action="store_true", help="Re-download raw pages even when cached")
    p.add_argument("--sleep", type=float, default=0.40, help="Minimum polite delay between API requests (default: 0.40s)")
    p.add_argument("--timeout", type=int, default=45, help="HTTP timeout seconds (default: 45)")
    p.add_argument("--max-retries", type=int, default=6, help="HTTP/API retry attempts (default: 6)")
    p.add_argument("--maxlag", type=int, default=5, help="Wikimedia Action API maxlag seconds (default: 5)")
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parser().parse_args(argv)
    output_dir: Path = args.output.expanduser().resolve()
    ensure_dir(output_dir)

    sources = selected_sources(args.source)
    limit_per_source = args.limit_per_source
    if args.test and limit_per_source is None:
        limit_per_source = 25
    if limit_per_source is not None and limit_per_source <= 0:
        raise SystemExit("--limit-per-source must be positive")

    run_manifest = {
        "scraper": "wiktionary_chengyu_scraper.py",
        "version": VERSION,
        "generated_at_utc": now_utc(),
        "user_agent": USER_AGENT,
        "stage": args.stage,
        "test": bool(args.test),
        "limit_per_source": limit_per_source,
        "sampling": "deterministic_spread" if limit_per_source is not None else "all_pages",
        "sources": [
            {
                "key": source.key,
                "site": source.site_key,
                "category": source.category,
                "label": source.label,
                "recurse_depth": source.recurse_depth,
            }
            for source in sources
        ],
        "context_urls": CONTEXT_URLS,
        "design_note": (
            "Raw source evidence is preserved. This staging run does not perform final Chengyu family deduplication "
            "or write Rails application data."
        ),
    }
    write_json(output_dir / "run_manifest.json", run_manifest)

    if args.stage in {"all", "harvest"}:
        inventory: Dict[Tuple[str, int], PageInventory] = {}
        memberships: List[Dict[str, Any]] = []
        clients: Dict[str, WikimediaClient] = {}

        for source in sources:
            site_key = source.site_key
            if site_key not in clients:
                clients[site_key] = WikimediaClient(
                    SITES[site_key],
                    sleep_seconds=args.sleep,
                    timeout=args.timeout,
                    max_retries=args.max_retries,
                    maxlag=args.maxlag,
                )
            harvest_source(
                clients[site_key],
                source,
                output_dir=output_dir,
                inventory=inventory,
                all_memberships=memberships,
                limit_per_source=limit_per_source,
            )

        write_csv(output_dir / "category_memberships.csv", memberships, CATEGORY_FIELDS)
        write_inventory(output_dir, inventory)
        harvest_pages(clients, inventory, output_dir=output_dir, refresh=bool(args.refresh))
        print(
            f"[harvest] unique_pages={len(inventory)} category_memberships={len(memberships)} "
            f"requests={sum(client.request_count for client in clients.values())}"
        )

    if args.stage in {"all", "extract"}:
        extract_all(output_dir)

    if args.stage in {"all", "diagnose"}:
        diagnose(output_dir)

    print(f"[done] staging={output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
