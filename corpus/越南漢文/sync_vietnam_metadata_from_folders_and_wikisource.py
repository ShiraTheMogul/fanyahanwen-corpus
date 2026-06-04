#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sync_vietnam_metadata_header_only.py

Strict header-only metadata repair for an already-periodised Vietnamese corpus tree.

This script never rewrites, replaces, cleans, downloads, or re-scrapes body text.
It only rewrites the initial '# KEY: value' metadata header. The body bytes after
the header separator are appended back unchanged.

Evidence separation:
  - Local reviewed folder path -> NATION and TIMES
  - Wikisource PAGE_TITLE/SOURCE_URL -> AUTHOR and WS_CATEGORIES only

Default safety:
  - dry run only; use --apply to write
  - changed files are backed up before writing
  - manifest includes body SHA256 before/after to prove body preservation

Typical use:
  python sync_vietnam_metadata_header_only.py ".../越南漢文/clean/New system"
  python sync_vietnam_metadata_header_only.py ".../越南漢文/clean/New system" --apply

If your folder layout is 大越/後黎朝/<work>/<file>.txt, defaults give:
  NATION: 大越
  TIMES: 後黎朝

If your folder layout uses the dynasty as both nation and time, use:
  --nation-index -1 --times-index -1
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import re
import shutil
import sys
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple
from urllib.parse import unquote, urlparse

import requests

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"
HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusMetadataHeaderOnly/1.0 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

VERSION = "v2-header-only-vietnam-metadata-sync-2026-06-04"

HEADER_LINE_RE = re.compile(r"^#\s*([A-Z0-9_]+)\s*:\s*(.*)\s*$")

BACKUP_SUFFIXES = (".bak", ".bak2", ".orig", ".tmp")
AUDIT_FILENAMES = {
    "vietnam_header_only_metadata_manifest.csv",
    "vietnam_header_only_metadata_summary.md",
    "vietnam_header_only_metadata_cache.json",
}

GENERIC_COMPONENTS = {
    "raw", "clean", "New system", "Staging", "staging", "review",
    "未分類", "無年代", "待分類", "需核", "越南漢文", "漢文", "漢詩",
}

# Metadata-only conservative normalisation. Not applied to body text.
CONSERVATIVE_TRADITIONAL_MAP = str.maketrans({
    "属": "屬", "国": "國", "号": "號", "台": "臺", "湾": "灣",
    "汉": "漢", "赵": "趙", "龙": "龍", "录": "錄", "实": "實",
    "纪": "紀", "记": "記", "书": "書", "诗": "詩", "论": "論",
    "传": "傳", "礼": "禮", "乐": "樂", "为": "為", "与": "與",
    "万": "萬",
})

_session = requests.Session()


@dataclass
class HeaderSplit:
    entries: List[Tuple[str, str, str]]  # key, value, original raw line without newline
    body_tail: str                       # exact body after consumed header separator
    newline: str                         # \n or \r\n for rebuilt header


@dataclass
class DerivedPathMetadata:
    nation: str
    times: str
    classification_folders: List[str]
    work_folder: str
    reason: str
    skipped: bool = False


@dataclass
class PageFacts:
    page_title: str
    resolved_title: str
    author: str
    ws_categories: List[str]
    source: str
    error: str = ""


@dataclass
class ChangeRow:
    relative_path: str
    changed: bool
    skipped: bool
    reason: str
    page_title: str
    resolved_title: str
    old_author: str
    new_author: str
    old_nation: str
    new_nation: str
    old_times: str
    new_times: str
    old_ws_categories: str
    new_ws_categories: str
    facts_error: str
    body_sha256_before: str
    body_sha256_after: str
    body_unchanged: bool


# -----------------------------
# Exact header splitting/rebuild
# -----------------------------

def detect_newline(text: str) -> str:
    first_crlf = text.find("\r\n")
    first_lf = text.find("\n")
    if first_crlf != -1 and (first_lf == -1 or first_crlf <= first_lf):
        return "\r\n"
    return "\n"


