#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Yomitan (Yomichan-style) term bank JSON -> Pleco PQB (SQLite), Plecofreq-matching schema + indexing.

Designed for dictionaries that look like:
  - index.json (metadata)
  - term_bank_*.json (list of term entries; each entry is a list/array)

This script:
- Reads one or more term_bank JSON files (repeatable).
- Merges duplicate headwords into ONE Pleco entry by concatenating unique definition blocks.
- Uses Mandarin pinyin (tone numbers via pypinyin) for Pleco 'pron' + sortkey so entries group nicely with store dicts.
- Keeps the term-bank's own reading (tone-mark pinyin etc.) inside the definition as "PY: ...".
- Preserves multiline definitions, converting '\\n' to Pleco newline U+EAB1.

Dependencies:
  pip install pypinyin

Example:
  python yomitan_json_to_pleco_pqb.py \
    --index index.json \
    --term term_bank_1.json \
    --out cc_vogelsang.pqb \
    --dict-name "cc_vogelsang (Vogelsang CC)" \
    --menu-name "Vogelsang CC" \
    --short-name "Vogelsang CC" \
    --icon "CC"
"""

from __future__ import annotations

import argparse
import json
import random
import re
import sqlite3
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple, Any

from pypinyin import Style
from pypinyin import pinyin as pypinyin_pinyin

PLECO_NL = "\ueab1"

# ------------------------- CJK filter -------------------------

CJK_RANGES = [
    (0x4E00, 0x9FFF),   # Unified Ideographs
    (0x3400, 0x4DBF),   # Ext A
    (0x20000, 0x2A6DF), # Ext B
    (0x2A700, 0x2B73F), # Ext C
    (0x2B740, 0x2B81D), # Ext D
    (0x2B820, 0x2CEAD), # Ext E
    (0x2CEB0, 0x2EBE0), # Ext F
    (0x31350, 0x323AF), # Ext H
    (0x2EBF0, 0x2EE5D), # Ext I
    (0x323B0, 0x33479), # Ext J
    (0x2F800, 0x2FA1F), # Compatibility Ideographs Supplement
]
EXTRA_ALLOWED = {0x3007}  # 〇

def is_cjk_word(word: str) -> bool:
    if not word:
        return False
    for ch in word:
        cp = ord(ch)
        if cp in EXTRA_ALLOWED:
            continue
        if not any(lo <= cp <= hi for lo, hi in CJK_RANGES):
            return False
    return True

# ------------------------- Plecofreq-like formatting -------------------------

def with_at_separators(word: str) -> str:
    return word if len(word) <= 1 else "@".join(list(word))

def mandarin_pinyin_tone3(word: str) -> List[str]:
    py = pypinyin_pinyin(word, style=Style.TONE3, heteronym=False, errors=lambda _: [""])
    out: List[str] = []
    for item in py:
        syl = (item[0] if item else "") or ""
        out.append(syl.replace("ü", "v"))
    return out

def make_pron_with_at(py_syllables: List[str]) -> str:
    # No spaces in displayed pinyin; keep @ boundaries.
    return "@".join(py_syllables) if py_syllables else ""

_FULLWIDTH_OFFSET = 0xFEE0
def to_fullwidth_ascii(s: str) -> str:
    out = []
    for ch in s:
        o = ord(ch)
        if 0x21 <= o <= 0x7E:
            out.append(chr(o + _FULLWIDTH_OFFSET))
        else:
            out.append(ch)
    return "".join(out)

def make_sortkey(py_syllables: List[str], word: str) -> str:
    if not word:
        return ""
    if len(word) == 1:
        return to_fullwidth_ascii(py_syllables[0] if py_syllables else "") + word
    return "".join(to_fullwidth_ascii(syl) + ch for ch, syl in zip(word, py_syllables))

def _split_pron_tokens(pron: str) -> List[str]:
    # Split on whitespace OR '@' so we can populate posdex correctly
    return [p for p in re.split(r"[\s@]+", pron.strip()) if p]

# ------------------------- Schema/index (match plecofreq) -------------------------

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
    "CREATE INDEX idx_pleco_dict_posdex_py_2_syllable_uid ON pleco_dict_posdex_py_2 (syllable, uid);",
    "CREATE INDEX idx_pleco_dict_posdex_py_2_uid ON pleco_dict_posdex_py_2 (uid);",
    "CREATE INDEX idx_pleco_dict_posdex_py_3_syllable_uid ON pleco_dict_posdex_py_3 (syllable, uid);",
    "CREATE INDEX idx_pleco_dict_posdex_py_3_uid ON pleco_dict_posdex_py_3 (uid);",
    "CREATE INDEX idx_pleco_dict_posdex_py_4_syllable_uid ON pleco_dict_posdex_py_4 (syllable, uid);",
    "CREATE INDEX idx_pleco_dict_posdex_py_4_uid ON pleco_dict_posdex_py_4 (uid);",
]

def _insert_posdex(cur: sqlite3.Cursor, uid: int, word_with_at: str, pron_with_at: str) -> None:
    word_no_at = word_with_at.replace("@", "")
    wlen = len(word_no_at)

    for i, ch in enumerate(list(word_no_at)[:4], start=1):
        cur.execute(
            f"INSERT INTO pleco_dict_posdex_hz_{i} (syllable, uid, length) VALUES (?, ?, ?);",
            (ch, uid, wlen),
        )

    py_tokens = _split_pron_tokens(pron_with_at)
    for i, syl in enumerate(py_tokens[:4], start=1):
        cur.execute(
            f"INSERT INTO pleco_dict_posdex_py_{i} (syllable, uid, length) VALUES (?, ?, ?);",
            (syl, uid, wlen),
        )

def _write_properties(cur: sqlite3.Cursor, *, dict_name: str, menu_name: str, short_name: str,
                      entry_count: int, now: int, icon_abbrev: str,
                      dict_copyright: str = "", trans_lang: str = "English") -> None:
    file_id = random.randint(-2_000_000_000, 2_000_000_000)
    file_creator = random.randint(1, 50_000_000)

    props = [
        ("DictCopyright", dict_copyright, 1),
        ("DictIconFillColor", "39372", 0),
        ("DictIconName", icon_abbrev, 1),
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
        ("TransLang", trans_lang, 1),
    ]
    for propid, propvalue, propisstring in props:
        cur.execute(
            "INSERT OR REPLACE INTO pleco_dict_properties (propset, propid, propvalue, propisstring) VALUES (0, ?, ?, ?);",
            (propid, propvalue, propisstring),
        )

# ------------------------- Yomitan parsing -------------------------

def _read_json(path: str) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))

def _term_entry_to_block(entry: Any) -> Optional[Tuple[str, str]]:
    """
    Yomichan/Yomitan term bank entry typically:
      [term, reading, altTerm, altReading, tags, glosses, ...]
    In your file, it looks like:
      [term, reading, "", "", 0, [ "gloss str", ...], 0, ""]
    We only rely on:
      term   -> entry[0]
      reading -> entry[1]
      gloss list -> entry[5] (but we handle other positions defensively)
    """
    if not isinstance(entry, list) or len(entry) < 2:
        return None
    term = str(entry[0]).strip()
    if not term or not is_cjk_word(term):
        return None

    reading = str(entry[1]).strip() if len(entry) > 1 and entry[1] is not None else ""
    glosses = None
    # Try the common slot first; then fall back to "first list-of-strings" slot.
    if len(entry) > 5 and isinstance(entry[5], list):
        glosses = entry[5]
    else:
        for v in entry:
            if isinstance(v, list) and v and all(isinstance(x, str) for x in v):
                glosses = v
                break
    if not glosses:
        return None

    # Build definition block:
    # - Put "PY: <reading>" on top if present
    # - Then each gloss item separated by blank line
    parts: List[str] = []
    if reading:
        parts.append(f"PY: {reading}")
        parts.append("")  # blank line

    # Convert newlines to Pleco newlines; keep fancy box drawing etc.
    gloss_items: List[str] = []
    for g in glosses:
        if not isinstance(g, str):
            continue
        s = g.replace("\r\n", "\n").replace("\r", "\n").strip()
        if not s:
            continue
        gloss_items.append(s.replace("\n", PLECO_NL))

    if not gloss_items:
        return None

    parts.append((PLECO_NL + PLECO_NL).join(gloss_items))
    block = PLECO_NL.join(parts).strip()
    return term, block

def load_term_banks(term_paths: Sequence[str]) -> Dict[str, str]:
    """
    Returns a merged {term: defn} map, deduping duplicate terms by concatenating unique blocks.
    """
    blocks: Dict[str, Set[str]] = {}

    for p in term_paths:
        data = _read_json(p)
        if not isinstance(data, list):
            raise ValueError(f"{p}: expected a JSON list at top level.")
        for entry in data:
            parsed = _term_entry_to_block(entry)
            if not parsed:
                continue
            term, block = parsed
            blocks.setdefault(term, set()).add(block)

    merged: Dict[str, str] = {}
    for term, bset in blocks.items():
        merged[term] = (PLECO_NL + PLECO_NL).join(sorted(bset))
    return merged

def load_index_meta(index_path: Optional[str]) -> Dict[str, str]:
    if not index_path:
        return {}
    meta = _read_json(index_path)
    if not isinstance(meta, dict):
        return {}
    out = {}
    for k in ("title", "description", "author", "revision", "url"):
        v = meta.get(k)
        if isinstance(v, str) and v.strip():
            out[k] = v.strip()
    return out

# ------------------------- Build PQB -------------------------

def build_pqb(defn_map: Dict[str, str], out_path: str, *,
              dict_name: str, menu_name: str, short_name: str, icon_abbrev: str,
              dict_copyright: str = "") -> None:
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

    for term in sorted(defn_map.keys()):
        defn = defn_map[term]
        if not defn.strip():
            continue

        word_with_at = with_at_separators(term)
        py_syls = mandarin_pinyin_tone3(term)
        pron_with_at = make_pron_with_at(py_syls)
        sortkey = make_sortkey(py_syls, term) or term  # fallback

        cur.execute(
            "INSERT INTO pleco_dict_entries (uid, created, modified, length, word, altword, pron, defn, sortkey) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
            (uid, now, now, len(term), word_with_at, None, pron_with_at, defn, sortkey),
        )
        _insert_posdex(cur, uid, word_with_at, pron_with_at)
        uid += 1

    entry_count = uid - 1
    _write_properties(
        cur,
        dict_name=dict_name,
        menu_name=menu_name,
        short_name=short_name,
        entry_count=entry_count,
        now=now,
        icon_abbrev=icon_abbrev,
        dict_copyright=dict_copyright,
    )

    cur.execute(
        "INSERT INTO pleco_dict_imports (starttime, endtime, startentry, endentry) VALUES (?, ?, 1, ?);",
        (now, now, entry_count),
    )

    con.commit()
    con.close()
    print(f"Wrote {out_path} with {entry_count} entries.")

# ------------------------- CLI -------------------------

def main(argv: Optional[Sequence[str]] = None) -> None:
    ap = argparse.ArgumentParser(description="Convert Yomitan/Yomichan term bank JSON to Pleco .pqb (SQLite).")
    ap.add_argument("--term", action="append", required=True, help="Path to term_bank_*.json (repeatable).")
    ap.add_argument("--index", help="Optional index.json for metadata.")
    ap.add_argument("--out", required=True, help="Output .pqb path.")

    ap.add_argument("--dict-name", help="Pleco DictName (defaults to index.json title).")
    ap.add_argument("--menu-name", help="Pleco DictMenuName (defaults to dict-name).")
    ap.add_argument("--short-name", help="Pleco DictShortName (defaults to menu-name).")
    ap.add_argument("--icon", dest="icon_abbrev", help="Pleco DictIconName (defaults to 2-3 letters from dict-name).")

    args = ap.parse_args(argv)

    meta = load_index_meta(args.index)
    fallback_title = meta.get("title") or "Yomitan Dictionary"
    dict_name = args.dict_name or fallback_title
    menu_name = args.menu_name or dict_name
    short_name = args.short_name or menu_name

    icon = args.icon_abbrev
    if not icon:
        # crude but practical: take first alphanum chunk, upper, 2 chars; fallback "YY"
        chunk = re.sub(r"[^A-Za-z0-9]+", " ", dict_name).strip().split(" ")[0] if dict_name else ""
        icon = (chunk[:2] if chunk else "YY").upper()

    dmap = load_term_banks(args.term)
    if not dmap:
        raise SystemExit("No usable entries found (after parsing + CJK filtering).")

    # Put useful index.json info into DictCopyright (shown in Pleco dictionary info)
    copyright_bits = []
    if meta.get("description"):
        copyright_bits.append(meta["description"])
    if meta.get("author"):
        copyright_bits.append(f"Author: {meta['author']}")
    if meta.get("revision"):
        copyright_bits.append(f"Revision: {meta['revision']}")
    if meta.get("url"):
        copyright_bits.append(meta["url"])
    dict_copyright = " | ".join(copyright_bits)

    build_pqb(
        dmap,
        args.out,
        dict_name=dict_name,
        menu_name=menu_name,
        short_name=short_name,
        icon_abbrev=icon,
        dict_copyright=dict_copyright,
    )

if __name__ == "__main__":
    main()
