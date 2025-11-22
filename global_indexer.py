#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Global corpus indexer.

Recursively finds every corpus directory that contains:
    clean/
    raw/                (optional)
    suspected_baihua/   (optional)

EXCEPTION:
    Any directory path that contains a component named 'scrape_output'
    is ignored. This lets you keep a staging area without polluting the index.

For each text file under clean/ or suspected_baihua/, reads the metadata header
and computes character counts for both CLEAN and RAW (if raw exists),
ignoring all whitespace characters.

Outputs:
    - Detailed per-juan index:
        <prefix>.json
        <prefix>.csv
        <prefix>.tsv
        <prefix>.xlsx   (if openpyxl is available)

    - Aggregated per-work index (all juans merged):
        <prefix>_by_work.json
        <prefix>_by_work.csv
        <prefix>_by_work.tsv
        <prefix>_by_work.xlsx   (if openpyxl is available)

Usage examples:

    # 1) Index current directory, output as index_<current_folder>.*
    python global_indexer.py

    # 2) Index a specific root, same auto prefix
    python global_indexer.py /path/to/root

    # 3) Index root, but customise output filenames (index_everything.*)
    python global_indexer.py /path/to/root --out-prefix index_everything
"""

import os
import re
import csv
import json
import argparse
from typing import Dict, List, Any

HEADER_PREFIX = "#"
JUAN_RE = re.compile(r"__juan_(\d+)\.txt$", re.IGNORECASE)

try:
    from openpyxl import Workbook
    HAS_OPENPYXL = True
except ImportError:
    HAS_OPENPYXL = False


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def find_corpus_dirs(root: str) -> List[str]:
    """
    A corpus directory is any dir containing at least a 'clean' subfolder.

    Directories are *ignored* if any path component is literally 'scrape_output'.
    This lets you keep a staging / dumping area called scrape_output/
    without it being included in the global index.
    """
    matches = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Skip anything inside scrape_output
        parts = os.path.relpath(dirpath, start=root).split(os.sep)
        if "scrape_output" in parts:
            continue

        if "clean" in dirnames:
            matches.append(dirpath)
    return sorted(set(matches))


def parse_header(path: str) -> Dict[str, str]:
    meta = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                if not line.startswith(HEADER_PREFIX):
                    break
                body = line[len(HEADER_PREFIX):].strip()
                if ":" in body:
                    key, val = body.split(":", 1)
                    meta[key.strip().upper()] = val.strip()
    except:
        pass
    return meta


def count_chars_without_header(path: str) -> int:
    """
    Count characters in file, ignoring header lines (starting with '#')
    and ignoring all whitespace characters (spaces, tabs, newlines, etc).
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            cnt = 0
            for line in f:
                if line.startswith(HEADER_PREFIX):
                    continue
                for ch in line:
                    if not ch.isspace():
                        cnt += 1
        return cnt
    except:
        return 0


def extract_juan(filename: str) -> int:
    m = JUAN_RE.search(filename)
    if not m:
        return 1
    try:
        return int(m.group(1))
    except:
        return 1


# ─────────────────────────────────────────────────────────────────────────────
# Indexing logic
# ─────────────────────────────────────────────────────────────────────────────

def get_superfolder(path: str, root: str, levels_up: int = 2) -> str:
    """
    Return the folder 'levels_up' above the file in the path, relative to root.
    Example:
      root = fanyahanwen-corpus
      path = fanyahanwen-corpus/中國漢文/clean/三國/七佛父母姓字經/__juan_1.txt
      levels_up = 2 -> '三國'
    """
    try:
        rel = os.path.relpath(path, start=root)
        parts = rel.split(os.sep)
        # filename is parts[-1]; levels_up=2 -> parts[-3]
        if len(parts) > levels_up:
            return parts[-(levels_up + 1)]
        return ""
    except Exception:
        return ""


