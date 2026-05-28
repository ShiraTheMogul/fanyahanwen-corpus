#!/usr/bin/env python3
"""
Stage Korean Wikisource-derived Hanwen files by period using WS_CATEGORIES year tags.

Default behaviour is cautious:
- skips .bak files
- ignores WS_CATEGORIES entries containing 提及
- groups files by work folder so multi-juan works stay together
- sends cross-period works to 待分類/跨期年份需核 unless --mixed-policy dominant is used
- replaces only the bogus '# NATION: 朝鮮典籍' line when a safe destination nation is known
- treats 1897, 1910, and 1945 as transition years when only a bare year is known

Folder model used here:
- 三國/高句麗, 三國/百濟, 三國/新羅
- 三韓一統
- 後三國時代
- 渤海
- 高麗 and 高麗/征東行省期
- 朝鮮王朝
- 大韓帝國
- 大日本帝國/朝鮮
- 近現代/待分類
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import shutil
import sys
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List, Optional, Tuple

YEAR_RE = re.compile(r"^(?:(前)(\d{1,4})|(\d{1,4}))年(?:\b|[^\d])")
HEADER_RE = re.compile(r"^#\s*([^:]+):\s*(.*)$")


def split_ws_categories(value: str) -> List[str]:
    return [part.strip() for part in (value or "").split(";") if part.strip()]


def extract_years_from_ws_categories(value: str) -> Tuple[List[int], List[int]]:
    """Return (exact_dating_years, mentioned_years).

    Exact means the category starts with e.g. '1777年' or '1745年方志'.
    Mentioned means the category contains '提及', e.g. '371年 (提及)'.
    The latter is useful evidence but must not drive folder placement.
    """
    exact: List[int] = []
    mentioned: List[int] = []
    for part in split_ws_categories(value):
        m = YEAR_RE.match(part)
        if not m:
            continue
        if m.group(1):
            year = -int(m.group(2))
        else:
            year = int(m.group(3))
        if "提及" in part:
            mentioned.append(year)
        else:
            exact.append(year)
    return exact, mentioned


def period_labels_for_year(y: int) -> List[str]:
    """Return all historically plausible labels for a year.

    This is intentionally allowed to return overlaps, because some periods
    coexist territorially or politically. The coarse classifier below chooses
    a single practical staging bucket for simple folder counts.
    """
    labels: List[str] = []

    # Three Kingdoms and overlapping early polities.
    if -37 <= y <= 668:
        labels.append("三國/高句麗")
    if -18 <= y <= 660:
        labels.append("三國/百濟")
    if -67 <= y <= 667:
        labels.append("三國/新羅")

    # Post-Three-Kingdoms / north-south and late-Silla overlap.
    if 668 <= y <= 889:
        labels.append("三韓一統")
    if 890 <= y <= 936:
        labels.append("後三國時代")
    if 696 <= y <= 936:
        labels.append("渤海")

    # Goryeo, with the Mongol/Yuan-linked征東行省 period separated.
    if 918 <= y <= 1269:
        labels.append("高麗")
    if 1270 <= y <= 1356:
        labels.append("高麗/征東行省期")
    if 1357 <= y <= 1391:
        labels.append("高麗")

    # Dynastic and modern transitions. Bare year categories cannot tell us
    # whether a text falls before or after an event inside the year.
    if y == 1392:
        labels.append("1392 transition: 高麗/朝鮮王朝")
    if 1393 <= y <= 1896:
        labels.append("朝鮮王朝")
    if y == 1897:
        labels.append("1897 transition: 朝鮮王朝/大韓帝國")
    if 1898 <= y <= 1909:
        labels.append("大韓帝國")
    if y == 1910:
        labels.append("1910 transition: 大韓帝國/大日本帝國朝鮮")
    if 1911 <= y <= 1944:
        labels.append("大日本帝國/朝鮮")
    if y == 1945:
        labels.append("1945 transition: 大日本帝國朝鮮/近現代")
    if y >= 1946:
        labels.append("近現代/待分類")

    return labels or ["out_of_defined_ranges"]


def coarse_from_year(y: int) -> str:
    """Return one practical staging bucket for a bare exact-year category."""
    if 1911 <= y <= 1944:
        return "大日本帝國/朝鮮"
    if y == 1945:
        return "1945 transition"
    if y == 1910:
        return "1910 transition"
    if 1898 <= y <= 1909:
        return "大韓帝國"
    if y == 1897:
        return "1897 transition"
    if 1393 <= y <= 1896:
        return "朝鮮王朝"
    if y == 1392:
        return "1392 transition"
    if 1270 <= y <= 1356:
        return "高麗/征東行省期"
    if 918 <= y <= 1391:
        return "高麗"
    if 890 <= y <= 936:
        return "後三國時代/overlap"
    if 668 <= y <= 889:
        return "三韓一統/渤海 overlap possible"
    if 696 <= y <= 936:
        return "渤海/overlap possible"
    if -67 <= y <= 667:
        return "三國"
    if y >= 1946:
        return "近現代/待分類"
    return "out_of_defined_ranges"


def destination_for_coarse(coarse: str) -> Tuple[str, Optional[str], Optional[str]]:
    """Return (destination_folder, nation_value, times_value).

    Metadata policy:
    - clear dynastic/polity buckets get NATION updated directly;
    - Japanese colonial Korea is staged under 大日本帝國/朝鮮, with
      NATION: 朝鮮 and TIMES: 大日本帝國, matching the Taiwan-style
      separation between territory and imperial period;
    - transition and overlap buckets do not force NATION.
    """
    table = {
        "三國": ("三國/待判定", None, "三國"),
        "三韓一統/渤海 overlap possible": ("待分類/三韓一統_渤海重疊", None, "三韓一統/渤海 overlap possible"),
        "渤海/overlap possible": ("待分類/渤海_重疊", "渤海", None),
        "後三國時代/overlap": ("後三國時代", None, "後三國時代"),
        "高麗": ("高麗", "高麗", None),
        "高麗/征東行省期": ("高麗/征東行省期", "高麗", "征東行省期"),
        "1392 transition": ("待分類/1392_高麗_朝鮮王朝_transition", None, "1392 transition"),
        "朝鮮王朝": ("朝鮮王朝", "朝鮮王朝", None),
        "1897 transition": ("待分類/1897_朝鮮王朝_大韓帝國_transition", None, "1897 transition"),
        "大韓帝國": ("大韓帝國", "大韓帝國", None),
        "1910 transition": ("待分類/1910_大韓帝國_大日本帝國朝鮮_transition", None, "1910 transition"),
        "大日本帝國/朝鮮": ("大日本帝國/朝鮮", "朝鮮", "大日本帝國"),
        "1945 transition": ("待分類/1945_大日本帝國朝鮮_近現代_transition", None, "1945 transition"),
        "近現代/待分類": ("近現代/待分類", None, "近現代/待分類"),
        "out_of_defined_ranges": ("待分類/out_of_defined_ranges", None, None),
        "no_exact_year": ("待分類/無年份", None, None),
        "mixed_coarse": ("待分類/跨期年份需核", None, None),
    }
    return table.get(coarse, (f"待分類/{coarse}", None, None))


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


def rewrite_metadata(text: str, nation: Optional[str], times: Optional[str], update_nation: bool, add_times: bool) -> str:
    if not (update_nation or add_times):
        return text
    lines = text.splitlines()
    out: List[str] = []
    in_header = True
    saw_nation = False
    saw_times = False
    inserted_times = False
    for line in lines:
        if in_header and not line.startswith("#"):
            if add_times and times and not saw_times and not inserted_times:
                out.append(f"# TIMES: {times}")
                inserted_times = True
            in_header = False
        if in_header:
            m = HEADER_RE.match(line)
            if m:
                key = m.group(1).strip()
                value = m.group(2).strip()
                if key == "NATION":
                    saw_nation = True
                    if update_nation and nation and value == "朝鮮典籍":
                        out.append(f"# NATION: {nation}")
                        continue
                if key == "TIMES":
                    saw_times = True
                    if add_times and times and not value:
                        out.append(f"# TIMES: {times}")
                        continue
        out.append(line)
    # If file had no body or no non-header line, append TIMES at end of header.
    if add_times and times and not saw_times and not inserted_times:
        # Find first non-header insertion point.
        for i, line in enumerate(out):
            if not line.startswith("#"):
                out.insert(i, f"# TIMES: {times}")
                break
        else:
            out.append(f"# TIMES: {times}")
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


@dataclass
class FileRecord:
    source_path: str
    relative_path: str
    work_folder: str
    headers: Dict[str, str]
    exact_years: List[int]
    mentioned_years: List[int]
    text: Optional[str] = None


@dataclass
class WorkDecision:
    work_folder: str
    files: List[FileRecord] = field(default_factory=list)
    exact_year_counts: Counter = field(default_factory=Counter)
    coarse_counts: Counter = field(default_factory=Counter)
    decision_coarse: str = "no_exact_year"
    decision_year: Optional[int] = None
    destination: str = "待分類/無年份"
    nation: Optional[str] = None
    times: Optional[str] = None
    reason: str = ""


def iter_zip_records(zip_path: Path, include_bak: bool) -> Iterable[FileRecord]:
    with zipfile.ZipFile(zip_path, "r") as z:
        for info in z.infolist():
            name = info.filename
            if info.is_dir() or not name.endswith(".txt"):
                continue
            if not include_bak and name.endswith(".txt.bak"):
                continue
            text = z.read(info).decode("utf-8", "replace")
            parts = PurePosixPath(name).parts
            # Drop the outer archive folder if present.
            if len(parts) > 1 and parts[0] == "朝鮮典籍":
                rel_parts = parts[1:]
            else:
                rel_parts = parts
            if len(rel_parts) < 2:
                work_folder = rel_parts[0]
            else:
                work_folder = rel_parts[0]
            rel = str(PurePosixPath(*rel_parts))
            h = parse_headers(text)
            exact, mentioned = extract_years_from_ws_categories(h.get("WS_CATEGORIES", ""))
            yield FileRecord(name, rel, work_folder, h, exact, mentioned, text)


def decide_works(records: List[FileRecord], mixed_policy: str) -> Dict[str, WorkDecision]:
    works: Dict[str, WorkDecision] = {}
    for rec in records:
        wd = works.setdefault(rec.work_folder, WorkDecision(work_folder=rec.work_folder))
        wd.files.append(rec)
        for y in rec.exact_years:
            wd.exact_year_counts[y] += 1
            wd.coarse_counts[coarse_from_year(y)] += 1

    for wd in works.values():
        if not wd.exact_year_counts:
            wd.decision_coarse = "no_exact_year"
            wd.reason = "no exact non-提及 year in WS_CATEGORIES"
        elif len(wd.coarse_counts) > 1 and mixed_policy == "review":
            wd.decision_coarse = "mixed_coarse"
            wd.reason = "exact WS_CATEGORIES years cross coarse periods; manual review needed"
        else:
            # Dominant coarse, then dominant exact year inside it.
            wd.decision_coarse = wd.coarse_counts.most_common(1)[0][0]
            eligible_years = [y for y, count in wd.exact_year_counts.items() if coarse_from_year(y) == wd.decision_coarse]
            wd.decision_year = Counter({y: wd.exact_year_counts[y] for y in eligible_years}).most_common(1)[0][0]
            wd.reason = "dominant exact non-提及 WS_CATEGORIES year"
        wd.destination, wd.nation, wd.times = destination_for_coarse(wd.decision_coarse)
    return works


def write_outputs(records: List[FileRecord], works: Dict[str, WorkDecision], out_dir: Optional[Path], out_zip: Optional[Path], update_nation: bool, add_times: bool) -> None:
    def staged_rel(rec: FileRecord) -> str:
        wd = works[rec.work_folder]
        return str(PurePosixPath(wd.destination) / PurePosixPath(rec.relative_path))

    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
    zf = zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) if out_zip else None
    try:
        for rec in records:
            wd = works[rec.work_folder]
            rel = staged_rel(rec)
            text = rec.text or ""
            text = rewrite_metadata(text, wd.nation, wd.times, update_nation, add_times)
            if out_dir:
                path = out_dir / Path(*PurePosixPath(rel).parts)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            if zf:
                zf.writestr(rel, text)
    finally:
        if zf:
            zf.close()


def write_manifest(records: List[FileRecord], works: Dict[str, WorkDecision], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "source_path", "staged_path", "work_folder", "work_title", "page_title",
            "exact_years", "mentioned_years", "decision_year", "decision_coarse", "all_coarse_counts",
            "destination", "nation", "times", "reason", "ws_categories"
        ])
        writer.writeheader()
        for rec in records:
            wd = works[rec.work_folder]
            staged = str(PurePosixPath(wd.destination) / PurePosixPath(rec.relative_path))
            writer.writerow({
                "source_path": rec.source_path,
                "staged_path": staged,
                "work_folder": rec.work_folder,
                "work_title": rec.headers.get("WORK_TITLE", ""),
                "page_title": rec.headers.get("PAGE_TITLE", ""),
                "exact_years": "|".join(map(str, sorted(set(rec.exact_years)))),
                "mentioned_years": "|".join(map(str, sorted(set(rec.mentioned_years)))),
                "decision_year": wd.decision_year or "",
                "decision_coarse": wd.decision_coarse,
                "all_coarse_counts": json.dumps(dict(wd.coarse_counts), ensure_ascii=False),
                "destination": wd.destination,
                "nation": wd.nation or "",
                "times": wd.times or "",
                "reason": wd.reason,
                "ws_categories": rec.headers.get("WS_CATEGORIES", ""),
            })


def write_summary(records: List[FileRecord], works: Dict[str, WorkDecision], path: Path) -> None:
    file_counts = Counter()
    work_counts = Counter()
    bogus_nations = Counter(rec.headers.get("NATION", "") for rec in records)
    for rec in records:
        file_counts[works[rec.work_folder].decision_coarse] += 1
    for wd in works.values():
        work_counts[wd.decision_coarse] += 1
    mixed = [wd for wd in works.values() if wd.decision_coarse == "mixed_coarse"]
    pre_joseon = [wd for wd in works.values() if wd.decision_coarse in {"高麗", "高麗/征東行省期", "三國", "後三國時代/overlap", "三韓一統/渤海 overlap possible", "渤海/overlap possible"}]
    later_periods = [wd for wd in works.values() if wd.decision_coarse in {"1897 transition", "大韓帝國", "1910 transition", "大日本帝國/朝鮮", "1945 transition", "近現代/待分類"}]
    lines = []
    lines.append("# Korean Wikisource staging report")
    lines.append("")
    lines.append(f"Files scanned: {len(records)}")
    lines.append(f"Work folders scanned: {len(works)}")
    lines.append("")
    lines.append("## NATION values before staging")
    for k, v in bogus_nations.most_common():
        lines.append(f"- {k or '(blank)'}: {v}")
    lines.append("")
    lines.append("## Work-folder decisions")
    for k, v in work_counts.most_common():
        lines.append(f"- {k}: {v} works")
    lines.append("")
    lines.append("## File decisions")
    for k, v in file_counts.most_common():
        lines.append(f"- {k}: {v} files")
    lines.append("")
    lines.append("## Pre-Joseon exact-year work folders")
    for wd in sorted(pre_joseon, key=lambda w: (w.decision_coarse, w.work_folder)):
        years = ", ".join(map(str, sorted(wd.exact_year_counts)))
        lines.append(f"- {wd.work_folder}: {wd.decision_coarse}; years {years}; files {len(wd.files)}")
    lines.append("")
    lines.append("## Later / colonial / modern exact-year work folders")
    for wd in sorted(later_periods, key=lambda w: (w.decision_coarse, w.work_folder)):
        years = ", ".join(map(str, sorted(wd.exact_year_counts)))
        lines.append(f"- {wd.work_folder}: {wd.decision_coarse}; years {years}; files {len(wd.files)}")
    lines.append("")
    lines.append("## Cross-period work folders sent to review")
    for wd in sorted(mixed, key=lambda w: w.work_folder):
        lines.append(f"- {wd.work_folder}: {dict(wd.coarse_counts)}; exact years {sorted(wd.exact_year_counts)}; files {len(wd.files)}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input_zip", type=Path)
    ap.add_argument("--out-dir", type=Path)
    ap.add_argument("--out-zip", type=Path)
    ap.add_argument("--manifest", nargs="?", const=Path("korea_wikisource_manifest.csv"), default=Path("korea_wikisource_manifest.csv"), type=Path, help="Manifest CSV path. May be used without a value.")
    ap.add_argument("--summary", nargs="?", const=Path("korea_wikisource_summary.md"), default=Path("korea_wikisource_summary.md"), type=Path, help="Summary Markdown path. May be used without a value.")
    ap.add_argument("--include-bak", action="store_true")
    ap.add_argument("--no-update-nation", action="store_true")
    ap.add_argument("--add-times", action="store_true")
    ap.add_argument("--mixed-policy", choices=["review", "dominant"], default="review")
    args = ap.parse_args()

    records = list(iter_zip_records(args.input_zip, include_bak=args.include_bak))
    works = decide_works(records, mixed_policy=args.mixed_policy)
    write_manifest(records, works, args.manifest)
    write_summary(records, works, args.summary)
    if args.out_dir or args.out_zip:
        write_outputs(records, works, args.out_dir, args.out_zip, update_nation=not args.no_update_nation, add_times=args.add_times)
    print(f"Scanned {len(records)} .txt files in {len(works)} work folders")
    print(f"Wrote manifest: {args.manifest}")
    print(f"Wrote summary: {args.summary}")
    if args.out_dir:
        print(f"Wrote staged folder: {args.out_dir}")
    if args.out_zip:
        print(f"Wrote staged zip: {args.out_zip}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
