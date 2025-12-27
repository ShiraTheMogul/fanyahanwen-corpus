#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
normalise_work_folders.py

Post-hoc fixer for earlier corpus runs where each subpage got its own
work folder, e.g.:

  raw/絜齋集_卷17/絜齋集_卷17__juan_01.txt
  raw/絜齋集_卷18/絜齋集_卷18__juan_01.txt
  raw/題雲水亭八景帖·曠野行人/...

This script:
  - Detects folders that look like "base_卷XX" or "base·subchapter".
  - Merges them into a shared "base" folder within the same category path.
  - Mirrors the move for both raw/ and clean/.
  - Leaves indexes alone (you can regenerate them or just use the filesystem-
    based summariser).

Usage:

  python normalise_work_folders.py siku_quanshu_corpus
  python normalise_work_folders.py category_corpus
"""

import argparse
import os
import re
import shutil
from typing import Dict, List, Tuple


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def guess_base_from_folder(folder_name: str) -> str | None:
    """
    Try to guess a 'base work' name from a folder that looks like a single part.

    Examples:
      絜齋集_卷17         -> 絜齋集
      絜齋集_第017卷      -> 絜齋集
      題雲水亭八景帖·曠野行人 -> 題雲水亭八景帖
    """
    # /卷XX case, where safe_filename has turned "/" into "_"
    m = re.match(r"(.+?)_卷([一二三四五六七八九十〇零\d]+)$", folder_name)
    if m:
        return m.group(1)

    # /第NN卷 pattern
    m = re.match(r"(.+?)_第(\d+)卷$", folder_name)
    if m:
        return m.group(1)

    # Dot chapter pattern, keep everything before "·"
    if "·" in folder_name:
        return folder_name.split("·", 1)[0].strip()

    return None


def find_leaf_work_dirs(raw_root: str) -> List[Tuple[str, str]]:
    """
    Return list of (dirpath, folder_name) for 'leaf' work dirs under raw_root:
    directories that contain files (text) and are not intermediate parents only.
    """
    result: List[Tuple[str, str]] = []
    for dirpath, dirnames, filenames in os.walk(raw_root):
        # If directory contains files, treat as potential work dir
        if filenames:
            folder_name = os.path.basename(dirpath)
            result.append((dirpath, folder_name))
    return result


def normalise_folders(corpus_root: str) -> None:
    raw_root = os.path.join(corpus_root, "raw")
    clean_root = os.path.join(corpus_root, "clean")

    if not os.path.isdir(raw_root):
        print(f"!! No raw/ directory at {raw_root}")
        return

    print(f"Normalising work folders under: {corpus_root}")
    print(f"  RAW root:   {raw_root}")
    print(f"  CLEAN root: {clean_root} (if present)")

    leaf_dirs = find_leaf_work_dirs(raw_root)

    # Map (category_path, base_name) -> list of child folders
    # category_path = relative parent path under raw_root, excluding work folder
    groups: Dict[Tuple[str, str], List[str]] = {}

    for dirpath, folder_name in leaf_dirs:
        rel = os.path.relpath(dirpath, raw_root)  # e.g. "經部/絜齋集_卷17"
        parts = rel.split(os.sep)
        if len(parts) < 1:
            continue
        cat_path = os.path.join(*parts[:-1]) if len(parts) > 1 else ""
        base = guess_base_from_folder(folder_name)
        if not base:
            continue  # normal folder (already base name), skip

        key = (cat_path, base)
        groups.setdefault(key, []).append(dirpath)

    if not groups:
        print("  No candidate split folders found; nothing to normalise.")
        return

    print(f"  Found {len(groups)} base titles with split folders to merge.\n")

    for (cat_path, base), child_dirs in groups.items():
        # Determine target dirs
        if cat_path:
            target_raw_dir = os.path.join(raw_root, cat_path, base)
            target_clean_dir = os.path.join(clean_root, cat_path, base)
        else:
            target_raw_dir = os.path.join(raw_root, base)
            target_clean_dir = os.path.join(clean_root, base)

        print(f"== Base: {base}  (category path: '{cat_path or '.'}') ==")
        print(f"  Target RAW dir:   {target_raw_dir}")
        print(f"  Target CLEAN dir: {target_clean_dir}")
        print(f"  Child RAW dirs:")
        for d in child_dirs:
            print(f"    - {d}")

        # Ensure target dirs exist
        ensure_dir(target_raw_dir)
        if os.path.isdir(clean_root):
            ensure_dir(target_clean_dir)

        # Move files
        for child_raw_dir in child_dirs:
            child_rel = os.path.relpath(child_raw_dir, raw_root)
            child_folder_name = os.path.basename(child_raw_dir)

            # Corresponding CLEAN dir
            if os.path.isdir(clean_root):
                child_clean_dir = os.path.join(clean_root, child_rel)
            else:
                child_clean_dir = None

            # Move RAW files
            for fname in os.listdir(child_raw_dir):
                src = os.path.join(child_raw_dir, fname)
                if not os.path.isfile(src):
                    continue
                dst = os.path.join(target_raw_dir, fname)
                if os.path.exists(dst):
                    print(f"    !! RAW collision: {dst} already exists, keeping existing and skipping move.")
                else:
                    print(f"    Moving RAW: {src} -> {dst}")
                    shutil.move(src, dst)

            # Move CLEAN files (if dir exists)
            if child_clean_dir and os.path.isdir(child_clean_dir):
                for fname in os.listdir(child_clean_dir):
                    src = os.path.join(child_clean_dir, fname)
                    if not os.path.isfile(src):
                        continue
                    dst = os.path.join(target_clean_dir, fname)
                    if os.path.exists(dst):
                        print(f"    !! CLEAN collision: {dst} already exists, keeping existing and skipping move.")
                    else:
                        print(f"    Moving CLEAN: {src} -> {dst}")
                        shutil.move(src, dst)

            # Remove now-empty child dirs
            try:
                os.rmdir(child_raw_dir)
            except OSError:
                pass
            if child_clean_dir and os.path.isdir(child_clean_dir):
                try:
                    os.rmdir(child_clean_dir)
                except OSError:
                    pass

        print("  -> Merge done.\n")

    print("All candidate groups processed. You may want to re-run any indexers/summarisers to reflect the new layout.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Normalise split work folders (e.g., *_卷XX, title·chapter) into base work folders."
    )
    parser.add_argument(
        "corpus_root",
        help="Path to corpus root containing raw/ and clean/ subdirectories.",
    )
    args = parser.parse_args()

    normalise_folders(args.corpus_root)


if __name__ == "__main__":
    main()