def index_one_corpus(corpus_dir: str, root: str) -> List[Dict[str, Any]]:
    """
    Index structure:

    corpus_dir/
       clean/
       raw/                (optional)
       suspected_baihua/   (optional)
    """
    rows: List[Dict[str, Any]] = []

    clean_dir = os.path.join(corpus_dir, "clean")
    raw_dir = os.path.join(corpus_dir, "raw")
    sb_dir = os.path.join(corpus_dir, "suspected_baihua")

    raw_exists = os.path.isdir(raw_dir)
    sb_exists = os.path.isdir(sb_dir)

    def process_folder(folder_path: str, folder_type: str):
        # folder_type = "clean" OR "suspected_baihua"
        for category in sorted(os.listdir(folder_path)):
            cat_path = os.path.join(folder_path, category)
            if not os.path.isdir(cat_path):
                continue

            for work_folder in sorted(os.listdir(cat_path)):
                work_path = os.path.join(cat_path, work_folder)
                if not os.path.isdir(work_path):
                    continue

                # Loop over every .txt file
                for fname in sorted(os.listdir(work_path)):
                    if not fname.lower().endswith(".txt"):
                        continue

                    clean_path = os.path.join(work_path, fname)
                    rel_clean = os.path.relpath(clean_path, start=root)

                    # Locate matching RAW file if raw exists
                    if raw_exists:
                        raw_counterpart = os.path.join(
                            raw_dir,
                            os.path.relpath(clean_path, start=folder_path)
                        )
                        if os.path.isfile(raw_counterpart):
                            rel_raw = os.path.relpath(raw_counterpart, start=root)
                            raw_char = count_chars_without_header(raw_counterpart)
                        else:
                            rel_raw = ""
                            raw_counterpart = ""
                            raw_char = 0
                    else:
                        raw_counterpart = ""
                        rel_raw = ""
                        raw_char = 0

                    meta = parse_header(clean_path)

                    row: Dict[str, Any] = {
                        "folder_type": folder_type,
                        "corpus_root": os.path.relpath(corpus_dir, start=root),
                        "category": category,
                        "work_folder": work_folder,

                        "work_title": meta.get("WORK_TITLE", work_folder),
                        "display_title": meta.get("DISPLAY_TITLE", meta.get("WORK_TITLE", work_folder)),
                        "author": meta.get("AUTHOR", ""),
                        "times": meta.get("TIMES", ""),
                        "page_title": meta.get("PAGE_TITLE", meta.get("WORK_TITLE", work_folder)),

                        "pageid": int(meta["PAGEID"]) if meta.get("PAGEID", "").isdigit() else None,

                        "juan_index": extract_juan(fname),

                        "clean_path": rel_clean,
                        "raw_path": rel_raw,

                        "filename": fname,
                        "superfolder": get_superfolder(clean_path, root, levels_up=2),

                        "char_count_clean": count_chars_without_header(clean_path),
                        "char_count_raw": raw_char,
                    }

                    row["is_empty_page"] = 1 if row["char_count_clean"] == 0 else 0

                    rows.append(row)

    # Process CLEAN first
    if os.path.isdir(clean_dir):
        process_folder(clean_dir, "clean")

    # Process suspected_baihua second
    if sb_exists:
        process_folder(sb_dir, "suspected_baihua")

    return rows



# ─────────────────────────────────────────────────────────────────────────────
# Aggregation: merge juans into works
# ─────────────────────────────────────────────────────────────────────────────

