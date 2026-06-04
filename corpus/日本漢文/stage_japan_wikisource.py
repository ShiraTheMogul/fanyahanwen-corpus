#!/usr/bin/env python3
"""
Stage Japan / Japan-linked Hanwen files into a copied review tree.

This script is deliberately copy-only. It never moves or deletes files from the
source corpus. The intended workflow is:

1. Run this against the current working folder.
2. Review the staged output folder, manifest CSV, and summary Markdown.
3. If the staged tree is good, replace/import it manually yourself.

It follows the Korean staging script pattern:
- skips backups by default
- ignores WS_CATEGORIES entries containing 提及 for dating
- groups multi-file works together before deciding placement
- sends cross-period or unperiodised works to root-level 未分類
- places texts with a period but no safe region/domain under that period's 未分類
- considers region/domain folders only when they are already present in New system

Important distinction:
- period evidence decides the big bucket first: 倭/弥生時代, 日本/江戸時代, etc.
- region/domain evidence only adds a layer inside that period when safe.

Default destination pattern examples:
- 日本/江戸時代/水戸藩/<work>/...
- 日本/江戸時代/未分類/<work>/...
- 倭/古墳時代/未分類/<work>/...
- 大日本帝国/台灣/<work>/...
- 未分類/無年代/<work>/...
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

HEADER_RE = re.compile(r"^#\s*([^:]+):\s*(.*)$")
WS_YEAR_RE = re.compile(r"^(?:(前)(\d{1,4})|(\d{1,4}))年(?:\b|[^\d])")
DATE_YEAR_RE = re.compile(r"(?<!\d)(?:(前)(\d{1,4})|(\d{3,4}))(?:年|[-/.]|$)")

DEFAULT_EXCLUDE_DIRS = {
    "New system",
    "Staging",
    "need to rescrape",
    "__MACOSX",
    ".git",
}

BACKUP_SUFFIXES = (
    ".bak",
    ".bak2",
    ".orig",
    ".tmp",
)

# Bare year categories cannot tell month/day, so these can be set aside by
# default. Use --transition-policy conventional if you want standard period
# buckets to absorb them.
TRANSITION_YEARS = {
    250, 592, 710, 794, 1185, 1334, 1573, 1603, 1868, 1912, 1926, 1989, 2019,
}

# Period ranges use practical staging conventions rather than a claim about
# historical truth. Where a boundary is famously fuzzy, the manifest records it.
# start/end are inclusive.
PERIODS = [
    (-300, 249, "倭", "弥生時代", "弥生時代"),
    (250, 591, "倭", "古墳時代", "古墳時代"),
    (592, 709, "倭", "飛鳥時代", "飛鳥時代"),
    (710, 793, "日本", "奈良時代", "奈良時代"),
    (794, 1184, "日本", "平安時代", "平安時代"),
    (1185, 1333, "日本", "鎌倉時代", "鎌倉時代"),
    (1334, 1572, "日本", "室町時代", "室町時代"),
    (1573, 1602, "日本", "安土桃山時代", "安土桃山時代"),
    (1603, 1867, "日本", "江戸時代", "江戸時代"),
    (1868, 1911, "日本", "明治時代", "明治時代"),
    (1912, 1925, "日本", "大正時代", "大正時代"),
    (1926, 1988, "日本", "昭和時代", "昭和時代"),
    (1989, 2018, "日本", "平成時代", "平成時代"),
    (2019, 9999, "日本", "令和時代", "令和時代"),
]

TIMES_TO_PERIOD = {
    label: (root, period) for _start, _end, root, period, label in PERIODS
}

IMPERIAL_REGION_ALIASES = {
    "台灣": {"台灣", "臺灣", "台湾", "台湾総督府", "臺灣總督府"},
    "朝鮮": {"朝鮮", "韩国", "韓國", "韓国", "朝鮮總督府", "朝鮮総督府"},
    "滿洲國": {"滿洲國", "滿州國", "満洲国", "满洲国", "滿洲", "満洲", "满洲"},
    "蒙疆聯合自治政府": {"蒙疆聯合自治政府", "蒙疆联合自治政府", "蒙疆", "蒙古聯合自治政府"},
}

IMPERIAL_REGION_RANGES = {
    "台灣": (1895, 1945),
    "朝鮮": (1910, 1945),
    "滿洲國": (1932, 1945),
    "蒙疆聯合自治政府": (1939, 1945),
}

GENERIC_REGION_WORDS = {
    "日本", "倭", "大日本帝国", "大日本帝國", "漢文", "日本漢文", "日本漢詩", "未分類",
}


def split_ws_categories(value: str) -> List[str]:
    return [part.strip() for part in (value or "").split(";") if part.strip()]


def normalise_for_match(value: str) -> str:
    return (value or "").replace("臺", "台").replace("國", "国").strip()


def extract_years_from_ws_categories(value: str) -> Tuple[List[int], List[int]]:
    """Return (exact_years, mentioned_years).

    Exact means a WS category begins with a year, such as 1777年 or 前57年.
    Mentioned means the category contains 提及; it is recorded in the manifest
    but does not drive placement.
    """
    exact: List[int] = []
    mentioned: List[int] = []
    for part in split_ws_categories(value):
        m = WS_YEAR_RE.match(part)
        if not m:
            continue
        year = -int(m.group(2)) if m.group(1) else int(m.group(3))
        if "提及" in part:
            mentioned.append(year)
        else:
            exact.append(year)
    return exact, mentioned


def extract_years_from_date(value: str) -> List[int]:
    """Extract conservative Gregorian-style years from a DATE header."""
    years: List[int] = []
    for m in DATE_YEAR_RE.finditer(value or ""):
        if m.group(1):
            years.append(-int(m.group(2)))
        else:
            years.append(int(m.group(3)))
    return years


def parse_headers(text: str) -> Dict[str, str]:
    headers: Dict[str, str] = {}
    for line in text.splitlines():
        m = HEADER_RE.match(line)
        if m:
            headers[m.group(1).strip()] = m.group(2).strip()
            continue
        if not line.startswith("#"):
            break
    return headers


def period_from_year(year: int) -> Optional[Tuple[str, str, str]]:
    """Return (root, period, label) for a year, or None if unsupported."""
    for start, end, root, period, label in PERIODS:
        if start <= year <= end:
            return root, period, label
    return None


def is_transition_year(year: int) -> bool:
    return year in TRANSITION_YEARS


def is_within_imperial_region_range(region: str, year: int) -> bool:
    bounds = IMPERIAL_REGION_RANGES.get(region)
    if not bounds:
        return False
    start, end = bounds
    return start <= year <= end


def safe_parts(path: PurePosixPath) -> List[str]:
    return [p for p in path.parts if p not in {".", ""}]


def should_skip_path(parts: Sequence[str], include_bak: bool, exclude_dirs: set[str]) -> bool:
    if any(part in exclude_dirs for part in parts[:-1]):
        return True
    name = parts[-1] if parts else ""
    if not name.endswith(".txt"):
        return True
    if not include_bak and name.endswith(BACKUP_SUFFIXES):
        return True
    return False


@dataclass
class RegionIndex:
    """Available region/domain folders, read from New system."""

    # base period path -> {display region path -> aliases}
    by_base: Dict[str, Dict[str, set[str]]] = field(default_factory=lambda: defaultdict(dict))
    all_region_aliases: Dict[str, set[str]] = field(default_factory=lambda: defaultdict(set))
    known_classification_parts: set[str] = field(default_factory=set)

    def add_region(self, base: str, region_path: str) -> None:
        if not region_path or region_path in GENERIC_REGION_WORDS:
            return
        leaf = region_path.split("/")[-1]
        aliases = {region_path, leaf, normalise_for_match(region_path), normalise_for_match(leaf)}
        self.by_base[base][region_path] = aliases
        self.all_region_aliases[region_path].update(aliases)
        self.known_classification_parts.update(region_path.split("/"))

    def regions_for_base(self, base: str) -> Dict[str, set[str]]:
        return self.by_base.get(base, {})


def build_region_index(system_root: Optional[Path]) -> RegionIndex:
    """Read actual destination folders from New system.

    This keeps the script aligned with the folder tree you already made, instead
    of hardcoding every han/domain/prefecture here.
    """
    idx = RegionIndex()

    # Always seed imperial regions because they are central and shallow.
    for region in IMPERIAL_REGION_ALIASES:
        idx.add_region("大日本帝国", region)
        idx.all_region_aliases[region].update(IMPERIAL_REGION_ALIASES[region])

    if not system_root or not system_root.exists():
        return idx

    for root_dir in [p for p in system_root.iterdir() if p.is_dir()]:
        root_name = root_dir.name
        idx.known_classification_parts.add(root_name)
        for period_dir in [p for p in root_dir.iterdir() if p.is_dir()]:
            period_name = period_dir.name
            idx.known_classification_parts.add(period_name)
            base = f"{root_name}/{period_name}" if root_name != "大日本帝国" else root_name

            # For 大日本帝国, the immediate children are the region layer.
            if root_name == "大日本帝国":
                idx.add_region("大日本帝国", period_name)
                continue

            for child in [p for p in period_dir.iterdir() if p.is_dir()]:
                child_name = child.name
                idx.known_classification_parts.add(child_name)
                if child_name == "未分類":
                    continue
                idx.add_region(base, child_name)

                # Handle nested modern prefecture layer: 都道府県/東京都, etc.
                if child_name == "都道府県":
                    for grandchild in [p for p in child.iterdir() if p.is_dir()]:
                        idx.known_classification_parts.add(grandchild.name)
                        idx.add_region(base, f"都道府県/{grandchild.name}")

    return idx


@dataclass
class FileRecord:
    source_path: str
    relative_path: str
    output_tail: str
    work_key: str
    headers: Dict[str, str]
    exact_years: List[int]
    mentioned_years: List[int]
    date_years: List[int]
    times_period: Optional[str]
    text: str


@dataclass
class WorkDecision:
    work_key: str
    files: List[FileRecord] = field(default_factory=list)
    exact_year_counts: Counter = field(default_factory=Counter)
    mentioned_year_counts: Counter = field(default_factory=Counter)
    date_year_counts: Counter = field(default_factory=Counter)
    period_counts: Counter = field(default_factory=Counter)
    decided_root: Optional[str] = None
    decided_period: Optional[str] = None
    decided_base: Optional[str] = None
    decided_year: Optional[int] = None
    destination: str = "未分類/無年代"
    region: Optional[str] = None
    region_candidates: Counter = field(default_factory=Counter)
    imperial_region_candidates: Counter = field(default_factory=Counter)
    reason: str = ""
    warnings: List[str] = field(default_factory=list)


class InputReader:
    def __init__(self, input_path: Path, include_bak: bool, exclude_dirs: set[str]):
        self.input_path = input_path
        self.include_bak = include_bak
        self.exclude_dirs = exclude_dirs

    def iter_text_files(self) -> Iterable[Tuple[str, str]]:
        if self.input_path.is_dir():
            yield from self._iter_dir()
        else:
            yield from self._iter_zip()

    def _iter_dir(self) -> Iterable[Tuple[str, str]]:
        for path in self.input_path.rglob("*.txt"):
            rel_path = path.relative_to(self.input_path)
            parts = rel_path.parts
            if should_skip_path(parts, self.include_bak, self.exclude_dirs):
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            rel = str(PurePosixPath(*parts))
            yield rel, text

    def _iter_zip(self) -> Iterable[Tuple[str, str]]:
        with zipfile.ZipFile(self.input_path, "r") as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                parts = safe_parts(PurePosixPath(info.filename))
                if should_skip_path(parts, self.include_bak, self.exclude_dirs):
                    continue
                text = zf.read(info).decode("utf-8", "replace")
                yield str(PurePosixPath(*parts)), text


def strip_existing_classification_prefix(parts: List[str], idx: RegionIndex) -> List[str]:
    """Remove old destination-like prefix, keeping the work/page structure.

    Example:
    大日本帝国/台灣/五妃廟文/弔五妃墓/弔五妃墓.txt -> 五妃廟文/弔五妃墓/弔五妃墓.txt
    日本/江戸時代/水戸藩/foo.txt -> foo.txt or work path after classification

    This prevents duplicated paths like 日本/江戸時代/水戸藩/日本/江戸時代/水戸藩/foo.txt.
    """
    if not parts:
        return parts

    root = parts[0]
    if root in {"New system", "Staging"}:
        return strip_existing_classification_prefix(parts[1:], idx)

    if root == "大日本帝国":
        # root + imperial region
        if len(parts) >= 2:
            return parts[2:] or [parts[-1]]
        return parts[1:]

    if root in {"日本", "倭"} and len(parts) >= 2:
        # root + period + optional known region/domain/prefecture path
        rest = parts[2:]
        if rest:
            # Drop one simple region/domain layer if it is known.
            if rest[0] in idx.known_classification_parts:
                # Special nested layer: 都道府県/東京都
                if rest[0] == "都道府県" and len(rest) >= 2:
                    return rest[2:] or [parts[-1]]
                return rest[1:] or [parts[-1]]
        return rest or [parts[-1]]

    return parts


def work_key_from_tail(tail_parts: List[str]) -> str:
    """Group files by work folder; root-level txt files become their own work."""
    if len(tail_parts) <= 1:
        return Path(tail_parts[0]).stem if tail_parts else "(unknown)"
    return str(PurePosixPath(*tail_parts[:-1]))


def collect_records(input_path: Path, include_bak: bool, exclude_dirs: set[str], idx: RegionIndex) -> List[FileRecord]:
    records: List[FileRecord] = []
    reader = InputReader(input_path, include_bak, exclude_dirs)
    for rel, text in reader.iter_text_files():
        parts = safe_parts(PurePosixPath(rel))
        tail_parts = strip_existing_classification_prefix(parts, idx)
        if not tail_parts:
            tail_parts = [parts[-1]]
        tail = str(PurePosixPath(*tail_parts))
        headers = parse_headers(text)
        exact, mentioned = extract_years_from_ws_categories(headers.get("WS_CATEGORIES", ""))
        date_years = extract_years_from_date(headers.get("DATE", ""))
        times = headers.get("TIMES", "").strip()
        times_period = None
        if times in TIMES_TO_PERIOD:
            root, period = TIMES_TO_PERIOD[times]
            times_period = f"{root}/{period}"
        records.append(FileRecord(
            source_path=rel,
            relative_path=rel,
            output_tail=tail,
            work_key=work_key_from_tail(tail_parts),
            headers=headers,
            exact_years=exact,
            mentioned_years=mentioned,
            date_years=date_years,
            times_period=times_period,
            text=text,
        ))
    return records


def searchable_blob(rec: FileRecord) -> str:
    fields = [
        rec.relative_path,
        rec.output_tail,
        rec.headers.get("TITLE", ""),
        rec.headers.get("WORK_TITLE", ""),
        rec.headers.get("PAGE_TITLE", ""),
        rec.headers.get("AUTHOR", ""),
        rec.headers.get("NATION", ""),
        rec.headers.get("TIMES", ""),
        rec.headers.get("CATEGORIES", ""),
        rec.headers.get("WS_CATEGORIES", ""),
    ]
    return "\n".join(fields)


def find_imperial_region_candidates(wd: WorkDecision) -> Counter:
    counts: Counter = Counter()
    for rec in wd.files:
        blob = searchable_blob(rec)
        blob_norm = normalise_for_match(blob)
        for region, aliases in IMPERIAL_REGION_ALIASES.items():
            for alias in aliases:
                if alias and (alias in blob or normalise_for_match(alias) in blob_norm):
                    counts[region] += 1
                    break
    return counts


def find_region_candidates(wd: WorkDecision, idx: RegionIndex, base: str) -> Counter:
    counts: Counter = Counter()
    possible = idx.regions_for_base(base)
    if not possible:
        return counts

    for rec in wd.files:
        blob = searchable_blob(rec)
        blob_norm = normalise_for_match(blob)
        for region_path, aliases in possible.items():
            if region_path in GENERIC_REGION_WORDS:
                continue
            for alias in aliases:
                if not alias or alias in GENERIC_REGION_WORDS:
                    continue
                alias_norm = normalise_for_match(alias)
                if alias in blob or alias_norm in blob_norm:
                    counts[region_path] += 1
                    break
    return counts


def decide_works(records: List[FileRecord], idx: RegionIndex, mixed_policy: str, transition_policy: str) -> Dict[str, WorkDecision]:
    works: Dict[str, WorkDecision] = {}
    for rec in records:
        wd = works.setdefault(rec.work_key, WorkDecision(work_key=rec.work_key))
        wd.files.append(rec)
        for y in rec.exact_years:
            wd.exact_year_counts[y] += 1
            p = period_from_year(y)
            if p:
                root, period, _label = p
                wd.period_counts[f"{root}/{period}"] += 1
            else:
                wd.period_counts["out_of_defined_ranges"] += 1
        for y in rec.mentioned_years:
            wd.mentioned_year_counts[y] += 1
        for y in rec.date_years:
            wd.date_year_counts[y] += 1
            # DATE is weaker than WS exact categories, so only used if no WS years.
            if not wd.exact_year_counts:
                p = period_from_year(y)
                if p:
                    root, period, _label = p
                    wd.period_counts[f"{root}/{period}"] += 1
        if rec.times_period and not wd.exact_year_counts and not wd.date_year_counts:
            wd.period_counts[rec.times_period] += 1

    for wd in works.values():
        decide_one_work(wd, idx, mixed_policy, transition_policy)
    return works


def decide_one_work(wd: WorkDecision, idx: RegionIndex, mixed_policy: str, transition_policy: str) -> None:
    if not wd.period_counts:
        wd.destination = "未分類/無年代"
        wd.reason = "no usable WS_CATEGORIES year, DATE year, or exact TIMES period"
        return

    period_keys = [key for key in wd.period_counts if key != "out_of_defined_ranges"]
    if not period_keys:
        wd.destination = "未分類/out_of_defined_ranges"
        wd.reason = "year evidence outside defined Japanese period ranges"
        return

    if len(set(period_keys)) > 1 and mixed_policy == "review":
        wd.destination = "未分類/跨期年份需核"
        wd.reason = "work has evidence crossing multiple period buckets"
        return

    chosen_base = Counter({k: wd.period_counts[k] for k in period_keys}).most_common(1)[0][0]
    root, period = chosen_base.split("/", 1)
    wd.decided_root = root
    wd.decided_period = period
    wd.decided_base = chosen_base

    # Pick a representative year, preferring WS exact years over DATE years.
    year_counter = wd.exact_year_counts or wd.date_year_counts
    if year_counter:
        eligible = Counter()
        for y, count in year_counter.items():
            p = period_from_year(y)
            if p and f"{p[0]}/{p[1]}" == chosen_base:
                eligible[y] += count
        if eligible:
            wd.decided_year = eligible.most_common(1)[0][0]

    if wd.decided_year is not None and is_transition_year(wd.decided_year):
        wd.warnings.append(f"boundary year: {wd.decided_year}")
        if transition_policy == "review":
            wd.destination = "未分類/境界年需核"
            wd.reason = "bare year is a period boundary; month/day needed for confident placement"
            return

    # Imperial territories override ordinary Meiji/Taisho/Showa period only if
    # region evidence is clear and the year is inside the colonial/state range.
    wd.imperial_region_candidates = find_imperial_region_candidates(wd)
    if wd.decided_year is not None and wd.imperial_region_candidates:
        plausible = Counter({
            region: count
            for region, count in wd.imperial_region_candidates.items()
            if is_within_imperial_region_range(region, wd.decided_year)
        })
        if len(plausible) == 1:
            region = next(iter(plausible))
            wd.region = region
            wd.destination = f"大日本帝国/{region}"
            wd.reason = "period from year; imperial region from categories/path/header"
            return
        if len(plausible) > 1:
            wd.destination = f"{chosen_base}/未分類"
            wd.reason = "period from year; multiple imperial region candidates"
            wd.warnings.append("ambiguous imperial region candidates")
            return

    wd.region_candidates = find_region_candidates(wd, idx, chosen_base)
    if len(wd.region_candidates) == 1:
        region_path = next(iter(wd.region_candidates))
        wd.region = region_path
        wd.destination = f"{chosen_base}/{region_path}"
        wd.reason = "period from year; region/domain from categories/path/header"
    elif len(wd.region_candidates) > 1:
        wd.destination = f"{chosen_base}/未分類"
        wd.reason = "period from year; multiple possible region/domain matches"
        wd.warnings.append("ambiguous region/domain candidates")
    else:
        wd.destination = f"{chosen_base}/未分類"
        wd.reason = "period from year; no safe region/domain evidence"


def rewrite_metadata(text: str, wd: WorkDecision, update_times: bool, update_nation: bool) -> str:
    """Optionally fill blank TIMES/NATION lines only; do not clobber real data."""
    if not (update_times or update_nation):
        return text

    lines = text.splitlines()
    out: List[str] = []
    in_header = True
    saw_times = False
    saw_nation = False
    inserted_times = False
    inserted_nation = False

    times_value = wd.decided_period
    nation_value = None
    if wd.destination.startswith("倭/"):
        nation_value = "倭"
    elif wd.destination.startswith("日本/"):
        nation_value = "日本"
    elif wd.destination.startswith("大日本帝国/"):
        # Keep territory/polity in NATION; imperial period can be TIMES.
        nation_value = wd.region
        times_value = "大日本帝国"

    for line in lines:
        if in_header and not line.startswith("#"):
            if update_nation and nation_value and not saw_nation and not inserted_nation:
                out.append(f"# NATION: {nation_value}")
                inserted_nation = True
            if update_times and times_value and not saw_times and not inserted_times:
                out.append(f"# TIMES: {times_value}")
                inserted_times = True
            in_header = False

        if in_header:
            m = HEADER_RE.match(line)
            if m:
                key = m.group(1).strip()
                value = m.group(2).strip()
                if key == "NATION":
                    saw_nation = True
                    if update_nation and nation_value and value in {"", "日本漢文", "日本漢詩", "朝鮮典籍"}:
                        out.append(f"# NATION: {nation_value}")
                        continue
                if key == "TIMES":
                    saw_times = True
                    if update_times and times_value and not value:
                        out.append(f"# TIMES: {times_value}")
                        continue
        out.append(line)

    if update_nation and nation_value and not saw_nation and not inserted_nation:
        for i, line in enumerate(out):
            if not line.startswith("#"):
                out.insert(i, f"# NATION: {nation_value}")
                break
        else:
            out.append(f"# NATION: {nation_value}")

    if update_times and times_value and not saw_times and not inserted_times:
        insert_at = 0
        for i, line in enumerate(out):
            if not line.startswith("#"):
                insert_at = i
                break
        else:
            insert_at = len(out)
        out.insert(insert_at, f"# TIMES: {times_value}")

    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def staged_rel(rec: FileRecord, wd: WorkDecision) -> str:
    return str(PurePosixPath(wd.destination) / PurePosixPath(rec.output_tail))


def write_outputs(records: List[FileRecord], works: Dict[str, WorkDecision], out_dir: Optional[Path], out_zip: Optional[Path], update_times: bool, update_nation: bool) -> None:
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
    zf = zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) if out_zip else None
    try:
        for rec in records:
            wd = works[rec.work_key]
            rel = staged_rel(rec, wd)
            text = rewrite_metadata(rec.text, wd, update_times=update_times, update_nation=update_nation)
            if out_dir:
                target = out_dir / Path(*PurePosixPath(rel).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding="utf-8")
            if zf:
                zf.writestr(rel, text)
    finally:
        if zf:
            zf.close()


def write_manifest(records: List[FileRecord], works: Dict[str, WorkDecision], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        fieldnames = [
            "row", "source_path", "staged_path", "work_key", "work_title", "page_title", "author",
            "exact_years", "mentioned_years", "date_years", "decision_year", "decision_base",
            "destination", "region", "region_candidates", "imperial_region_candidates",
            "reason", "warnings", "ws_categories",
        ]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row, rec in enumerate(records, start=1):
            wd = works[rec.work_key]
            writer.writerow({
                "row": row,
                "source_path": rec.source_path,
                "staged_path": staged_rel(rec, wd),
                "work_key": rec.work_key,
                "work_title": rec.headers.get("WORK_TITLE", ""),
                "page_title": rec.headers.get("PAGE_TITLE", ""),
                "author": rec.headers.get("AUTHOR", ""),
                "exact_years": "|".join(map(str, sorted(set(rec.exact_years)))),
                "mentioned_years": "|".join(map(str, sorted(set(rec.mentioned_years)))),
                "date_years": "|".join(map(str, sorted(set(rec.date_years)))),
                "decision_year": wd.decided_year or "",
                "decision_base": wd.decided_base or "",
                "destination": wd.destination,
                "region": wd.region or "",
                "region_candidates": json.dumps(dict(wd.region_candidates), ensure_ascii=False),
                "imperial_region_candidates": json.dumps(dict(wd.imperial_region_candidates), ensure_ascii=False),
                "reason": wd.reason,
                "warnings": " | ".join(wd.warnings),
                "ws_categories": rec.headers.get("WS_CATEGORIES", ""),
            })


def write_summary(records: List[FileRecord], works: Dict[str, WorkDecision], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    file_dest_counts = Counter()
    work_dest_counts = Counter()
    warnings = []
    no_period = []
    no_region = []
    ambiguous = []

    for rec in records:
        file_dest_counts[works[rec.work_key].destination] += 1
    for wd in works.values():
        work_dest_counts[wd.destination] += 1
        if wd.destination.startswith("未分類/"):
            no_period.append(wd)
        if wd.destination.endswith("/未分類"):
            no_region.append(wd)
        if wd.warnings:
            warnings.append(wd)
        if "multiple" in wd.reason or "crossing" in wd.reason:
            ambiguous.append(wd)

    lines: List[str] = []
    lines.append("# Japan staging report")
    lines.append("")
    lines.append(f"Files scanned: {len(records)}")
    lines.append(f"Work units scanned: {len(works)}")
    lines.append("")
    lines.append("## Work destinations")
    for dest, count in work_dest_counts.most_common():
        lines.append(f"- {dest}: {count} works")
    lines.append("")
    lines.append("## File destinations")
    for dest, count in file_dest_counts.most_common():
        lines.append(f"- {dest}: {count} files")
    lines.append("")
    lines.append("## Periodised but region/domain unresolved")
    for wd in sorted(no_region, key=lambda w: w.work_key)[:300]:
        year = wd.decided_year if wd.decided_year is not None else ""
        lines.append(f"- {wd.work_key}: {wd.decided_base}; year {year}; files {len(wd.files)}")
    if len(no_region) > 300:
        lines.append(f"- ... {len(no_region) - 300} more omitted; see CSV manifest")
    lines.append("")
    lines.append("## Not periodised / sent to root 未分類")
    for wd in sorted(no_period, key=lambda w: w.work_key)[:300]:
        years = ", ".join(map(str, sorted(wd.exact_year_counts or wd.date_year_counts)))
        lines.append(f"- {wd.work_key}: {wd.destination}; years {years}; reason {wd.reason}; files {len(wd.files)}")
    if len(no_period) > 300:
        lines.append(f"- ... {len(no_period) - 300} more omitted; see CSV manifest")
    lines.append("")
    lines.append("## Warnings / ambiguity")
    warning_map = {wd.work_key: wd for wd in warnings + ambiguous}
    warning_list = sorted(warning_map.values(), key=lambda w: w.work_key)
    for wd in warning_list[:300]:
        lines.append(f"- {wd.work_key}: {wd.destination}; {wd.reason}; {' | '.join(wd.warnings)}")
    if len(warning_list) > 300:
        lines.append(f"- ... {len(warning_list) - 300} more omitted; see CSV manifest")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Copy-stage Japanese Hanwen files into the new period/domain tree for review.")
    ap.add_argument("input", type=Path, help="Source directory or zip, e.g. corpus/日本漢文/clean")
    ap.add_argument("--system-root", type=Path, help="Destination model folder, usually clean/New system")
    ap.add_argument("--out-dir", type=Path, help="Copied staged review tree. Nothing is written unless this or --out-zip is set.")
    ap.add_argument("--out-zip", type=Path, help="Optional zip of the staged review tree")
    ap.add_argument("--manifest", type=Path, default=Path("japan_staging_manifest.csv"), help="CSV manifest path")
    ap.add_argument("--summary", type=Path, default=Path("japan_staging_summary.md"), help="Markdown summary path")
    ap.add_argument("--include-bak", action="store_true", help="Include backup-like txt files; off by default")
    ap.add_argument("--exclude", action="append", default=[], help="Extra top-level/source directory name to exclude; may be repeated")
    ap.add_argument("--mixed-policy", choices=["review", "dominant"], default="review", help="What to do when one work spans multiple periods")
    ap.add_argument("--transition-policy", choices=["review", "conventional"], default="review", help="What to do with bare boundary years like 1868 or 1912")
    ap.add_argument("--update-times", action="store_true", help="Fill blank/missing TIMES in copied files when safely decided")
    ap.add_argument("--update-nation", action="store_true", help="Fill blank/generic NATION in copied files when safely decided")
    args = ap.parse_args()

    exclude_dirs = set(DEFAULT_EXCLUDE_DIRS)
    exclude_dirs.update(args.exclude)

    idx = build_region_index(args.system_root)
    records = collect_records(args.input, include_bak=args.include_bak, exclude_dirs=exclude_dirs, idx=idx)
    works = decide_works(records, idx=idx, mixed_policy=args.mixed_policy, transition_policy=args.transition_policy)

    write_manifest(records, works, args.manifest)
    write_summary(records, works, args.summary)

    if args.out_dir or args.out_zip:
        write_outputs(records, works, args.out_dir, args.out_zip, update_times=args.update_times, update_nation=args.update_nation)

    print(f"Scanned {len(records)} .txt files in {len(works)} work units")
    print(f"Wrote manifest: {args.manifest}")
    print(f"Wrote summary: {args.summary}")
    if args.out_dir:
        print(f"Wrote staged review tree: {args.out_dir}")
    if args.out_zip:
        print(f"Wrote staged zip: {args.out_zip}")
    if not args.out_dir and not args.out_zip:
        print("No staged files written because neither --out-dir nor --out-zip was set")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
