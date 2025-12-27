#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple


# Han blocks — exactly as specified
HAN_RE = re.compile(
    r"[\u3400-\u4DBF\u4E00-\u9FFF"
    r"\U00020000-\U0002A6DF"
    r"\U0002A700-\U0002B73F"
    r"\U0002B740-\U0002B81D"
    r"\U0002B820-\U0002CEAD"
    r"\U0002CEB0-\U0002EBE0"
    r"\U00031350-\U000323AF"
    r"\U0002EBF0-\U0002EE5D"
    r"\U000323B0-\U00033479"
    r"\U0002F800-\U0002FA1F]"
)


def load_cangjie_table(path: Path) -> Dict[str, List[str]]:
    """
    Parses SCIM / ibus-table Cangjie tables:
        code<TAB>char<TAB>freq
    Returns: char -> [codes...]
    """
    mapping: Dict[str, List[str]] = {}
    in_table = False

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if line == "BEGIN_TABLE":
                in_table = True
                continue
            if line == "END_TABLE":
                break
            if not in_table or not line or line.startswith("#"):
                continue

            parts = line.split("\t")
            if len(parts) < 2:
                continue

            code = parts[0].strip().lower()
            ch = parts[1].strip()
            if len(ch) != 1 or not code:
                continue

            lst = mapping.setdefault(ch, [])
            if code not in lst:
                lst.append(code)

    return mapping


def cangjie_for_text(text: str, table: Dict[str, List[str]]) -> str:
    out: List[str] = []
    for ch in HAN_RE.findall(text or ""):
        codes = table.get(ch)
        if codes:
            out.append("/".join(codes))
    return " ".join(out)


def first_data_row(lines: List[str]) -> Tuple[int, str]:
    """
    Returns (lineno, line) of first non-comment, non-empty line.
    lineno is 1-based for human-friendly logs.
    """
    for i, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        if line.startswith("#"):
            continue
        return i, line
    raise SystemExit("No data rows found (only comments/blank lines).")


def ensure_len(fields: List[str], n: int) -> List[str]:
    if len(fields) < n:
        fields.extend([""] * (n - len(fields)))
    return fields


def main() -> None:
    ap = argparse.ArgumentParser(description="Fill existing Cangjie fields in an Anki TXT export.")
    ap.add_argument("--in-txt", required=True, type=Path)
    ap.add_argument("--out-txt", required=True, type=Path)

    ap.add_argument("--text-field", required=True, type=int, help="Index of text field (0-based)")
    ap.add_argument("--cj3-field", type=int, help="Index of CJ3 field (0-based)")
    ap.add_argument("--cj5-field", type=int, help="Index of CJ5 field (0-based)")
    ap.add_argument("--cj3-table", type=Path, help="Path to CJ3 table")
    ap.add_argument("--cj5-table", type=Path, help="Path to CJ5 table")

    ap.add_argument("--log-bad-rows", type=Path, default=None,
                    help="Optional path to write rows that were padded/odd")

    args = ap.parse_args()

    cj3 = load_cangjie_table(args.cj3_table) if args.cj3_field is not None else None
    cj5 = load_cangjie_table(args.cj5_table) if args.cj5_field is not None else None

    # Read all lines once so we can infer expected field count safely
    raw_lines = args.in_txt.read_text(encoding="utf-8-sig", errors="replace").splitlines(True)

    first_lineno, first_line = first_data_row(raw_lines)
    expected_fields = len(first_line.rstrip("\n").split("\t"))

    # Validate indices against expected field count
    max_needed = max(
        [args.text_field]
        + ([args.cj3_field] if args.cj3_field is not None else [])
        + ([args.cj5_field] if args.cj5_field is not None else [])
    )
    if max_needed >= expected_fields:
        raise SystemExit(
            f"Your chosen field index {max_needed} is >= expected field count {expected_fields} "
            f"(inferred from line {first_lineno}). "
            f"Either the indices are wrong, or your file has mixed row widths."
        )

    bad_log = []
    with args.out_txt.open("w", encoding="utf-8-sig", newline="") as fout:
        for lineno, line in enumerate(raw_lines, start=1):
            if line.startswith("#") or not line.strip():
                fout.write(line)
                continue

            fields = line.rstrip("\n").split("\t")
            orig_len = len(fields)

            # Pad short rows up to expected_fields
            if orig_len < expected_fields:
                ensure_len(fields, expected_fields)
                bad_log.append(f"लाइन {lineno}: padded {orig_len} -> {len(fields)} fields\n")

            text = fields[args.text_field]

            if cj3 is not None and args.cj3_field is not None:
                fields[args.cj3_field] = cangjie_for_text(text, cj3)
            if cj5 is not None and args.cj5_field is not None:
                fields[args.cj5_field] = cangjie_for_text(text, cj5)

            fout.write("\t".join(fields) + "\n")

    if args.log_bad_rows is not None:
        args.log_bad_rows.write_text("".join(bad_log), encoding="utf-8")


if __name__ == "__main__":
    main()
