#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pd_banner_cutter.py  (v2)

Aggressively remove Wikisource-style public-domain boilerplate banners.

This version explicitly incorporates the exact banner strings used in your
banners_begone_in_my_clean_house.py (LF + CRLF variants), and keeps the broader
substring/regex matching as a safety net.

Approach (BODY ONLY; header preserved):
  1) Remove exact full-banner strings anywhere in the body (safe replacement).
  2) If any fuzzier PD banner is detected, CUT the body at the earliest banner start.

Why do both?
- Exact replacement is safest when the banner appears inline.
- Cutting is robust when Wikisource injects banner variants you haven't enumerated yet.

Dependencies: none (stdlib only)

Examples
--------
# Dry-run
python pd_banner_cutter.py --root "C:\path\to\corpus" --dry-run --inplace

# In-place (all .txt)
python pd_banner_cutter.py --root "C:\path\to\corpus" --inplace

# Only process files under clean AND not under raw (matches your older banner tool)
python pd_banner_cutter.py --root "C:\path\to\corpus" --inplace --clean-not-raw

# Mirror to a new output root
python pd_banner_cutter.py --root "./corpus" --out "./corpus_no_pd"
"""
from __future__ import annotations

import argparse
import os
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HEADER_LINE_RE = re.compile(r"^#\s*([A-Z0-9_]+)\s*:\s*(.*)\s*$")

# -----------------------------
# Long-path-safe walker (Windows)
# -----------------------------

def to_extended_length_path(p: Path) -> Path:
    if os.name != "nt":
        return p
    s = str(p)
    if s.startswith("\\\\?\\"):
        return p
    if s.startswith("\\\\"):
        return Path("\\\\?\\UNC\\" + s.lstrip("\\"))
    if re.match(r"^[A-Za-z]:\\\\", s):
        return Path("\\\\?\\" + s)
    return p


def walk_txt_files(root: Path) -> List[Path]:
    root_abs = root.expanduser().resolve()
    root_walk = to_extended_length_path(root_abs)
    out: List[Path] = []
    for dirpath, _, filenames in os.walk(str(root_walk)):
        for fn in filenames:
            if fn.lower().endswith(".txt"):
                out.append(Path(dirpath) / fn)
    return out


def path_parts_lower(p: Path) -> List[str]:
    return [part.lower() for part in p.parts]


def should_process_clean_not_raw(p: Path) -> bool:
    """
    Mirror banners_begone_in_my_clean_house.py:
      - process only if "clean" appears somewhere in the path (excluding filename)
      - skip anything under a folder named "raw"
    """
    parts = path_parts_lower(p)
    if "raw" in parts:
        return False
    return "clean" in parts[:-1]


# -----------------------------
# Header parsing
# -----------------------------

def parse_header(text: str) -> Tuple[Dict[str, str], str]:
    """
    Header = consecutive '# KEY: value' lines from start until first blank line.
    Returns (meta, body).
    """
    lines = text.splitlines()
    meta: Dict[str, str] = {}
    body_start = 0

    for i, ln in enumerate(lines):
        if ln.strip() == "":
            body_start = i + 1
            break
        m = HEADER_LINE_RE.match(ln)
        if not m:
            body_start = i
            break
        meta[m.group(1)] = m.group(2)

    body = "\n".join(lines[body_start:]) if body_start < len(lines) else ""
    return meta, body


def build_header(meta: Dict[str, str]) -> str:
    lines = []
    for k, v in meta.items():
        vv = str(v).strip()
        if vv:
            lines.append(f"# {k}: {vv}")
    return "\n".join(lines) + "\n\n"


def rebuild(meta: Dict[str, str], body: str) -> str:
    return build_header(meta) + body.lstrip("\n")


# -----------------------------
# Aggressive PD detection + exact banner removal
# -----------------------------

# Exact banner strings from banners_begone_in_my_clean_house.py (LF + CRLF)
BANNER_LF = (
    "此作品在全世界都属于\n"
    "公有领域\n"
    "，因为作者逝世已经超过年，且作品于年月日之前出版。"
)
BANNER_CRLF = BANNER_LF.replace("\n", "\r\n")

# Also allow a few obvious orthographic variants of that exact banner.
# (We still rely on regex for anything wilder.)
BANNER_LF_VARIANTS = [
    BANNER_LF,
    BANNER_CRLF,
    # Traditional-ish punctuation variants (common copy edits)
    BANNER_LF.replace("属于", "屬於"),
    BANNER_CRLF.replace("属于", "屬於"),
    BANNER_LF.replace("公有领域", "公有領域").replace("因为", "因為").replace("已经", "已經"),
    BANNER_CRLF.replace("公有领域", "公有領域").replace("因为", "因為").replace("已经", "已經"),
]

PD_SUBSTRINGS = [
    # Canonical
    "本作品在全世界都属于",
    "本作品在全世界都屬於",
    "此作品在全世界都属于",
    "此作品在全世界都屬於",
    # Descriptor inserted (本唐朝作品…, 本三國作品…, 本宋朝作品…)
    "作品在全世界都属于",
    "作品在全世界都屬於",
    # Second-line boilerplate fragments (broad)
    "公有领域",
    "公有領域",
    "因为作者",
    "因為作者",
    "作者逝世",
    "远远超过",
    "遠遠超過",
    "遠遠超过",
    # English
    "Public domain",
    "PUBLIC DOMAIN",
]

PD_REGEXES = [
    # "本/此 + (anything) + 作品 + (anything) + 在全世界都属于/屬於"
    r"[本此][\s\S]{0,80}?作品[\s\S]{0,80}?在[\s\S]{0,40}?全世界[\s\S]{0,40}?都[\s\S]{0,20}?属[于於]",
    r"[本此][\s\S]{0,80}?作品[\s\S]{0,80}?在[\s\S]{0,40}?全世界[\s\S]{0,40}?都[\s\S]{0,20}?屬[于於]",

    # Sometimes banner starts at "作品在全世界都属于/屬於" without leading 本/此
    r"作品[\s\S]{0,80}?在[\s\S]{0,40}?全世界[\s\S]{0,40}?都[\s\S]{0,20}?属[于於]",
    r"作品[\s\S]{0,80}?在[\s\S]{0,40}?全世界[\s\S]{0,40}?都[\s\S]{0,20}?屬[于於]",

    # Second-line banner line by itself (simplified/traditional mix)
    r"公有[領领]域[\s\S]{0,80}?(因|因为|因為)[\s\S]{0,80}?作者[\s\S]{0,80}?逝世[\s\S]{0,120}?已[經经]",
    r"作者[\s\S]{0,80}?逝世[\s\S]{0,200}?(远远超过|遠遠超過|遠遠超过)",

    # English variants (broad)
    r"(?i)\bpublic\s+domain\b",
    r"(?i)\bthis\s+work\s+is\s+in\s+the\s+public\s+domain\b",
]


def remove_exact_banners(body: str) -> Tuple[str, int]:
    """
    Remove exact full-banner strings anywhere in the body.
    Returns (new_body, removed_count).
    """
    removed = 0
    new = body
    for b in BANNER_LF_VARIANTS:
        c = new.count(b)
        if c:
            removed += c
            new = new.replace(b, "")
    return new, removed


def earliest_pd_cut_index(body: str) -> Optional[int]:
    cut_idx: Optional[int] = None

    # Substring hits
    for s in PD_SUBSTRINGS:
        i = body.find(s)
        if i != -1:
            cut_idx = i if cut_idx is None else min(cut_idx, i)

    # Regex hits (DOTALL to span line breaks)
    for pat in PD_REGEXES:
        m = re.search(pat, body, flags=re.DOTALL)
        if m:
            cut_idx = m.start() if cut_idx is None else min(cut_idx, m.start())

    return cut_idx


def strip_pd_banners(body: str) -> Tuple[str, bool, int, bool]:
    """
    Returns:
      (new_body, changed, exact_removed_count, did_cut)
    """
    body2, exact_removed = remove_exact_banners(body)

    did_cut = False
    idx = earliest_pd_cut_index(body2)
    if idx is not None:
        body2 = body2[:idx].rstrip() + "\n"
        did_cut = True

    changed = (body2 != body)
    return body2, changed, exact_removed, did_cut


# -----------------------------
# IO helpers
# -----------------------------

def read_text(p: Path) -> Optional[str]:
    for enc in ("utf-8-sig", "utf-8"):
        try:
            return p.read_text(encoding=enc)
        except UnicodeDecodeError:
            continue
        except OSError:
            return None
    return None


def write_text(p: Path, text: str) -> bool:
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        return True
    except OSError:
        return False


# -----------------------------
# Main
# -----------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="Aggressively remove Wikisource PD banners from corpus files.")
    ap.add_argument("--root", required=True, help="Corpus root directory")
    ap.add_argument("--out", default=None, help="Output root (if omitted, must use --inplace)")
    ap.add_argument("--inplace", action="store_true", help="Modify files in place")
    ap.add_argument("--dry-run", action="store_true", help="Do not write files; just report counts")
    ap.add_argument("--only-clean", action="store_true",
                    help="Only process files whose path contains a folder named 'clean' (case-insensitive)")
    ap.add_argument("--clean-not-raw", action="store_true",
                    help="Process only files under 'clean' and NOT under any 'raw' folder (matches your older banner tool)")

    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()
    if not root.exists():
        raise SystemExit(f"Root does not exist: {root}")

    if not args.inplace and args.out is None:
        raise SystemExit("You must pass either --inplace or --out <dir>")

    out_root = Path(args.out).expanduser().resolve() if args.out else None

    files = walk_txt_files(root)

    if args.clean_not_raw:
        files = [p for p in files if should_process_clean_not_raw(p)]
    elif args.only_clean:
        files = [p for p in files if any(part.lower() == "clean" for part in p.parts)]

    print(f"Found {len(files)} .txt files to consider under {root}")

    changed = 0
    exact_removed_total = 0
    cut_total = 0
    skipped_os = 0
    skipped_decode = 0
    wrote = 0

    for p in files:
        text = read_text(p)
        if text is None:
            try:
                _ = p.stat()
                skipped_decode += 1
            except Exception:
                skipped_os += 1
            continue

        meta, body = parse_header(text)
        new_body, did_change, exact_removed, did_cut = strip_pd_banners(body)

        if not did_change:
            continue

        changed += 1
        exact_removed_total += exact_removed
        cut_total += 1 if did_cut else 0

        new_text = rebuild(meta, new_body)

        if args.dry_run:
            continue

        if args.inplace:
            ok = write_text(p, new_text)
        else:
            assert out_root is not None
            rel = p.relative_to(root)
            ok = write_text(out_root / rel, new_text)

        if ok:
            wrote += 1
        else:
            skipped_os += 1

    print(f"Files changed: {changed}")
    print(f"Exact full-banner removals: {exact_removed_total}")
    print(f"Files cut at banner start: {cut_total}")

    if args.dry_run:
        print("Dry-run: no files written.")
    else:
        print(f"Files written: {wrote}")

    if skipped_os:
        print(f"Skipped (OS/path issues): {skipped_os}")
    if skipped_decode:
        print(f"Skipped (decode issues): {skipped_decode}")


if __name__ == "__main__":
    main()
