#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
cleanup_sunwen.py

Run this from inside scrape_output/.

What it does:
- Enters ./孫中山/
- For each work directory, fixes metadata:
  - Moves YYYY年 from WS_CATEGORIES into TIMES (TIMES becomes "YYYY年")
  - Removes that YYYY年 from WS_CATEGORIES
- Classifies the work into 清朝 vs 中華民國 (cutoff year: 1912)
- Moves the entire work folder into 孫中山/清朝/ or 孫中山/中華民國/
- Deletes any empty folders under 孫中山/
"""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path
from typing import Optional, Tuple, List

YEAR_RE = re.compile(r"(?P<y>\d{4})年")

def parse_header_lines(text: str) -> Tuple[List[str], List[str]]:
    """
    Split file into:
    - header lines: consecutive lines starting with '# ' or '#' at the top
    - body lines: the rest
    """
    lines = text.splitlines(True)  # keep line endings
    header = []
    body_start = 0
    for i, line in enumerate(lines):
        if line.startswith("#"):
            header.append(line)
        else:
            body_start = i
            break
    else:
        body_start = len(lines)
    body = lines[body_start:]
    return header, body

def get_field(header: List[str], key: str) -> Optional[Tuple[int, str]]:
    """
    Find a header field like '# KEY: value'
    Returns (index, value_string) or None.
    """
    prefix = f"# {key}:"
    for i, line in enumerate(header):
        if line.startswith(prefix):
            value = line[len(prefix):].strip()
            return i, value
    return None

def set_field(header: List[str], key: str, value: str) -> None:
    """
    Set or insert '# KEY: value' in header.
    If key exists, replace it. Otherwise append at end of header.
    """
    found = get_field(header, key)
    new_line = f"# {key}: {value}\n"
    if found is None:
        header.append(new_line)
    else:
        idx, _old = found
        # Preserve original newline style by keeping '\n' always (fine for corpus)
        header[idx] = new_line

def fix_year_from_ws_categories(header: List[str]) -> Optional[int]:
    """
    If WS_CATEGORIES contains a YYYY年 token:
    - set TIMES to 'YYYY年'
    - remove that YYYY年 token from WS_CATEGORIES
    Returns the extracted year (int) or None if no year found.
    """
    ws = get_field(header, "WS_CATEGORIES")
    if ws is None:
        return None

    idx, ws_val = ws
    parts = [p.strip() for p in ws_val.split(";") if p.strip()]
    years = []
    for p in parts:
        m = YEAR_RE.fullmatch(p)
        if m:
            years.append(int(m.group("y")))

    if not years:
        return None

    # If multiple year-categories somehow exist, choose the earliest (most conservative)
    year = min(years)

    # Remove any exact 'YYYY年' tokens
    parts = [p for p in parts if not (YEAR_RE.fullmatch(p) and int(YEAR_RE.fullmatch(p).group("y")) == year)]

    # Update header fields
    set_field(header, "TIMES", f"{year}年")
    set_field(header, "WS_CATEGORIES", ";".join(parts))

    return year

def detect_year_from_times(header: List[str]) -> Optional[int]:
    """
    Try to get a 4-digit year from TIMES (e.g., '1904年', '1904年1月1日').
    """
    t = get_field(header, "TIMES")
    if t is None:
        return None
    _idx, val = t
    m = YEAR_RE.search(val)
    if not m:
        return None
    return int(m.group("y"))

def detect_era(header: List[str], fallback_year: Optional[int]) -> str:
    """
    Decide '清朝' vs '中華民國'.

    Priority:
    1) If TIMES explicitly contains '清' => 清朝
    2) If TIMES explicitly contains '民國' or '中華民國' => 中華民國
    3) Else if year available:
       - year <= 1911 => 清朝
       - year >= 1912 => 中華民國
    4) Else default to 中華民國 (keeps things moving without stalling)
    """
    t = get_field(header, "TIMES")
    times_val = t[1] if t else ""

    if "清" in times_val:
        return "清朝"
    if "民國" in times_val or "中華民國" in times_val:
        return "中華民國"

    y = fallback_year
    if y is None:
        y = detect_year_from_times(header)

    if y is None:
        return "中華民國"

    return "清朝" if y <= 1911 else "中華民國"

def process_txt_file(path: Path) -> Tuple[Optional[int], str]:
    """
    Read, fix header year-from-categories, write back if changed.
    Return (year_used_or_found, era).
    """
    original = path.read_text(encoding="utf-8")
    header, body = parse_header_lines(original)

    year_from_cat = fix_year_from_ws_categories(header)
    year_for_era = year_from_cat if year_from_cat is not None else detect_year_from_times(header)
    era = detect_era(header, year_for_era)

    rewritten = "".join(header) + "".join(body)
    if rewritten != original:
        path.write_text(rewritten, encoding="utf-8")

    return year_for_era, era

def remove_empty_dirs(root: Path) -> None:
    """
    Delete empty directories under root (bottom-up).
    """
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        p = Path(dirpath)
        # If directory contains no files and no subdirs (after prior deletions), remove it.
        if not any(Path(dirpath).iterdir()):
            try:
                p.rmdir()
            except OSError:
                pass

def main() -> None:
    scrape_root = Path.cwd()
    sun_dir = scrape_root / "孫中山"
    if not sun_dir.exists() or not sun_dir.is_dir():
        raise SystemExit("Expected a folder './孫中山' in the current directory (scrape_output).")

    qing_dir = sun_dir / "清朝"
    roc_dir = sun_dir / "中華民國"
    qing_dir.mkdir(exist_ok=True)
    roc_dir.mkdir(exist_ok=True)

    # Work directories: direct children of 孫中山, excluding the target era folders
    for work_dir in sorted([p for p in sun_dir.iterdir() if p.is_dir() and p.name not in ("清朝", "中華民國")]):
        txt_files = sorted(work_dir.rglob("*.txt"))

        # If it has no .txt, it will be removed by empty-dir cleanup later.
        if not txt_files:
            continue

        # Decide era based on the first .txt after processing it.
        # (If you ever get mixed-era folders, this can be changed to vote across all files.)
        _year, era = process_txt_file(txt_files[0])

        # Still process any remaining .txt files for metadata cleanup
        for tf in txt_files[1:]:
            process_txt_file(tf)

        target_parent = qing_dir if era == "清朝" else roc_dir
        target = target_parent / work_dir.name

        # If already in the right place, skip moving.
        if work_dir.parent == target_parent:
            continue

        # Avoid collisions: if a folder with same name already exists, merge by moving contents.
        if target.exists():
            # Move contents into target, then delete source if empty.
            for item in work_dir.iterdir():
                dest = target / item.name
                if dest.exists():
                    # If collision on file, overwrite (assumes scrape is authoritative)
                    if dest.is_file():
                        dest.unlink()
                    else:
                        # If both are dirs, merge recursively
                        pass
                shutil.move(str(item), str(dest))
            remove_empty_dirs(work_dir)
        else:
            shutil.move(str(work_dir), str(target))

    # Finally, delete any and all empty directories under 孫中山
    remove_empty_dirs(sun_dir)

if __name__ == "__main__":
    main()
