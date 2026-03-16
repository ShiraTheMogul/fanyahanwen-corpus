#!/usr/bin/env python3
"""
Extract Takekoshi's Manchu-Chinese transcription table from the PDF into CSV.

What this script does
---------------------
1. Reads the PDF with pypdf.
2. Rebuilds "logical lines" from the extracted text.
3. Detects:
   - the syllable/final header, like （a）, （ie）, （i［ɿ］）
   - the initial header, like （b）, （zh）, （q）
   - the individual entry chunks, like:
       罷 ba 74
       拿/挐 na 12
       只 dz 31/jy 9
4. Writes two files:
   - clean_rows.csv      -> rows that parsed cleanly
   - review_rows.csv     -> rows that need a human look

Database idea
-------------
The "clean_rows.csv" file is deliberately exploded into one row per:
    character x romanization variant

So if the source says:
    拿/挐 na 12
you will get:
    拿, na
    挐, na

And if the source says:
    只 dz 31/jy 9
you will get:
    只, dz
    只, jy

This is usually the easiest shape to import into a database.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from pypdf import PdfReader


# -----------------------------
# 1) Small data containers
# -----------------------------

@dataclass
class ParsedEntry:
    page_number: int
    final_label: str
    initial_label: str
    chars_raw: str
    roman_raw: str
    count: str | None
    source_chunk: str


# -----------------------------
# 2) Unicode / text helpers
# -----------------------------

CJK_RE = r"\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff"

# These are the roman letters/marks that actually appear in the PDF.
ROMAN_CHARS = "A-Za-zšžŠŽāēīōūĀĒĪŌŪʻʼʽ'’ɿʅ"

ROMAN_TOKEN_RE = re.compile(rf"[{ROMAN_CHARS}]+(?:/[{ROMAN_CHARS}]+)*")


def normalize_text(text: str) -> str:
    """
    Make the extracted PDF text more regular.

    Why normalize?
    --------------
    PDF extraction often gives:
    - odd spaces
    - split lines
    - full-width spaces
    - visually identical punctuation as different codepoints
    """
    text = unicodedata.normalize("NFC", text)
    text = text.replace("\u3000", " ")   # full-width space -> normal space
    text = text.replace("\xa0", " ")     # non-breaking space -> normal space
    return text


def is_probable_header_or_noise(line: str) -> bool:
    """
    Drop page headers / page numbers / intro noise.

    We keep this conservative:
    - if in doubt, keep the line
    - better to review a bad row than silently lose data
    """
    line = line.strip()

    if not line:
        return True

    # Simple page numbers like "9", "10", ...
    if re.fullmatch(r"\d+", line):
        return True

    # Journal / title headers.
    if "古代文字資料館発行" in line:
        return True
    if "満洲文字注音一覧表" in line:
        return True
    if line == "竹越 孝":
        return True
    if line.startswith("＜凡例＞"):
        return True
    if line.startswith("・本稿は"):
        return True
    if line.startswith("・本書については"):
        return True
    if line.startswith("・漢字の現代北京音は"):
        return True
    if line.startswith("・漢字の横に"):
        return True
    if line.startswith("・漢字において"):
        return True

    return False


def rebuild_logical_lines(page_text: str) -> list[str]:
    """
    Rebuild lines that belong together.

    PDF extraction often turns this:
        （j） 結 giye 5/giyei 2，借 giye 4，
         接 giye 3，節 giye 3

    into two separate lines.

    Our rule:
    - a new line that starts with （ ... ） is a new logical line
    - otherwise, it is a continuation of the previous logical line
    """
    raw_lines = [normalize_text(x).strip() for x in page_text.splitlines()]
    raw_lines = [x for x in raw_lines if not is_probable_header_or_noise(x)]

    logical_lines: list[str] = []

    for line in raw_lines:
        if not line:
            continue

        if line.startswith("（"):
            logical_lines.append(line)
        else:
            if logical_lines:
                logical_lines[-1] += " " + line
            else:
                logical_lines.append(line)

    # Final cleanup
    cleaned: list[str] = []
    for line in logical_lines:
        line = re.sub(r"\s+", " ", line).strip()

        # Insert a missing space between Han text and romanization if the PDF
        # extraction glued them together, e.g.:
        #   駕giya  -> 駕 giya
        line = re.sub(rf"([{CJK_RE}/])([{ROMAN_CHARS}])", r"\1 \2", line)

        cleaned.append(line)

    return cleaned


# -----------------------------
# 3) Parsing section headers
# -----------------------------

SECTION_ONLY_RE = re.compile(r"^（([^）]+)）$")

SECTION_WITH_BODY_RE = re.compile(r"^（([^）]+)）\s*(.+)$")


def parse_pages_into_entries(pdf_path: Path) -> tuple[list[ParsedEntry], list[dict]]:
    """
    Walk the PDF page by page and recover entry-level chunks.

    Output:
    - parsed_entries: chunks like "罷 ba 74"
    - review_rows: lines/chunks we could not confidently structure
    """
    reader = PdfReader(str(pdf_path))

    parsed_entries: list[ParsedEntry] = []
    review_rows: list[dict] = []

    current_final: str | None = None

    for page_index, page in enumerate(reader.pages, start=1):
        page_text = page.extract_text() or ""
        logical_lines = rebuild_logical_lines(page_text)

        for line in logical_lines:
            # Case 1: line is just a final header like （a）
            only_match = SECTION_ONLY_RE.match(line)
            if only_match:
                label = only_match.group(1).strip()
                current_final = label
                continue

            # Case 2: line starts with an initial label and then body
            body_match = SECTION_WITH_BODY_RE.match(line)
            if not body_match:
                # Not a line we know how to structure. Keep it for review.
                review_rows.append({
                    "page_number": page_index,
                    "final_label": current_final or "",
                    "initial_label": "",
                    "reason": "unstructured_logical_line",
                    "source_text": line,
                })
                continue

            initial_label = body_match.group(1).strip()
            body = body_match.group(2).strip()

            # If there is no current final yet, this is almost certainly not table data.
            if current_final is None:
                review_rows.append({
                    "page_number": page_index,
                    "final_label": "",
                    "initial_label": initial_label,
                    "reason": "initial_before_final",
                    "source_text": line,
                })
                continue

            # Split the body on the full-width comma used by the PDF.
            chunks = [chunk.strip() for chunk in body.split("，") if chunk.strip()]

            for chunk in chunks:
                parsed = parse_entry_chunk(
                    chunk=chunk,
                    page_number=page_index,
                    final_label=current_final,
                    initial_label=initial_label,
                )
                if parsed is None:
                    review_rows.append({
                        "page_number": page_index,
                        "final_label": current_final,
                        "initial_label": initial_label,
                        "reason": "chunk_parse_failed",
                        "source_text": chunk,
                    })
                else:
                    parsed_entries.append(parsed)

    return parsed_entries, review_rows


def parse_entry_chunk(
    chunk: str,
    page_number: int,
    final_label: str,
    initial_label: str,
) -> ParsedEntry | None:
    """
    Parse one chunk such as:
        罷 ba 74
        拿/挐 na 12
        只 dz 31/jy 9
        楽 le/lo
        日 ži 65/žy

    Strategy
    --------
    We scan left to right:
    1. the Han-string at the start
    2. the romanization token right after it
    3. an optional count

    Anything stranger than that is sent to review_rows.csv.
    """
    chunk = chunk.strip()
    chunk = re.sub(r"\s+", " ", chunk)

    # 1) Han characters / variants at the beginning.
    chars_match = re.match(rf"^([{CJK_RE}/]+)\s+(.*)$", chunk)
    if not chars_match:
        return None

    chars_raw = chars_match.group(1).strip()
    rest = chars_match.group(2).strip()

    # 2) Romanization token.
    roman_match = ROMAN_TOKEN_RE.match(rest)
    if not roman_match:
        return None

    roman_raw = roman_match.group(0).strip()
    tail = rest[roman_match.end():].strip()

    # 3) Optional count.
    # Accept only a plain integer here. If the tail is stranger than that,
    # keep the row in review rather than guessing.
    count = None
    if tail:
        simple_count = re.fullmatch(r"\d+", tail)
        if simple_count:
            count = simple_count.group(0)
        else:
            # Try one rescue pattern:
            # some rows look like: "只 dz 31/jy 9"
            # but after comma splitting this often becomes:
            #   "只 dz 31/jy 9"
            # which is really two readings:
            #   dz 31
            #   jy 9
            # We do NOT guess here. We send the chunk to review so nothing is lost.
            return None

    return ParsedEntry(
        page_number=page_number,
        final_label=final_label,
        initial_label=initial_label,
        chars_raw=chars_raw,
        roman_raw=roman_raw,
        count=count,
        source_chunk=chunk,
    )


# -----------------------------
# 4) Romanization -> Manchu script
# -----------------------------
#
# Important design choice:
# ------------------------
# We keep this transliterator intentionally explicit and conservative.
#
# It handles:
# - ordinary Manchu letters
# - the special Chinese transcription letters you care about
#
# It does NOT try to force every contextual glyph form by hand.
# Unicode shaping should handle the visible joining forms.
#
# If you later want every historical scribal form or variant selector,
# that is a second layer and should stay separate from the extraction layer.
#

SPECIAL_MULTI_TOKENS = [
    ("ts’y", "ᡮ"),   # c in ci-type syllables
    ("ts' y", "ᡮ"),  # just in case of damaged spacing
    ("ts’", "ᡮ"),
    ("ts'", "ᡮ"),
    ("g’o", "ᡬᠣ"),  # special g' before o
    ("g’", "ᡬ"),
    ("g'", "ᡬ"),
    ("k’o", "ᠺᠣ"),  # special k' before o
    ("k’", "ᠺ"),
    ("k'", "ᠺ"),
    ("h’o", "ᡭᠣ"),  # special h' before o
    ("h’", "ᡭ"),
    ("h'", "ᡭ"),
    ("dz", "ᡯ"),
    ("ž", "ᡰ"),
    ("sy", "ᠰᡟ"),
    ("jy", "ᡷᡳ"),
    ("c’y", "ᡱᡳ"),
    ("c’", "ᡱ"),
    ("c'", "ᡱ"),
    ("ng", "ᠩ"),
]

SINGLE_TOKENS = {
    "a": "ᠠ",
    "e": "ᡝ",
    "i": "ᡳ",
    "o": "ᠣ",
    "u": "ᡠ",
    "ū": "ᡡ",
    "b": "ᠪ",
    "p": "ᡦ",
    "m": "ᠮ",
    "f": "ᡶ",
    "d": "ᡩ",
    "t": "ᡨ",
    "n": "ᠨ",
    "l": "ᠯ",
    "s": "ᠰ",
    "š": "ᡧ",
    "h": "ᡥ",
    "g": "ᡤ",
    "k": "ᡴ",
    "j": "ᠵ",
    "c": "ᠴ",
    "y": "ᠶ",
    "r": "ᡵ",
    "w": "ᠸ",
    "'": "",
    "’": "",
    "ʼ": "",
    "ʽ": "",
}


def roman_to_manchu(roman: str) -> str:
    """
    Convert Takekoshi's Möllendorff-style romanization back into Manchu script.

    This is a greedy tokenizer:
    - try the longest special token first
    - otherwise fall back to one character at a time
    """
    roman = roman.strip()
    roman = roman.replace(" ", "")
    roman = unicodedata.normalize("NFC", roman)

    out = []
    i = 0

    while i < len(roman):
        matched = False

        for latin, manchu in SPECIAL_MULTI_TOKENS:
            if roman.startswith(latin, i):
                out.append(manchu)
                i += len(latin)
                matched = True
                break

        if matched:
            continue

        ch = roman[i]
        if ch in SINGLE_TOKENS:
            out.append(SINGLE_TOKENS[ch])
            i += 1
            continue

        # Unknown symbol: preserve visibly so the problem is obvious.
        out.append(f"[{ch}]")
        i += 1

    return "".join(out)


# -----------------------------
# 5) Explode rows for database import
# -----------------------------

def explode_entry(entry: ParsedEntry) -> list[dict]:
    """
    Turn one parsed chunk into one-or-more database rows.

    Example:
        chars_raw = "拿/挐"
        roman_raw = "na"

    becomes two rows:
        拿, na
        挐, na

    Example:
        chars_raw = "樂"
        roman_raw = "le/lo"

    becomes:
        樂, le
        樂, lo

    We keep chars and romanizations independent on purpose.
    This is safer than pretending slash positions always align one-to-one.
    """
    chars = [x for x in entry.chars_raw.split("/") if x]
    romans = [x for x in entry.roman_raw.split("/") if x]

    rows: list[dict] = []
    for char in chars:
        for roman in romans:
            rows.append({
                "page_number": entry.page_number,
                "final_label": entry.final_label,
                "initial_label": entry.initial_label,
                "character": char,
                "chars_raw": entry.chars_raw,
                "romanization": roman,
                "roman_raw": entry.roman_raw,
                "occurrence_count": entry.count or "",
                "manchu_script": roman_to_manchu(roman),
                "source_chunk": entry.source_chunk,
            })

    return rows


# -----------------------------
# 6) Main program
# -----------------------------

def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return

    fieldnames = list(rows[0].keys())
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract Takekoshi's table from PDF into clean CSV."
    )
    parser.add_argument("pdf", type=Path, help="Path to takekoshi101.pdf")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("takekoshi_extract"),
        help="Directory where CSV files will be written",
    )
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)

    parsed_entries, review_rows = parse_pages_into_entries(args.pdf)

    clean_rows: list[dict] = []
    for entry in parsed_entries:
        clean_rows.extend(explode_entry(entry))

    write_csv(args.out_dir / "clean_rows.csv", clean_rows)
    write_csv(args.out_dir / "review_rows.csv", review_rows)

    print(f"Parsed entry chunks: {len(parsed_entries)}")
    print(f"Exploded clean rows: {len(clean_rows)}")
    print(f"Review rows: {len(review_rows)}")
    print(f"Output directory: {args.out_dir}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