def split_header_exact(text: str) -> HeaderSplit:
    """Split only the leading '# KEY: value' header.

    The body_tail is preserved exactly after the first blank separator line.
    If there is no metadata header, body_tail is the entire original text.
    """
    newline = detect_newline(text)
    entries: List[Tuple[str, str, str]] = []
    pos = 0
    consumed_any_header = False

    while pos < len(text):
        nl = text.find("\n", pos)
        if nl == -1:
            raw_line_with_eol = text[pos:]
            next_pos = len(text)
        else:
            raw_line_with_eol = text[pos:nl + 1]
            next_pos = nl + 1

        raw_line = raw_line_with_eol.rstrip("\r\n")
        m = HEADER_LINE_RE.match(raw_line)
        if m:
            entries.append((m.group(1).strip(), m.group(2).strip(), raw_line))
            pos = next_pos
            consumed_any_header = True
            continue

        # Consume exactly one blank separator after a real header.
        if consumed_any_header and raw_line.strip() == "":
            pos = next_pos
            break

        # Non-header text begins. Do not consume it.
        break

    if not consumed_any_header:
        return HeaderSplit(entries=[], body_tail=text, newline=newline)

    return HeaderSplit(entries=entries, body_tail=text[pos:], newline=newline)


def entries_to_meta(entries: Sequence[Tuple[str, str, str]]) -> Dict[str, str]:
    meta: Dict[str, str] = {}
    for key, value, _line in entries:
        meta[key] = value
    return meta


def build_header_only_text(
    split: HeaderSplit,
    updates: Dict[str, Optional[str]],
    append_order: Sequence[str],
    *,
    prune_to_schema: bool = False,
    schema_order: Optional[Sequence[str]] = None,
) -> str:
    """Build new text by replacing header only and appending body_tail unchanged."""
    nl = split.newline

    if prune_to_schema:
        merged = entries_to_meta(split.entries)
        for key, value in updates.items():
            if value is None or str(value).strip() == "":
                merged.pop(key, None)
            else:
                merged[key] = str(value).strip()
        keys = list(schema_order or [])
        header_lines = [f"# {key}: {merged[key].strip()}" for key in keys if merged.get(key, "").strip()]
        return nl.join(header_lines) + nl + nl + split.body_tail

    seen: set[str] = set()
    header_lines: List[str] = []

    for key, _old_value, original_line in split.entries:
        seen.add(key)
        if key in updates:
            new_value = updates[key]
            if new_value is None or str(new_value).strip() == "":
                continue
            header_lines.append(f"# {key}: {str(new_value).strip()}")
        else:
            # Preserve unrelated metadata lines byte-for-byte except newline style.
            header_lines.append(original_line)

    for key in append_order:
        if key in seen:
            continue
        val = updates.get(key)
        if val is not None and str(val).strip() != "":
            header_lines.append(f"# {key}: {str(val).strip()}")

    return nl.join(header_lines) + nl + nl + split.body_tail


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="surrogatepass")).hexdigest()


# -----------------------------
# Path-derived metadata
# -----------------------------

def make_converter(mode: str):
    if mode == "none":
        return lambda s: s
    if mode == "conservative":
        return lambda s: s.translate(CONSERVATIVE_TRADITIONAL_MAP)
    if mode == "opencc":
        try:
            from opencc import OpenCC  # type: ignore
        except Exception as exc:
            raise SystemExit(
                "OpenCC requested, but Python opencc is not available. "
                "Use --character-mode none/conservative or install opencc. "
                f"Original error: {exc}"
            )
        cc = OpenCC("s2t")
        return lambda s: cc.convert(s)
    raise ValueError(f"unknown character mode: {mode}")


def looks_like_work_folder(folder_name: str, file_stem: str) -> bool:
    f = folder_name.strip()
    s = file_stem.strip()
    if not f or not s:
        return False
    return s == f or s.startswith(f + "__") or s.startswith(f + "_") or f in s


def get_classification_folders(root: Path, path: Path) -> Tuple[List[str], str]:
    rel = path.relative_to(root)
    dirs = list(rel.parent.parts)
    work_folder = ""
    if dirs and looks_like_work_folder(dirs[-1], path.stem):
        work_folder = dirs[-1]
        dirs = dirs[:-1]
    classification = [
        d for d in dirs
        if d not in GENERIC_COMPONENTS and not d.startswith("_metadata_backup")
    ]
    return classification, work_folder


