#!/usr/bin/env python3
"""Build a read-only inventory/match report from harvested scholarly sources.

This script NEVER edits corpus works. It reads:
  * the current local PALCC corpus tree;
  * the untracked source-harvest staging directory;
and writes CSV/JSON/TXT reports back into staging.

The job is intentionally suitable for an unattended overnight run. The default
"deep" corpus scan walks current files and reads only metadata/header prefixes,
rather than trusting checked-in aggregate indexes to be perfectly current.
"""

from __future__ import annotations

import argparse
import html as html_lib
import csv
import io
import json
import os
import re
import signal
import sys
import unicodedata
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from difflib import SequenceMatcher
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Iterable, Iterator
from xml.etree import ElementTree as ET

HEADER_BYTES = 32768
HAN_RE = re.compile(r"[\u3400-\u4DBF\u4E00-\u9FFF\U00020000-\U0002EBEF]")
CJK_TITLE_RE = re.compile(r"[\u3400-\u9FFF々〆ヵヶぁ-んァ-ヶー]{2,}")
KANRIPO_ID_RE = re.compile(r"\b(KR[1-6][a-z][0-9]{4})\b", re.I)
BIB_ID_RE = re.compile(r"(?<!\d)(\d{7,12})(?!\d)")
WORK_ID_RE = re.compile(r"(?<![A-Za-z0-9])(W-\d{8})(?!\d)", re.I)
SPACE_PUNCT_RE = re.compile(
    r"[\s\u3000\-‐‑‒–—―_·・,，.。:：;；!！?？/／\\|｜'‘’\"“”"
    r"\(\)（）\[\]［］\{\}｛｝<>＜＞《》〈〉『』「」【】〔〕〖〗〘〙〚〛]+"
)
EDITION_QUALIFIERS_RE = re.compile(
    r"(?:四庫全書本|欽定四庫全書|四庫本|文淵閣本|影印本|刻本|刊本|寫本|写本|抄本|鈔本|校本|注本|註本)$"
)

# Small, deliberately conservative title-only folding table. This is not a text
# normalizer; it merely prevents common Japanese shinjitai / simplified title
# spellings from defeating candidate discovery.
TITLE_FOLD = str.maketrans(
    {
        "学": "學", "国": "國", "経": "經", "礼": "禮", "旧": "舊", "与": "與",
        "万": "萬", "図": "圖", "広": "廣", "会": "會", "訳": "譯", "説": "說",
        "戦": "戰", "伝": "傳", "実": "實", "録": "錄", "歴": "歷", "亜": "亞",
        "仏": "佛", "宝": "寶", "体": "體", "徳": "德", "辺": "邊", "関": "關",
        "門": "門", "発": "發", "来": "來", "楽": "樂", "読": "讀", "書": "書",
        "遥": "遙", "游": "遊", "荘": "莊", "礼": "禮", "寿": "壽", "医": "醫",
        "薬": "藥", "芸": "藝", "気": "氣", "帰": "歸", "応": "應", "竜": "龍",
        "沢": "澤", "沢": "澤", "沢": "澤", "台": "臺", "湾": "灣", "号": "號",
        "声": "聲", "処": "處", "尽": "盡", "観": "觀", "雑": "雜", "総": "總",
        "禅": "禪", "静": "靜", "円": "圓", "覚": "覺", "変": "變", "権": "權",
        "済": "濟", "辺": "邊", "増": "增", "単": "單", "団": "團", "独": "獨",
        "対": "對", "当": "當", "帯": "帶", "県": "縣", "郷": "鄉", "郡": "郡",
        "塩": "鹽", "広": "廣", "浜": "濱", "辺": "邊", "沢": "澤", "桜": "櫻",
    }
)

SKIP_PRIMARY_COMPONENTS = {
    "scripts", "raw", "variants", "kanbun", "hanvan", "hanmun", "annotations",
    "scrape_output", "node_modules", "vendor", ".git",
}

UD_KNOWN_WORKS = {
    "UD_Classical_Chinese-Kyoto": [
        "論語", "孟子", "禮記", "十八史略", "楚辭", "戰國策", "唐詩三百首",
        "摩訶般若波羅蜜大明呪經", "金剛般若波羅蜜經", "佛說阿彌陀經",
    ],
    "UD_Classical_Chinese-TueCL": ["逍遙遊", "莊子"],
}


class StopRequested(Exception):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(message: str) -> None:
    print(f"[{utc_now()}] {message}", flush=True)


def handle_stop(signum: int, _frame: Any) -> None:
    name = signal.Signals(signum).name
    log(f"Received {name}; stopping inventory cleanly.")
    raise StopRequested(name)


def install_signal_handlers() -> None:
    signal.signal(signal.SIGINT, handle_stop)
    signal.signal(signal.SIGTERM, handle_stop)


def atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def write_csv(path: Path, rows: list[dict[str, Any]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def clean_scalar(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (list, tuple, set)):
        return " | ".join(clean_scalar(item) for item in value if clean_scalar(item))
    return str(value).strip()


def title_normalize(value: str) -> str:
    text = unicodedata.normalize("NFKC", clean_scalar(value)).translate(TITLE_FOLD)
    text = SPACE_PUNCT_RE.sub("", text)
    return text.casefold()


def title_core(value: str) -> str:
    text = unicodedata.normalize("NFKC", clean_scalar(value)).translate(TITLE_FOLD)
    # Remove parenthesized edition notes before punctuation is stripped.
    text = re.sub(r"[（(][^（）()]{0,40}(?:四庫|版本|本|注|註|校|刊|寫|写|抄|鈔)[^（）()]{0,40}[）)]", "", text)
    text = SPACE_PUNCT_RE.sub("", text)
    previous = None
    while text and text != previous:
        previous = text
        text = EDITION_QUALIFIERS_RE.sub("", text)
    return text.casefold()


def title_aliases(*values: str) -> set[str]:
    aliases: set[str] = set()
    for value in values:
        if not value:
            continue
        for candidate in (title_normalize(value), title_core(value)):
            if candidate:
                aliases.add(candidate)
    return aliases


def han_ratio(text: str) -> float:
    denominator = 0
    han = 0
    for char in text:
        cat = unicodedata.category(char)
        if char.isspace() or cat.startswith("P") or cat.startswith("S") or cat.startswith("N"):
            continue
        denominator += 1
        if HAN_RE.fullmatch(char):
            han += 1
    return (han / denominator) if denominator else 0.0


def read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def parse_text_header(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    try:
        with path.open("rb") as handle:
            raw = handle.read(HEADER_BYTES)
        text = raw.decode("utf-8-sig", errors="replace")
        for line in text.splitlines():
            if not line.startswith("#"):
                break
            body = line[1:].strip()
            if ":" in body:
                key, value = body.split(":", 1)
                meta[key.strip().upper()] = value.strip()
    except OSError:
        pass
    return meta


@dataclass
class CorpusWork:
    key: str
    corpus_root: str
    path: str
    title: str
    display_title: str = ""
    author: str = ""
    work_id: str = ""
    source_urls: set[str] = field(default_factory=set)
    aliases: set[str] = field(default_factory=set)
    evidence_files: set[str] = field(default_factory=set)

    def add_aliases(self, *values: str) -> None:
        self.aliases.update(title_aliases(*values))


def corpus_root_for(path: Path, corpus_dir: Path) -> str:
    try:
        rel = path.relative_to(corpus_dir)
        return rel.parts[0] if rel.parts else ""
    except ValueError:
        return ""


def nearest_metadata(path: Path, metadata_by_dir: dict[Path, dict[str, Any]], corpus_dir: Path) -> tuple[Path | None, dict[str, Any] | None]:
    current = path.parent
    while current != corpus_dir and corpus_dir in current.parents:
        if current in metadata_by_dir:
            return current, metadata_by_dir[current]
        current = current.parent
    return None, None


def likely_work_dir(path: Path, title: str, corpus_dir: Path) -> Path:
    norm = title_normalize(title)
    if norm:
        for parent in [path.parent, *path.parents]:
            if parent == corpus_dir:
                break
            if title_normalize(parent.name) == norm or title_core(parent.name) == title_core(title):
                return parent
    return path.parent


def load_corpus_works(repo_root: Path, deep: bool = True) -> list[CorpusWork]:
    corpus_dir = repo_root / "corpus"
    if not corpus_dir.is_dir():
        raise RuntimeError(f"Corpus directory not found: {corpus_dir}")

    works: dict[str, CorpusWork] = {}
    metadata_by_dir: dict[Path, dict[str, Any]] = {}

    # First pass: modern metadata is authoritative for the work folder it lives in.
    meta_count = 0
    for meta_path in corpus_dir.rglob("metadata.json"):
        rel_parts = meta_path.relative_to(corpus_dir).parts
        if any(part in SKIP_PRIMARY_COMPONENTS for part in rel_parts):
            continue
        payload = read_json(meta_path, {})
        if not isinstance(payload, dict):
            continue
        title = clean_scalar(payload.get("title") or payload.get("work_title") or meta_path.parent.name)
        if not title:
            continue
        metadata_by_dir[meta_path.parent] = payload
        corpus_root = clean_scalar(payload.get("corpus_root")) or corpus_root_for(meta_path, corpus_dir)
        rel_work = meta_path.parent.relative_to(repo_root).as_posix()
        key = f"meta:{rel_work}"
        work = works.get(key)
        if work is None:
            work = CorpusWork(
                key=key,
                corpus_root=corpus_root,
                path=rel_work,
                title=title,
                display_title=clean_scalar(payload.get("display_title")),
                author=clean_scalar(payload.get("author")),
                work_id=clean_scalar(payload.get("work_id")),
            )
            works[key] = work
        work.add_aliases(title, work.display_title, meta_path.parent.name)
        sources = payload.get("sources") or payload.get("source_urls") or []
        if isinstance(sources, str):
            sources = [sources]
        if isinstance(sources, list):
            work.source_urls.update(clean_scalar(item) for item in sources if clean_scalar(item))
        work.evidence_files.add(meta_path.relative_to(repo_root).as_posix())
        meta_count += 1
        if meta_count % 1000 == 0:
            log(f"Corpus metadata scan: {meta_count:,} metadata.json files")

    if not deep:
        log(f"Corpus metadata scan complete: {meta_count:,} metadata files; quick mode skips text headers.")
        return sorted(works.values(), key=lambda work: (work.corpus_root, work.title, work.path))

    # Second pass: legacy header metadata and works without metadata.json.
    text_count = 0
    accepted_text_count = 0
    for text_path in corpus_dir.rglob("*.txt"):
        rel_parts = text_path.relative_to(corpus_dir).parts
        if not rel_parts:
            continue
        if any(part in SKIP_PRIMARY_COMPONENTS for part in rel_parts):
            continue
        # Only primary clean/suspected_baihua trees are corpus works.
        if "clean" not in rel_parts and "suspected_baihua" not in rel_parts:
            continue
        text_count += 1
        meta_dir, modern = nearest_metadata(text_path, metadata_by_dir, corpus_dir)
        header = parse_text_header(text_path)
        title = clean_scalar(
            (modern or {}).get("title")
            or header.get("WORK_TITLE")
            or header.get("DISPLAY_TITLE")
            or header.get("PAGE_TITLE")
        )
        if not title:
            # Last-resort folder title; useful for older corpus material.
            title = text_path.parent.name
        display_title = clean_scalar((modern or {}).get("display_title") or header.get("DISPLAY_TITLE"))
        author = clean_scalar((modern or {}).get("author") or header.get("AUTHOR"))
        corpus_root = clean_scalar((modern or {}).get("corpus_root")) or corpus_root_for(text_path, corpus_dir)

        if meta_dir is not None:
            rel_work = meta_dir.relative_to(repo_root).as_posix()
            key = f"meta:{rel_work}"
        else:
            work_dir = likely_work_dir(text_path, title, corpus_dir)
            rel_work = work_dir.relative_to(repo_root).as_posix()
            key = f"legacy:{corpus_root}:{rel_work}:{title_normalize(title)}"

        work = works.get(key)
        if work is None:
            work = CorpusWork(
                key=key,
                corpus_root=corpus_root,
                path=rel_work,
                title=title,
                display_title=display_title,
                author=author,
                work_id=clean_scalar((modern or {}).get("work_id")),
            )
            works[key] = work
        elif not work.author and author:
            work.author = author
        if not work.display_title and display_title:
            work.display_title = display_title
        work.add_aliases(title, display_title, header.get("PAGE_TITLE", ""))
        if not header.get("WORK_TITLE") and modern is None:
            work.add_aliases(text_path.parent.name)
        source_url = header.get("SOURCE_URL", "")
        if source_url:
            work.source_urls.add(source_url)
        work.evidence_files.add(text_path.relative_to(repo_root).as_posix())
        accepted_text_count += 1
        if text_count % 2000 == 0:
            log(f"Corpus deep scan: {text_count:,} text files inspected; {len(works):,} work records")

    log(
        f"Corpus scan complete: {meta_count:,} metadata files + {accepted_text_count:,} primary text files; "
        f"{len(works):,} work records."
    )
    return sorted(works.values(), key=lambda work: (work.corpus_root, work.title, work.path))


class Matcher:
    def __init__(self, works: list[CorpusWork]):
        self.works = works
        self.exact: dict[str, set[int]] = defaultdict(set)
        self.ngrams: dict[str, set[int]] = defaultdict(set)
        for idx, work in enumerate(works):
            for alias in work.aliases:
                self.exact[alias].add(idx)
                for gram in self._grams(alias):
                    self.ngrams[gram].add(idx)

    @staticmethod
    def _grams(text: str) -> set[str]:
        if len(text) <= 2:
            return set(text)
        return {text[i : i + 2] for i in range(len(text) - 1)}

    def match(self, title: str, *, limit: int = 5) -> dict[str, Any]:
        aliases = title_aliases(title)
        if not aliases:
            return self._empty("source_title_missing")

        exact_ids: set[int] = set()
        for alias in aliases:
            exact_ids.update(self.exact.get(alias, set()))
        if exact_ids:
            candidates = [self.works[idx] for idx in sorted(exact_ids)]
            return self._result(
                "exact_title" if len(candidates) == 1 else "exact_title_ambiguous",
                1.0,
                candidates[:limit],
            )

        candidate_ids: Counter[int] = Counter()
        for alias in aliases:
            for gram in self._grams(alias):
                for idx in self.ngrams.get(gram, set()):
                    candidate_ids[idx] += 1
        if not candidate_ids:
            return self._empty("no_title_match")

        # Cap expensive SequenceMatcher calls to the strongest ngram candidates.
        scored: list[tuple[float, CorpusWork]] = []
        for idx, _hits in candidate_ids.most_common(80):
            work = self.works[idx]
            best = 0.0
            for source_alias in aliases:
                for target_alias in work.aliases:
                    if min(len(source_alias), len(target_alias)) < 2:
                        continue
                    ratio = SequenceMatcher(None, source_alias, target_alias, autojunk=False).ratio()
                    # Containment of a meaningful title is a strong signal, especially
                    # where PALCC adds an edition qualifier to a canonical title.
                    if min(len(source_alias), len(target_alias)) >= 4 and (
                        source_alias in target_alias or target_alias in source_alias
                    ):
                        ratio = max(ratio, 0.94)
                    best = max(best, ratio)
            scored.append((best, work))
        scored.sort(key=lambda item: (-item[0], item[1].title, item[1].path))
        best_score = scored[0][0] if scored else 0.0
        if best_score >= 0.92:
            status = "strong_title_match"
        elif best_score >= 0.80:
            status = "review_title_match"
        else:
            status = "no_title_match"
        candidates = [work for score, work in scored[:limit] if score >= max(0.65, best_score - 0.10)]
        return self._result(status, round(best_score, 4), candidates)

    @staticmethod
    def _empty(status: str) -> dict[str, Any]:
        return {
            "match_status": status,
            "match_score": 0.0,
            "palcc_title": "",
            "palcc_path": "",
            "palcc_work_id": "",
            "palcc_corpus_root": "",
            "candidate_count": 0,
            "candidate_titles": "",
            "candidate_paths": "",
        }

    def _result(self, status: str, score: float, candidates: list[CorpusWork]) -> dict[str, Any]:
        first = candidates[0] if candidates else None
        return {
            "match_status": status,
            "match_score": score,
            "palcc_title": first.title if first else "",
            "palcc_path": first.path if first else "",
            "palcc_work_id": first.work_id if first else "",
            "palcc_corpus_root": first.corpus_root if first else "",
            "candidate_count": len(candidates),
            "candidate_titles": " | ".join(work.title for work in candidates),
            "candidate_paths": " | ".join(work.path for work in candidates),
        }


class KanripoAnchorParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.href: str | None = None
        self.buffer: list[str] = []
        self.records: dict[str, str] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a":
            return
        attr = dict(attrs)
        href = attr.get("href") or ""
        if KANRIPO_ID_RE.search(href):
            self.href = href
            self.buffer = []

    def handle_data(self, data: str) -> None:
        if self.href is not None:
            self.buffer.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() != "a" or self.href is None:
            return
        target = self.href + " " + "".join(self.buffer)
        match = KANRIPO_ID_RE.search(target)
        if match:
            identifier = match.group(1).upper()
            title = " ".join("".join(self.buffer).split())
            title = re.sub(rf"\b{re.escape(identifier)}\b", "", title, flags=re.I).strip(" :-—–")
            if title and identifier not in self.records:
                self.records[identifier] = title
        self.href = None
        self.buffer = []


def clean_kanripo_catalog_label(label: str) -> tuple[str, str, str]:
    """Split catalogue labels like 周易註-魏-王弼 into title, period, author."""
    text = " ".join(clean_scalar(label).split()).strip(" |｜:-—–")
    if not text:
        return "", "", ""
    parts = [part.strip() for part in re.split(r"\s*-\s*", text)]
    if len(parts) >= 2 and CJK_TITLE_RE.search(parts[0]):
        title = parts[0]
        period = parts[1] if len(parts) >= 2 else ""
        author = "-".join(parts[2:]).strip("-") if len(parts) >= 3 else ""
    else:
        title, period, author = text, "", ""
    return title.strip(), period.strip(), author.strip()


def recover_kanripo_titles_from_raw_html(
    text: str, known: dict[str, str], labels: dict[str, str]
) -> dict[str, str]:
    """Recover titles when the ID and title live in adjacent table/list cells."""
    matches = list(KANRIPO_ID_RE.finditer(text))
    for pos, match in enumerate(matches):
        identifier = match.group(1).upper()
        if identifier in known:
            continue
        end = matches[pos + 1].start() if pos + 1 < len(matches) else min(len(text), match.end() + 1200)
        segment = text[match.end() : min(end, match.end() + 1200)]
        visible = html_lib.unescape(re.sub(r"<[^>]+>", "\n", segment))
        pieces = [" ".join(piece.split()).strip(" |｜:-—–") for piece in visible.splitlines()]
        pieces = [piece for piece in pieces if piece and CJK_TITLE_RE.search(piece)]
        if not pieces:
            continue
        raw_label = pieces[0][:240]
        title, _period, _author = clean_kanripo_catalog_label(raw_label)
        if title:
            known[identifier] = title
            labels.setdefault(identifier, raw_label)
    return known


def parse_kanripo(staging_root: Path, matcher: Matcher) -> list[dict[str, Any]]:
    source_root = staging_root / "kanripo"
    ids_path = source_root / "catalog_ids.txt"
    if not ids_path.exists():
        log("Kanripo inventory skipped: catalog_ids.txt not found.")
        return []
    all_ids = [line.strip().upper() for line in ids_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    titles: dict[str, str] = {}
    labels: dict[str, str] = {}
    for html_path in sorted((source_root / "catalog_pages").glob("*.html")):
        parser = KanripoAnchorParser()
        text = html_path.read_text(encoding="utf-8", errors="replace")
        try:
            parser.feed(text)
        except Exception:
            pass
        for identifier, label in parser.records.items():
            labels[identifier] = label
            title, _period, _author = clean_kanripo_catalog_label(label)
            if title:
                titles[identifier] = title
        # Fallback for catalogue tables where the ID and title are separate cells.
        recover_kanripo_titles_from_raw_html(text, titles, labels)
        # Final fallback: visible text snippets that already contain both ID + title.
        plain = html_lib.unescape(re.sub(r"<[^>]+>", "\n", text))
        for line in plain.splitlines():
            match = KANRIPO_ID_RE.search(line)
            if not match:
                continue
            identifier = match.group(1).upper()
            if identifier in titles:
                continue
            after = line[match.end() :].strip(" \t:-—–|｜")
            after = re.sub(r"\s+", " ", after)
            title, _period, _author = clean_kanripo_catalog_label(after)
            if title and CJK_TITLE_RE.search(title):
                titles[identifier] = title[:240]
                labels.setdefault(identifier, after[:240])

    rows: list[dict[str, Any]] = []
    for index, identifier in enumerate(all_ids, start=1):
        title = titles.get(identifier, "")
        label = labels.get(identifier, title)
        parsed_title, source_period, source_author = clean_kanripo_catalog_label(label)
        if parsed_title:
            title = parsed_title
        match = matcher.match(title)
        if match["match_status"] in {"exact_title", "exact_title_ambiguous", "strong_title_match"}:
            classification = "existing_work_or_edition_candidate"
        elif title and match["match_status"] in {"review_title_match"}:
            classification = "manual_title_review"
        elif title:
            classification = "probable_new_catalogue_work"
        else:
            classification = "catalogue_title_unresolved"
        row = {
            "source": "kanripo",
            "source_id": identifier,
            "source_title": title,
            "source_author": source_author,
            "source_period": source_period,
            "source_catalog_label": label,
            "source_url": f"https://www.kanripo.org/text/{identifier}",
            "has_text_payload": int((source_root / "works" / identifier / "source.json").exists()),
            "text_han_ratio": "",
            "classification": classification,
            **match,
        }
        rows.append(row)
        if index % 2000 == 0:
            log(f"Kanripo matching: {index:,}/{len(all_ids):,}")
    log(f"Kanripo inventory complete: {len(rows):,} catalogue records; {len(titles):,} titles recovered.")
    return rows


def decode_csv_bytes(data: bytes) -> str:
    for encoding in ("utf-8-sig", "utf-8", "cp932", "shift_jis"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def field_lookup(row: dict[str, Any], names: Iterable[str]) -> str:
    normalized = {unicodedata.normalize("NFKC", str(key)).strip().casefold(): clean_scalar(value) for key, value in row.items()}
    for name in names:
        value = normalized.get(unicodedata.normalize("NFKC", name).strip().casefold())
        if value:
            return value
    return ""


def parse_codh_metadata_zip(zip_path: Path) -> dict[str, dict[str, Any]]:
    records: dict[str, dict[str, Any]] = {}
    if not zip_path.exists():
        return records
    with zipfile.ZipFile(zip_path) as archive:
        csv_names = [name for name in archive.namelist() if name.lower().endswith((".csv", ".tsv")) and not name.endswith("/")]
        log(f"CODH metadata: {len(csv_names):,} tabular files in archive")
        for name in csv_names:
            data = archive.read(name)
            text = decode_csv_bytes(data)
            sample = text[:4096]
            delimiter = "\t" if name.lower().endswith(".tsv") else ","
            try:
                dialect = csv.Sniffer().sniff(sample, delimiters=",\t;")
                delimiter = dialect.delimiter
            except csv.Error:
                pass
            reader = csv.DictReader(io.StringIO(text), delimiter=delimiter)
            for row in reader:
                bib_id = field_lookup(row, [
                    "国文研書誌ID", "國文研書誌ID", "書誌ID", "bibliographic id", "bibliographic_id", "id",
                ])
                if not bib_id:
                    # Some files encode the ID in a filename/folder rather than a column.
                    match = BIB_ID_RE.search(name)
                    bib_id = match.group(1) if match else ""
                if not bib_id:
                    continue
                bib_id_match = BIB_ID_RE.search(bib_id)
                if bib_id_match:
                    bib_id = bib_id_match.group(1)
                title = field_lookup(row, ["統一書名", "統一書名等", "書名", "題名", "title", "work title"])
                author = field_lookup(row, ["著者名", "著者", "編著者", "author", "creator"])
                publication = field_lookup(row, ["出版事項", "刊年", "publication", "date"])
                note = field_lookup(row, ["注記", "備考", "略解題", "note", "description"])
                current = records.setdefault(
                    bib_id,
                    {
                        "bibliographic_id": bib_id,
                        "title": title,
                        "author": author,
                        "publication": publication,
                        "note": note,
                        "metadata_files": set(),
                    },
                )
                current["metadata_files"].add(name)
                if not current.get("title") and title:
                    current["title"] = title
                if not current.get("author") and author:
                    current["author"] = author
                if not current.get("publication") and publication:
                    current["publication"] = publication
                if not current.get("note") and note:
                    current["note"] = note
    return records


def extract_docx_text(data: bytes) -> str:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            xml = archive.read("word/document.xml")
        root = ET.fromstring(xml)
        pieces: list[str] = []
        for elem in root.iter():
            if elem.tag.endswith("}t") and elem.text:
                pieces.append(elem.text)
        return "".join(pieces)
    except Exception:
        return ""


def inventory_codh_payload(zip_path: Path, *, tags: bool = False) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = defaultdict(lambda: {"files": 0, "characters": 0, "han": 0})
    if not zip_path.exists():
        return result
    with zipfile.ZipFile(zip_path) as archive:
        names = [name for name in archive.namelist() if not name.endswith("/")]
        log(f"CODH {'tag' if tags else 'text'} payload: {len(names):,} files")
        for index, name in enumerate(names, start=1):
            id_match = BIB_ID_RE.search(name)
            bib_id = id_match.group(1) if id_match else ""
            if not bib_id:
                continue
            entry = result[bib_id]
            entry["files"] += 1
            if tags:
                continue
            lower = name.lower()
            text = ""
            if lower.endswith((".txt", ".csv", ".tsv", ".xml")):
                try:
                    text = decode_csv_bytes(archive.read(name))
                except Exception:
                    text = ""
            elif lower.endswith(".docx"):
                try:
                    text = extract_docx_text(archive.read(name))
                except Exception:
                    text = ""
            if text:
                entry["characters"] += len(text)
                entry["han"] += len(HAN_RE.findall(text))
            if index % 500 == 0:
                log(f"CODH payload scan: {index:,}/{len(names):,} archive entries")
    return result


def parse_codh(staging_root: Path, matcher: Matcher) -> list[dict[str, Any]]:
    raw = staging_root / "codh_japanese_classical_books" / "raw"
    metadata = parse_codh_metadata_zip(raw / "metadata.zip")
    text_info = inventory_codh_payload(raw / "text.zip", tags=False)
    tag_info = inventory_codh_payload(raw / "tag.zip", tags=True)
    all_ids = sorted(set(metadata) | set(text_info) | set(tag_info))
    rows: list[dict[str, Any]] = []
    for bib_id in all_ids:
        meta = metadata.get(bib_id, {})
        title = clean_scalar(meta.get("title"))
        author = clean_scalar(meta.get("author"))
        text_record = text_info.get(bib_id, {})
        text_chars = int(text_record.get("characters", 0) or 0)
        text_han = int(text_record.get("han", 0) or 0)
        ratio = round(text_han / text_chars, 4) if text_chars else ""
        match = matcher.match(title)
        has_text = int(bool(text_record.get("files")))
        if match["match_status"] in {"exact_title", "exact_title_ambiguous", "strong_title_match"}:
            classification = "existing_work_text_or_witness_candidate" if has_text else "existing_bibliographic_record"
        elif match["match_status"] == "review_title_match":
            classification = "manual_title_review"
        elif has_text and ratio != "" and float(ratio) >= 0.60:
            classification = "candidate_new_han_heavy_text"
        elif has_text:
            classification = "text_present_language_review"
        else:
            classification = "catalogue_only_no_palcc_match"
        rows.append(
            {
                "source": "codh",
                "source_id": bib_id,
                "source_title": title,
                "source_author": author,
                "source_url": f"https://codh.rois.ac.jp/pmjt/book/{bib_id}/",
                "has_text_payload": has_text,
                "text_han_ratio": ratio,
                "text_files": int(text_record.get("files", 0) or 0),
                "tag_files": int(tag_info.get(bib_id, {}).get("files", 0) or 0),
                "publication": clean_scalar(meta.get("publication")),
                "classification": classification,
                **match,
            }
        )
    log(f"CODH inventory complete: {len(rows):,} bibliographic IDs; {sum(int(row['has_text_payload']) for row in rows):,} with text payloads.")
    return rows


def parse_ud(staging_root: Path, matcher: Matcher) -> list[dict[str, Any]]:
    source_root = staging_root / "ud_classical_chinese"
    rows: list[dict[str, Any]] = []
    for treebank, titles in UD_KNOWN_WORKS.items():
        tb_root = source_root / treebank
        manifest = read_json(tb_root / "source.json", {}) or {}
        commit = clean_scalar(((manifest.get("upstream") or {}).get("commit")))
        archive_files = list((tb_root / "raw").glob("*.zip")) if (tb_root / "raw").is_dir() else []
        sentences = 0
        tokens = 0
        # Count actual harvested CoNLL-U data once; this does not try to assign
        # individual sentences to works because UD split files combine works.
        for archive_path in archive_files:
            try:
                with zipfile.ZipFile(archive_path) as archive:
                    for name in archive.namelist():
                        if not name.endswith(".conllu"):
                            continue
                        text = archive.read(name).decode("utf-8", errors="replace")
                        sentences += sum(1 for line in text.splitlines() if line.startswith("# sent_id"))
                        tokens += sum(
                            1 for line in text.splitlines()
                            if line and not line.startswith("#") and "\t" in line and line.split("\t", 1)[0].isdigit()
                        )
            except Exception as exc:
                log(f"UD archive warning ({archive_path.name}): {exc}")
        for title in titles:
            match = matcher.match(title)
            if match["match_status"] in {"exact_title", "exact_title_ambiguous", "strong_title_match"}:
                classification = "annotation_for_existing_work"
            elif match["match_status"] == "review_title_match":
                classification = "annotation_alignment_review"
            else:
                classification = "source_work_not_found_in_palcc"
            rows.append(
                {
                    "source": "ud",
                    "source_id": treebank,
                    "source_title": title,
                    "source_author": "",
                    "source_url": clean_scalar(((manifest.get("upstream") or {}).get("documentation"))),
                    "has_text_payload": int(bool(archive_files)),
                    "text_han_ratio": "",
                    "treebank_commit": commit,
                    "treebank_sentences": sentences,
                    "treebank_tokens": tokens,
                    "classification": classification,
                    **match,
                }
            )
    log(f"UD inventory complete: {len(rows):,} source-work alignment targets.")
    return rows


def project_identifier(project: dict[str, Any]) -> tuple[str, str]:
    for value in (project.get("path"), project.get("name"), project.get("path_with_namespace")):
        text = clean_scalar(value)
        # Work-level IDs contain digits too, so test W-... before the generic
        # bibliographic-number pattern.
        match = WORK_ID_RE.search(text)
        if match:
            return "work_id", match.group(1).upper()
        match = BIB_ID_RE.search(text)
        if match:
            return "bibliographic_id", match.group(1)
    return "", ""


def title_from_project(project: dict[str, Any]) -> str:
    for value in (project.get("description"), project.get("name")):
        text = clean_scalar(value)
        if not text:
            continue
        # Strip project IDs and generic OCR suffixes before deciding whether useful title text remains.
        text = BIB_ID_RE.sub("", text)
        text = WORK_ID_RE.sub("", text)
        text = re.sub(r"(?:_?text|OCR|テキスト|全文)", " ", text, flags=re.I)
        text = " ".join(text.split()).strip(" _-—–:：")
        if CJK_TITLE_RE.search(text):
            return text[:240]
    return ""


def parse_nijl(staging_root: Path, matcher: Matcher, codh_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    source_root = staging_root / "nijl_kokusho_ocr"
    codh_by_id = {clean_scalar(row.get("source_id")): row for row in codh_rows if clean_scalar(row.get("source_id"))}
    rows: list[dict[str, Any]] = []
    seen_projects: set[str] = set()
    for group in ("Kokusho", "Kokusho-Works"):
        payload = read_json(source_root / f"catalog-{group}.json", {}) or {}
        projects = payload.get("projects") or []
        if not isinstance(projects, list):
            continue
        for index, project in enumerate(projects, start=1):
            if not isinstance(project, dict):
                continue
            project_key = clean_scalar(project.get("path_with_namespace") or project.get("web_url") or project.get("id"))
            if project_key in seen_projects:
                continue
            seen_projects.add(project_key)
            id_kind, source_id = project_identifier(project)
            codh = codh_by_id.get(source_id) if id_kind == "bibliographic_id" else None
            project_title = title_from_project(project)
            title = clean_scalar((codh or {}).get("source_title")) or project_title
            match = matcher.match(title)
            if codh:
                if codh.get("match_status") in {"exact_title", "exact_title_ambiguous", "strong_title_match"}:
                    classification = "codh_linked_existing_work_ocr_project"
                elif codh.get("has_text_payload"):
                    classification = "codh_linked_candidate_new_work_ocr_project"
                else:
                    classification = "codh_linked_ocr_project"
            elif title and match["match_status"] in {"exact_title", "exact_title_ambiguous", "strong_title_match"}:
                classification = "title_linked_existing_work_ocr_project"
            elif title and match["match_status"] == "review_title_match":
                classification = "manual_title_review"
            elif title:
                classification = "titled_ocr_project_no_palcc_match"
            else:
                classification = "catalogue_project_unresolved"
            project_dir_name = project_key.replace("/", "__") if project_key else ""
            has_payload = int(bool(project_dir_name and (source_root / "projects" / project_dir_name / "source.json").exists()))
            rows.append(
                {
                    "source": "nijl",
                    "source_id": source_id,
                    "source_id_kind": id_kind,
                    "source_title": title,
                    "source_author": clean_scalar((codh or {}).get("source_author")),
                    "source_url": clean_scalar(project.get("web_url")),
                    "group": group,
                    "project": project_key,
                    "has_text_payload": has_payload,
                    "text_han_ratio": clean_scalar((codh or {}).get("text_han_ratio")),
                    "codh_linked": int(codh is not None),
                    "classification": classification,
                    **match,
                }
            )
            if index % 5000 == 0:
                log(f"NIJL {group} matching: {index:,}/{len(projects):,}")
    log(f"NIJL inventory complete: {len(rows):,} projects; {sum(int(row['codh_linked']) for row in rows):,} linked to CODH IDs.")
    return rows


COMMON_FIELDS = [
    "source", "source_id", "source_id_kind", "source_title", "source_author", "source_period", "source_catalog_label", "source_url",
    "classification", "has_text_payload", "text_han_ratio", "match_status", "match_score",
    "palcc_title", "palcc_path", "palcc_work_id", "palcc_corpus_root", "candidate_count",
    "candidate_titles", "candidate_paths", "text_files", "tag_files", "publication", "group",
    "project", "codh_linked", "treebank_commit", "treebank_sentences", "treebank_tokens",
]


def summarize_source(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "records": len(rows),
        "with_titles": sum(bool(clean_scalar(row.get("source_title"))) for row in rows),
        "with_text_payload": sum(bool(int(row.get("has_text_payload") or 0)) for row in rows),
        "match_status": dict(Counter(clean_scalar(row.get("match_status")) for row in rows)),
        "classifications": dict(Counter(clean_scalar(row.get("classification")) for row in rows)),
    }


def write_reports(output_dir: Path, works: list[CorpusWork], source_rows: dict[str, list[dict[str, Any]]], started_at: str) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    corpus_rows = [
        {
            "work_id": work.work_id,
            "corpus_root": work.corpus_root,
            "title": work.title,
            "display_title": work.display_title,
            "author": work.author,
            "path": work.path,
            "aliases": " | ".join(sorted(work.aliases)),
            "source_urls": " | ".join(sorted(work.source_urls)),
            "evidence_file_count": len(work.evidence_files),
        }
        for work in works
    ]
    write_csv(
        output_dir / "corpus_works.csv",
        corpus_rows,
        ["work_id", "corpus_root", "title", "display_title", "author", "path", "aliases", "source_urls", "evidence_file_count"],
    )

    all_rows: list[dict[str, Any]] = []
    for source, rows in source_rows.items():
        write_csv(output_dir / f"{source}_matches.csv", rows, COMMON_FIELDS)
        all_rows.extend(rows)
    write_csv(output_dir / "all_source_matches.csv", all_rows, COMMON_FIELDS)

    strong_status = {"exact_title", "exact_title_ambiguous", "strong_title_match"}
    strong = [row for row in all_rows if row.get("match_status") in strong_status]
    review = [
        row for row in all_rows
        if row.get("match_status") == "review_title_match"
        or "review" in clean_scalar(row.get("classification"))
        or row.get("match_status") == "source_title_missing"
    ]
    new_candidates = [
        row for row in all_rows
        if clean_scalar(row.get("classification")) in {
            "probable_new_catalogue_work",
            "candidate_new_han_heavy_text",
            "titled_ocr_project_no_palcc_match",
            "codh_linked_candidate_new_work_ocr_project",
            "source_work_not_found_in_palcc",
        }
    ]
    write_csv(output_dir / "strong_matches.csv", strong, COMMON_FIELDS)
    write_csv(output_dir / "needs_review.csv", review, COMMON_FIELDS)
    write_csv(output_dir / "new_candidates.csv", new_candidates, COMMON_FIELDS)

    summary = {
        "started_at": started_at,
        "finished_at": utc_now(),
        "status": "complete",
        "output_dir": str(output_dir),
        "corpus_works": len(works),
        "sources": {source: summarize_source(rows) for source, rows in source_rows.items()},
        "derived": {
            "strong_matches": len(strong),
            "needs_review": len(review),
            "new_candidates": len(new_candidates),
        },
        "important_note": (
            "Title matching is triage, not an ingestion decision. A title match can mean the same work, "
            "a different witness/edition, a commentary, or a related text. No corpus files were changed."
        ),
    }
    atomic_json(output_dir / "summary.json", summary)

    lines = [
        "FANYA HANWEN SOURCE INVENTORY",
        "=============================",
        "",
        f"Corpus work records: {len(works):,}",
        "",
    ]
    for source, data in summary["sources"].items():
        lines.append(f"{source.upper()}")
        lines.append(f"  records:           {data['records']:,}")
        lines.append(f"  source titles:     {data['with_titles']:,}")
        lines.append(f"  text payloads:     {data['with_text_payload']:,}")
        for status, count in sorted(data["match_status"].items()):
            lines.append(f"  {status:22s} {count:,}")
        lines.append("")
    lines.extend(
        [
            "DERIVED QUEUES",
            f"  strong_matches.csv: {len(strong):,}",
            f"  needs_review.csv:    {len(review):,}",
            f"  new_candidates.csv:  {len(new_candidates):,}",
            "",
            "No corpus files were changed.",
            "A title match is only a candidate relationship; witness/edition/content comparison comes next.",
            "",
        ]
    )
    (output_dir / "summary.txt").write_text("\n".join(lines), encoding="utf-8", newline="\n")
    return summary


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--staging-root", type=Path, required=True)
    parser.add_argument(
        "--quick-corpus-scan",
        action="store_true",
        help="Read metadata.json only. Default is an overnight-safe deep scan of current text headers too.",
    )
    parser.add_argument(
        "--sources",
        default="ud,codh,kanripo,nijl",
        help="Comma-separated source reports to build (default: ud,codh,kanripo,nijl).",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    install_signal_handlers()
    repo_root = args.repo_root.expanduser().resolve()
    staging_root = args.staging_root.expanduser().resolve()
    state_dir = staging_root / "_state"
    state_dir.mkdir(parents=True, exist_ok=True)
    started_at = utc_now()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_dir = staging_root / "_inventory" / stamp
    requested = [item.strip().lower() for item in args.sources.split(",") if item.strip()]
    valid = {"ud", "codh", "kanripo", "nijl"}
    unknown = sorted(set(requested) - valid)
    if unknown:
        raise SystemExit(f"Unknown inventory sources: {', '.join(unknown)}")

    state = {
        "started_at": started_at,
        "status": "running",
        "repo_root": str(repo_root),
        "staging_root": str(staging_root),
        "output_dir": str(output_dir),
        "sources_requested": requested,
        "deep_corpus_scan": not args.quick_corpus_scan,
    }
    atomic_json(state_dir / "last_inventory.json", state)

    try:
        log(f"Repository: {repo_root}")
        log(f"Staging:    {staging_root}")
        log(f"Output:     {output_dir}")
        log("Inventory is read-only: no PALCC files will be changed.")
        works = load_corpus_works(repo_root, deep=not args.quick_corpus_scan)
        matcher = Matcher(works)
        source_rows: dict[str, list[dict[str, Any]]] = {}

        codh_rows: list[dict[str, Any]] = []
        if "ud" in requested:
            source_rows["ud"] = parse_ud(staging_root, matcher)
        if "codh" in requested or "nijl" in requested:
            codh_rows = parse_codh(staging_root, matcher)
            if "codh" in requested:
                source_rows["codh"] = codh_rows
        if "kanripo" in requested:
            source_rows["kanripo"] = parse_kanripo(staging_root, matcher)
        if "nijl" in requested:
            source_rows["nijl"] = parse_nijl(staging_root, matcher, codh_rows)

        summary = write_reports(output_dir, works, source_rows, started_at)
        state.update(
            {
                "status": "complete",
                "finished_at": utc_now(),
                "summary": summary,
            }
        )
        atomic_json(state_dir / "last_inventory.json", state)
        log("Inventory complete.")
        log(f"Human summary: {output_dir / 'summary.txt'}")
        log(f"Review queue:  {output_dir / 'needs_review.csv'}")
        log(f"New candidates:{output_dir / 'new_candidates.csv'}")
        return 0
    except StopRequested:
        state.update({"status": "stopped", "finished_at": utc_now()})
        atomic_json(state_dir / "last_inventory.json", state)
        log("Inventory stopped by user request. Existing reports/snapshots are preserved.")
        return 130
    except Exception as exc:
        state.update({"status": "failed", "finished_at": utc_now(), "error": str(exc)})
        atomic_json(state_dir / "last_inventory.json", state)
        log(f"INVENTORY FAILED: {exc}")
        raise


if __name__ == "__main__":
    raise SystemExit(main())
