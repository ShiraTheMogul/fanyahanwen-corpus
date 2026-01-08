#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# I FUCKED UP THE SCRAAAAPE
from __future__ import annotations
import argparse
import re
from pathlib import Path


# Default bracket pairs: only the ones you asked for + common angle variant
BRACKET_PAIRS_DEFAULT = [
    ("「", "」"),
    ("『", "』"),
    ("【", "】"),
    ("〔", "〕"),
    ("（", "）"),
]
# Comma-like punctuation to pull up (newline before them)
COMMAS_DEFAULT = ["，", "、"]

def reduce_leading_blank_lines(text: str, max_blanks: int = 2) -> str:
    lines = text.splitlines(True)
    i = 0
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    blanks = i
    if blanks <= max_blanks:
        return text

    newline = "\n"
    for ln in lines[:blanks]:
        if ln.endswith("\r\n"):
            newline = "\r\n"
            break
        if ln.endswith("\n"):
            newline = "\n"
            break

    return (newline * max_blanks) + "".join(lines[blanks:])


def fix_newline_before_commas(text: str, comma_chars: list[str]) -> str:
    cc = "".join(re.escape(ch) for ch in comma_chars)
    # spaces/tabs + newline + spaces/tabs + comma -> comma
    return re.sub(rf"[ \t]*\r?\n[ \t]*([{cc}])", r"\1", text)


def fix_brackets_strong(text: str, open_ch: str, close_ch: str) -> str:
    """
    Strong bracket fix:
    - If open/close are separated by ANY whitespace/newlines, remove ALL whitespace/newlines INSIDE.
    - Also remove newline immediately after close.
    """
    o = re.escape(open_ch)
    c = re.escape(close_ch)

    # Replace open ... close, non-greedy, across newlines
    # Inside content: delete spaces/tabs/newlines (not other chars)
    pattern = re.compile(rf"{o}(.*?){c}", re.DOTALL)

    def repl(m: re.Match) -> str:
        inner = m.group(1)
        # Remove whitespace (space/tab/newline). Keep other chars.
        inner = re.sub(r"[ \t\r\n]+", "", inner)
        return f"{open_ch}{inner}{close_ch}"

    text = pattern.sub(repl, text)

    # Remove newline (and surrounding spaces/tabs) immediately after close
    text = re.sub(rf"{c}[ \t]*\r?\n[ \t]*", close_ch, text)
    return text


def yoink_dangling_opening_bracket(text: str, opening_set: set[str]) -> str:
    """
    If a line is exactly an opening bracket (e.g. 《), and:
      - line above exists and is nonblank
      - line above-that is blank OR doesn't exist
    then remove the newline between above-line and bracket line.
    """
    lines = text.splitlines(True)

    def is_blank(idx: int) -> bool:
        return 0 <= idx < len(lines) and lines[idx].strip() == ""

    for i in range(1, len(lines)):
        cur_stripped = lines[i].strip("\r\n")
        if cur_stripped in opening_set:
            prev = lines[i-1]
            if prev.strip() == "":
                continue  # don't merge across blank lines
            # "If there's two, assume not issue": only merge if i-2 is blank or doesn't exist
            if i - 2 >= 0 and not is_blank(i - 2):
                continue
            # Merge: remove newline at end of prev, then append current line as-is
            prev_no_nl = prev.rstrip("\r\n")
            # Keep original newline style from prev line if it had one
            lines[i-1] = prev_no_nl + cur_stripped + ("\r\n" if prev.endswith("\r\n") else "\n")
            lines[i] = ""  # delete bracket-only line; it's been attached
    return "".join(lines)


# ---------------------------------
# Optional heuristic: prose re-flow
# ---------------------------------

STRONG_CLOSERS = set("。！？；：」』》〉）】〕")  # "done" punctuation
# (we are not changing these, only using them as signals)

