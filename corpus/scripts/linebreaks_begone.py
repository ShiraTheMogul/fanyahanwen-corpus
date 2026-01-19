#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
fix_shuowen_linebreaks_inplace.py

Runs on the current directory by default (recursive), overwrites .txt in place, no backups.

Run:
  python fix_shuowen_linebreaks_inplace.py
Optional:
  python fix_shuowen_linebreaks_inplace.py --dir "PATH/TO/FOLDER"
"""

import argparse
import re
from pathlib import Path

COLON_LINES = {":", "："}  # ASCII + fullwidth colon

# Basic punctuation that usually ends an entry sentence in this dataset.
END_PUNCT = ("。", "！", "？", "」", "”")

# “This line starts a new entry headword” (character + optional parens + colon).
# Examples: 小（）：..., 少：..., 𠔁：..., 呬（）：...
HEADWORD_RE = re.compile(
    r"^\s*(["
    r"\u3400-\u9fff"          # CJK Unified Ideographs Extension A + BMP
    r"\U00020000-\U0002FA1F"  # Extensions B.. etc
    r"]{1,3})"                # headword is usually 1 char, occasionally 2-3
    r"(?:（[^）]*）)?"
    r"\s*[：:]\s*"
)

# MediaWiki UI junk lines we want to drop.
JUNK_EXACT = {
    "◄", "►",
    "[", "]",
    "编辑",
    "編輯",
}

JUNK_RE_LIST = [
    re.compile(r"^\s*說文解字\s*$"),              # page header repeated
    re.compile(r"^\s*說文解字/[\d]+\s*$"),        # like 說文解字/02
    re.compile(r"^\s*卷[一二三四五六七八九十百千0-9]+\s*$"),  # bare “卷二”
    re.compile(r"^\s*姊妹计划：数据项\s*$"),       # site-specific artifact seen in your file
    re.compile(r"^\s*^\s*$"),                     # (handled later, but ok)
]


def is_headword_line(line: str) -> bool:
    return HEADWORD_RE.match(line) is not None


def is_section_header(line: str) -> bool:
    # Keep headers like “小部”, “八部”, “口部” etc.
    # This is intentionally conservative: only 1-4 chars ending with 部.
    s = line.strip()
    return bool(re.fullmatch(r"[\u3400-\u9fff\U00020000-\U0002FA1F]{1,4}部", s))


def should_drop_line(line: str) -> bool:
    s = line.strip()

    if not s:
        return True

    if s in JUNK_EXACT:
        return True

    for rx in JUNK_RE_LIST:
        if rx.match(s):
            # We keep genuine chapter titles like "卷二" only if you want them.
            # Right now, this drops them (because in your scrape they behave like nav clutter).
            return True

    # Drop pure bracketed UI labels like "[编辑]" if they survived in one line.
    if re.fullmatch(r"\[\s*(编辑|編輯)\s*\]", s):
        return True

    # Drop a line that is only the replacement char.
    if s == "�":
        return True

    return False


def rectify_shuowen_text(text: str) -> str:
    # Normalize newlines
    text = text.replace("\r\n", "\n").replace("\r", "\n")

    # Remove replacement characters inside lines as well.
    # (If you prefer to keep them, delete this line.)
    text = text.replace("�", "")

    lines = text.split("\n")

    # Pass A: fix the known colon/paren split patterns (your original “easy wins”).
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]

        # Rule A1: "A" "\n" ":" "\n" "B"  ->  "A：B"
        if line.strip() in COLON_LINES:
            prev = out.pop() if out else ""
            next_line = lines[i + 1] if (i + 1) < len(lines) else ""
            out.append(prev.rstrip() + "：" + next_line.lstrip())
            i += 2
            continue

        # Rule A2: "X（" "\n" "）：..."  -> "X（）：..."
        if out and out[-1].rstrip().endswith(("（", "(")):
            nxt = line.lstrip()
            if nxt.startswith(("）：", "):", "）:", "):")):
                out[-1] = out[-1].rstrip() + nxt
                i += 1
                continue

        # Rule A3: "X（" "\n" "）"  -> "X（）"
        if line.strip() in {"）", ")"} and out and out[-1].rstrip().endswith(("（", "(")):
            out[-1] = out[-1].rstrip() + line.strip()
            i += 1
            continue

        out.append(line)
        i += 1

    text = "\n".join(out)

    # Rule A4: collapse whitespace-newline around colons if scraping introduced it
    text = re.sub(r"[ \t]*([：:])[ \t]*\n[ \t]*", r"\1", text)

    # Pass B: drop obvious MediaWiki/nav junk and normalize spacing.
    kept = []
    for raw in text.split("\n"):
        s = raw.strip()

        # Keep section headers (like “口部”) even though they match “short CJK lines”.
        if is_section_header(s):
            kept.append(s)
            continue

        if should_drop_line(s):
            continue

        kept.append(s)

    # Pass C: smart-join lines that are clearly wrapped mid-definition.
    #
    # Pattern:
    # - If current line is NOT a headword start
    # - and previous line does NOT end with sentence punctuation
    # then join current onto previous with no newline.
    #
    # This avoids gluing separate entries, because entry lines start with “X：...”
    joined = []
    for line in kept:
        if not joined:
            joined.append(line)
            continue

        prev = joined[-1]

        if (not is_headword_line(line)) and (not prev.endswith(END_PUNCT)):
            # Join with no extra space (Chinese text usually shouldn’t gain spaces)
            joined[-1] = prev + line
        else:
            joined.append(line)

    # Final: remove repeated blank lines (there should be none), return with trailing newline
    fixed = "\n".join(joined).strip() + "\n"
    return fixed


def process_file(path: Path) -> bool:
    original = path.read_text(encoding="utf-8")
    fixed = rectify_shuowen_text(original)
    if fixed != original:
        path.write_text(fixed, encoding="utf-8")
        return True
    return False


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--dir",
        default=".",
        help="Directory to scan recursively for .txt files (default: current directory)",
    )
    args = ap.parse_args()

    root = Path(args.dir).resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"Not a directory: {root}")

    total = 0
    changed = 0

    for p in root.rglob("*.txt"):
        total += 1
        if process_file(p):
            changed += 1
            print(f"[fixed] {p}")
        else:
            print(f"[ok]    {p}")

    print(f"\nDone. Folder: {root}\nFiles scanned: {total}\nFiles changed: {changed}")


if __name__ == "__main__":
    main()
