#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys

TARGET_SUFFIX = ".txt"
AUTHOR_LINE = "# AUTHOR: 柯劭忞"

def split_header_body(text: str):
    """
    Same header rule as the corpus:
    - consecutive lines starting with '#'
    - first blank line ends the header
    """
    lines = text.splitlines(keepends=True)

    if not lines or not lines[0].lstrip().startswith("#"):
        return "", text, False

    header_end = None
    for i, line in enumerate(lines):
        if line.strip() == "":
            header_end = i
            break
        if not line.lstrip().startswith("#"):
            return "", text, False

    if header_end is None:
        return "".join(lines), "", True

    header = "".join(lines[:header_end]).rstrip("\r\n")
    body = "".join(lines[header_end:]).lstrip("\r\n")
    return header, body, True


def process_file(path: str):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    header, body, has_header = split_header_body(text)
    if not has_header:
        return False

    new_header = header + "\n" + NATION_LINE + "\n" + TIMES_LINE
    new_text = new_header + "\n\n" + body if body else new_header + "\n"

    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)

    return True


def main(root: str):
    root = os.path.abspath(root)
    updated = 0

    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(TARGET_SUFFIX):
                full_path = os.path.join(dirpath, name)
                if process_file(full_path):
                    updated += 1
                    print(f"✓ added: {os.path.relpath(full_path, root)}")

    print(f"\nDone. Updated {updated} files.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python add_maoshixu_author.py <shijing_root>")
        sys.exit(1)

    main(sys.argv[1])