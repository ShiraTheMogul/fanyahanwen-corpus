from __future__ import annotations

import argparse
import os
from pathlib import Path

BANNER_LF = (
    "此作品在全世界都属于\n"
    "公有领域\n"
    "，因为作者逝世已经超过年，且作品于年月日之前出版。"
)
BANNER_CRLF = BANNER_LF.replace("\n", "\r\n")


def path_parts_lower(p: Path) -> list[str]:
    # Normalize for case-insensitive matching on Windows
    return [part.lower() for part in p.parts]


def should_process_file(p: Path) -> bool:
    """
    Process only files that are:
      - under a directory named 'clean' (anywhere in the path),
      - NOT under any directory named 'raw'.
    """
    parts = path_parts_lower(p)
    if "raw" in parts:
        return False
    # A file is "under clean" if *any* parent directory is named clean
    return "clean" in parts[:-1]


def read_text_best_effort(p: Path) -> str | None:
    """
    Try UTF-8 (with and without BOM). If decoding fails, skip the file.
    """
    for enc in ("utf-8-sig", "utf-8"):
        try:
            return p.read_text(encoding=enc)
        except UnicodeDecodeError:
            continue
        except Exception:
            return None
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="Root folder of your corpus")
    ap.add_argument("--dry-run", action="store_true", help="Report changes but do not modify files")
    ap.add_argument(
        "--ext",
        default=".txt",
        help="Comma-separated extensions to process (default: .txt). Use '*' to process all files.",
    )
    ap.add_argument("--backup", action="store_true", help="Write a .bak copy before modifying")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.exists():
        raise SystemExit(f"Root does not exist: {root}")

    exts = None
    if args.ext.strip() != "*":
        exts = {e.strip().lower() for e in args.ext.split(",") if e.strip()}
        if not exts:
            raise SystemExit("No extensions provided. Use --ext .txt or --ext '*'")

    changed_files = 0
    total_replacements = 0
    scanned_files = 0
    skipped_decode = 0

    for p in root.rglob("*"):
        if not p.is_file():
            continue

        if exts is not None and p.suffix.lower() not in exts:
            continue

        if not should_process_file(p):
            continue

        scanned_files += 1

        text = read_text_best_effort(p)
        if text is None:
            skipped_decode += 1
            continue

        count = text.count(BANNER_LF) + text.count(BANNER_CRLF)
        if count == 0:
            continue

        new_text = text.replace(BANNER_LF, "").replace(BANNER_CRLF, "")
        # Safety: only count if something actually changed
        if new_text == text:
            continue

        changed_files += 1
        total_replacements += count

        rel = p.relative_to(root)
        print(f"[match] {rel}  ({count} occurrence(s))")

        if not args.dry_run:
            if args.backup:
                bak = p.with_suffix(p.suffix + ".bak")
                if not bak.exists():
                    bak.write_text(text, encoding="utf-8-sig")

            # Write back with BOM for Excel/Windows friendliness; change to utf-8 if you prefer
            p.write_text(new_text, encoding="utf-8-sig")

    print("\n--- summary ---")
    print(f"root: {root}")
    print(f"scanned files: {scanned_files}")
    print(f"changed files: {changed_files}")
    print(f"total banner removals: {total_replacements}")
    if skipped_decode:
        print(f"skipped (decode issues): {skipped_decode}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
