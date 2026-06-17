#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
song_author_propagation_v2.py

Second-pass helper for a 宋朝 folder.

Purpose:
  Move works from 不詳 into existing target folders, mainly 北宋 / 南宋,
  by using author evidence.

This version fixes the main limits in the first author-propagation script:

  1. It can extract author names from parenthesised titles/folder names:
       對酒歌（宋 陳襄）
       不寐 (范成大)

  2. It canonicalises Wikisource "page does not exist" author candidates:
       陳言
       陳言（页面不存在）
     These become one candidate instead of causing a false multiple-author review.

  3. It can import a previous regionaliser author_lookup_audit.csv and use
     its derived_target rows as hints.

Safety rules:
  - Dry-run by default.
  - No movement unless --apply.
  - No invented folders.
  - No filename changes.
  - No metadata-field additions.
  - --fill-author only fills an existing blank # AUTHOR: line.
  - Lookup/provenance goes into _audit_author_propagation_v2 only.
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
from urllib.parse import quote, unquote, urlparse

try:
    import requests
except ImportError:
    requests = None  # type: ignore


SCRIPT_VERSION = "song-author-propagation-v2-2026-06-17"

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"

DEFAULT_USER_AGENT = (
    "FanyaHanwenCorpusAuthorPropagation/2.0 "
    "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
    "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
)

UNKNOWN_FOLDER_DEFAULTS = {"不詳", "未知", "未詳"}
AUDIT_DIR_NAME = "_audit_author_propagation_v2"

HEADER_LINE_RE = re.compile(r"^#\s*([A-Z0-9_]+)\s*:\s*(.*)\s*$")

PAGE_AUTHOR_TEMPLATE_RE = re.compile(
    r"\|\s*(?:author|作者|著者|撰者|translator|譯者|译者|override_author)\s*=\s*([^|\n\r}]{1,100})",
    re.IGNORECASE,
)

AUTHOR_LINK_RE = re.compile(r"\[\[(?:Author|作者):([^|\]#]+)(?:\|[^\]]*)?\]\]")

PAREN_RE = re.compile(r"[（(]([^（）()]{1,30})[）)]")

BAD_AUTHOR_VALUES = {
    "",
    "佚名",
    "不詳",
    "未知",
    "无名氏",
    "無名氏",
    "多人",
    "群体",
    "群體",
    "various",
    "anonymous",
    "unknown",
    "佛經",
    "宋詞",
    "詩",
    "詞",
    "七言絕句",
    "五言絕句",
    "七言律詩",
    "五言律詩",
    "樂府雅詞",
}

BAD_AUTHOR_SUBSTRINGS = (
    "页面不存在",
    "頁面不存在",
    "page does not exist",
    "維基文庫",
    "维基文库",
    "Category:",
    "分類:",
    "分类:",
)

AUTHOR_CATEGORY_HINT_WORDS = (
    "作者", "作家", "詩人", "词人", "詞人", "文學家", "文学家",
    "人", "人物", "官員", "官员", "政治人物", "書法家", "画家", "畫家",
    "皇帝", "君主", "臣", "將領", "将领", "學者", "学者", "儒學", "儒学",
)

PERIOD_PREFIXES = (
    "宋", "宋代", "北宋", "南宋", "金", "金朝", "遼", "辽", "遼朝", "辽朝", "西夏",
    "唐", "五代", "元", "明", "清", "漢", "汉", "魏", "晉", "晋",
)

SIMPLIFIED_NORMALISATIONS = {
    "陈": "陳",
    "杨": "楊",
    "刘": "劉",
    "赵": "趙",
    "吴": "吳",
    "张": "張",
    "欧阳": "歐陽",
    "苏": "蘇",
    "陆": "陸",
    "范": "范",
    "勋": "勳",
}


def is_windows() -> bool:
    return os.name == "nt"


def long_path(path: Path | str) -> str:
    s = os.path.abspath(os.fspath(path))
    if not is_windows():
        return s
    if s.startswith("\\\\?\\"):
        return s
    if s.startswith("\\\\"):
        return "\\\\?\\UNC\\" + s.lstrip("\\")
    return "\\\\?\\" + s


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def write_csv(path: Path, rows: List[dict]) -> None:
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

    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fields})


def title_from_url_or_title(raw: str) -> str:
    s = (raw or "").strip()
    if not s:
        return ""
    if s.startswith("http://") or s.startswith("https://"):
        parsed = urlparse(s)
        parts = [p for p in parsed.path.split("/") if p]
        if parts and parts[0] == "wiki":
            return unquote("/".join(parts[1:]))
        if parts:
            return unquote(parts[-1])
    return s


