#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import fnmatch
import os
import re
import sys
import time
from typing import Dict, Iterable, List, Optional, Tuple

import requests

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"
HEADERS = {
    "User-Agent": (
        "FanyaHanwenScraper/0.3"
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

META_PAGE_RX = re.compile(r"^\s*#\s*PAGE_TITLE:\s*(.+?)\s*$", flags=re.M)
META_DISPLAY_RX = re.compile(r"^\s*#\s*DISPLAY_TITLE:\s*(.+?)\s*$", flags=re.M)
HEADING_LINE_RX = re.compile(r"^(?P<eq>==+)\s*(?P<title>[^=]+?)\s*(?P=eq)\s*$", flags=re.M)


# -------------------------
# “zhengzi” core, but header-preserving and no western spaces
# -------------------------

def is_han_character(ch: str) -> bool:
    cp = ord(ch)
    return (
        (0x4E00 <= cp <= 0x9FFF) or
        (0x3400 <= cp <= 0x4DBF) or
        (0x20000 <= cp <= 0x2A6DF) or
        (0x2A700 <= cp <= 0x2B73F) or
        (0x2B740 <= cp <= 0x2B81D) or
        (0x2B820 <= cp <= 0x2CEAD) or
        (0x2CEB0 <= cp <= 0x2EBE0) or
        (0x2EBF0 <= cp <= 0x2EE5D) or
        (0x31350 <= cp <= 0x323AF) or
        (0x323B0 <= cp <= 0x33479) or
        (0x2F800 <= cp <= 0x2FA1F)
    )

def is_cjk_punct(ch: str) -> bool:
    cp = ord(ch)
    if 0x3000 <= cp <= 0x303F:
        return True
    if 0xFE10 <= cp <= 0xFE1F:
        return True
    if 0xFE30 <= cp <= 0xFE4F:
        return True
    if 0xFF00 <= cp <= 0xFFEF:
        return True
    return ch in {'。','，','、','；','：','？','！','「','」','『','』','《','》','（','）','【','】','…','—','～','〈','〉','〜'}

def split_header_body(text: str) -> Tuple[str, str, bool]:
    lines = text.splitlines(keepends=True)
    if not lines:
        return "", "", False
    if not lines[0].lstrip().startswith("#"):
        return "", text, False

    header_end = None
    for i, line in enumerate(lines):
        if line.strip() == "":
            header_end = i
            break
        if not line.lstrip().startswith("#"):
            return "", text, False

    if header_end is None:
        return "".join(lines).rstrip("\r\n"), "", True

    header = "".join(lines[:header_end]).rstrip("\r\n")
    body = "".join(lines[header_end:]).lstrip("\r\n")
    return header, body, True

def zhengzi_filter_preserve_header(text: str) -> str:
    header, body, has = split_header_body(text)

    out_chars: List[str] = []
    for ch in body:
        if is_han_character(ch) or is_cjk_punct(ch) or ch in "\n\r\t":
            out_chars.append(ch)
        # crucially: NOT allowing ASCII space " "

    body2 = "".join(out_chars)
    body2 = body2.replace(" ", "").replace("\u3000", "")
    body2 = body2.replace("\r\n", "\n").replace("\r", "\n")
    body2 = re.sub(r"\n{3,}", "\n\n", body2).strip() + "\n"

    if has:
        return header + "\n\n" + body2
    return body2


# -------------------------
# Utils
# -------------------------

def iter_files(root: str, pattern: str) -> Iterable[str]:
    for dirpath, _, filenames in os.walk(root):
        if os.path.basename(dirpath) == "bak":
            continue
        for name in filenames:
            if fnmatch.fnmatch(name, pattern):
                yield os.path.join(dirpath, name)

def read_meta(text: str) -> Tuple[Optional[str], Optional[str]]:
    mp = META_PAGE_RX.search(text)
    md = META_DISPLAY_RX.search(text)
    return (mp.group(1).strip() if mp else None, md.group(1).strip() if md else None)

def preface_path_for(poem_path: str, display_title: str) -> str:
    folder = os.path.dirname(poem_path)
    base = display_title if display_title else os.path.splitext(os.path.basename(poem_path))[0]
    return os.path.join(folder, f"{base}_毛詩序.txt")

def ensure_parent(path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)

def write_bak(root: str, target: str) -> None:
    rel = os.path.relpath(target, root)
    bak_path = os.path.join(root, "bak", rel)
    ensure_parent(bak_path)
    if os.path.exists(target):
        with open(target, "r", encoding="utf-8") as f:
            old = f.read()
        with open(bak_path, "w", encoding="utf-8") as f:
            f.write(old)

def api_get(session: requests.Session, params: Dict, timeout: int = 30) -> Dict:
    params = dict(params)
    params["format"] = "json"
    params["formatversion"] = 2
    r = session.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=timeout)
    r.raise_for_status()
    data = r.json()
    if "error" in data:
        raise RuntimeError(str(data["error"]))
    return data

def fetch_wikitext(session: requests.Session, page_title: str) -> str:
    data = api_get(session, {
        "action": "query",
        "prop": "revisions",
        "titles": page_title,
        "rvprop": "content",
        "rvslots": "main",
    })
    pages = data.get("query", {}).get("pages", [])
    if not pages:
        return ""
    revs = pages[0].get("revisions", [])
    if not revs:
        return ""
    return revs[0].get("slots", {}).get("main", {}).get("content", "") or ""

def _strip_template_noise_leading_lines(chunk: str) -> str:
    lines = chunk.splitlines()
    out = []
    started = False
    for line in lines:
        s = line.strip()
        if not started:
            if s == "":
                continue
            if s.startswith("{{") and s.endswith("}}"):
                continue
            if s.startswith("<") and s.endswith(">"):
                continue
            started = True
        out.append(line)
    return "\n".join(out).strip()

def extract_mao_shixu(wt: str) -> str:
    if not wt:
        return ""

    headings = []
    for m in HEADING_LINE_RX.finditer(wt):
        eq = m.group("eq")
        title = m.group("title").strip()
        level = len(eq)
        headings.append((m.start(), m.end(), level, title))

    def extract_until(start_end_idx: int, start_pos: int, start_level: Optional[int]) -> str:
        if not headings:
            return wt[start_pos:].strip()
        next_pos = None
        for (hs, he, lvl, title) in headings:
            if hs <= start_end_idx:
                continue
            if start_level is None or lvl <= start_level:
                next_pos = hs
                break
        return (wt[start_pos:next_pos] if next_pos is not None else wt[start_pos:]).strip()

    # 1) Heading 毛詩序 (any level)
    for (hs, he, lvl, title) in headings:
        if title.replace(" ", "") == "毛詩序":
            chunk = extract_until(he, he, lvl)
            return _strip_template_noise_leading_lines(chunk)

    # 2) Line-start marker
    m2 = re.search(r"^毛詩序[：:\s]*", wt, flags=re.M)
    if m2:
        start = m2.end()
        chunk = extract_until(start, start, None)
        return _strip_template_noise_leading_lines(chunk)

    # 3) Anywhere fallback
    i = wt.find("毛詩序")
    if i != -1:
        chunk = extract_until(i, i, None)
        return _strip_template_noise_leading_lines(chunk)

    return ""

def wikitext_min_clean(t: str) -> str:
    if not t:
        return ""
    t = re.sub(r"<ref[^>]*>[\s\S]*?</ref>", "", t, flags=re.I)
    t = re.sub(r"<references\s*/\s*>", "", t, flags=re.I)
    t = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", t)
    t = re.sub(r"\[\[([^\]]+)\]\]", r"\1", t)
    # drop templates
    t = re.sub(r"\{\{[^{}]+\}\}", "", t)
    # drop tags
    t = re.sub(r"<[^>]+>", "", t)
    t = t.replace("\r\n", "\n").replace("\r", "\n")
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip() + "\n"

def write_report(root: str, misses: List[str]) -> None:
    path = os.path.join(root, "mao_shixu_missing_report.txt")
    ensure_parent(path)
    with open(path, "w", encoding="utf-8") as f:
        for line in misses:
            f.write(line.rstrip() + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", help="Root corpus folder")
    ap.add_argument("--pattern", default="*.txt")
    ap.add_argument("--sleep", type=float, default=0.4)
    ap.add_argument("--only-missing", action="store_true")
    ap.add_argument("--bak", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    print(f"[mao_shixu_grabber] Root resolved to: {root}")

    session = requests.Session()
    cache: Dict[str, str] = {}

    misses: List[str] = []
    processed = 0
    skipped = 0
    no_mao = 0
    no_meta = 0

    for poem_path in iter_files(root, args.pattern):
        if poem_path.endswith("_毛詩序.txt"):
            continue

        with open(poem_path, "r", encoding="utf-8") as f:
            poem_text = f.read()

        page_title, display_title = read_meta(poem_text)
        if not page_title:
            no_meta += 1
            continue

        out_path = preface_path_for(poem_path, display_title or "")
        if args.only_missing and os.path.exists(out_path):
            skipped += 1
            continue

        if page_title not in cache:
            try:
                cache[page_title] = fetch_wikitext(session, page_title)
            except Exception as e:
                misses.append(f"API_FAIL\t{page_title}\t{os.path.relpath(poem_path, root)}\t{e}")
                continue
            time.sleep(args.sleep)

        wt = cache[page_title]
        mao = extract_mao_shixu(wt)
        if not mao.strip():
            no_mao += 1
            misses.append(f"NO_MAO\t{page_title}\t{os.path.relpath(poem_path, root)}")
            continue

        header, _, has = split_header_body(poem_text)
        header = header.strip() if has else ""

        body = wikitext_min_clean(mao)
        ensure_parent(out_path)

        if args.bak:
            write_bak(root, out_path)

        # write raw preface with header
        raw_preface = (header + "\n\n" + body) if header else body

        # now zhengzi-filter body (preserving header)
        cleaned_preface = zhengzi_filter_preserve_header(raw_preface)

        with open(out_path, "w", encoding="utf-8") as f:
            f.write(cleaned_preface)

        processed += 1
        print(f"✓ {page_title} -> {os.path.relpath(out_path, root)}")

    write_report(root, misses)

    print("\nDone.")
    print(f"Processed: {processed}")
    print(f"Skipped: {skipped}")
    print(f"Missing metadata: {no_meta}")
    print(f"No 毛詩序 extracted: {no_mao}")
    print(f"Report: {os.path.join(root, 'mao_shixu_missing_report.txt')}")


if __name__ == "__main__":
    main()