def pick_index(items: Sequence[str], index: int) -> str:
    if not items:
        return ""
    try:
        return items[index]
    except IndexError:
        return ""


def derive_path_metadata(root: Path, path: Path, *, nation_index: int, times_index: int, converter) -> DerivedPathMetadata:
    try:
        classification, work_folder = get_classification_folders(root, path)
    except Exception as exc:
        return DerivedPathMetadata("", "", [], "", f"could not derive relative path: {exc}", skipped=True)

    if not classification:
        return DerivedPathMetadata("", "", classification, work_folder, "no classification folders before work/file", skipped=True)

    converted = [converter(x) for x in classification]
    nation = pick_index(converted, nation_index)
    times = pick_index(converted, times_index)

    if not times:
        times = nation
    if not nation and times:
        nation = times

    if not nation and not times:
        return DerivedPathMetadata("", "", converted, work_folder, "selected NATION/TIMES indices were empty", skipped=True)

    return DerivedPathMetadata(
        nation=nation,
        times=times,
        classification_folders=converted,
        work_folder=work_folder,
        reason=f"header-only path metadata from folders {converted!r} using nation_index={nation_index}, times_index={times_index}",
        skipped=False,
    )


# -----------------------------
# Wikisource metadata only
# -----------------------------

def safe_request(params: Dict[str, Any], *, sleep: float, max_retries: int = 3) -> Dict[str, Any]:
    params = dict(params)
    params.setdefault("format", "json")
    params.setdefault("formatversion", "2")
    for attempt in range(1, max_retries + 1):
        try:
            time.sleep(sleep)
            r = _session.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=35)
            r.raise_for_status()
            data = r.json()
            if "error" in data:
                if attempt == max_retries:
                    return {"_error": str(data["error"])}
                continue
            return data
        except Exception as exc:
            if attempt == max_retries:
                return {"_error": str(exc)}
            time.sleep(min(2.0, 0.35 * attempt))
    return {"_error": "unknown request failure"}


def resolve_redirect_title(title: str, *, sleep: float) -> Optional[str]:
    if not title:
        return None
    data = safe_request({"action": "query", "titles": title, "redirects": "1"}, sleep=sleep)
    if data.get("_error"):
        return title
    query = data.get("query") or {}
    pages = query.get("pages") or []
    if not pages:
        return None
    pg = pages[0]
    if "missing" in pg:
        return None
    redirects = query.get("redirects") or []
    if redirects:
        return redirects[-1].get("to") or title
    return pg.get("title") or title


def root_title_for_page(title: str) -> str:
    return title.split("/", 1)[0].strip()


def fetch_wikitext_metadata_source(title: str, *, sleep: float) -> Tuple[str, str, str]:
    """Fetch page wikitext as metadata source only. Never written to corpus body."""
    resolved = resolve_redirect_title(title, sleep=sleep)
    if not resolved:
        return "", "", "missing"
    data = safe_request(
        {
            "action": "query",
            "prop": "revisions",
            "titles": resolved,
            "rvprop": "content",
            "rvslots": "main",
        },
        sleep=sleep,
    )
    if data.get("_error"):
        return "", resolved, str(data.get("_error"))
    pages = (data.get("query") or {}).get("pages") or []
    if not pages:
        return "", resolved, "no_pages"
    revs = pages[0].get("revisions") or []
    if not revs:
        return "", resolved, "no_revisions"
    slots = revs[0].get("slots") or {}
    main = slots.get("main") or {}
    return main.get("content", "") or "", resolved, ""


def fetch_categories_exact(title: str, *, sleep: float) -> Tuple[List[str], str, str]:
    resolved = resolve_redirect_title(title, sleep=sleep)
    if not resolved:
        return [], "", "missing"
    data = safe_request(
        {
            "action": "query",
            "prop": "categories",
            "titles": resolved,
            "cllimit": "max",
            "clshow": "!hidden",
        },
        sleep=sleep,
    )
    if data.get("_error"):
        return [], resolved, str(data.get("_error"))
    pages = (data.get("query") or {}).get("pages") or []
    if not pages:
        return [], resolved, "no_pages"
    cats = pages[0].get("categories") or []
    out: List[str] = []
    for cat in cats:
        name = cat.get("title") or ""
        if name.startswith("Category:"):
            name = name.split(":", 1)[1]
        if name:
            out.append(name)
    return sorted(set(out)), resolved, ""