def canonical_author(raw: str) -> str:
    s = (raw or "").strip()
    s = unquote(s)
    s = re.sub(r"<[^>]+>", "", s)
    s = re.sub(r"\{\{[^{}]{0,120}\}\}", "", s)
    s = s.replace("[[", "").replace("]]", "")
    s = s.replace("Author:", "").replace("作者:", "")

    if "|" in s:
        s = s.split("|", 1)[0]

    # Remove Wikisource redlink markers and similar trailing junk.
    s = re.sub(r"[（(]\s*(?:页面不存在|頁面不存在|page does not exist).*?[）)]", "", s, flags=re.I)
    s = re.sub(r"\s*(?:页面不存在|頁面不存在|page does not exist).*$", "", s, flags=re.I)

    # Remove period prefixes often used in titles: （宋 陳襄）, （宋陳襄）.
    s = re.sub(r"\s+", "", s)
    for prefix in PERIOD_PREFIXES:
        if s.startswith(prefix) and len(s) > len(prefix) + 1:
            s = s[len(prefix):]
            break

    # Remove after obvious separators.
    s = re.split(r"[，,；;、/／]", s, maxsplit=1)[0]
    s = s.strip("：:[]（）()《》「」『』· ")

    for simp, trad in SIMPLIFIED_NORMALISATIONS.items():
        s = s.replace(simp, trad)

    if any(bad.lower() in s.lower() for bad in BAD_AUTHOR_SUBSTRINGS):
        return ""

    if s.lower() in BAD_AUTHOR_VALUES:
        return ""

    if not s:
        return ""

    # Reject obvious titles/prose, but keep 2-4 char names and some 5-char monk names.
    if len(s) > 8:
        return ""

    if re.search(r"[。！？!?：:\n\r\t]", s):
        return ""

    return s


def extract_parenthetical_authors(text: str) -> List[str]:
    out: List[str] = []
    for m in PAREN_RE.finditer(text or ""):
        cand = canonical_author(m.group(1))
        if cand:
            out.append(cand)
    return list(dict.fromkeys(out))


def parse_header_and_body(text: str) -> Tuple[Dict[str, str], str]:
    lines = text.splitlines()
    meta: Dict[str, str] = {}
    body_start = 0

    for i, line in enumerate(lines):
        if line.strip() == "":
            body_start = i + 1
            break
        m = HEADER_LINE_RE.match(line)
        if not m:
            body_start = i
            break
        meta[m.group(1)] = m.group(2)
    else:
        body_start = len(lines)

    return meta, "\n".join(lines[body_start:])


def rebuild_with_author_if_possible(original_text: str, author: str) -> Tuple[str, bool, str]:
    lines = original_text.splitlines()
    for i, line in enumerate(lines):
        m = HEADER_LINE_RE.match(line)
        if not m:
            if line.strip() == "":
                break
            break
        key, value = m.group(1), m.group(2)
        if key == "AUTHOR":
            if not value.strip() and author:
                lines[i] = f"# AUTHOR: {author}"
                return "\n".join(lines) + ("\n" if original_text.endswith("\n") else ""), True, "filled_existing_blank_AUTHOR"
            return original_text, False, "AUTHOR_not_blank"
    return original_text, False, "no_AUTHOR_field"


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
    ws_categories: str

    def title_strings(self) -> List[str]:
        vals = [
            self.work_rel,
            self.file_name,
            self.work_title,
            self.display_title,
            self.page_title,
            title_from_url_or_title(self.source_url),
        ]
        return [v for v in vals if v]


@dataclass
class WorkGroup:
    top_folder: str
    work_rel: str
    files: List[FileRec] = field(default_factory=list)

    @property
    def key(self) -> str:
        return f"{self.top_folder}/{self.work_rel}"

    def all_title_strings(self) -> List[str]:
        vals: List[str] = []
        for rec in self.files:
            vals.extend(rec.title_strings())
        return list(dict.fromkeys(v for v in vals if v))

    def authors_from_headers(self) -> Set[str]:
        return {rec.author_header for rec in self.files if rec.author_header}

    def candidate_authors(self, parse_title_authors: bool) -> Dict[str, Set[str]]:
        out: Dict[str, Set[str]] = defaultdict(set)

        for rec in self.files:
            if rec.author_header:
                out[rec.author_header].add("metadata_AUTHOR")

        if parse_title_authors:
            for text in self.all_title_strings():
                for cand in extract_parenthetical_authors(text):
                    out[cand].add("title_parentheses")

        return out