def prose_reflow_paragraphs(text: str, *,
                            min_lines: int = 6,
                            short_line_len: int = 6,
                            short_line_ratio: float = 0.65,
                            strong_closer_ratio_max: float = 0.25) -> str:
    """
    Operate per paragraph (split by blank lines).
    If paragraph looks like wrapped prose (many short lines, low punctuation closures),
    join single newlines inside it.
    """
    # Split into blocks keeping blank lines as separators
    # This preserves paragraph breaks.
    blocks = re.split(r"(\r?\n\s*\r?\n+)", text)

    out = []
    for blk in blocks:
        if re.fullmatch(r"\r?\n\s*\r?\n+", blk or ""):
            out.append(blk)
            continue

        # Analyze lines in this block
        lines = [ln for ln in re.split(r"\r?\n", blk) if ln is not None]
        # Ignore blocks that are trivially small
        nonblank_lines = [ln for ln in lines if ln.strip() != ""]
        if len(nonblank_lines) < min_lines:
            out.append(blk)
            continue

        lens = [len(re.sub(r"\s+", "", ln)) for ln in nonblank_lines]
        short_count = sum(1 for L in lens if L <= short_line_len)
        short_ratio = short_count / max(1, len(nonblank_lines))

        closer_count = 0
        for ln in nonblank_lines:
            s = ln.rstrip()
            if s and s[-1] in STRONG_CLOSERS:
                closer_count += 1
        closer_ratio = closer_count / max(1, len(nonblank_lines))

        if short_ratio >= short_line_ratio and closer_ratio <= strong_closer_ratio_max:
            # Join single newlines inside block: replace \n between nonblank lines with nothing
            # Keep existing line breaks that are "blank lines" (none inside blk by construction)
            joined = re.sub(r"\r?\n", "", blk)
            out.append(joined)
        else:
            out.append(blk)

    return "".join(out)


# -------------
# Pipeline + IO
# -------------

def normalize_v2(text: str,
                 bracket_pairs: list[tuple[str, str]],
                 comma_chars: list[str],
                 enable_prose_reflow: bool) -> str:
    text = reduce_leading_blank_lines(text, max_blanks=2)

    opening_set = {o for o, _ in bracket_pairs}
    text = yoink_dangling_opening_bracket(text, opening_set)

    for o, c in bracket_pairs:
        text = fix_brackets_strong(text, o, c)

    text = fix_newline_before_commas(text, comma_chars)

    if enable_prose_reflow:
        text = prose_reflow_paragraphs(text)

    return text


def iter_txt_files(root: Path):
    for p in root.rglob("*.txt"):
        if p.is_file():
            yield p


def read_text_guess_encoding(path: Path) -> tuple[str, str]:
    for enc in ("utf-8", "utf-8-sig", "gb18030"):
        try:
            return path.read_text(encoding=enc), enc
        except UnicodeDecodeError:
            continue
    return path.read_text(encoding="utf-8", errors="replace"), "utf-8 (errors=replace)"


def write_text(path: Path, text: str, enc: str):
    if "errors=replace" in enc:
        path.write_text(text, encoding="utf-8")
    else:
        path.write_text(text, encoding=enc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", help="Root folder of the corpus")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--backup", action="store_true")
    ap.add_argument("--verbose", action="store_true")

    ap.add_argument("--prose-reflow", action="store_true",
                    help="Optional heuristic: reflow paragraphs that look like wrapped prose.")

    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()
    if not root.exists():
        raise SystemExit(f"Root does not exist: {root}")

    bracket_pairs = list(BRACKET_PAIRS_DEFAULT)
    comma_chars = list(COMMAS_DEFAULT)

    scanned = changed = 0

    for path in iter_txt_files(root):
        scanned += 1
        original, enc = read_text_guess_encoding(path)
        fixed = normalize_v2(original, bracket_pairs, comma_chars, args.prose_reflow)

        if fixed != original:
            changed += 1
            if args.verbose or args.dry_run:
                print(f"CHANGED: {path} (encoding={enc})")

            if not args.dry_run:
                if args.backup:
                    bak = path.with_suffix(path.suffix + ".bak2")
                    if not bak.exists():
                        write_text(bak, original, enc)
                write_text(path, fixed, enc)

    print(f"Done. Scanned {scanned} .txt files; changed {changed}.")


if __name__ == "__main__":
    main()