def strip_wiki_markup(value: str) -> str:
    s = (value or "").strip()
    if not s:
        return ""
    s = re.sub(r"<!--.*?-->", "", s, flags=re.S)
    s = re.sub(r"\[\[[^\]|]+\|([^\]]+)\]\]", r"\1", s)
    s = re.sub(r"\[\[([^\]]+)\]\]", r"\1", s)

    def repl_template(m: re.Match) -> str:
        inner = m.group(1)
        parts = [p.strip() for p in inner.split("|") if p.strip()]
        if len(parts) >= 2:
            return parts[-1]
        return ""

    s = re.sub(r"\{\{([^{}]+)\}\}", repl_template, s)
    s = s.replace("Author:", "").replace("作者:", "")
    s = re.sub(r"<[^>]+>", "", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip(" |，,;；")


def extract_template_field(wikitext: str, field_names: Sequence[str]) -> str:
    if not wikitext:
        return ""
    # Handles both one-line {{Header|title=X|author=Y|...}} and multiline | author = Y.
    names = "|".join(re.escape(n) for n in field_names)
    pattern = re.compile(rf"\|\s*(?:{names})\s*=\s*([^|}}\n\r]*)", flags=re.I)
    m = pattern.search(wikitext)
    if m:
        return strip_wiki_markup(m.group(1))
    return ""


def extract_author_from_wikitext(wikitext: str) -> str:
    author = extract_template_field(wikitext, ["author", "作者"])
    if author:
        return author
    m = re.search(r"作者\s*[：:]\s*([^\n|{}<>]{1,80})", wikitext)
    if m:
        return strip_wiki_markup(m.group(1))
    return ""


def get_page_facts(page_title: str, *, sleep: float, root_fallback: bool = True) -> PageFacts:
    if not page_title:
        return PageFacts("", "", "", [], "none", "no PAGE_TITLE or SOURCE_URL")

    errors: List[str] = []
    wt, resolved, err = fetch_wikitext_metadata_source(page_title, sleep=sleep)
    if err:
        errors.append(f"wikitext:{err}")
    author = extract_author_from_wikitext(wt)
    source = "wikitext"

    if not author and root_fallback and "/" in page_title:
        root = root_title_for_page(page_title)
        wt_root, resolved_root, err_root = fetch_wikitext_metadata_source(root, sleep=sleep)
        if err_root:
            errors.append(f"root_wikitext:{err_root}")
        author = extract_author_from_wikitext(wt_root)
        if author:
            source = "root_wikitext"
            if not resolved:
                resolved = resolved_root

    cats, resolved_cats, cats_err = fetch_categories_exact(page_title, sleep=sleep)
    if cats_err:
        errors.append(f"categories:{cats_err}")
    if not cats and root_fallback and "/" in page_title:
        root = root_title_for_page(page_title)
        cats, resolved_root_cats, cats_root_err = fetch_categories_exact(root, sleep=sleep)
        if cats_root_err:
            errors.append(f"root_categories:{cats_root_err}")
        if cats and not resolved_cats:
            resolved_cats = resolved_root_cats

    if not resolved:
        resolved = resolved_cats or page_title
    if not author:
        errors.append("author_not_found")
    if not cats:
        errors.append("ws_categories_not_found")

    return PageFacts(
        page_title=page_title,
        resolved_title=resolved,
        author=author,
        ws_categories=cats,
        source=source,
        error=";".join(errors),
    )


def extract_page_title(meta: Dict[str, str]) -> str:
    page_title = (meta.get("PAGE_TITLE") or "").strip()
    if page_title:
        return page_title
    url = (meta.get("SOURCE_URL") or meta.get("URL") or "").strip()
    if not url:
        return ""
    try:
        u = urlparse(url)
        parts = [p for p in u.path.split("/") if p]
        if not parts:
            return ""
        if parts[0] == "wiki" and len(parts) >= 2:
            return unquote("/".join(parts[1:]))
        if len(parts) >= 2:
            return unquote("/".join(parts[1:]))
        return unquote(parts[-1])
    except Exception:
        return ""


# -----------------------------
# Files, backups, reports
# -----------------------------

def is_backup_file(path: Path) -> bool:
    return any(path.name.endswith(suf) for suf in BACKUP_SUFFIXES)


def iter_text_files(root: Path) -> Iterable[Path]:
    for path in root.rglob("*.txt"):
        if not path.is_file():
            continue
        if is_backup_file(path):
            continue
        if path.name in AUDIT_FILENAMES:
            continue
        if any(part.startswith("_metadata_backup") for part in path.parts):
            continue
        yield path


def backup_file(root: Path, path: Path, backup_dir: Path) -> None:
    rel = path.relative_to(root)
    target = backup_dir / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)