class WikiClient:
    def __init__(self, sleep: float, user_agent: str):
        if requests is None:
            raise SystemExit("Missing dependency: requests. Install with: pip install requests")
        self.sleep = sleep
        self.session = requests.Session()
        self.headers = {"User-Agent": user_agent}
        self.page_parse_cache: Dict[str, Dict[str, Any]] = {}
        self.page_exists_cache: Dict[str, bool] = {}
        self.page_category_cache: Dict[str, List[str]] = {}
        self.author_info_cache: Dict[str, Dict[str, Any]] = {}

    def api_get(self, params: Dict[str, Any], retries: int = 5) -> Dict[str, Any]:
        params = dict(params)
        params.setdefault("format", "json")
        params.setdefault("formatversion", "2")

        for attempt in range(1, retries + 1):
            time.sleep(self.sleep)
            r = self.session.get(API_ENDPOINT, params=params, headers=self.headers, timeout=45)

            if r.status_code == 429:
                retry_after = r.headers.get("Retry-After")
                wait = float(retry_after) if retry_after and retry_after.isdigit() else min(90.0, 10.0 * attempt)
                print(f"[warn] API rate-limited; sleeping {wait:.1f}s")
                time.sleep(wait)
                continue

            try:
                r.raise_for_status()
                data = r.json()
            except Exception as exc:
                if attempt == retries:
                    print(f"[warn] API failed: {exc}", file=sys.stderr)
                    return {}
                time.sleep(min(10.0, 2.0 * attempt))
                continue

            if "error" in data:
                code = (data.get("error") or {}).get("code", "")
                if code in {"missingtitle", "invalidtitle", "nosuchpageid"}:
                    return {}
                if attempt == retries:
                    print(f"[warn] API error: {data.get('error')}", file=sys.stderr)
                    return {}
                time.sleep(min(10.0, 2.0 * attempt))
                continue

            return data

        return {}

    def page_exists(self, title: str) -> bool:
        title = title.strip()
        if not title:
            return False
        if title in self.page_exists_cache:
            return self.page_exists_cache[title]
        data = self.api_get({"action": "query", "titles": title, "redirects": "1"})
        pages = (data.get("query") or {}).get("pages") or []
        ok = bool(pages and "missing" not in pages[0])
        self.page_exists_cache[title] = ok
        return ok

    def parse_page(self, title: str) -> Dict[str, Any]:
        title = title.strip()
        if not title:
            return {}
        if title in self.page_parse_cache:
            return self.page_parse_cache[title]

        data = self.api_get({
            "action": "parse",
            "page": title,
            "prop": "wikitext|links|text",
            "disablelimitreport": "1",
            "disableeditsection": "1",
            "disabletoc": "1",
        })
        parse = data.get("parse") or {}
        self.page_parse_cache[title] = parse if isinstance(parse, dict) else {}
        return self.page_parse_cache[title]

    def categories(self, title: str) -> List[str]:
        title = title.strip()
        if not title:
            return []
        if title in self.page_category_cache:
            return self.page_category_cache[title]

        out: List[str] = []
        cont: Dict[str, Any] = {}
        while True:
            params: Dict[str, Any] = {
                "action": "query",
                "prop": "categories",
                "titles": title,
                "cllimit": "max",
                "clshow": "!hidden",
            }
            params.update(cont)
            data = self.api_get(params)
            pages = (data.get("query") or {}).get("pages") or []
            for page in pages:
                if "missing" in page:
                    continue
                for cat in page.get("categories") or []:
                    name = cat.get("title", "")
                    if name.startswith("Category:"):
                        name = name.split(":", 1)[1]
                    if name:
                        out.append(name)
            nxt = data.get("continue") or {}
            if not nxt:
                break
            cont = nxt

        out = list(dict.fromkeys(out))
        self.page_category_cache[title] = out
        return out

    def extract_authors_from_work_page(self, title: str) -> Tuple[Dict[str, Set[str]], str]:
        parse = self.parse_page(title)
        if not parse:
            return {}, "missing_or_unparsed"

        out: Dict[str, Set[str]] = defaultdict(set)

        wt_node = parse.get("wikitext")
        wikitext = str(wt_node.get("*") if isinstance(wt_node, dict) else (wt_node or ""))

        for m in PAGE_AUTHOR_TEMPLATE_RE.finditer(wikitext):
            a = canonical_author(m.group(1))
            if a:
                out[a].add("work_page_template_author")

        for m in AUTHOR_LINK_RE.finditer(wikitext):
            a = canonical_author(m.group(1))
            if a:
                out[a].add("work_page_author_link")

        for link in parse.get("links") or []:
            if not isinstance(link, dict):
                continue
            target = str(link.get("title") or link.get("*") or "")
            if target.startswith(("Author:", "作者:")):
                a = canonical_author(target.split(":", 1)[1])
                if a:
                    out[a].add("work_page_parse_link")

        text_node = parse.get("text")
        html = str(text_node.get("*") if isinstance(text_node, dict) else (text_node or ""))
        for m in re.finditer(r'title="(?:Author|作者):([^"]+)"', html):
            a = canonical_author(m.group(1))
            if a:
                out[a].add("work_page_html_author_link")

        if len(out) == 1:
            return out, "unique_work_page_author"
        if len(out) > 1:
            return out, "multiple_work_page_authors"
        return {}, "no_author_found"

    def author_info(self, author: str) -> Dict[str, Any]:
        author = canonical_author(author)
        if not author:
            return {"status": "bad_author", "author": author, "author_page": "", "categories": [], "description": ""}

        if author in self.author_info_cache:
            return self.author_info_cache[author]

        author_page = ""
        for title in (f"Author:{author}", f"作者:{author}"):
            if self.page_exists(title):
                author_page = title
                break

        if not author_page:
            info = {"status": "missing_author_page", "author": author, "author_page": "", "categories": [], "description": ""}
            self.author_info_cache[author] = info
            return info

        cats = self.categories(author_page)
        parse = self.parse_page(author_page)
        text_node = parse.get("text") if parse else ""
        html = str(text_node.get("*") if isinstance(text_node, dict) else (text_node or ""))

        desc = ""
        if html:
            desc = re.sub(r"<script.*?</script>", "", html, flags=re.DOTALL | re.IGNORECASE)
            desc = re.sub(r"<style.*?</style>", "", desc, flags=re.DOTALL | re.IGNORECASE)
            desc = re.sub(r"<[^>]+>", "", desc)
            desc = re.sub(r"\s+", "", desc)[:700]

        info = {
            "status": "found",
            "author": author,
            "author_page": author_page,
            "categories": cats,
            "description": desc,
        }
        self.author_info_cache[author] = info
        return info


