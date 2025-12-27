#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PDF (text-layer) -> Pleco PQB builder (Kangxi-style, v11)

What v8 fixes:
- Geometry-based row reconstruction via pdfplumber.extract_words() (no OCR)
- **Dynamic per-page column split** (x-axis drifts page-to-page; uses bold/large text as anchor when available)
- 2-column reading order: LEFT top→bottom, then RIGHT top→bottom
- Single cursor persists across columns and page breaks (defs can flow right→left across pages)
- **Hard sanity check**: romanisation syllable count must match headword Hanzi count.
  If mismatched, we attempt deterministic repairs (lookahead):
    A) extend headword with following pure-CJK line(s)
    B) extend romanisation with following romanisation-only line(s)
  If still mismatched, we DO NOT start a new entry (prevents garbage entries like stray 湯).

Other features:
- Romanisation keeps spaces & diacritics; PUA stripped by default (optional stub)
- Simplified via OpenCC (t2s) preserved alongside Traditional; [字] when identical
- Conservative IPA from intro mapping table (exact match first; optional exact-only)
- Duplicate headwords merged into one defn block (Kangxi-style)

Dependencies:
  pip install pdfplumber opencc-python-reimplemented pypinyin
"""

from __future__ import annotations

import argparse
import random
import re
import sqlite3
import time
import statistics
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import pdfplumber
from opencc import OpenCC
from pypinyin import Style
from pypinyin import pinyin as pypinyin_pinyin

PLECO_NL = "\ueab1"

# ------------------------- Parsing helpers -------------------------

PUA_RE = re.compile(r"[\uE000-\uF8FF\U000F0000-\U000FFFFD\U00100000-\U0010FFFD]")
CJK_RE = re.compile(r"[\u3400-\u9FFF\uF900-\uFAFF]")
CJK_ONLY_RE = re.compile(r"^[\u3400-\u9FFF\uF900-\uFAFF]+$")

# "Romanisation-only" heuristic: no CJK, and contains some Latin.
LATIN_RE = re.compile(r"[A-Za-z]")

BRACKET_NUM_RE = re.compile(r"\[(\d+)\]")
WS_RE = re.compile(r"\s+")

def norm(s: str) -> str:
    s = s.replace("\u00a0", " ").replace("\ufeff", "")
    s = WS_RE.sub(" ", s).strip()
    return s

def first_cjk_span(s: str) -> Optional[Tuple[int, int]]:
    m = CJK_RE.search(s)
    if not m:
        return None
    i = m.start()
    j = i
    while j < len(s) and CJK_RE.match(s[j]):
        j += 1
    return i, j

def hanzi_count(s: str) -> int:
    return len(CJK_RE.findall(s))

def rom_tokens(s: str) -> List[str]:
    # Keep diacritics/apostrophes; just split on whitespace.
    s = norm(s)
    if not s:
        return []
    return [t for t in s.split(" ") if t]

WU_SYL_RE = re.compile(
    r"^[A-Za-zÀ-ÖØ-öø-ÿ]+(?:['’][A-Za-zÀ-ÖØ-öø-ÿ]+)*$"
)
# A tiny stoplist for obvious English noise that sometimes leaks left of the headword
EN_NOISE = {
    "the","a","an","and","or","to","of","in","on","for","with","as","at","by",
    "is","are","was","were","be","been","being","from","that","this","these","those",
    "one","two","three","four","five","six","seven","eight","nine","ten",
    "also","want","during","time","period","white","stem","taro","everyone","better","life",
}

def extract_wu_tail(prefix: str, needed: int) -> Optional[str]:
    """
    Rescue romanisation when x-axis leakage injects English/other tokens before the headword.

    We scan tokens *backwards* and collect the last `needed` Wu-like syllables.
    Returns a space-joined string if found, else None.
    """
    toks = rom_tokens(prefix)
    if not toks or needed <= 0:
        return None

    picked: List[str] = []
    for t in reversed(toks):
        tl = t.lower()
        if tl in EN_NOISE:
            # hard skip obvious English
            continue
        if WU_SYL_RE.match(t) and len(t) <= 16:
            picked.append(t)
            if len(picked) == needed:
                return " ".join(reversed(picked))
        else:
            # If we've started collecting, and then hit non-Wu token, we still keep searching,
            # because leakage can insert junk between syllables. But cap how far we search.
            pass

    return None

def split_columns_words(page) -> Tuple[List[str], List[str]]:
    """
    Geometry-based line reconstruction with **dynamic per-page column split**.
    The PDF's x-axis alignment drifts slightly; a fixed midline can leak words across columns.
    Strategy:
      1) extract words with fontname/size if available
      2) choose "anchor" words likely from headword rows (bold-ish or larger size), else fall back to all words
      3) infer a split x by finding a robust gap between left/right word x positions
      4) bucket words by that split and cluster into lines
    Returns (left_lines, right_lines) WITHOUT interleaving.
    """
    y_tol = 2.5
    gap_space = 1.5

    words = page.extract_words(
        use_text_flow=False,
        keep_blank_chars=False,
        x_tolerance=1.0,
        y_tolerance=2.0,
        extra_attrs=["fontname", "size"],
    ) or []

    if not words:
        return [], []

    sizes = [w.get("size") for w in words if isinstance(w.get("size"), (int, float))]
    size_med = statistics.median(sizes) if sizes else None

    def is_anchor(w: dict) -> bool:
        fn = (w.get("fontname") or "")
        sz = w.get("size")
        boldish = bool(re.search(r"(bold|black|heavy)", fn, re.I))
        largish = (isinstance(sz, (int, float)) and size_med is not None and sz >= size_med + 0.5)
        return boldish or largish

    anchors = [w for w in words if is_anchor(w)]
    sample = anchors if len(anchors) >= 30 else words

    x0s = [w.get("x0", 0.0) for w in sample]
    x1s = [w.get("x1", 0.0) for w in sample]
    width = getattr(page, "width", None) or (max(x1s) + 1.0)
    mid0 = width / 2.0

    def pct(arr, p):
        arr = sorted(arr)
        if not arr:
            return 0.0
        k = (len(arr) - 1) * p
        f = math.floor(k)
        c = math.ceil(k)
        if f == c:
            return arr[int(k)]
        return arr[f] * (c - k) + arr[c] * (k - f)

    left_x1s = [w.get("x1", 0.0) for w in sample if w.get("x0", 0.0) < mid0]
    right_x0s = [w.get("x0", 0.0) for w in sample if w.get("x0", 0.0) > mid0]

    left_edge = pct(left_x1s, 0.95) if left_x1s else mid0
    right_edge = pct(right_x0s, 0.05) if right_x0s else mid0

    if right_edge > left_edge + 10:
        split_x = (left_edge + right_edge) / 2.0
    else:
        split_x = mid0

    left_words = [w for w in words if w.get("x0", 0.0) < split_x]
    right_words = [w for w in words if w.get("x0", 0.0) >= split_x]

    def _cluster(ws: List[dict]) -> List[Tuple[float, str]]:
        ws = sorted(ws, key=lambda w: (w.get("top", 0.0), w.get("x0", 0.0)))
        rows: List[List[dict]] = []
        for w in ws:
            if not rows:
                rows.append([w])
                continue
            last = rows[-1]
            last_top = statistics.median([x["top"] for x in last if "top" in x])
            if abs(w.get("top", 0.0) - last_top) <= y_tol:
                last.append(w)
            else:
                rows.append([w])

        out: List[Tuple[float, str]] = []
        for row in rows:
            row = sorted(row, key=lambda w: w.get("x0", 0.0))
            s = ""
            prev = None
            for w in row:
                t = w.get("text", "")
                if not t:
                    continue
                if prev is None:
                    s = t
                else:
                    gap = w.get("x0", 0.0) - prev.get("x1", 0.0)
                    s += (" " if gap > gap_space else "") + t
                prev = w
            s = norm(s)
            if s:
                top_med = statistics.median([x["top"] for x in row if "top" in x])
                out.append((top_med, s))
        return out

    left_lines = [s for _, s in _cluster(left_words)]
    right_lines = [s for _, s in _cluster(right_words)]
    return left_lines, right_lines

# ------------------------- IPA mapping -------------------------

_IPA_SIGNAL_CHARS = set("ɐɑɒæɓʙβɔɕçðəɛɜɞɡɣɦɪʝɭɬɫɱŋɲɳøɵɸʁɾʂʃθʊʋʌʍʎʏʐʑʒʔˈˌːˑ̩̯̃̊˥˦˧˨˩ˀᴇ")
_IPA_SIGNAL_RE = re.compile(r"[" + re.escape("".join(_IPA_SIGNAL_CHARS)) + r"]")

def _looks_like_mapping_row(line: str) -> bool:
    toks = line.split()
    return len(toks) >= 3 and bool(_IPA_SIGNAL_RE.search(toks[0]))

def build_qian_to_ipa_map(pdf_path: Path, *, intro_pages: int = 10) -> Dict[str, str]:
    q2i: Dict[str, str] = {}
    with pdfplumber.open(str(pdf_path)) as pdf:
        for i in range(min(intro_pages, len(pdf.pages))):
            txt = pdf.pages[i].extract_text() or ""
            for raw_ln in txt.splitlines():
                ln = norm(raw_ln)
                if not ln or not _looks_like_mapping_row(ln):
                    continue
                toks = ln.split()
                if len(toks) < 3:
                    continue
                ipa = toks[0].strip()
                qian = toks[2].strip()
                if not re.fullmatch(r"[A-Za-z'’]+", qian):
                    continue
                if qian in q2i and q2i[qian] != ipa:
                    continue
                q2i[qian] = ipa
    return q2i

def qian_to_ipa_conservative(qian: str, q2i: Dict[str, str], *, exact_only: bool = False) -> str:
    qian = norm(qian)
    if not qian:
        return ""
    if qian in q2i:
        return q2i[qian]
    if exact_only:
        return ""
    parts = [p for p in re.split(r"[’'\-•·\s]+", qian) if p]
    if not parts:
        return ""
    mapped: List[str] = []
    for p in parts:
        if p in q2i:
            mapped.append(q2i[p])
        elif p.lower() in q2i:
            mapped.append(q2i[p.lower()])
        else:
            return ""
    return " ".join(mapped)

# ------------------------- Pleco helpers (Kangxi-style) -------------------------

def mandarin_pinyin_tone3(word: str) -> List[str]:
    py = pypinyin_pinyin(word, style=Style.TONE3, heteronym=False, errors=lambda _: [""])
    out: List[str] = []
    for item in py:
        syl = (item[0] if item else "") or ""
        out.append(syl.replace("ü", "v"))
    return out

_FULLWIDTH_OFFSET = 0xFEE0
def to_fullwidth_ascii(s: str) -> str:
    out = []
    for ch in s:
        o = ord(ch)
        out.append(chr(o + _FULLWIDTH_OFFSET) if 0x21 <= o <= 0x7E else ch)
    return "".join(out)

def make_sortkey(py_syllables: List[str], word: str) -> str:
    if not word:
        return ""
    if len(word) == 1:
        return to_fullwidth_ascii(py_syllables[0] if py_syllables else "") + word
    syls = (py_syllables + [""] * len(word))[: len(word)]
    return "".join(to_fullwidth_ascii(syl) + ch for ch, syl in zip(word, syls))

def split_pron_tokens(pron: str) -> List[str]:
    return [p for p in re.split(r"[\s@]+", pron.strip()) if p]

# ------------------------- Kangxi-style schema/index -------------------------

SCHEMA_SQL = [
    """
    CREATE TABLE 'pleco_dict_entries' (
      "uid" INTEGER PRIMARY KEY AUTOINCREMENT,
      "created" INTEGER,
      "modified" INTEGER,
      "length" INTEGER,
      "word" TEXT COLLATE NOCASE,
      "altword" TEXT COLLATE NOCASE,
      "pron" TEXT COLLATE NOCASE,
      "defn" TEXT,
      "sortkey" TEXT UNIQUE
    );
    """,
    """
    CREATE TABLE 'pleco_dict_imports' (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "starttime" INTEGER,
      "endtime" INTEGER,
      "startentry" INTEGER,
      "endentry" INTEGER
    );
    """,
    """
    CREATE TABLE 'pleco_dict_properties' (
      "propset" INTEGER,
      "propid" TEXT,
      "propvalue" TEXT,
      "propisstring" INTEGER,
      UNIQUE ("propset","propid")
    );
    """,
    "CREATE TABLE 'pleco_dict_posdex_hz_1' (syllable TEXT, uid INTEGER, length INTEGER);",
    "CREATE TABLE 'pleco_dict_posdex_hz_2' (syllable TEXT, uid INTEGER, length INTEGER);",
    "CREATE TABLE 'pleco_dict_posdex_hz_3' (syllable TEXT, uid INTEGER, length INTEGER);",
    "CREATE TABLE 'pleco_dict_posdex_hz_4' (syllable TEXT, uid INTEGER, length INTEGER);",
    "CREATE TABLE 'pleco_dict_posdex_py_1' (syllable TEXT, uid INTEGER, length INTEGER);",
    "CREATE TABLE 'pleco_dict_posdex_py_2' (syllable TEXT, uid INTEGER, length INTEGER);",
    "CREATE TABLE 'pleco_dict_posdex_py_3' (syllable TEXT, uid INTEGER, length INTEGER);",
    "CREATE TABLE 'pleco_dict_posdex_py_4' (syllable TEXT, uid INTEGER, length INTEGER);",
]

INDEX_SQL = [
    "CREATE INDEX idx_pleco_dict_entries_sortkey ON pleco_dict_entries (sortkey);",
    "CREATE INDEX idx_pleco_dict_posdex_hz_1_syllable_uid_length ON pleco_dict_posdex_hz_1 (syllable, uid, length);",
    "CREATE INDEX idx_pleco_dict_posdex_hz_1_uid ON pleco_dict_posdex_hz_1 (uid);",
    "CREATE INDEX idx_pleco_dict_posdex_hz_2_syllable_uid ON pleco_dict_posdex_hz_2 (syllable, uid);",
    "CREATE INDEX idx_pleco_dict_posdex_hz_2_uid ON pleco_dict_posdex_hz_2 (uid);",
    "CREATE INDEX idx_pleco_dict_posdex_hz_3_syllable_uid ON pleco_dict_posdex_hz_3 (syllable, uid);",
    "CREATE INDEX idx_pleco_dict_posdex_hz_3_uid ON pleco_dict_posdex_hz_3 (uid);",
    "CREATE INDEX idx_pleco_dict_posdex_hz_4_syllable_uid ON pleco_dict_posdex_hz_4 (syllable, uid);",
    "CREATE INDEX idx_pleco_dict_posdex_hz_4_uid ON pleco_dict_posdex_hz_4 (uid);",
    "CREATE INDEX idx_pleco_dict_posdex_py_1_syllable_uid_length ON pleco_dict_posdex_py_1 (syllable, uid, length);",
    "CREATE INDEX idx_pleco_dict_posdex_py_1_uid ON pleco_dict_posdex_py_1 (uid);",
    "CREATE INDEX idx_pleco_dict_posdex_py_2_syllable_uid_length ON pleco_dict_posdex_py_2 (syllable, uid, length);",
    "CREATE INDEX idx_pleco_dict_posdex_py_2_uid ON pleco_dict_posdex_py_2 (uid);",
    "CREATE INDEX idx_pleco_dict_posdex_py_3_syllable_uid_length ON pleco_dict_posdex_py_3 (syllable, uid, length);",
    "CREATE INDEX idx_pleco_dict_posdex_py_3_uid ON pleco_dict_posdex_py_3 (uid);",
    "CREATE INDEX idx_pleco_dict_posdex_py_4_syllable_uid_length ON pleco_dict_posdex_py_4 (syllable, uid, length);",
    "CREATE INDEX idx_pleco_dict_posdex_py_4_uid ON pleco_dict_posdex_py_4 (uid);",
]

def write_properties(cur: sqlite3.Cursor, *, dict_name: str, menu_name: str, short_name: str, icon: str,
                     entry_count: int, now: int) -> None:
    file_id = random.randint(-2_000_000_000, 2_000_000_000)
    file_creator = random.randint(1, 50_000_000)
    props = [
        ("DictCopyright", "", 1),
        ("DictIconFillColor", "39372", 0),
        ("DictIconName", icon, 1),
        ("DictIconTextColor", "16777215", 0),
        ("DictLang", "Chinese", 1),
        ("DictMenuName", menu_name, 1),
        ("DictName", dict_name, 1),
        ("DictShortName", short_name, 1),
        ("EditLock", None, 0),
        ("EntryCount", str(entry_count), 0),
        ("FileCreated", str(now), 0),
        ("FileCreator", str(file_creator), 0),
        ("FileGenerator", "Pleco Engine 2.0", 1),
        ("FileID", str(file_id), 0),
        ("FilePlatform", "Android", 1),
        ("FormatString", "Pleco SQL Dictionary Database", 1),
        ("FormatVersion", "8", 0),
        ("NoSortKey", None, 0),
        ("SortMethod", None, 0),
        ("TransLang", "English", 1),
    ]
    for propid, propvalue, propisstring in props:
        cur.execute(
            "INSERT OR REPLACE INTO pleco_dict_properties (propset, propid, propvalue, propisstring) VALUES (0, ?, ?, ?);",
            (propid, propvalue, propisstring),
        )

def insert_posdex(cur: sqlite3.Cursor, uid: int, word: str, pron: str) -> None:
    wlen = len(word)
    for i, ch in enumerate(list(word)[:4], start=1):
        cur.execute(f"INSERT INTO pleco_dict_posdex_hz_{i} (syllable, uid, length) VALUES (?, ?, ?);", (ch, uid, wlen))
    py_tokens = split_pron_tokens(pron)
    for i, syl in enumerate(py_tokens[:4], start=1):
        cur.execute(f"INSERT INTO pleco_dict_posdex_py_{i} (syllable, uid, length) VALUES (?, ?, ?);", (syl, uid, wlen))

# ------------------------- Entry extraction + merging -------------------------

@dataclass
class Entry:
    headword: str
    trad: str
    simp: str
    rom: str
    ipa: str
    defn: str
    page: int
    pua: Optional[str] = None

def consume_lines(lines: List[str], *, page_no: int, cc: OpenCC, q2i: Dict[str, str],
                  keep_pua: bool, ipa_exact_only: bool, primary_trad: bool,
                  cur: Optional[Entry]) -> Tuple[List[Entry], Optional[Entry]]:
    out: List[Entry] = []
    i = 0
    while i < len(lines):
        raw_n = norm(lines[i])
        i += 1
        if not raw_n:
            continue

        span = first_cjk_span(raw_n)
        if span:
            a, b = span
            prefix = raw_n[:a].strip()

            pua_in_prefix = PUA_RE.search(prefix)
            if pua_in_prefix:
                rom_raw = prefix[:pua_in_prefix.start()].strip()
                pua_found = prefix[pua_in_prefix.start():].strip() or None
            else:
                rom_raw = prefix
                pua_found = "".join(PUA_RE.findall(raw_n)) or None

            rom_raw = norm(rom_raw)
            hz_trad = raw_n[a:b]
            hz_simp = cc.convert(hz_trad)
            after = norm(raw_n[b:])
            after = BRACKET_NUM_RE.sub("", after, count=1).strip()

            # If romanisation missing, don't start a new entry.
            if not rom_raw:
                if cur:
                    cur.defn = norm((cur.defn + " " + raw_n).strip())
                continue

            # --- v11 parity enforcement + deterministic repair + Wu-tail rescue ---
            hcnt = hanzi_count(hz_trad)
            rtoks = rom_tokens(rom_raw)
            if len(rtoks) != hcnt:
                rescued = extract_wu_tail(prefix, hcnt)
                if rescued:
                    rom_raw = rescued
                    rtoks = rom_tokens(rom_raw)


            # attempt repair via lookahead up to 3 lines total
            look = 0
            # A) headword extension with pure CJK lines
            while hcnt < len(rtoks) and look < 3 and i < len(lines):
                nxt = norm(lines[i])
                if nxt and CJK_ONLY_RE.match(nxt) and not LATIN_RE.search(nxt) and len(nxt) <= 6:
                    hz_trad += nxt
                    hz_simp += cc.convert(nxt)
                    hcnt = hanzi_count(hz_trad)
                    i += 1
                    look += 1
                else:
                    break

            # B) romanisation extension with romanisation-only lines (no CJK, has Latin)
            while len(rtoks) < hcnt and look < 3 and i < len(lines):
                nxt = norm(lines[i])
                if nxt and (first_cjk_span(nxt) is None) and LATIN_RE.search(nxt):
                    # take the whole line as additional rom tokens (stop at any PUA if present)
                    pua_m = PUA_RE.search(nxt)
                    nxt_rom = nxt[:pua_m.start()].strip() if pua_m else nxt
                    # if the line looks like a definition (has lots of punctuation), don't steal it
                    # but romanisation continuation lines are typically short and mostly letters/diacritics/apostrophes
                    if len(nxt_rom) <= 40:
                        rom_raw = norm(rom_raw + " " + nxt_rom)
                        rtoks = rom_tokens(rom_raw)
                        i += 1
                        look += 1
                        continue
                break

            # Final parity check
            if len(rtoks) != hcnt:
                # refuse to create a new entry; treat as continuation/garbage
                if cur:
                    cur.defn = norm((cur.defn + " " + raw_n).strip())
                continue
            # --- end parity / rescue ---

            head = hz_trad if primary_trad else hz_simp
            ipa = qian_to_ipa_conservative(rom_raw, q2i, exact_only=ipa_exact_only)

            if cur:
                cur.defn = norm(cur.defn)
                out.append(cur)

            cur = Entry(
                headword=head,
                trad=hz_trad,
                simp=hz_simp,
                rom=rom_raw,
                ipa=ipa,
                defn=after,
                page=page_no,
                pua=pua_found if keep_pua else None,
            )
            continue

        # No headword: continuation
        if cur:
            cur.defn = norm((cur.defn + " " + raw_n).strip())

    return out, cur

def parse_pdf(pdf_path: Path, *, cc: OpenCC, q2i: Dict[str, str], keep_pua: bool,
              ipa_exact_only: bool, primary_trad: bool, max_pages: int) -> List[Entry]:
    out: List[Entry] = []
    cur: Optional[Entry] = None

    with pdfplumber.open(str(pdf_path)) as pdf:
        total = len(pdf.pages)
        limit = max_pages if max_pages and max_pages > 0 else total

        for pi in range(min(limit, total)):
            page_no = pi + 1
            left_lines, right_lines = split_columns_words(pdf.pages[pi])

            new_left, cur = consume_lines(
                left_lines, page_no=page_no, cc=cc, q2i=q2i,
                keep_pua=keep_pua, ipa_exact_only=ipa_exact_only, primary_trad=primary_trad,
                cur=cur,
            )
            out.extend(new_left)

            new_right, cur = consume_lines(
                right_lines, page_no=page_no, cc=cc, q2i=q2i,
                keep_pua=keep_pua, ipa_exact_only=ipa_exact_only, primary_trad=primary_trad,
                cur=cur,
            )
            out.extend(new_right)

    if cur:
        cur.defn = norm(cur.defn)
        out.append(cur)

    return out

def build_defn_block(e: Entry, *, include_pua_stub: bool) -> str:
    lines: List[str] = []

    if e.trad and (not e.simp or e.simp == e.trad):
        lines.append(f"[字] {e.trad}")
    else:
        if e.trad:
            lines.append(f"[繁] {e.trad}")
        if e.simp:
            lines.append(f"[简] {e.simp}")

    if e.rom:
        lines.append(f"[罗] {e.rom}")
    if e.ipa:
        lines.append(f"[IPA] {e.ipa}")
    if include_pua_stub and e.pua:
        lines.append(f"[音符] {e.pua}")

    lines.append("")

    if e.defn:
        defn_text = e.defn
        # De-hyphenate linebreak artifacts like 'pe- riod' -> 'period'
        defn_text = re.sub(r"([A-Za-z]{2,})-\s+([A-Za-z]{2,})", r"\1\2", defn_text)
        defn_text = re.sub(r"^\s*(\d+)\s+", r"\1 ", defn_text)
        defn_text = re.sub(r"\s+(\d+)\s+", PLECO_NL + r"\1 ", defn_text)
        lines.append(defn_text)

    lines.append(f"(p.{e.page})")
    return PLECO_NL.join(lines).strip()

def merge_entries(entries: List[Entry], *, include_pua_stub: bool) -> Dict[str, str]:
    blocks: Dict[str, set] = {}
    for e in entries:
        if not e.headword:
            continue
        block = build_defn_block(e, include_pua_stub=include_pua_stub)
        if not block:
            continue
        blocks.setdefault(e.headword, set()).add(block)

    merged: Dict[str, str] = {}
    for w, bset in blocks.items():
        merged[w] = (PLECO_NL + PLECO_NL).join(sorted(bset))
    return merged

# ------------------------- PQB builder -------------------------

def build_pqb(defn_map: Dict[str, str], out_path: str, *, dict_name: str, menu_name: str,
              short_name: str, icon: str) -> None:
    out = Path(out_path)
    if out.exists():
        out.unlink()

    con = sqlite3.connect(str(out))
    con.execute("PRAGMA page_size=1024;")
    con.execute("PRAGMA journal_mode=DELETE;")
    con.execute("PRAGMA synchronous=FULL;")
    cur = con.cursor()

    for sql in SCHEMA_SQL:
        cur.executescript(sql)
    for sql in INDEX_SQL:
        cur.execute(sql)

    now = int(time.time())
    uid = 1

    for word in sorted(defn_map.keys()):
        py = mandarin_pinyin_tone3(word)
        pron = " ".join([p for p in py if p])
        sk_base = make_sortkey(py, word) or word
        sk = sk_base
        defn = defn_map[word]

        for attempt in range(8):
            try:
                cur.execute(
                    "INSERT INTO pleco_dict_entries (uid, created, modified, length, word, altword, pron, defn, sortkey) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
                    (uid, now, now, len(word), word, None, pron, defn, sk),
                )
                break
            except sqlite3.IntegrityError as ex:
                if "pleco_dict_entries.sortkey" not in str(ex):
                    raise
                sk = sk_base + to_fullwidth_ascii(f"#{uid}.{attempt+1}")
        else:
            raise RuntimeError(f"Could not create unique sortkey for {word!r}")

        insert_posdex(cur, uid, word, pron)
        uid += 1

    count = uid - 1
    write_properties(cur, dict_name=dict_name, menu_name=menu_name, short_name=short_name,
                     icon=icon, entry_count=count, now=now)
    cur.execute("INSERT INTO pleco_dict_imports (starttime, endtime, startentry, endentry) VALUES (?, ?, 1, ?);",
                (now, now, count))

    con.commit()
    con.close()
    print(f"Wrote {out_path} with {count} entries.")

# ------------------------- CLI -------------------------

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pdf", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-pages", type=int, default=0)

    ap.add_argument("--primary-trad", action="store_true")
    ap.add_argument("--keep-pua", action="store_true")
    ap.add_argument("--ipa-exact-only", action="store_true")

    ap.add_argument("--dict-name", required=True)
    ap.add_argument("--menu-name", required=True)
    ap.add_argument("--short-name", required=True)
    ap.add_argument("--icon", required=True)

    args = ap.parse_args()

    pdf_path = Path(args.pdf)
    cc = OpenCC("t2s")
    q2i = build_qian_to_ipa_map(pdf_path, intro_pages=10)

    entries = parse_pdf(
        pdf_path,
        cc=cc,
        q2i=q2i,
        keep_pua=args.keep_pua,
        ipa_exact_only=args.ipa_exact_only,
        primary_trad=args.primary_trad,
        max_pages=args.max_pages,
    )

    dmap = merge_entries(entries, include_pua_stub=args.keep_pua)
    if not dmap:
        raise SystemExit("No entries parsed (PDF might be image-only or parsing needs tuning).")

    build_pqb(
        dmap,
        args.out,
        dict_name=args.dict_name,
        menu_name=args.menu_name,
        short_name=args.short_name,
        icon=args.icon,
    )

if __name__ == "__main__":
    main()