def aggregate_by_work(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Merge all juans belonging to the same 'work' into a single row.

    Grouping key:
        (folder_type, corpus_root, category, work_folder,
         work_title, display_title, author, times)

    For each group, we compute:
        - total_char_count_clean
        - total_char_count_raw
        - juan_count
        - empty_juan_count
        - min_juan_index
        - max_juan_index
        - pageid (first non-null)
        - page_title (first non-empty)
        - example_clean_path (first seen)
        - example_raw_path (first seen non-empty)
    """
    agg: Dict[tuple, Dict[str, Any]] = {}

    for r in rows:
        key = (
            r.get("folder_type", ""),
            r.get("corpus_root", ""),
            r.get("category", ""),
            r.get("work_folder", ""),
            r.get("work_title", ""),
            r.get("display_title", ""),
            r.get("author", ""),
            r.get("times", ""),
        )

        if key not in agg:
            agg[key] = {
                "folder_type": r.get("folder_type", ""),
                "corpus_root": r.get("corpus_root", ""),
                "category": r.get("category", ""),
                "work_folder": r.get("work_folder", ""),

                "work_title": r.get("work_title", ""),
                "display_title": r.get("display_title", ""),
                "author": r.get("author", ""),
                "times": r.get("times", ""),

                "pageid": r.get("pageid"),
                "page_title": r.get("page_title", ""),

                "juan_count": 0,
                "min_juan_index": r.get("juan_index", 1),
                "max_juan_index": r.get("juan_index", 1),

                "total_char_count_clean": 0,
                "total_char_count_raw": 0,
                "empty_juan_count": 0,

                "example_clean_path": r.get("clean_path", ""),
                "example_raw_path": r.get("raw_path", ""),
            }

        g = agg[key]

        # update counts
        g["juan_count"] += 1
        ji = r.get("juan_index", 1)
        if ji < g["min_juan_index"]:
            g["min_juan_index"] = ji
        if ji > g["max_juan_index"]:
            g["max_juan_index"] = ji

        g["total_char_count_clean"] += r.get("char_count_clean", 0)
        g["total_char_count_raw"] += r.get("char_count_raw", 0)
        g["empty_juan_count"] += r.get("is_empty_page", 0)

        # fill in pageid / page_title if we don't have them yet
        if g["pageid"] is None and r.get("pageid") is not None:
            g["pageid"] = r.get("pageid")
        if not g["page_title"] and r.get("page_title"):
            g["page_title"] = r.get("page_title")

        # example paths: keep the first non-empty we see
        if not g["example_clean_path"] and r.get("clean_path"):
            g["example_clean_path"] = r.get("clean_path")
        if not g["example_raw_path"] and r.get("raw_path"):
            g["example_raw_path"] = r.get("raw_path")

    # Turn dict into list, sorted for stability
    agg_rows = list(agg.values())
    agg_rows.sort(
        key=lambda x: (
            x["folder_type"],
            x["corpus_root"],
            x["category"],
            x["work_folder"],
            x["work_title"],
        )
    )
    return agg_rows


# ─────────────────────────────────────────────────────────────────────────────
# Write outputs
# ─────────────────────────────────────────────────────────────────────────────

def write_xlsx(rows: List[Dict[str, Any]], fields: List[str], path: str):
    if not HAS_OPENPYXL:
        print("openpyxl not installed; skipping XLSX output.")
        return
    wb = Workbook()
    ws = wb.active
    ws.title = "index"
    # header
    ws.append(fields)
    # rows
    for r in rows:
        ws.append([r.get(f, "") for f in fields])
    wb.save(path)
    print(f"Wrote {path}")


def write_detailed_index(rows: List[Dict[str, Any]], prefix: str):
    if not rows:
        print("No rows — detailed index is empty.")
        return

    fields = [
    "folder_type",
    "corpus_root",
    "category",
    "work_folder",

    "pageid",
    "work_title",
    "display_title",
    "page_title",
    "author",
    "times",

    "juan_index",
    "raw_path",
    "clean_path",

    # NEW fields
    "filename",
    "superfolder",

    "char_count_raw",
    "char_count_clean",
    "is_empty_page",
]


    # JSON
    with open(prefix + ".json", "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    print(f"Wrote {prefix}.json")

    # EXCEL-FRIENDLY CSV  (UTF-8 with BOM, CRLF)
    with open(prefix + ".csv", "w", encoding="utf-8-sig", newline="\r\n") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {prefix}.csv")

    # EXCEL-FRIENDLY TSV  (UTF-8 with BOM, CRLF)
    with open(prefix + ".tsv", "w", encoding="utf-8-sig", newline="\r\n") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {prefix}.tsv")

    # XLSX
    write_xlsx(rows, fields, prefix + ".xlsx")


def write_work_index(rows: List[Dict[str, Any]], prefix: str):
    if not rows:
        print("No rows — per-work index is empty.")
        return

    fields = [
        "folder_type",
        "corpus_root",
        "category",
        "work_folder",

        "pageid",
        "work_title",
        "display_title",
        "page_title",
        "author",
        "times",

        "juan_count",
        "min_juan_index",
        "max_juan_index",

        "total_char_count_raw",
        "total_char_count_clean",
        "empty_juan_count",

        "example_raw_path",
        "example_clean_path",
    ]

    # JSON
    with open(prefix + ".json", "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    print(f"Wrote {prefix}.json")

    # CSV
    with open(prefix + ".csv", "w", encoding="utf-8-sig", newline="\r\n") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {prefix}.csv")

    # TSV
    with open(prefix + ".tsv", "w", encoding="utf-8-sig", newline="\r\n") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {prefix}.tsv")

    # XLSX
    write_xlsx(rows, fields, prefix + ".xlsx")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Build a global index over all corpora under ROOT.\n"
                    "A corpus is any directory containing a 'clean/' subfolder.\n"
                    "Directories containing a 'scrape_output' component are ignored."
    )
    ap.add_argument(
        "root",
        nargs="?",
        default=".",
        help="Root folder containing corpora (default: current directory)."
    )
    ap.add_argument(
        "--out-prefix", "-o",
        dest="out_prefix",
        default=None,
        help=(
            "Base name for output files (without extension). "
            "If omitted, defaults to 'index_<root_folder_name>'."
        ),
    )

    a = ap.parse_args()

    root = os.path.abspath(a.root)

    # Decide output prefix
    if a.out_prefix:
        prefix = a.out_prefix
    else:
        base = os.path.basename(root.rstrip(os.sep)) or "root"
        prefix = f"index_{base}"

    print(f"Root directory: {root}")
    print(f"Output prefix:  {prefix}")

    corpus_dirs = find_corpus_dirs(root)
    if not corpus_dirs:
        print("No corpus directories found (no clean/ folders outside scrape_output).")
        return

    print(f"\nFound {len(corpus_dirs)} corpus roots:")
    for c in corpus_dirs:
        print("  -", os.path.relpath(c, start=root))

    all_rows: List[Dict[str, Any]] = []
    for c in corpus_dirs:
        print(f"\nIndexing: {os.path.relpath(c, start=root)}")
        rows = index_one_corpus(c, root)
        all_rows.extend(rows)

    print(f"\nTotal indexed files (per-juan rows): {len(all_rows)}")

    # Write detailed (per-juan) index
    write_detailed_index(all_rows, prefix)

    # Aggregate into per-work view
    work_rows = aggregate_by_work(all_rows)
    print(f"Total aggregated works (per-work rows): {len(work_rows)}")
    write_work_index(work_rows, prefix + "_by_work")

    print("Done.")


if __name__ == "__main__":
    main()