def infer_target_from_terms(
    terms: Iterable[str],
    target_folders: Set[str],
    root_folder_name: str,
) -> Tuple[str, str, str]:
    hits: Dict[str, List[str]] = defaultdict(list)

    for term in terms:
        t = (term or "").strip()
        if not t:
            continue

        for target in target_folders:
            if target == root_folder_name:
                continue

            if target and target in t:
                if t in {target, root_folder_name}:
                    continue

                if any(hint in t for hint in AUTHOR_CATEGORY_HINT_WORDS) or t.startswith(target):
                    hits[target].append(t)

    if len(hits) == 1:
        target = next(iter(hits))
        return target, "author_page_terms", "；".join(hits[target])

    if len(hits) > 1:
        packed = " | ".join(f"{k}:{'；'.join(v)}" for k, v in sorted(hits.items()))
        return "", "ambiguous_author_page_terms", packed

    return "", "no_target_terms", ""


def scan_files(root: Path, audit_dir_name: str) -> List[FileRec]:
    records: List[FileRec] = []

    for path in root.rglob("*.txt"):
        try:
            rel_path = path.relative_to(root)
        except ValueError:
            continue

        parts = rel_path.parts
        if not parts:
            continue

        if parts[0].startswith("_audit") or parts[0] == audit_dir_name:
            continue

        if len(parts) < 3:
            continue

        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = path.read_text(encoding="utf-8", errors="replace")

        meta, _body = parse_header_and_body(text)
        author = canonical_author(meta.get("AUTHOR", ""))

        records.append(FileRec(
            path=path,
            rel="/".join(parts),
            top_folder=parts[0],
            work_rel="/".join(parts[1:-1]),
            file_name=parts[-1],
            meta=meta,
            author_header=author,
            work_title=meta.get("WORK_TITLE", ""),
            display_title=meta.get("DISPLAY_TITLE", ""),
            page_title=meta.get("PAGE_TITLE", ""),
            source_url=meta.get("SOURCE_URL", ""),
            ws_categories=meta.get("WS_CATEGORIES", ""),
        ))

    return records


