#!/usr/bin/env python3
# normalize_clean_tree_from_moe_csv.py
#
# Input tree shape:
#   Country/
#     clean/...
#     raw/...
#
# Output:
#   Country/
#     normalized/...   (mirrors clean/)
#
# Mapping source:
#   MOE-style CSV with columns: glyph, canonical_glyph
#   We map: glyph -> canonical_glyph

import argparse
import csv
from pathlib import Path


def load_moe_mapping(csv_path: Path) -> dict[str, str]:
    """
    MOE CSV semantics:
      - grade == 正字   : the standard (identity row)
      - grade == 異體字 : a variant of the standard
      - grade == 附錄字 : usually a non-standard/extra form (often still safe to collapse)

    For corpus normalization we want:
      variant glyph -> canonical glyph
    """
    mapping: dict[str, str] = {}

    with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        required = {"glyph", "canonical_glyph", "grade"}
        if reader.fieldnames is None or not required.issubset(set(reader.fieldnames)):
            raise ValueError(
                f"CSV missing required columns. Need {required}, got {reader.fieldnames}"
            )

        for row in reader:
            grade = (row.get("grade") or "").strip()

            # Only build replacements from non-standard entries
            if grade not in {"異體字"}:
                continue

            src = (row.get("glyph") or "").strip()
            dst = (row.get("canonical_glyph") or "").strip()

            if not src or not dst:
                continue
            if src == dst:
                continue

            # If the same src appears multiple times, keep the first mapping.
            mapping.setdefault(src, dst)

    return mapping


def normalize_text(text: str, mapping: dict[str, str]) -> tuple[str, int]:
    """
    Pattern:
      for each character ch in the string:
        replace with mapping[ch] if present, else keep ch

    Returns:
      (normalized_text, changed_count)
    """
    out = []
    changed = 0

    for ch in text:
        repl = mapping.get(ch)
        if repl is None:
            out.append(ch)
        else:
            out.append(repl)
            if repl != ch:
                changed += 1

    return "".join(out), changed


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Normalize all files under */clean/ into */normalized/ using MOE variants CSV."
    )
    parser.add_argument(
        "--root",
        required=True,
        help="Path containing country folders OR a single country folder (must contain clean/).",
    )
    parser.add_argument(
        "--mapping-csv",
        required=True,
        help="Path to MOE variants CSV (must have columns glyph, canonical_glyph).",
    )
    parser.add_argument(
        "--encoding",
        default="utf-8",
        help="Text encoding for corpus files. Default: utf-8",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing files in normalized/. If omitted, existing outputs are skipped.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be written, but do not write files.",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    csv_path = Path(args.mapping_csv).resolve()

    if not csv_path.exists():
        print(f"[error] mapping CSV not found: {csv_path}")
        return 2

    mapping = load_moe_mapping(csv_path)
    print(f"[info] loaded mapping entries = {len(mapping)} from {csv_path}")

    # Support either:
    #   root = Country/  (contains clean/)
    #   root = folder containing many Country/ dirs
    countries: list[Path] = []
    if (root / "clean").is_dir():
        countries.append(root)
    else:
        for child in root.iterdir():
            if child.is_dir() and (child / "clean").is_dir():
                countries.append(child)

    if not countries:
        print(f"[error] No folders with a 'clean/' subfolder found under: {root}")
        return 2

    scanned = 0
    written = 0
    skipped = 0
    decode_failed = 0
    total_changed = 0

    for country_dir in sorted(countries):
        clean_dir = country_dir / "clean"
        normalized_dir = country_dir / "normalized"

        print(f"[info] country={country_dir.name}")
        print(f"[info]   input : {clean_dir}")
        print(f"[info]   output: {normalized_dir}")

        for in_path in clean_dir.rglob("*"):
            if in_path.is_dir():
                continue

            rel = in_path.relative_to(clean_dir)
            out_path = normalized_dir / rel

            scanned += 1

            if out_path.exists() and not args.overwrite:
                skipped += 1
                continue

            try:
                text = in_path.read_text(encoding=args.encoding)
            except UnicodeDecodeError:
                decode_failed += 1
                print(f"[warn] decode failed, skipping: {in_path}")
                continue

            normalized, changed = normalize_text(text, mapping)
            total_changed += changed

            if args.dry_run:
                print(f"[dry] would write {out_path} (changed_chars={changed})")
                continue

            out_path.parent.mkdir(parents=True, exist_ok=True)
            def win_long_path(p: Path) -> str:
                s = str(p.resolve())
                # Only apply on Windows drive-letter paths like C:\...
                if len(s) >= 240 and s[1:3] == ":\\":
                    return "\\\\?\\" + s
                return s

            with open(win_long_path(out_path), "w", encoding=args.encoding, newline="") as f:
                f.write(normalized)
            written += 1

        print(f"[info]   done country={country_dir.name}")

    print("[summary]")
    print(f"  scanned_files        = {scanned}")
    print(f"  written_files        = {written}")
    print(f"  skipped_existing     = {skipped}")
    print(f"  decode_failed        = {decode_failed}")
    print(f"  changed_char_count   = {total_changed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
