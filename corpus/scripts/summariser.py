#!/usr/bin/env python3
"""
summariser.py

Quick-and-dirty corpus summary for the Siku Quanshu scraper index.

Usage:
    python summariser.py siku_quanshu_corpus/index.csv
"""

import csv
import sys
from collections import defaultdict

def safe_int(value):
    """Convert a string to int safely, treating empty/None as 0."""
    if value is None:
        return 0
    value = str(value).strip()
    if not value:
        return 0
    try:
        return int(value)
    except ValueError:
        return 0

def main(index_path):
    print(f"Reading index: {index_path}\n")

    # Per-work stats (grouped by work_title)
    works = defaultdict(lambda: {
        "juan_count": 0,
        "raw_chars": 0,
        "clean_chars": 0,
        "empty_count": 0,
    })

    # Per-folder stats (grouped by folder_key)
    folders = defaultdict(lambda: {
        "juan_count": 0,
        "raw_chars": 0,
        "clean_chars": 0,
        "empty_count": 0,
    })

    total_juan = 0
    total_empty = 0
    total_raw_chars = 0
    total_clean_chars = 0

    with open(index_path, "r", encoding="utf-8-sig") as f:
        rdr = csv.DictReader(f)

        # Show which columns we actually have (for sanity)
        print("Columns detected in index:")
        print("  " + ", ".join(rdr.fieldnames))
        print()

        for row in rdr:
            total_juan += 1

            title = row.get("work_title", "").strip()
            folder_key = row.get("folder_key", "").strip()

            # Support both naming schemes:
            #
            # Old (what summariser expected before):
            #   raw_char_count, clean_char_count
            # New (what scraper writes now):
            #   char_count_raw, char_count_clean
            raw_chars = (
                safe_int(row.get("raw_char_count")) or
                safe_int(row.get("char_count_raw"))
            )
            clean_chars = (
                safe_int(row.get("clean_char_count")) or
                safe_int(row.get("char_count_clean"))
            )

            # is_empty as integer if present
            is_empty = safe_int(row.get("is_empty"))

            # Update per-work stats
            works[title]["juan_count"] += 1
            works[title]["raw_chars"] += raw_chars
            works[title]["clean_chars"] += clean_chars
            works[title]["empty_count"] += is_empty

            # Update per-folder stats (folder_key may be empty for old indices)
            if folder_key:
                folders[folder_key]["juan_count"] += 1
                folders[folder_key]["raw_chars"] += raw_chars
                folders[folder_key]["clean_chars"] += clean_chars
                folders[folder_key]["empty_count"] += is_empty

            # Global totals
            total_raw_chars += raw_chars
            total_clean_chars += clean_chars
            total_empty += is_empty

    # Print global summary
    print(f"Total index rows (juan entries): {total_juan}")
    print(f"Total distinct works (by work_title): {len(works)}")
    print(f"Total distinct folders (by folder_key): {len(folders)}")
    print(f"Total CLEAN characters: {total_clean_chars}")
    print(f"Total RAW characters:   {total_raw_chars}")
    print(f"Empty juan (is_empty=1): {total_empty}")
    print()

    # Top N largest works by clean chars
    N = 10
    print(f"Top {N} largest works (by CLEAN character count):")
    print("-" * 56)
    sorted_works = sorted(
        works.items(),
        key=lambda kv: kv[1]["clean_chars"],
        reverse=True,
    )
    for i, (title, stats) in enumerate(sorted_works[:N], start=1):
        print(f" {i}. {title}")
        print(f"      juan: {stats['juan_count']}, "
              f"clean chars: {stats['clean_chars']}, "
              f"empty juan: {stats['empty_count']}")
    print()

    # Top N largest folders by clean chars
    print(f"Top {N} largest folders (by CLEAN character count):")
    print("-" * 59)
    sorted_folders = sorted(
        folders.items(),
        key=lambda kv: kv[1]["clean_chars"],
        reverse=True,
    )
    for i, (folder, stats) in enumerate(sorted_folders[:N], start=1):
        print(f" {i}. {folder}")
        print(f"      juan: {stats['juan_count']}, "
              f"clean chars: {stats['clean_chars']}, "
              f"empty juan: {stats['empty_count']}")
    print()

    print("Done.")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python summariser.py path/to/index.csv")
        sys.exit(1)
    main(sys.argv[1])