def write_manifest(rows: Sequence[ChangeRow], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "relative_path", "changed", "skipped", "reason", "page_title", "resolved_title",
        "old_author", "new_author", "old_nation", "new_nation", "old_times", "new_times",
        "old_ws_categories", "new_ws_categories", "facts_error",
        "body_sha256_before", "body_sha256_after", "body_unchanged",
    ]
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for row in rows:
            w.writerow({k: getattr(row, k) for k in fieldnames})


def write_summary(rows: Sequence[ChangeRow], path: Path, *, apply: bool, backup_dir: Optional[Path], args: argparse.Namespace) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    changed = sum(1 for r in rows if r.changed)
    skipped = sum(1 for r in rows if r.skipped)
    body_changed = sum(1 for r in rows if not r.body_unchanged)
    author_counts = Counter(r.new_author for r in rows if r.new_author and not r.skipped)
    nation_counts = Counter(r.new_nation for r in rows if r.new_nation and not r.skipped)
    times_counts = Counter(r.new_times for r in rows if r.new_times and not r.skipped)
    errors = Counter(r.facts_error for r in rows if r.facts_error)
    reasons = Counter(r.reason for r in rows)

    lines: List[str] = []
    lines.append("# Vietnamese header-only metadata sync report")
    lines.append("")
    lines.append(f"Version: {VERSION}")
    lines.append(f"Mode: {'APPLY / headers rewritten' if apply else 'DRY RUN / no files rewritten'}")
    lines.append(f"Root: {args.root}")
    lines.append(f"Nation index: {args.nation_index}")
    lines.append(f"Times index: {args.times_index}")
    lines.append(f"Character mode: {args.character_mode}")
    if backup_dir:
        lines.append(f"Backup directory: {backup_dir}")
    lines.append(f"Files scanned: {len(rows)}")
    lines.append(f"Files changed / would change: {changed}")
    lines.append(f"Files skipped: {skipped}")
    lines.append(f"Body preservation failures: {body_changed}")
    lines.append("")

    lines.append("## New NATION values")
    for k, v in nation_counts.most_common():
        lines.append(f"- {k}: {v}")
    lines.append("")

    lines.append("## New TIMES values")
    for k, v in times_counts.most_common():
        lines.append(f"- {k}: {v}")
    lines.append("")

    lines.append("## New AUTHOR values")
    for k, v in author_counts.most_common(80):
        lines.append(f"- {k}: {v}")
    lines.append("")

    lines.append("## Wikisource metadata warnings")
    for k, v in errors.most_common():
        lines.append(f"- {k}: {v}")
    lines.append("")

    lines.append("## Reasons")
    for k, v in reasons.most_common():
        lines.append(f"- {k}: {v}")
    lines.append("")

    lines.append("## Changed files")
    for r in rows:
        if r.changed:
            lines.append(
                f"- {r.relative_path}: AUTHOR {r.old_author!r} -> {r.new_author!r}; "
                f"NATION {r.old_nation!r} -> {r.new_nation!r}; "
                f"TIMES {r.old_times!r} -> {r.new_times!r}; "
                f"WS_CATEGORIES {r.old_ws_categories!r} -> {r.new_ws_categories!r}; "
                f"body_unchanged={r.body_unchanged}"
            )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# -----------------------------