def group_records(records: List[FileRec]) -> Dict[Tuple[str, str], WorkGroup]:
    groups: Dict[Tuple[str, str], WorkGroup] = {}
    for rec in records:
        key = (rec.top_folder, rec.work_rel)
        if key not in groups:
            groups[key] = WorkGroup(top_folder=rec.top_folder, work_rel=rec.work_rel)
        groups[key].files.append(rec)
    return groups


def clean_group_key(raw: str, root_name: str, unknown_folders: Set[str]) -> str:
    s = (raw or "").strip().replace("\\", "/")
    while s.startswith("./"):
        s = s[2:]
    prefix = root_name + "/"
    if s.startswith(prefix):
        s = s[len(prefix):]
    return s


def import_author_lookup_audit(
    path: Path,
    root_name: str,
    target_folders: Set[str],
    unknown_folders: Set[str],
) -> Tuple[Dict[str, str], Dict[str, Set[str]], List[dict]]:
    """
    Import previous regionaliser author_lookup_audit.csv.

    Returns:
      group_target_map: "不詳/work" -> target
      author_targets: author -> set(target)
      rows
    """
    group_target_map: Dict[str, str] = {}
    author_targets: Dict[str, Set[str]] = defaultdict(set)
    rows: List[dict] = []

    if not path or not path.exists():
        return group_target_map, author_targets, rows

    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            target = (row.get("derived_target") or row.get("inferred_target") or "").strip()
            if target not in target_folders:
                continue

            raw_group = row.get("group") or row.get("work_key") or ""
            group = clean_group_key(raw_group, root_name, unknown_folders)
            if not any(group.startswith(u + "/") for u in unknown_folders):
                continue

            author = canonical_author(row.get("author", ""))

            group_target_map[group] = target

            if author:
                author_targets[author].add(target)

            rows.append({
                "source_file": str(path),
                "group": group,
                "author": author,
                "target": target,
                "source_column": "derived_target/inferred_target",
                "raw_group": raw_group,
            })

    return group_target_map, author_targets, rows


def build_seed_author_targets(
    groups: Dict[Tuple[str, str], WorkGroup],
    unknown_folders: Set[str],
    parse_title_authors: bool,
) -> Tuple[Dict[str, Set[str]], List[dict]]:
    author_targets: Dict[str, Set[str]] = defaultdict(set)
    rows: List[dict] = []

    for group in groups.values():
        if group.top_folder in unknown_folders:
            continue

        candidates = group.candidate_authors(parse_title_authors)
        for author, sources in candidates.items():
            author_targets[author].add(group.top_folder)
            rows.append({
                "author": author,
                "known_target": group.top_folder,
                "known_work": group.work_rel,
                "candidate_sources": "，".join(sorted(sources)),
            })

    return author_targets, rows


def collapse_author_targets(author_targets: Dict[str, Set[str]]) -> Tuple[Dict[str, str], List[dict]]:
    resolved: Dict[str, str] = {}
    ambiguous: List[dict] = []

    for author, targets in sorted(author_targets.items()):
        if len(targets) == 1:
            resolved[author] = next(iter(targets))
        elif len(targets) > 1:
            ambiguous.append({
                "author": author,
                "targets": "，".join(sorted(targets)),
                "reason": "author_maps_to_multiple_targets",
            })

    return resolved, ambiguous


def title_for_lookup(rec: FileRec) -> str:
    return rec.page_title or title_from_url_or_title(rec.source_url) or rec.work_title or rec.work_rel


def fill_author_in_dir(directory: Path, author: str) -> None:
    for txt in directory.rglob("*.txt"):
        try:
            original = txt.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            original = txt.read_text(encoding="utf-8", errors="replace")
        new_text, changed, _reason = rebuild_with_author_if_possible(original, author)
        if changed:
            txt.write_text(new_text, encoding="utf-8", newline="\n")


