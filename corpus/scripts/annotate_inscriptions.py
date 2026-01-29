#!/usr/bin/env python3
# annotate_inscriptions.py

import argparse
import os
import re
from pathlib import Path
from typing import List, Optional, Tuple

CH_COMMA = "，"

# Extend this set as you encounter more titles in your dataset.
# Rule of thumb: titles are usually short and institutional roles.
JOB_TITLES = {
    "王",  # king
    "祝",  # liturgist
    "史",  # scribe
    "師",  # army leader
    "臣", # servant - shouldn't come up...
    "侯", # maybe a fang leader arrives
}


def read_lines(path: Path) -> List[str]:
    with path.open("r", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines(True)  # keep line endings


def write_lines(path: Path, lines: List[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        f.writelines(lines)


def first_inscription_line(lines: List[str]) -> Optional[str]:
    for raw in lines:
        line = raw.rstrip("\r\n")
        if not line.strip():
            continue
        if line.startswith("#"):
            continue
        return line
    return None


def meta_prefix(key: str) -> str:
    return f"# {key}:"


def find_meta_line(lines: List[str], key: str) -> Optional[Tuple[int, str]]:
    prefix = meta_prefix(key)
    for i, raw in enumerate(lines):
        line = raw.rstrip("\r\n")
        if line.startswith(prefix):
            value = line.split(":", 1)[1].strip()
            return (i, value)
    return None


def preferred_line_ending(lines: List[str]) -> str:
    for raw in lines:
        if raw.endswith("\r\n"):
            return "\r\n"
        if raw.endswith("\n"):
            return "\n"
    return "\n"


def set_meta_value(lines: List[str], key: str, value: str) -> None:
    found = find_meta_line(lines, key)
    ending = preferred_line_ending(lines)
    new_raw = f"# {key}: {value}{ending}"

    if found:
        idx, _old = found
        # keep the existing line ending if possible
        if lines[idx].endswith("\r\n"):
            ending = "\r\n"
        elif lines[idx].endswith("\n"):
            ending = "\n"
        lines[idx] = f"# {key}: {value}{ending}"
        return

    # Insert after last metadata line at the top
    insert_at = 0
    for i, raw in enumerate(lines):
        if raw.startswith("#"):
            insert_at = i + 1
            continue
        break
    lines.insert(insert_at, new_raw)


def remove_meta_line(lines: List[str], key: str) -> Optional[str]:
    found = find_meta_line(lines, key)
    if not found:
        return None
    idx, _val = found
    return lines.pop(idx)


def insert_meta_line_before(lines: List[str], raw_line: str, before_key: str) -> None:
    """
    Insert a prepared '# KEY: ...' line before '# BEFORE_KEY: ...' if it exists,
    else insert at end of header metadata block.
    """
    before = find_meta_line(lines, before_key)
    if before:
        before_idx, _ = before
        lines.insert(before_idx, raw_line)
        return

    # end of header metadata block
    insert_at = 0
    for i, raw in enumerate(lines):
        if raw.startswith("#"):
            insert_at = i + 1
            continue
        break
    lines.insert(insert_at, raw_line)


def ensure_meta_before(lines: List[str], key: str, before_key: str) -> None:
    """
    If key exists, move it before before_key (if before_key exists).
    """
    raw = remove_meta_line(lines, key)
    if raw is None:
        return
    insert_meta_line_before(lines, raw, before_key)


def parse_categories(cat_value: str) -> List[str]:
    if not cat_value.strip():
        return []
    parts = [p.strip() for p in cat_value.split(CH_COMMA)]
    return [p for p in parts if p]


def join_categories(cats: List[str]) -> str:
    return CH_COMMA.join(cats)


def dedupe_preserve_order(items: List[str]) -> List[str]:
    seen = set()
    out = []
    for x in items:
        if x in seen:
            continue
        seen.add(x)
        out.append(x)
    return out


def clean_uncertainty(text: str) -> str:
    # If there is a "（？）" act as if it isn't there
    return text.replace("（？）", "").strip()


def infer_nation_period_stage(times: str) -> Tuple[Optional[str], Optional[str], Optional[str]]:
    t = (times or "").strip()
    if not t:
        return (None, None, None)

    if "商" in t:
        stage = t.replace("商代", "").replace("商", "").strip() or None
        return ("商朝", None, stage)

    zhou_markers = ["戰國", "春秋", "西周", "東周", "秦"]
    if any(m in t for m in zhou_markers):
        nation = "周朝"
        if "秦代" in t or "秦" in t:
            period = "秦代"
        elif "戰國" in t:
            period = "戰國"
        elif "春秋" in t:
            period = "春秋"
        elif "西周" in t:
            period = "西周"
        elif "東周" in t:
            period = "東周"
        else:
            period = None

        stage = t
        if period:
            stage = stage.replace(period, "").strip()
        stage = stage.replace("秦", "").strip()
        stage = stage or None
        return (nation, period, stage)

    return (None, None, None)


def endswith_tag(inscription: str, tag: str) -> bool:
    s = inscription.rstrip()
    return s.endswith(tag)


def infer_diviner(inscription: str) -> Tuple[Optional[str], Optional[str]]:
    """
    Returns (author, category_to_add)

    Rules:
    - 卜貞 (empty X) => (None, None)
    - 卜我貞 => (None, 隊貞)
    - if X is a JOB_TITLE => (None, X貞)  [category only]
    - else => (X, None)                  [author only]
    """
    m = re.search(r"卜(.*?)貞", inscription)
    if not m:
        return (None, None)

    x = clean_uncertainty(m.group(1))

    if x == "":
        return (None, None)

    if x == "我":
        return (None, "隊貞")

    if x in JOB_TITLES:
        return (None, f"{x}貞")

    return (x, None)


def annotate_file(path: Path, apply: bool) -> Tuple[bool, str]:
    lines = read_lines(path)
    inscription = first_inscription_line(lines)

    times_meta = find_meta_line(lines, "TIMES")
    times_value = times_meta[1] if times_meta else ""

    nation, period, stage = infer_nation_period_stage(times_value)

    cats_meta = find_meta_line(lines, "CATEGORIES")
    existing_cats = parse_categories(cats_meta[1]) if cats_meta else []
    cats = list(existing_cats)

    # Periodisation goes into categories
    if period:
        cats.append(period)
    if stage:
        cats.append(stage)

    author_to_set = None

    if inscription:
        author, div_cat = infer_diviner(inscription)
        if div_cat:
            cats.append(div_cat)
        if author:
            author_to_set = author

        if endswith_tag(inscription, "告"):
            cats.append("告")
        if endswith_tag(inscription, "用"):
            cats.append("用")
        if "雨" in inscription:
            cats.append("雨")

    cats = dedupe_preserve_order([c for c in cats if c])

    before = "".join(lines)

    if nation:
        set_meta_value(lines, "NATION", nation)
    if author_to_set:
        set_meta_value(lines, "AUTHOR", author_to_set)
    if cats:
        set_meta_value(lines, "CATEGORIES", join_categories(cats))

    # Re-ordering constraints:
    # - NATION and AUTHOR before TIMES
    ensure_meta_before(lines, "NATION", "TIMES")
    ensure_meta_before(lines, "AUTHOR", "TIMES")

    # - CATEGORIES before ID
    ensure_meta_before(lines, "CATEGORIES", "ID")

    after = "".join(lines)
    changed = (after != before)

    if changed and apply:
        write_lines(path, lines)

    if not nation:
        return (changed, "manual_review: could not infer NATION from # TIMES:")
    return (changed, "ok")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Append oracle-bone authorship + categories into metadata headers (# ...)."
    )
    ap.add_argument("root", help="Root folder to scan.")
    ap.add_argument("--apply", action="store_true", help="Write changes (default: dry-run).")
    ap.add_argument("--ext", default=".txt", help="File extension to process (default: .txt).")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.exists():
        print(f"[error] root not found: {root}")
        return 2

    changed_count = 0
    total = 0
    manual = []

    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(args.ext):
                continue
            path = Path(dirpath) / fn
            total += 1

            changed, status = annotate_file(path, apply=args.apply)
            if changed:
                changed_count += 1
                if not args.apply:
                    print(f"[dry-run] would update: {path}")
                else:
                    print(f"[updated] {path}")

            if status.startswith("manual_review"):
                manual.append(str(path))

    print(f"\n[done] total={total} changed={changed_count} apply={args.apply}")
    if manual:
        print("\n[manual_review] could not infer NATION from # TIMES: (showing up to 50)")
        for p in manual[:50]:
            print(f" - {p}")
        if len(manual) > 50:
            print(f" ... and {len(manual) - 50} more")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
