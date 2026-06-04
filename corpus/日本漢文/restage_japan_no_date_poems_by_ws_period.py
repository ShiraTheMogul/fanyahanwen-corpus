#!/usr/bin/env python3
"""
Restage Japanese poem files that landed in 未分類/無年代 because they had no
usable year, but their WS_CATEGORIES directly names a Japanese period such as
平安時代, 鎌倉時代, 江戸時代, etc.

Designed for this specific cleanup pass:

    japan_periodised_review/未分類/無年代/日本漢詩

Safety model:
- copy-only
- never deletes or moves the source files
- by default, writes copied files back under the inferred review root
- rewrites NATION and TIMES in the copied files to match the chosen destination
- sends ambiguous items to 未分類/跨期時代カテゴリ需核
- leaves items with no usable period label in 未分類/無年代

Example:

    python restage_japan_no_date_poems_by_ws_period.py ^
      "C:\\...\\japan_periodised_review\\未分類\\無年代\\日本漢詩"

If the input folder is exactly .../japan_periodised_review/未分類/無年代/日本漢詩,
the output root is inferred as .../japan_periodised_review.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

HEADER_RE = re.compile(r"^#\s*([^:]+):\s*(.*)$")

BACKUP_SUFFIXES = (
    ".bak",
    ".bak2",
    ".orig",
    ".tmp",
)

# These labels map from period words found in WS_CATEGORIES to the folder tree.
# Longest aliases should be checked first so e.g. 安土桃山時代 wins as a whole.
PERIOD_ALIASES: List[Tuple[str, str, str]] = [
    ("安土桃山時代", "日本", "安土桃山時代"),
    ("弥生時代", "倭", "弥生時代"),
    ("彌生時代", "倭", "弥生時代"),
    ("古墳時代", "倭", "古墳時代"),
    ("飛鳥時代", "倭", "飛鳥時代"),
    ("奈良時代", "日本", "奈良時代"),
    ("平安時代", "日本", "平安時代"),
    ("平安朝", "日本", "平安時代"),
    ("鎌倉時代", "日本", "鎌倉時代"),
    ("室町時代", "日本", "室町時代"),
    # Wikisource-style categories sometimes use 南北朝時代. In this folder
    # system, that belongs under the broad 室町時代 bucket unless you later
    # manually split 北朝 / 南朝 by content.
    ("南北朝時代", "日本", "室町時代"),
    ("江戸時代", "日本", "江戸時代"),
    ("江戶時代", "日本", "江戸時代"),
    ("明治時代", "日本", "明治時代"),
    ("大正時代", "日本", "大正時代"),
    ("昭和時代", "日本", "昭和時代"),
    ("平成時代", "日本", "平成時代"),
    ("令和時代", "日本", "令和時代"),
]

# If a category says only 大日本帝国 without a territory, it is too vague for
# this pass. Territory-specific imperial categories can be added here later if
# you need them for another cleanup pass.
IGNORED_PERIODISH_LABELS = {
    "大日本帝国",
    "大日本帝國",
}


def split_ws_categories(value: str) -> List[str]:
    return [part.strip() for part in (value or "").split(";") if part.strip()]


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


def period_candidates_from_ws_categories(value: str) -> Counter:
    """Find direct period-name evidence in WS_CATEGORIES.

    A candidate is counted when a category part contains a period label such as
    平安時代 or 江戸時代. Category parts containing 提及 are skipped, because those
    usually mean the category is about something mentioned, not the text's date.
    """
    counts: Counter = Counter()
    for part in split_ws_categories(value):
        if "提及" in part:
            continue
        if any(label in part for label in IGNORED_PERIODISH_LABELS):
            # Too broad by itself; do not treat as a period bucket.
            continue
        for alias, root, period in PERIOD_ALIASES:
            if alias in part:
                counts[f"{root}/{period}"] += 1
                break
    return counts


def should_skip_file(path: Path, include_bak: bool) -> bool:
    if not path.name.endswith(".txt"):
        return True
    if include_bak and path.name.endswith(".txt"):
        return False
    return path.name.endswith(BACKUP_SUFFIXES)


@dataclass
class FileRecord:
    source_path: Path
    rel_inside_input: PurePosixPath
    output_tail: PurePosixPath
    work_key: str
    headers: Dict[str, str]
    period_candidates: Counter
    text: str


@dataclass
class WorkDecision:
    work_key: str
    files: List[FileRecord] = field(default_factory=list)
    period_counts: Counter = field(default_factory=Counter)
    destination: str = "未分類/無年代"
    decided_root: Optional[str] = None
    decided_period: Optional[str] = None
    reason: str = ""


def work_key_from_tail(tail: PurePosixPath) -> str:
    parts = tail.parts
    if len(parts) <= 1:
        return Path(parts[0]).stem if parts else "(unknown)"
    return str(PurePosixPath(*parts[:-1]))


def collect_records(input_dir: Path, include_bak: bool, keep_input_folder: bool) -> List[FileRecord]:
    records: List[FileRecord] = []
    input_name = input_dir.name

    for path in sorted(input_dir.rglob("*.txt")):
        if should_skip_file(path, include_bak=include_bak):
            continue
        rel = PurePosixPath(*path.relative_to(input_dir).parts)
        if keep_input_folder:
            tail = PurePosixPath(input_name) / rel
        else:
            tail = rel
        text = path.read_text(encoding="utf-8", errors="replace")
        headers = parse_headers(text)
        period_candidates = period_candidates_from_ws_categories(headers.get("WS_CATEGORIES", ""))
        records.append(FileRecord(
            source_path=path,
            rel_inside_input=rel,
            output_tail=tail,
            work_key=work_key_from_tail(tail),
            headers=headers,
            period_candidates=period_candidates,
            text=text,
        ))
    return records


def decide_works(records: List[FileRecord], mixed_policy: str) -> Dict[str, WorkDecision]:
    works: Dict[str, WorkDecision] = {}
    for rec in records:
        wd = works.setdefault(rec.work_key, WorkDecision(work_key=rec.work_key))
        wd.files.append(rec)
        wd.period_counts.update(rec.period_candidates)

    for wd in works.values():
        if not wd.period_counts:
            wd.destination = "未分類/無年代"
            wd.reason = "no direct Japanese period label found in WS_CATEGORIES"
            continue

        if len(wd.period_counts) > 1 and mixed_policy == "review":
            wd.destination = "未分類/跨期時代カテゴリ需核"
            wd.reason = "multiple period labels found in WS_CATEGORIES across this work"
            continue

        chosen = wd.period_counts.most_common(1)[0][0]
        root, period = chosen.split("/", 1)
        wd.decided_root = root
        wd.decided_period = period
        wd.destination = f"{root}/{period}/未分類"
        wd.reason = "direct Japanese period label found in WS_CATEGORIES"

    return works


def metadata_for_destination(wd: WorkDecision) -> Tuple[Optional[str], Optional[str]]:
    if not wd.decided_root or not wd.decided_period:
        return None, None
    return wd.decided_root, wd.decided_period


def rewrite_metadata(text: str, wd: WorkDecision, update_nation: bool, update_times: bool) -> str:
    nation, times = metadata_for_destination(wd)
    if not nation:
        update_nation = False
    if not times:
        update_times = False
    if not (update_nation or update_times):
        return text

    lines = text.splitlines()
    out: List[str] = []
    in_header = True
    saw_nation = False
    saw_times = False

    for line in lines:
        if in_header and not line.startswith("#"):
            if update_nation and not saw_nation:
                out.append(f"# NATION: {nation}")
                saw_nation = True
            if update_times and not saw_times:
                out.append(f"# TIMES: {times}")
                saw_times = True
            in_header = False

        if in_header:
            m = HEADER_RE.match(line)
            if m:
                key = m.group(1).strip()
                if key == "NATION":
                    saw_nation = True
                    if update_nation:
                        out.append(f"# NATION: {nation}")
                        continue
                if key == "TIMES":
                    saw_times = True
                    if update_times:
                        out.append(f"# TIMES: {times}")
                        continue
        out.append(line)

    if update_nation and not saw_nation:
        out.append(f"# NATION: {nation}")
    if update_times and not saw_times:
        out.append(f"# TIMES: {times}")

    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def staged_rel(rec: FileRecord, wd: WorkDecision) -> PurePosixPath:
    return PurePosixPath(wd.destination) / rec.output_tail


def write_outputs(records: List[FileRecord], works: Dict[str, WorkDecision], out_root: Path, update_nation: bool, update_times: bool, overwrite: bool) -> None:
    for rec in records:
        wd = works[rec.work_key]
        rel = staged_rel(rec, wd)
        target = out_root / Path(*rel.parts)
        if target.exists() and not overwrite:
            # Avoid silently clobbering an existing reviewed copy.
            raise FileExistsError(f"Target already exists; use --overwrite if intentional: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        text = rewrite_metadata(rec.text, wd, update_nation=update_nation, update_times=update_times)
        target.write_text(text, encoding="utf-8")


def write_manifest(records: List[FileRecord], works: Dict[str, WorkDecision], manifest_path: Path, out_root: Path) -> None:
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("w", encoding="utf-8-sig", newline="") as f:
        fieldnames = [
            "row", "source_path", "staged_path", "work_key", "title", "work_title", "author",
            "old_nation", "new_nation", "old_times", "new_times",
            "period_candidates", "destination", "reason", "ws_categories",
        ]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row, rec in enumerate(records, start=1):
            wd = works[rec.work_key]
            new_nation, new_times = metadata_for_destination(wd)
            rel = staged_rel(rec, wd)
            writer.writerow({
                "row": row,
                "source_path": str(rec.source_path),
                "staged_path": str(out_root / Path(*rel.parts)),
                "work_key": rec.work_key,
                "title": rec.headers.get("TITLE", ""),
                "work_title": rec.headers.get("WORK_TITLE", ""),
                "author": rec.headers.get("AUTHOR", ""),
                "old_nation": rec.headers.get("NATION", ""),
                "new_nation": new_nation or "",
                "old_times": rec.headers.get("TIMES", ""),
                "new_times": new_times or "",
                "period_candidates": json.dumps(dict(rec.period_candidates), ensure_ascii=False),
                "destination": wd.destination,
                "reason": wd.reason,
                "ws_categories": rec.headers.get("WS_CATEGORIES", ""),
            })


def write_summary(records: List[FileRecord], works: Dict[str, WorkDecision], summary_path: Path) -> None:
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    work_dest_counts = Counter(wd.destination for wd in works.values())
    file_dest_counts = Counter(works[rec.work_key].destination for rec in records)

    lines: List[str] = []
    lines.append("# Japanese poem WS-period rescue report")
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
    lines.append("## Still unresolved")
    unresolved = [wd for wd in works.values() if wd.destination.startswith("未分類/")]
    for wd in sorted(unresolved, key=lambda w: w.work_key)[:300]:
        lines.append(f"- {wd.work_key}: {wd.destination}; {wd.reason}; files {len(wd.files)}")
    if len(unresolved) > 300:
        lines.append(f"- ... {len(unresolved) - 300} more omitted; see CSV manifest")

    summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def infer_review_root(input_dir: Path) -> Path:
    """Infer .../japan_periodised_review from .../未分類/無年代/日本漢詩."""
    try:
        if input_dir.parent.name == "無年代" and input_dir.parent.parent.name == "未分類":
            return input_dir.parent.parent.parent
    except IndexError:
        pass
    return input_dir.parent / "period_label_restaged"


def main() -> int:
    ap = argparse.ArgumentParser(description="Restage no-date Japanese poem files by direct period labels in WS_CATEGORIES.")
    ap.add_argument("input_dir", type=Path, help="Usually japan_periodised_review/未分類/無年代/日本漢詩")
    ap.add_argument("--out-root", type=Path, help="Review tree root. If omitted, inferred from the input path.")
    ap.add_argument("--manifest", type=Path, help="CSV manifest path. Defaults under the output root.")
    ap.add_argument("--summary", type=Path, help="Markdown summary path. Defaults under the output root.")
    ap.add_argument("--include-bak", action="store_true", help="Include backup-like txt files; off by default")
    ap.add_argument("--flatten", action="store_true", help="Do not preserve the input folder name, e.g. 日本漢詩, under each destination")
    ap.add_argument("--mixed-policy", choices=["review", "dominant"], default="review", help="What to do when one work has several period labels")
    ap.add_argument("--no-update-nation", action="store_true", help="Do not rewrite NATION in copied files")
    ap.add_argument("--no-update-times", action="store_true", help="Do not rewrite TIMES in copied files")
    ap.add_argument("--overwrite", action="store_true", help="Allow overwriting target files if the script is rerun")
    ap.add_argument("--dry-run", action="store_true", help="Write manifest and summary only; do not copy files")
    args = ap.parse_args()

    input_dir = args.input_dir
    if not input_dir.exists() or not input_dir.is_dir():
        raise SystemExit(f"Input folder does not exist or is not a folder: {input_dir}")

    out_root = args.out_root or infer_review_root(input_dir)
    manifest = args.manifest or (out_root / "japan_poems_ws_period_rescue_manifest.csv")
    summary = args.summary or (out_root / "japan_poems_ws_period_rescue_summary.md")

    records = collect_records(input_dir, include_bak=args.include_bak, keep_input_folder=not args.flatten)
    works = decide_works(records, mixed_policy=args.mixed_policy)

    write_manifest(records, works, manifest, out_root=out_root)
    write_summary(records, works, summary)

    if not args.dry_run:
        write_outputs(
            records,
            works,
            out_root=out_root,
            update_nation=not args.no_update_nation,
            update_times=not args.no_update_times,
            overwrite=args.overwrite,
        )

    print(f"Scanned {len(records)} .txt files in {len(works)} work units")
    print(f"Output root: {out_root}")
    print(f"Wrote manifest: {manifest}")
    print(f"Wrote summary: {summary}")
    if args.dry_run:
        print("Dry run only: no files copied")
    else:
        print("Copied restaged files. Original files were not moved or deleted.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
