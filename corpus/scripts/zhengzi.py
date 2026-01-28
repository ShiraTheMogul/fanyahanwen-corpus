# Checks if a script has any non-Han characters and hits them with an orbital space laser manned by confucius himself
# Updated to CJK Extension J.

import argparse
import fnmatch
import os
import tempfile
from typing import Tuple


# ---- Character allowlist (copied from your zhengzi.py) ----

def is_han_character(char: str) -> bool:
    code_point = ord(char)

    if 0x4E00 <= code_point <= 0x9FFF:   # CJK Unified Ideographs
        return True
    if 0x3400 <= code_point <= 0x4DBF:   # Extension A
        return True
    if 0x20000 <= code_point <= 0x2A6DF: # Extension B
        return True
    if 0x2A700 <= code_point <= 0x2B73F: # Extension C
        return True
    if 0x2B740 <= code_point <= 0x2B81D: # Extension D
        return True
    if 0x2B820 <= code_point <= 0x2CEAD: # Extension E
        return True
    if 0x2CEB0 <= code_point <= 0x2EBE0: # Extension F
        return True
    if 0x31350 <= code_point <= 0x323AF: # Extension H
        return True
    if 0x2EBF0 <= code_point <= 0x2EE5D: # Extension I
        return True
    if 0x323B0 <= code_point <= 0x33479: # Extension J
        return True
    if 0x2F800 <= code_point <= 0x2FA1F: # Compatibility Supplement
        return True

    return False


def is_traditional_punctuation(char: str) -> bool:
    code_point = ord(char)

    if 0x3000 <= code_point <= 0x303F:  # CJK Symbols and Punctuation
        return True
    if 0xFE10 <= code_point <= 0xFE1F:  # Vertical Forms
        return True
    if 0xFE30 <= code_point <= 0xFE4F:  # CJK Compatibility Forms
        return True
    if 0xFF00 <= code_point <= 0xFFEF:  # Halfwidth and Fullwidth Forms
        return True

    traditional_punctuation = {
        '。', '，', '、', '；', '：', '？', '！', '「', '」', '『', '』',
        '《', '》', '（', '）', '［', '］', '｛', '｝', '【', '】', '…',
        '—', '～', '・', '〃', '〄', '々', '〆', '〇', '〈', '〉', '〖',
        '〗', '〘', '〙', '〚', '〛', '〜', '〝', '〞', '〟', '〰', '〱',
        '〲', '〳', '〴', '〵', '〶', '〷', '〸', '〹', '〺'
    }
    return char in traditional_punctuation


def is_allowed_character(char: str) -> bool:
    return is_han_character(char) or is_traditional_punctuation(char) or char in "\n\r\t "


def filter_han_text(text: str) -> str:
    out = []
    for ch in text:
        if is_allowed_character(ch):
            out.append(ch)
    return "".join(out)


# ---- Header preservation ----

def split_header_body(text: str) -> Tuple[str, str, bool]:
    """
    Returns (header, body, has_header)

    Header rule:
      - Starting from top: consecutive lines beginning with '#'
      - then the first blank line ends the header
    """
    lines = text.splitlines(keepends=True)

    if not lines:
        return "", "", False

    # Must start with a '#' line
    if not lines[0].lstrip().startswith("#"):
        return "", text, False

    header_end_idx = None
    seen_hash_run = True

    for i, line in enumerate(lines):
        stripped = line.strip()

        # While in header run: accept "# ..." lines
        if seen_hash_run:
            if stripped == "":
                header_end_idx = i
                break
            if line.lstrip().startswith("#"):
                continue
            # If we hit a non-# line before blank line, treat as "no header"
            return "", text, False

    if header_end_idx is None:
        # File is only header, no blank line; treat whole file as header
        return "".join(lines), "", True

    header = "".join(lines[:header_end_idx]).rstrip("\r\n")
    body = "".join(lines[header_end_idx:])  # includes the blank line(s)
    # Normalize to exactly one blank line after header when re-writing
    body = body.lstrip("\r\n")
    return header, body, True


def process_file(path: str, inplace: bool, suffix: str, skip_no_header: bool) -> bool:
    """
    Returns True if processed (written), False if skipped.
    """
    with open(path, "r", encoding="utf-8") as f:
        original = f.read()

    header, body, has_header = split_header_body(original)

    if skip_no_header and not has_header:
        return False

    filtered_body = filter_han_text(body)

    # Recompose
    if has_header:
        new_text = header + "\n\n" + filtered_body.lstrip("\r\n")
    else:
        new_text = filtered_body

    # If no change, skip writing
    if new_text == original:
        return False

    if inplace:
        # Atomic write: write temp next to file then replace
        dirpath = os.path.dirname(path) or "."
        fd, tmp_path = tempfile.mkstemp(prefix=".zhengzi_", suffix=".tmp", dir=dirpath)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as tf:
                tf.write(new_text)
            os.replace(tmp_path, path)
        finally:
            # If something went wrong before replace, ensure tmp is removed
            if os.path.exists(tmp_path):
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass
    else:
        base, ext = os.path.splitext(path)
        out_path = f"{base}{suffix}{ext}"
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(new_text)

    return True


def iter_files(root: str, pattern: str):
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if fnmatch.fnmatch(name, pattern):
                yield os.path.join(dirpath, name)


def main() -> None:
    ap = argparse.ArgumentParser(description="Han-only filter that preserves # metadata headers.")
    ap.add_argument("root", help="Root directory to process recursively")
    ap.add_argument("--pattern", default="*.txt", help="Filename pattern, e.g. *.txt (default)")
    ap.add_argument("--inplace", action="store_true", help="Overwrite files in place (recommended)")
    ap.add_argument("--suffix", default="_han_only", help="Suffix for output files if not --inplace")
    ap.add_argument("--skip-no-header", action="store_true", help="Only process files that start with a # metadata header")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        raise SystemExit(f"Not a directory: {root}")

    processed = 0
    skipped = 0

    for path in iter_files(root, args.pattern):
        try:
            did = process_file(
                path=path,
                inplace=args.inplace,
                suffix=args.suffix,
                skip_no_header=args.skip_no_header,
            )
            if did:
                processed += 1
                print(f"✓ {path}")
            else:
                skipped += 1
        except Exception as e:
            print(f"✗ {path} :: {e}")

    print(f"\nOrbital strike succeeded. Obliterated: {processed}, Skipped/unchanged: {skipped}")


if __name__ == "__main__":
    main()