def move_group(
    root: Path,
    group: WorkGroup,
    target: str,
    apply: bool,
    merge_existing: bool,
    fill_author: bool,
    author_to_fill: str,
) -> Tuple[str, str]:
    source_dir = root / group.top_folder / Path(group.work_rel)
    target_dir = root / target / Path(group.work_rel)

    if not source_dir.exists():
        return "skipped", "source_dir_missing"

    if target_dir.exists() and not merge_existing:
        return "review", "target_work_folder_exists"

    if not apply:
        if target_dir.exists() and merge_existing:
            return "would_merge", "dry_run"
        return "would_move", "dry_run"

    if not target_dir.exists():
        target_dir.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(long_path(source_dir), long_path(target_dir))
        if fill_author and author_to_fill:
            fill_author_in_dir(target_dir, author_to_fill)
        return "moved", ""

    collisions: List[str] = []
    moved_any = False

    for src_path in sorted(source_dir.rglob("*")):
        if src_path.is_dir():
            continue
        rel = src_path.relative_to(source_dir)
        dst = target_dir / rel
        if dst.exists():
            collisions.append(str(rel).replace("\\", "/"))
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(long_path(src_path), long_path(dst))
        moved_any = True

    if fill_author and author_to_fill:
        fill_author_in_dir(target_dir, author_to_fill)

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
        description="Second-pass 宋朝 author propagation from 不詳 to existing target folders."
    )
    parser.add_argument("root", nargs="?", default=".", help="宋朝 folder. Default: current folder.")
    parser.add_argument("--unknown-folder", action="append", default=[], help="Unknown folder name. Default includes 不詳.")
    parser.add_argument("--apply", action="store_true", help="Actually move folders. Default is dry-run.")
    parser.add_argument("--merge-existing", action="store_true", help="Merge into existing target work folder if file paths do not collide.")
    parser.add_argument("--fill-author", action="store_true", help="Fill existing blank # AUTHOR: lines when a single author is known.")
    parser.add_argument("--parse-title-authors", action="store_true", default=True, help="Extract author from title/folder parentheses. Default: on.")
    parser.add_argument("--no-parse-title-authors", action="store_false", dest="parse_title_authors", help="Disable parenthetical title-author extraction.")
    parser.add_argument("--fetch-missing-authors", action="store_true", help="Fetch Wikisource work pages to find missing authors.")
    parser.add_argument("--author-page-lookup", action="store_true", help="Fetch Author pages to infer target folder from categories/descriptions.")
    parser.add_argument("--import-author-lookup-audit", help="Path to prior author_lookup_audit.csv with derived_target/inferred_target columns.")
    parser.add_argument("--sleep", type=float, default=1.5, help="Seconds between Wikisource API calls.")
    parser.add_argument("--user-agent", default=os.environ.get("FANYA_WIKISOURCE_USER_AGENT", DEFAULT_USER_AGENT))
    parser.add_argument("--audit-dir", default=AUDIT_DIR_NAME)
    parser.add_argument("--progress-every", type=int, default=100)
    parser.add_argument("--version", action="version", version=SCRIPT_VERSION)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)

    root = Path(args.root).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        print(f"[error] Root is not a folder: {root}", file=sys.stderr)
        return 2

    root_name = root.name
    unknown_folders = set(UNKNOWN_FOLDER_DEFAULTS)
    unknown_folders.update(args.unknown_folder)

    audit_dir = root / args.audit_dir
    audit_dir.mkdir(parents=True, exist_ok=True)

    direct_folders = {
        p.name for p in root.iterdir()
        if p.is_dir() and not p.name.startswith("_audit") and p.name not in unknown_folders
    }
    target_folders = set(direct_folders)

    print(f"[version] {SCRIPT_VERSION}")
    print(f"[root] {root}")
    print(f"[mode] {'APPLY' if args.apply else 'DRY RUN'}")
    print(f"[targets] {', '.join(sorted(target_folders))}")
    print(f"[unknown folders] {', '.join(sorted(unknown_folders))}")
    print(f"[options] parse_title_authors={args.parse_title_authors} fetch_missing_authors={args.fetch_missing_authors} author_page_lookup={args.author_page_lookup}")
    print(f"[policy] merge_existing={args.merge_existing} fill_author={args.fill_author}")
    print()

    records = scan_files(root, args.audit_dir)
    groups = group_records(records)
    unknown_groups = [g for g in groups.values() if g.top_folder in unknown_folders]

    print(f"[scan] files={len(records):,} work_groups={len(groups):,} unknown_groups={len(unknown_groups):,}")

    seed_author_targets, seed_rows = build_seed_author_targets(
        groups=groups,
        unknown_folders=unknown_folders,
        parse_title_authors=args.parse_title_authors,
    )

    imported_group_targets: Dict[str, str] = {}
    imported_author_targets: Dict[str, Set[str]] = defaultdict(set)
    imported_rows: List[dict] = []

    if args.import_author_lookup_audit:
        audit_path = Path(args.import_author_lookup_audit).expanduser().resolve()
        imported_group_targets, imported_author_targets, imported_rows = import_author_lookup_audit(
            path=audit_path,
            root_name=root_name,
            target_folders=target_folders,
            unknown_folders=unknown_folders,
        )
        for author, targets in imported_author_targets.items():
            seed_author_targets[author].update(targets)

    author_target_map, ambiguous_author_rows = collapse_author_targets(seed_author_targets)

    print(f"[seed] unambiguous_author_targets={len(author_target_map):,} ambiguous_author_targets={len(ambiguous_author_rows):,}")
    print(f"[import] group_targets={len(imported_group_targets):,} imported_rows={len(imported_rows):,}")

    client: Optional[WikiClient] = None
    if args.fetch_missing_authors or args.author_page_lookup:
        client = WikiClient(sleep=args.sleep, user_agent=args.user_agent)

    fetched_author_rows: List[dict] = []
    candidate_rows: List[dict] = []
    author_lookup_rows: List[dict] = []
    move_rows: List[dict] = []
    unresolved_rows: List[dict] = []

    fetched_by_group: Dict[str, Dict[str, Set[str]]] = {}

    if args.fetch_missing_authors and client is not None:
        print("[pass 1] fetching missing authors")
        for idx, group in enumerate(unknown_groups, start=1):
            if args.progress_every and idx % args.progress_every == 0:
                print(f"[fetch] {idx}/{len(unknown_groups)}")

            existing = group.candidate_authors(args.parse_title_authors)
            if existing:
                continue

            titles = list(dict.fromkeys(title_for_lookup(rec) for rec in group.files if title_for_lookup(rec)))
            merged: Dict[str, Set[str]] = defaultdict(set)
            statuses: List[str] = []

            for title in titles[:3]:
                found, status = client.extract_authors_from_work_page(title)
                statuses.append(f"{title}:{status}")
                for author, sources in found.items():
                    merged[author].update(sources)

            if merged:
                fetched_by_group[group.key] = merged
                fetched_author_rows.append({
                    "work_key": group.key,
                    "authors": "，".join(sorted(merged)),
                    "sources": " | ".join(f"{a}:{'，'.join(sorted(s))}" for a, s in sorted(merged.items())),
                    "statuses": " | ".join(statuses),
                })

    author_page_target_cache: Dict[str, Tuple[str, str, str]] = {}

    def target_for_author(author: str) -> Tuple[str, str, str]:
        if author in author_target_map:
            return author_target_map[author], "seed_or_imported_author_target", f"{author}->{author_target_map[author]}"

        if not args.author_page_lookup or client is None:
            return "", "no_author_target", ""

        if author in author_page_target_cache:
            return author_page_target_cache[author]

        info = client.author_info(author)
        cats = info.get("categories") or []
        desc = info.get("description") or ""
        target, source, detail = infer_target_from_terms(
            list(cats) + ([desc] if desc else []),
            target_folders,
            root_name,
        )

        author_lookup_rows.append({
            "author": author,
            "status": info.get("status", ""),
            "author_page": info.get("author_page", ""),
            "categories": "，".join(cats),
            "description_head": desc[:200],
            "target": target,
            "source": source,
            "detail": detail,
        })

        author_page_target_cache[author] = (target, source, detail)
        return author_page_target_cache[author]

    print("[pass 2] planning moves")
    for idx, group in enumerate(unknown_groups, start=1):
        if args.progress_every and idx % args.progress_every == 0:
            print(f"[plan] {idx}/{len(unknown_groups)}")

        candidates = group.candidate_authors(args.parse_title_authors)

        if group.key in fetched_by_group:
            for author, sources in fetched_by_group[group.key].items():
                candidates[author].update(sources)

        for author, sources in sorted(candidates.items()):
            candidate_rows.append({
                "work_key": group.key,
                "author": author,
                "sources": "，".join(sorted(sources)),
            })

        imported_target = imported_group_targets.get(group.key)
        author_for_fill = ""

        if imported_target:
            # If there is a single clean author candidate, use it for optional fill-author.
            if len(candidates) == 1:
                author_for_fill = next(iter(candidates))
            status, note = move_group(root, group, imported_target, args.apply, args.merge_existing, args.fill_author, author_for_fill)
            move_rows.append({
                "status": status,
                "note": note,
                "source_folder": group.top_folder,
                "target_folder": imported_target,
                "work_rel": group.work_rel,
                "source_path": group.key,
                "target_path": f"{imported_target}/{group.work_rel}",
                "author": author_for_fill,
                "evidence_source": "imported_group_target",
                "evidence_detail": "imported from author_lookup_audit derived_target/inferred_target",
                "file_count": len(group.files),
            })
            if status in {"review", "merged_with_collisions"}:
                unresolved_rows.append({
                    "priority": "high",
                    "reason": status,
                    "work_key": group.key,
                    "target": imported_target,
                    "note": note,
                })
            continue

        if not candidates:
            unresolved_rows.append({
                "priority": "low",
                "reason": "no_author_candidate",
                "work_key": group.key,
                "titles": " | ".join(group.all_title_strings()[:5]),
            })
            continue

        author_targets: Dict[str, Tuple[str, str, str]] = {}
        for author in sorted(candidates):
            target, source, detail = target_for_author(author)
            if target:
                author_targets[author] = (target, source, detail)

        if not author_targets:
            unresolved_rows.append({
                "priority": "low",
                "reason": "author_has_no_target",
                "work_key": group.key,
                "authors": "，".join(sorted(candidates)),
                "candidate_sources": " | ".join(f"{a}:{'，'.join(sorted(s))}" for a, s in sorted(candidates.items())),
            })
            continue

        target_set = {t[0] for t in author_targets.values()}
        if len(target_set) != 1:
            unresolved_rows.append({
                "priority": "medium",
                "reason": "authors_map_to_multiple_targets",
                "work_key": group.key,
                "authors": "，".join(sorted(candidates)),
                "targets": " | ".join(f"{a}->{v[0]}" for a, v in sorted(author_targets.items())),
            })
            continue

        target = next(iter(target_set))
        # Use fill-author only if one candidate maps successfully.
        if len(author_targets) == 1:
            author_for_fill = next(iter(author_targets.keys()))

        evidence_source = "author_target"
        evidence_detail = " | ".join(f"{a}:{src}:{detail}" for a, (_target, src, detail) in sorted(author_targets.items()))

        status, note = move_group(root, group, target, args.apply, args.merge_existing, args.fill_author, author_for_fill)

        move_rows.append({
            "status": status,
            "note": note,
            "source_folder": group.top_folder,
            "target_folder": target,
            "work_rel": group.work_rel,
            "source_path": group.key,
            "target_path": f"{target}/{group.work_rel}",
            "author": author_for_fill or "，".join(sorted(author_targets)),
            "evidence_source": evidence_source,
            "evidence_detail": evidence_detail,
            "file_count": len(group.files),
        })

        if status in {"review", "merged_with_collisions"}:
            unresolved_rows.append({
                "priority": "high",
                "reason": status,
                "work_key": group.key,
                "target": target,
                "note": note,
            })

    print("[audit] writing")
    write_csv(audit_dir / "move_plan.csv", move_rows)
    write_csv(audit_dir / "unresolved_author_propagation.csv", unresolved_rows)
    write_csv(audit_dir / "candidate_authors.csv", candidate_rows)
    write_csv(audit_dir / "fetched_author_candidates.csv", fetched_author_rows)
    write_csv(audit_dir / "author_lookup_audit.csv", author_lookup_rows)
    write_csv(audit_dir / "author_seed_rows.csv", seed_rows)
    write_csv(audit_dir / "ambiguous_author_targets.csv", ambiguous_author_rows)
    write_csv(audit_dir / "imported_author_lookup_rows.csv", imported_rows)

    summary = {
        "script_version": SCRIPT_VERSION,
        "root": str(root),
        "mode": "apply" if args.apply else "dry_run",
        "created_at_utc": now_utc(),
        "files_scanned": len(records),
        "work_groups": len(groups),
        "unknown_groups": len(unknown_groups),
        "target_folders": sorted(target_folders),
        "unknown_folders": sorted(unknown_folders),
        "seed_unambiguous_author_targets": len(author_target_map),
        "seed_ambiguous_author_targets": len(ambiguous_author_rows),
        "imported_group_targets": len(imported_group_targets),
        "imported_rows": len(imported_rows),
        "move_plan_rows": len(move_rows),
        "review_rows": len(unresolved_rows),
        "fetched_author_rows": len(fetched_author_rows),
        "parse_title_authors": bool(args.parse_title_authors),
        "fetch_missing_authors": bool(args.fetch_missing_authors),
        "author_page_lookup": bool(args.author_page_lookup),
        "fill_author": bool(args.fill_author),
        "merge_existing": bool(args.merge_existing),
        "metadata_policy": "No metadata additions; --fill-author only fills existing blank AUTHOR lines.",
    }
    (audit_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    print()
    print(f"[done] move_plan_rows={len(move_rows):,}")
    print(f"[done] unresolved/review_rows={len(unresolved_rows):,}")
    print(f"[audit] {audit_dir}")
    if not args.apply:
        print("[dry-run] No folders were moved.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