# Main
# -----------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="Header-only sync for Vietnamese corpus AUTHOR/NATION/TIMES/WS_CATEGORIES.")
    ap.add_argument("root", type=Path, nargs="?", help="Root of the reviewed/periodised tree to scan")
    ap.add_argument("--apply", action="store_true", help="Actually rewrite headers. Default is dry-run.")
    ap.add_argument("--manifest", type=Path, help="Manifest CSV path. Default: <root>/vietnam_header_only_metadata_manifest.csv")
    ap.add_argument("--summary", type=Path, help="Summary Markdown path. Default: <root>/vietnam_header_only_metadata_summary.md")
    ap.add_argument("--backup-dir", type=Path, help="Backup directory used with --apply. Default: <root>/_metadata_backup_<timestamp>")
    ap.add_argument("--sleep", type=float, default=0.45, help="Seconds between API requests")
    ap.add_argument("--nation-index", type=int, default=0, help="Classification folder for NATION. Default 0 = first. Use -1 for deepest.")
    ap.add_argument("--times-index", type=int, default=-1, help="Classification folder for TIMES. Default -1 = deepest.")
    ap.add_argument("--character-mode", choices=["none", "conservative", "opencc"], default="none", help="Normalise folder-derived NATION/TIMES only. Default none = use folder spelling exactly.")
    ap.add_argument("--no-fetch-author", action="store_true", help="Do not fetch/update AUTHOR from Wikisource")
    ap.add_argument("--no-fetch-ws-categories", action="store_true", help="Do not fetch/update WS_CATEGORIES from Wikisource")
    ap.add_argument("--keep-existing-author-if-not-found", action="store_true", default=True, help="Keep existing AUTHOR if no author is found. Default on.")
    ap.add_argument("--clear-author-if-not-found", dest="keep_existing_author_if_not_found", action="store_false", help="Blank AUTHOR if no online author is found")
    ap.add_argument("--root-fallback", action="store_true", default=True, help="For subpages, fall back to root page for AUTHOR/WS_CATEGORIES. Default on.")
    ap.add_argument("--no-root-fallback", dest="root_fallback", action="store_false", help="Disable root-page fallback for subpages")
    ap.add_argument("--prune-header-to-schema", action="store_true", help="Rewrite header into narrow schema order. Body is still preserved exactly.")
    ap.add_argument("--version", action="store_true", help="Print version and exit")

    args = ap.parse_args()

    if args.version:
        print(VERSION)
        return 0

    if args.root is None:
        ap.error("root is required unless --version is used")

    root = args.root.resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"Root does not exist or is not a directory: {root}")

    converter = make_converter(args.character_mode)
    manifest_path = args.manifest or (root / "vietnam_header_only_metadata_manifest.csv")
    summary_path = args.summary or (root / "vietnam_header_only_metadata_summary.md")

    backup_dir: Optional[Path] = None
    if args.apply:
        if args.backup_dir:
            backup_dir = args.backup_dir.resolve()
        else:
            stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_dir = root / f"_metadata_backup_{stamp}"
        backup_dir.mkdir(parents=True, exist_ok=True)

    schema_order = [
        "WORK_TITLE", "DISPLAY_TITLE", "PAGE_TITLE", "AUTHOR", "NATION",
        "TIMES", "CATEGORIES", "YEAR", "CHAPTER", "SOURCE_URL",
        "WS_CATEGORIES", "SCRAPED_AT_UTC",
    ]

    facts_cache: Dict[str, PageFacts] = {}
    rows: List[ChangeRow] = []

    for path in sorted(iter_text_files(root)):
        rel = path.relative_to(root).as_posix()
        try:
            old_text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            old_text = path.read_text(encoding="utf-8", errors="replace")

        split = split_header_exact(old_text)
        meta = entries_to_meta(split.entries)
        body_before = split.body_tail
        body_hash_before = sha256_text(body_before)

        old_author = meta.get("AUTHOR", "")
        old_nation = meta.get("NATION", "")
        old_times = meta.get("TIMES", "")
        old_ws_categories = meta.get("WS_CATEGORIES", "")

        derived = derive_path_metadata(
            root,
            path,
            nation_index=args.nation_index,
            times_index=args.times_index,
            converter=converter,
        )

        page_title = extract_page_title(meta)
        facts = PageFacts(page_title, page_title, "", [], "not_fetched", "")
        if page_title and (not args.no_fetch_author or not args.no_fetch_ws_categories):
            if page_title not in facts_cache:
                facts_cache[page_title] = get_page_facts(page_title, sleep=args.sleep, root_fallback=args.root_fallback)
            facts = facts_cache[page_title]
        elif not page_title and (not args.no_fetch_author or not args.no_fetch_ws_categories):
            facts = PageFacts("", "", "", [], "none", "no PAGE_TITLE or SOURCE_URL")

        if derived.skipped:
            rows.append(ChangeRow(
                relative_path=rel,
                changed=False,
                skipped=True,
                reason=derived.reason,
                page_title=page_title,
                resolved_title=facts.resolved_title,
                old_author=old_author,
                new_author="",
                old_nation=old_nation,
                new_nation="",
                old_times=old_times,
                new_times="",
                old_ws_categories=old_ws_categories,
                new_ws_categories="",
                facts_error=facts.error,
                body_sha256_before=body_hash_before,
                body_sha256_after=body_hash_before,
                body_unchanged=True,
            ))
            continue

        new_author = old_author
        if not args.no_fetch_author:
            if facts.author:
                new_author = facts.author
            elif not args.keep_existing_author_if_not_found:
                new_author = ""

        new_ws_categories = old_ws_categories
        if not args.no_fetch_ws_categories:
            new_ws_categories = "，".join(facts.ws_categories)

        updates: Dict[str, Optional[str]] = {
            "AUTHOR": new_author,
            "NATION": derived.nation,
            "TIMES": derived.times,
            "WS_CATEGORIES": new_ws_categories,
        }

        new_text = build_header_only_text(
            split,
            updates,
            append_order=["AUTHOR", "NATION", "TIMES", "WS_CATEGORIES"],
            prune_to_schema=bool(args.prune_header_to_schema),
            schema_order=schema_order,
        )

        # Absolute guard: body after rebuild must be byte-for-byte equivalent as a Python string.
        split_after = split_header_exact(new_text)
        body_after = split_after.body_tail
        body_hash_after = sha256_text(body_after)
        body_unchanged = body_hash_before == body_hash_after and body_before == body_after
        if not body_unchanged:
            raise RuntimeError(
                f"Refusing to write {rel}: body would change. "
                "This script is header-only, so this indicates a bug."
            )

        changed = new_text != old_text
        rows.append(ChangeRow(
            relative_path=rel,
            changed=changed,
            skipped=False,
            reason=derived.reason,
            page_title=page_title,
            resolved_title=facts.resolved_title,
            old_author=old_author,
            new_author=new_author,
            old_nation=old_nation,
            new_nation=derived.nation,
            old_times=old_times,
            new_times=derived.times,
            old_ws_categories=old_ws_categories,
            new_ws_categories=new_ws_categories,
            facts_error=facts.error,
            body_sha256_before=body_hash_before,
            body_sha256_after=body_hash_after,
            body_unchanged=True,
        ))

        if args.apply and changed:
            assert backup_dir is not None
            backup_file(root, path, backup_dir)
            path.write_text(new_text, encoding="utf-8")

    write_manifest(rows, manifest_path)
    write_summary(rows, summary_path, apply=args.apply, backup_dir=backup_dir, args=args)

    changed_count = sum(1 for r in rows if r.changed)
    skipped_count = sum(1 for r in rows if r.skipped)
    body_failures = sum(1 for r in rows if not r.body_unchanged)
    print(f"Scanned {len(rows)} .txt files")
    print(f"{'Changed' if args.apply else 'Would change'} {changed_count} headers")
    print(f"Skipped {skipped_count} files")
    print(f"Body preservation failures: {body_failures}")
    print(f"Wrote manifest: {manifest_path}")
    print(f"Wrote summary: {summary_path}")
    if backup_dir:
        print(f"Backed up changed files to: {backup_dir}")
    if not args.apply:
        print("Dry run only. Re-run with --apply to rewrite headers.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
