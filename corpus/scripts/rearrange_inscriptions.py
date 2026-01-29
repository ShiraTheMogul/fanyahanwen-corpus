#!/usr/bin/env python3
# fix_wrong_zhou_layout.py
#
# Fix bad rearrangement result:
#   WRONG: 周朝/<period>/<medium>/<stage>/<file>
#   RIGHT: 周朝/<medium>/<period>/<stage>/<file>
#
# - Moves files only; does not edit file contents.
# - Dry-run by default; use --apply to actually move.
# - Conservative: only moves files matching the wrong pattern.
# - Avoids overwrites by adding __dupN suffixes.

import argparse
import os
import shutil
from pathlib import Path
from typing import Optional, Tuple


# Adjust if you later add more media folders
KNOWN_MEDIA = {"甲骨", "簡牘", "金文"}

# Your period buckets (as folders under 周朝 in the *wrong* result)
KNOWN_PERIODS = {"戰國", "春秋", "西周", "東周", "秦代"}

# Stages are messy; we just treat the next folder as "stage" and don't validate it.


def is_txt(path: Path, ext: str) -> bool:
    return path.is_file() and path.name.endswith(ext)


def parse_wrong_zhou_path(path: Path, root: Path) -> Optional[Tuple[str, str, str, Path]]:
    """
    If path matches:
      root/周朝/<period>/<medium>/<stage>/<filename>
    return (period, medium, stage, relative_dir_of_file)

    Otherwise return None.

    relative_dir_of_file is the directory path relative to root (excluding filename).
    """
    try:
        rel = path.relative_to(root)
    except ValueError:
        return None

    parts = rel.parts
    # Need at least: 周朝 / period / medium / stage / filename
    if len(parts) < 5:
        return None

    if parts[0] != "周朝":
        return None

    period = parts[1]
    medium = parts[2]
    stage = parts[3]

    if period not in KNOWN_PERIODS:
        return None

    if medium not in KNOWN_MEDIA:
        return None

    # Everything else we treat as stage (no normalisation)
    return (period, medium, stage, rel.parent)


def safe_move(src: Path, dst: Path, apply: bool) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)

    if not apply:
        print(f"[dry-run] {src}  ->  {dst}")
        return

    final_dst = dst
    if final_dst.exists():
        stem = final_dst.stem
        suffix = final_dst.suffix
        i = 2
        while True:
            cand = final_dst.with_name(f"{stem}__dup{i}{suffix}")
            if not cand.exists():
                final_dst = cand
                break
            i += 1

    shutil.move(str(src), str(final_dst))
    print(f"[moved]   {src}  ->  {final_dst}")


def cleanup_empty_dirs(start_dir: Path, stop_at: Path, apply: bool) -> None:
    """
    After moving files, optionally remove empty directories upward,
    stopping at stop_at (not removing stop_at itself).
    """
    if not apply:
        return

    cur = start_dir
    while True:
        if cur == stop_at:
            break
        if not cur.exists() or not cur.is_dir():
            break
        try:
            next(cur.iterdir())
            break  # not empty
        except StopIteration:
            cur.rmdir()
            cur = cur.parent


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Fix wrong '周朝/<period>/<medium>/<stage>' layout into '周朝/<medium>/<period>/<stage>'."
    )
    ap.add_argument("root", help="Root folder containing 商朝/周朝/etc (the already-rearranged tree).")
    ap.add_argument("--apply", action="store_true", help="Actually move files (default is dry-run).")
    ap.add_argument("--ext", default=".txt", help="File extension to process (default: .txt)")
    ap.add_argument("--cleanup-empty", action="store_true", help="Remove empty dirs left behind (only with --apply).")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.exists():
        print(f"[error] root not found: {root}")
        return 2

    zhou_root = root / "周朝"
    if not zhou_root.exists():
        print(f"[error] no 周朝 folder under: {root}")
        return 2

    moved = 0
    skipped = 0
    candidates = 0

    # Walk only inside 周朝 (we are fixing the 周朝 mistake)
    for dirpath, _dirnames, filenames in os.walk(zhou_root):
        dirpath_p = Path(dirpath)

        for fn in filenames:
            src = dirpath_p / fn
            if not is_txt(src, args.ext):
                continue

            candidates += 1
            parsed = parse_wrong_zhou_path(src, root)
            if not parsed:
                skipped += 1
                continue

            period, medium, stage, _src_rel_parent = parsed

            # Build correct destination:
            # root/周朝/<medium>/<period>/<stage>/<filename>
            dst = root / "周朝" / medium / period / stage / fn
            safe_move(src, dst, args.apply)
            moved += 1

            if args.cleanup_empty:
                # After moving, try cleaning the now-empty stage dir up to 周朝/period
                # WRONG layout dirs: 周朝/period/medium/stage
                cleanup_empty_dirs(src.parent, stop_at=(root / "周朝" / period), apply=args.apply)

    print("\n[done]")
    print(f"  scanned_txt_files = {candidates}")
    print(f"  moved            = {moved}")
    print(f"  skipped          = {skipped}  (not matching wrong pattern)")
    print(f"  apply            = {args.apply}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
