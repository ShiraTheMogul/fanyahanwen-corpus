#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scrape_bible_wikisource.py

Imports the seven Literary Chinese Bible translations held on zh.wikisource
into the Fanya Hanwen corpus tree, one folder per edition.

  文理和合譯本            聖經 (文理和合)                    66 books, 1189 ch
  委辦譯本／代表譯本       聖經 (委辦譯本或稱代表譯本)          incomplete
  新遺詔聖經 (正教會)      新遺詔聖經                         flat page titles
  淺文理和合譯本 新約      新約全書 (淺文理和合)               27 books
  施約瑟淺文理譯本         聖經 (施約瑟淺文理譯本)             66 books
  欽定舊遺詔聖書 (太平)    欽定舊遺詔聖書                      6 juan
  欽定前遺詔聖書 (太平)    欽定前遺詔聖書                      27 books

Output layout, matching the 聖經 folder already in the tree:

  <corpus>/中國漢文/clean/<period>/<polity>/<folder>/
      metadata.json
      <目錄名>.txt
      舊約/<書名>/<書名>_目錄.txt
      舊約/<書名>/第一章.txt
      新約/...

Every .txt and .json is written UTF-8 **with BOM**, LF newlines.

Usage
-----
  python scrape_bible_wikisource.py --corpus E:\\fanyahanwen-corpus\\corpus
  python scrape_bible_wikisource.py --corpus ... --edition 文理和合 --dry-run
  python scrape_bible_wikisource.py --corpus ... --book 創世記 --limit-chapters 1

`--dry-run` writes nothing and prints what would be written.
`--out DIR` writes the whole tree somewhere else for inspection first.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import time
from typing import Dict, Iterable, List, Optional, Tuple

import requests

SCRIPT_VERSION = "v1-2026-09-14"

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusBibleScraper/1.0 "
        "(chippy2001@live.co.uk; "
        "https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

SLEEP_SECONDS = 1.0
BATCH = 20              # titles per API call; the API caps anonymous callers at 50


# ---------------------------------------------------------------------------
# Literary numerals
# ---------------------------------------------------------------------------

DIGITS = "〇一二三四五六七八九"


def han_number(n: int) -> str:
    """Literary numeral in the style these texts use for their own chapter
    headings.  Verified against all 1,395 chapter headings across the seven
    editions: 1,394 reproduce exactly, the 1 failure being a known Wikisource
    typo (委辦譯本 創世記 ch.26 headed 第二十五章).

        1-10     一 … 十
        11-19    十一 … 十九
        20-99    二十 / 二十一 … 九十九
        100      一百                (irregular; the texts' own form)
        101-110  百有一 … 百有十      (有 fills the empty tens place)
        111-199  百十一 / 百二十 … 百九十九

    Verse numbers reach 176 (詩篇第百十九篇); the same rule is carried up.
    """
    if n < 1:
        raise ValueError("no numeral for %r" % (n,))
    if n <= 10:
        return "十" if n == 10 else DIGITS[n]
    if n < 20:
        return "十" + DIGITS[n - 10]
    if n < 100:
        tens, ones = divmod(n, 10)
        return DIGITS[tens] + "十" + (DIGITS[ones] if ones else "")
    if n == 100:
        return "一百"
    if n <= 110:
        return "百有" + han_number(n - 100)
    if n < 200:
        return "百" + han_number(n - 100)
    hundreds, rest = divmod(n, 100)
    head = DIGITS[hundreds] + "百"
    if rest == 0:
        return head
    if rest <= 10:
        return head + "有" + han_number(rest)
    return head + han_number(rest)


# ---------------------------------------------------------------------------
# Edition table
# ---------------------------------------------------------------------------
#
# toc:  how the index page lists its books
#   "testaments"  ==舊約== / ==新約== bullet lists of /subpages
#   "flat"        one bullet list of /subpages, no testament split
#   "links"       bullet list of ordinary [[Page]] links (not subpages)
#
# unit: what a chapter file is called — 章 or 篇 is taken per-heading, this is
#       only the fallback.

EDITIONS: List[Dict[str, object]] = [
    {
        "key": "文理和合",
        "root_title": "聖經 (文理和合)",
        "folder": "聖經 (文理和合譯本)",
        "period": "中華民國",
        "polity": "中華民國",
        "toc": "testaments",
        "toc_name": "新舊約全書目錄",
        "metadata": {
            "title": "聖經",
            "work_base_title": "聖經",
            "edition": "文理和合譯本",
            "authors": ["湛約翰", "艾約瑟", "惠志道", "謝衛樓", "沙伯"],
            "date_label": "1919年",
            "ca": "1906–1934年",
            "categories": ["基督教", "聖經", "翻譯"],
            "notes": (
                "新約1906年初版，新舊約全書1919年初版，修訂新約後之新舊約全書1923年出版，"
                "1934年印行最後一版。維基文庫所載者為1934年修訂版。"
            ),
        },
    },
    {
        "key": "委辦",
        "root_title": "聖經 (委辦譯本或稱代表譯本)",
        "folder": "聖經 (委辦譯本)",
        "period": "清朝",
        "polity": "大清",
        "toc": "testaments",
        "toc_name": "新舊約全書目錄",
        "metadata": {
            "title": "聖經",
            "work_base_title": "聖經",
            "edition": "委辦譯本（代表譯本）",
            "authors": [
                "麥都思", "文惠廉", "裨治文", "施敦力", "婁理華",
                "克陛存", "理雅各", "美魏茶", "高德", "羅爾悌", "迪因修", "王韜",
            ],
            "date_label": "1854年",
            "ca": "1852–1854年",
            "categories": ["基督教", "聖經", "翻譯"],
            "notes": "維基文庫錄入未竟，非全書。王韜潤筆。",
        },
    },
    {
        "key": "新遺詔",
        "root_title": "新遺詔聖經",
        "folder": "新遺詔聖經",
        "period": "清朝",
        "polity": "大清",
        "toc": "links",
        "toc_name": "新遺詔聖經目錄",
        "metadata": {
            "title": "吾主伊伊穌斯合利爾斯托斯新遺詔聖經",
            "work_base_title": "新遺詔聖經",
            "edition": "正教會固利爾乙譯本",
            "authors": ["固利爾乙", "隆源", "瑪利爾亞", "摩伊些乙", "尼伊克他"],
            "date_label": "1864年",
            "ca": "1864年",
            "categories": ["基督教", "正教會", "聖經", "翻譯"],
            "notes": (
                "同治三年甲子刊。教會斯拉夫語及通用希臘語俄羅斯正教會原文譯本。"
                "原書小字旁注表音，維基文庫以 <sup> 標之；本次匯入依 --sup-mode 處理。"
            ),
        },
    },
    {
        "key": "淺文理和合",
        "root_title": "新約全書 (淺文理和合)",
        "folder": "新約全書 (淺文理和合譯本)",
        "period": "清朝",
        "polity": "大清",
        "toc": "flat",
        "toc_name": "新約全書目錄",
        "testament": "新約",
        "metadata": {
            "title": "新約全書",
            "work_base_title": "新約全書",
            "edition": "淺文理和合譯本",
            "authors": ["包約翰", "白漢理", "汲約翰", "葉道勝", "紀好弼", "戴維思"],
            "date_label": "1904年",
            "ca": "1904年",
            "categories": ["基督教", "聖經", "翻譯"],
            "notes": "據1912年印刷版錄入，內文與1904年第二次修訂版相同。無舊約。",
        },
    },
    {
        "key": "施約瑟",
        "root_title": "聖經 (施約瑟淺文理譯本)",
        "folder": "聖經 (施約瑟淺文理譯本)",
        "period": "清朝",
        "polity": "大清",
        "toc": "testaments",
        "toc_name": "新舊約全書目錄",
        "metadata": {
            "title": "聖經",
            "work_base_title": "聖經",
            "edition": "施約瑟淺文理譯本（天主版）",
            "authors": ["施約瑟"],
            "date_label": "1902年",
            "ca": "1902年",
            "categories": ["基督教", "聖經", "翻譯"],
            "notes": "天主版。另有上帝版，僅神名及部分譯名有異。",
        },
    },
    {
        "key": "欽定舊遺詔",
        "root_title": "欽定舊遺詔聖書",
        "folder": "欽定舊遺詔聖書",
        "period": "清朝",
        "polity": "太平天囯",
        "toc": "links",
        "toc_name": "欽定舊遺詔聖書目錄",
        "testament": "舊約",
        "metadata": {
            "title": "欽定舊遺詔聖書",
            "work_base_title": "欽定舊遺詔聖書",
            "edition": "太平天囯欽定本",
            "authors": ["洪秀全"],
            "date_label": "1853年",
            "ca": "1853年",
            "categories": ["基督教", "聖經", "太平天國"],
            "notes": (
                "癸好三年新刻，共六卷，止於約書亞書。天王洪秀全親自刪改。"
                "原書天頭批註非聖經正文，維基文庫以 {{批}} 內嵌，本次匯入作 〈…〉 夾註。"
            ),
        },
    },
    {
        "key": "欽定前遺詔",
        "root_title": "欽定前遺詔聖書",
        "folder": "欽定前遺詔聖書",
        "period": "清朝",
        "polity": "太平天囯",
        "toc": "links",
        "toc_name": "欽定前遺詔聖書目錄",
        "testament": "新約",
        "metadata": {
            "title": "欽定前遺詔聖書",
            "work_base_title": "欽定前遺詔聖書",
            "edition": "太平天囯欽定本",
            "authors": ["洪秀全"],
            "date_label": "1853年",
            "ca": "1853年",
            "categories": ["基督教", "聖經", "太平天國"],
            "notes": "癸好三年新刻。缺第四卷《約翰傳福音書》。天頭批註非正文，作 〈…〉 夾註。",
        },
    },
]


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------


class Wiki:
    def __init__(self, sleep: float = SLEEP_SECONDS) -> None:
        self.session = requests.Session()
        self.session.headers.update(HEADERS)
        self.sleep = sleep

    def get(self, **params) -> dict:
        params.setdefault("format", "json")
        params.setdefault("formatversion", "2")
        for attempt in range(6):
            try:
                r = self.session.get(API_ENDPOINT, params=params, timeout=60)
                if r.status_code == 200:
                    time.sleep(self.sleep)
                    return r.json()
                sys.stderr.write("  HTTP %s, retrying\n" % r.status_code)
            except Exception as exc:                       # noqa: BLE001
                sys.stderr.write("  %s, retrying\n" % exc)
            time.sleep(5 * (attempt + 1))
        raise RuntimeError("API failed: %r" % (params,))

    def wikitext(self, titles: Iterable[str]) -> Dict[str, str]:
        """Fetch raw wikitext for many pages at once."""
        titles = list(titles)
        out: Dict[str, str] = {}
        for i in range(0, len(titles), BATCH):
            chunk = titles[i:i + BATCH]
            data = self.get(action="query", prop="revisions", rvprop="content",
                            rvslots="main", titles="|".join(chunk))
            for page in data.get("query", {}).get("pages", []):
                if "revisions" not in page:
                    sys.stderr.write("  MISSING PAGE: %s\n" % page.get("title"))
                    continue
                out[page["title"]] = page["revisions"][0]["slots"]["main"]["content"]
        return out


# ---------------------------------------------------------------------------
# Table of contents
# ---------------------------------------------------------------------------

SUBPAGE_RE = re.compile(r"^\*\s*\[\[/([^|\]]+)(?:\|([^\]]*))?\]\]")
LINKPAGE_RE = re.compile(r"^\*\s*\[\[([^|\]#]+)(?:\|([^\]]*))?\]\]")
# the 目錄 line also carries the book's 簡稱 and its declared chapter count:
#   *[[/創世記|創世記]]　　（創）　　<span …>計五十</span>章
ABBREV_RE = re.compile(r"[（(]([^（）()]{1,4})[）)]")
DECLARED_RE = re.compile(r"計\s*([〇一二三四五六七八九十百有]+)\s*[章篇]")

_NUM_CACHE: Dict[str, int] = {}


def han_to_int(s: str) -> Optional[int]:
    """Inverse of han_number, over the range these 目錄 use (1-150)."""
    if not _NUM_CACHE:
        for i in range(1, 400):
            _NUM_CACHE[han_number(i)] = i
            _NUM_CACHE.setdefault(han_number(i).lstrip("一"), i)   # 一百 vs 百
    return _NUM_CACHE.get(s)


def parse_toc(edition: dict, index_wikitext: str) -> List[Dict[str, str]]:
    """Return [{'page': full wiki title, 'name': folder name, 'testament': ...}]
    in the order the book's own 目錄 lists them."""
    mode = edition["toc"]
    root = edition["root_title"]
    books: List[Dict[str, str]] = []
    testament = edition.get("testament")

    for line in index_wikitext.splitlines():
        stripped = line.strip()
        # 計五十章 is often split by a letter-spacing span: 計<span …>五十</span>章
        plain = TAG_RE.sub("", stripped).replace("　", "")
        abbrev_m = ABBREV_RE.search(plain)
        declared_m = DECLARED_RE.search(plain)
        extra = {
            "abbrev": abbrev_m.group(1) if abbrev_m else "",
            "declared_chapters": han_to_int(declared_m.group(1)) if declared_m else None,
        }
        if mode == "testaments":
            if re.match(r"^==\s*舊約\s*==", stripped):
                testament = "舊約"
                continue
            if re.match(r"^==\s*新約\s*==", stripped):
                testament = "新約"
                continue

        if mode in ("testaments", "flat"):
            m = SUBPAGE_RE.match(stripped)
            if not m:
                continue
            sub = m.group(1).strip()
            # 施約瑟's 目錄 carries a note in the label: 所羅門歌{{*|又名雅歌}}
            books.append(dict(extra,
                              page="%s/%s" % (root, sub),
                              name=re.sub(r"\{\{[^{}]*\}\}", "",
                                          TAG_RE.sub("", m.group(2) or sub)).strip(),
                              testament=testament or ""))
        else:                                              # "links"
            m = LINKPAGE_RE.match(stripped)
            if not m:
                continue
            target = m.group(1).strip()
            if target.startswith(("File:", "Category:", "Image:", "檔案:", "分類:")):
                continue
            # 新遺詔聖經 puts its 旁注 inside the link label: 達罗<sup>尔</sup>玛人书
            name = TAG_RE.sub("", (m.group(2) or target)).strip()
            # the root's own front matter (序, 贈言, 總目) is catalogue, not text
            if re.search(r"(序$|贈言$|仝序$|總目$)", name):
                continue
            books.append(dict(extra, page=target, name=name,
                              testament=testament or ""))
    return books


# ---------------------------------------------------------------------------
# Cleaning
# ---------------------------------------------------------------------------

NOTE_OPEN, NOTE_CLOSE = "〈", "〉"

# {{ul|X}} 專名號, {{du|X}} 書名號, {{專|X}} {{地|X}} — printed as side-lines
# beside the text; dropped in clean/.  They can mark two names at once,
# {{專|雅各|約瑟}}, so the inner bar is dropped with them.
UL_RE = re.compile(r"\{\{\s*(?:ul|du|專|地)\s*\|([^{}]*)\}\}")
# {{Unihan|2BB07}} names a character by codepoint — 𫬇, plane 2.  Resolve it to
# the real character; never let it fall out of the text.
UNIHAN_RE = re.compile(r"\{\{\s*Unihan\s*\|\s*([0-9A-Fa-f]{4,6})\s*\}\}")
# {{?|⿰口士}} is a character with NO Unicode encoding, given as an Ideographic
# Description Sequence.  The IDS is the only representation there is, so it is
# kept as the text.
IDS_RE = re.compile(r"\{\{\s*\?\s*\|([^{}|]*)\}\}")
# {{-|X}} wraps a 詩篇 題辭 (superscription) and nests {{ul}} inside it, so it
# can only be unwrapped once the inner templates are gone.
DASH_RE = re.compile(r"\{\{\s*-\s*\|([^{}]*)\}\}")
# {{*|X}} 夾註, {{批|X}} 洪秀全天頭批註 → house note style
NOTE_RE = re.compile(r"\{\{\s*(?:\*|批)\s*\|([^{}]*)\}\}")
# {{!|字|編者說明}} — Wikisource's own glyph note; keep the character only
GLYPH_RE = re.compile(r"\{\{\s*!\s*\|([^{}|]*)\|[^{}]*\}\}")
# <sup>[[#1a|a]]</sup> — cross-references ADDED by Wikisource, not in the book
XREF_RE = re.compile(r"<sup>\s*\[\[[^\]]*\]\]\s*</sup>")
SUP_RE = re.compile(r"<sup>([^<]*)</sup>")
# image embeds carry their own display parameters (右|无框|444x444像素) which a
# plain link-unwrap would leave behind as text
FILE_RE = re.compile(r"\[\[\s*(?:File|Image|檔案|文件|圖像|图像)\s*:[^\[\]]*"
                     r"(?:\[\[[^\[\]]*\]\][^\[\]]*)*\]\]", re.I)
WIKILINK_RE = re.compile(r"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]")
EXTLINK_RE = re.compile(r"\[(?:https?|//)\S*(?:\s+([^\]]*))?\]")
DROP_TEMPLATES_RE = re.compile(
    r"\{\{\s*(?:gototop|chapter|Chapter|Anchor|anchor|-\s*\}|檢索|HideH|HideF|"
    r"header2?|footer|Textquality|PD[^{}|]*|Pd[^{}|]*)[^{}]*\}\}", re.I)
TAG_RE = re.compile(r"</?[a-zA-Z][^>]*>")
QUOTE_RE = re.compile(r"'{2,5}")


def clean_inline(text: str, sup_mode: str = "inline", keep_spaces: bool = False) -> str:
    """Strip Wikisource markup down to the text as the book prints it.

    Glosses and annotations survive as 〈…〉, matching the house convention for
    Wikisource-sourced files already in clean/.
    """
    text = XREF_RE.sub("", text)                       # editorial, not in book
    for _ in range(8):                                 # {{ul}} nests in {{*}}/{{-}}
        new = UNIHAN_RE.sub(lambda mm: chr(int(mm.group(1), 16)), text)
        new = IDS_RE.sub(lambda mm: mm.group(1).strip(), new)
        new = UL_RE.sub(lambda mm: mm.group(1).replace("|", ""), new)
        new = GLYPH_RE.sub(r"\1", new)
        new = NOTE_RE.sub(NOTE_OPEN + r"\1" + NOTE_CLOSE, new)
        new = DASH_RE.sub(r"\1", new)
        if new == text:
            break
        text = new
    if sup_mode == "drop":
        text = SUP_RE.sub("", text)
    elif sup_mode == "bracket":
        text = SUP_RE.sub(r"（\1）", text)
    else:
        text = SUP_RE.sub(r"\1", text)                 # inline, reading order
    text = DROP_TEMPLATES_RE.sub("", text)
    text = RESIDUAL_VERSE_RE.sub("", text)
    text = EXTLINK_RE.sub("", text)
    text = FILE_RE.sub("", text)
    text = WIKILINK_RE.sub(r"\1", text)
    text = QUOTE_RE.sub("", text)
    text = TAG_RE.sub("", text)
    text = text.replace("&nbsp;", "\u3000")
    if keep_spaces:
        # \u65b0\u907a\u8a54\u8056\u7d93 marks its verses with nothing but a space before the
        # numeral, so the spaces are load-bearing there and must survive.
        text = re.sub(r"[ \t]+", " ", text)
    else:
        text = re.sub(r"[ \t]+", "", text)             # no ASCII space in LZH
    return text.strip()


NUMERAL_CHARS = set(DIGITS + "\u5341\u767e\u6709")


def numeral_prefix(seg: str) -> Tuple[str, Optional[int]]:
    """Longest leading run of numeral characters, and the integer it spells."""
    i = 0
    while i < len(seg) and seg[i] in NUMERAL_CHARS:
        i += 1
    while i:
        value = han_to_int(seg[:i])
        if value is not None:
            return seg[:i], value
        i -= 1
    return "", None


def split_inline_verses(text: str) -> Tuple[List[Tuple[int, str]], str, List[str]]:
    """Verses marked the way \u65b0\u907a\u8a54\u8056\u7d93 marks them: a Han numeral butted onto
    the verse, the previous verse ended by a single space.

        \u4e00\u6590\u6c83\u80a5\u52d2\u4e4e\u3001\u6211\u65bc\u4f0a\u4f0a\u7a4c\u65af\u884c\u4e8b\u8aa8\u4eba\u3001 \u4e8c\u53ca\u964d\u8af8\u8aed\u3001\u4e88\u8a17\u8056\u795e\u9078\u5f92\u3001\u2026

    Walks the expected verse numbers in order, so a numeral appearing inside a
    verse (\u4e09\u65e5, \u5341\u4e8c\u4f7f\u5f92) cannot be mistaken for a verse mark unless it happens
    to be exactly the number due next.
    """
    warnings: List[str] = []
    out: List[Tuple[int, str]] = []
    preamble: List[str] = []
    current: List[str] = []
    current_number: Optional[int] = None
    expect = 1
    for seg in re.split(r"\s+", text.strip()):
        if not seg:
            continue
        prefix, value = numeral_prefix(seg)
        if value != expect:
            if seg.startswith(han_number(expect)):
                prefix = han_number(expect)             # the verse's own text
            else:                                       # begins with a numeral
                (current if current_number else preamble).append(seg)
                continue
        if current_number is not None:
            out.append((current_number, "".join(current)))
        current_number, current = expect, [seg[len(prefix):]]
        expect += 1
    if current_number is not None:
        out.append((current_number, "".join(current)))
    if preamble:
        warnings.append("%d segment(s) before verse one kept as a preamble"
                        % len(preamble))
    return out, "".join(preamble), warnings


# ---------------------------------------------------------------------------
# Book parsing
# ---------------------------------------------------------------------------

# A CHAPTER boundary is a level-2 heading and nothing else.  施約瑟淺文理譯本
# puts ===天主創造天地=== section headings every few verses; those are printed
# text inside the chapter, not chapter breaks.
HEADING_RE = re.compile(r"^(==)([^=\n].*?)==\s*$", re.M)
SUBHEADING_RE = re.compile(r"^(={3,5})([^=\n].*?)\1\s*$", re.M)
CHAPTER_TAG_RE = re.compile(r"\{\{\s*[Cc]hapter\s*\|\s*(\d+)")
# both spellings: {{verse|chapter=1|verse=1}} and {{verse|1|1}}
# 新遺詔聖經 spells the template {{Verse|9|1}} with a capital V in places, so the
# name is matched case-insensitively; the parameter names are matched too.
# 新遺詔聖經 spells it {{Verse|9|1}} with a capital V in places, and 委辦譯本
# writes a merged pair as a range, {{verse|1|1-2}}.
VERSE_RE = re.compile(
    r"\{\{\s*[Vv]erse\s*\|\s*(?:chapter\s*=\s*)?(\d+)\s*\|\s*(?:verse\s*=\s*)?"
    r"(\d+)(?:\s*[-–—]\s*(\d+))?\s*\}\}")
ANY_VERSE_RE = re.compile(r"\{\{\s*[Vv]erse\s*\|")
# A verse template still sitting inside a verse BODY is one VERSE_RE could not
# read — {{verse|32|}} with no number, {{verse|、 unclosed.  Three exist.  The
# warning names each one; the fragment itself is dropped so the corpus text
# stays clean.
RESIDUAL_VERSE_RE = re.compile(r"\{\{\s*[Vv]erse\s*\|[^{}]*\}\}|\{\{\s*[Vv]erse\s*\|")


def heading_label(raw: str) -> str:
    """Text of a heading with its span/colour markup removed."""
    s = re.sub(r"\{\{\s*[Cc]hapter\s*\|\s*\d+\s*\|([^{}]*)\}\}", r"\1", raw)
    s = TAG_RE.sub("", s)
    return s.strip()


def single_chapter_page(wikitext: str, sup_mode: str) -> Tuple[List[dict], List[str]]:
    """A page with no level-2 headings.  Two shapes occur, both in 新遺詔聖經:

      * a one-chapter epistle whose VERSES are the === 一 === subheadings
        (宗徒伊望公书第二/第三, 宗徒伊屋达公书 …)
      * a one-chapter epistle set as unbroken prose with no verse numbers
        at all (宗徒葩韦勒达肥利孟书)
    """
    warnings: List[str] = []
    verses: List[Tuple[str, str]] = []
    subs = list(SUBHEADING_RE.finditer(wikitext))
    numbered = [(han_to_int(heading_label(s.group(2))), s) for s in subs]
    numbered = [(n, s) for n, s in numbered if n is not None]

    if numbered and [n for n, _ in numbered] == list(range(1, len(numbered) + 1)):
        for i, (n, s) in enumerate(numbered):
            end = numbered[i + 1][1].start() if i + 1 < len(numbered) else len(wikitext)
            text = clean_inline(wikitext[s.end():end], sup_mode)
            if text:
                verses.append(("〔%s〕" % han_number(n), text))
        warnings.append("verses taken from === N === subheadings, no chapter heading")
    else:
        text = clean_inline(wikitext, sup_mode)
        if not text:
            return [], ["page has no body text"]
        verses.append(("", text))
        warnings.append("no chapter or verse marks in the source; "
                        "written as one unnumbered 第一章")

    return [{
        "number": 1, "unit": "章", "label": "第一章", "division": None,
        "preamble": "", "verses": verses, "summary": "",
    }], warnings


def parse_book(wikitext: str, sup_mode: str = "inline") -> Tuple[List[dict], List[str]]:
    """Split a book page into chapters.

    Returns (chapters, warnings).  Each chapter is
        {number, unit, label, division, verses: [(marker, text)], summary}

    The chapter NUMBER comes from the {{verse}} tags, never from the heading —
    委辦譯本 創世記 headings 第二十五章 twice, and the tags are the correct ones.
    """
    warnings: List[str] = []

    # --- the HideH ... HideF block at the top is the book's own 章目 table ----
    summaries: Dict[int, str] = {}
    toc_block = wikitext
    end = toc_block.find("{{HideF}}")
    if end != -1:
        toc_block = toc_block[:end]
        rows = re.findall(r"^\|\s*\[\[#第[^\]]*\]\]\s*\n\|\s*(.+)$", toc_block, re.M)
        for i, summary in enumerate(rows, 1):
            summaries[i] = clean_inline(summary, sup_mode)

    # --- carve the page at its headings ------------------------------------
    marks = list(HEADING_RE.finditer(wikitext))
    if not marks:
        return single_chapter_page(wikitext, sup_mode)

    chapters: List[dict] = []
    pending_division: Optional[str] = None

    for i, m in enumerate(marks):
        body = wikitext[m.end(): marks[i + 1].start() if i + 1 < len(marks) else len(wikitext)]
        label = heading_label(m.group(2))

        verses = list(VERSE_RE.finditer(body))
        good = {v.start() for v in verses}
        for bad in ANY_VERSE_RE.finditer(body):
            if bad.start() not in good:
                warnings.append("malformed verse template %r — no number to read"
                                % body[bad.start():bad.start() + 22].replace("\n", " "))

        # --- 新遺詔聖經: no templates, Han numerals inline, space-separated ---
        if not verses:
            inline_text = clean_inline(body, sup_mode, keep_spaces=True)
            head = re.match(r"^第([〇一二三四五六七八九十百有]+)([章篇])$", label)
            if head and inline_text:
                number = han_to_int(head.group(1))
                if number is None:
                    warnings.append("unreadable heading %r" % label)
                    continue
                pairs, pre, warn = split_inline_verses(inline_text)
                warnings.extend("%s: %s" % (label, w) for w in warn)
                chapters.append({
                    "number": number,
                    "unit": head.group(2),
                    "label": "第%s%s" % (han_number(number), head.group(2)),
                    "division": pending_division,
                    "preamble": pre,
                    "verses": [("〔%s〕" % han_number(n), t) for n, t in pairs if t],
                    "summary": "",
                })
                pending_division = None
                continue
            # otherwise a division heading such as 詩篇卷一 — belongs to the
            # chapter that follows it
            if label:
                pending_division = label
            continue

        number = int(verses[0].group(1))
        tag = CHAPTER_TAG_RE.search(body)
        if tag and int(tag.group(1)) != number:
            warnings.append("chapter tag %s disagrees with verse tags %s"
                            % (tag.group(1), number))

        unit = "篇" if label.endswith("篇") else "章"
        expected = "第%s%s" % (han_number(number), unit)
        if label and label != expected:
            warnings.append("heading %r renumbered to %r from its verse tags"
                            % (label, expected))

        # --- anything before verse 1 is a 題辭 (psalm superscription) -------
        preamble = clean_inline(body[:verses[0].start()], sup_mode).strip("○　 ")

        # --- verses --------------------------------------------------------
        out: List[Tuple[str, str]] = []
        carried: List[str] = []
        for j, v in enumerate(verses):
            vnum, vend = int(v.group(2)), int(v.group(3) or v.group(2))
            raw = body[v.end(): verses[j + 1].start() if j + 1 < len(verses) else len(body)]
            # a === section heading === inside the chapter (施約瑟) is printed text
            raw = SUBHEADING_RE.sub(lambda mm: "\n" + heading_label(mm.group(2)) + "\n", raw)
            text = clean_inline(raw, sup_mode)
            marker = "".join("〔%s〕" % han_number(k) for k in range(vnum, vend + 1))
            if not text:
                carried.append(marker)           # merged verse, e.g. 利未記十一46-47
                continue
            out.append(("".join(carried) + marker, text))
            carried = []
        if carried and out:
            out[-1] = (out[-1][0], out[-1][1])
            warnings.append("trailing empty verse marker(s) %s dropped" % "".join(carried))

        chapters.append({
            "number": number,
            "unit": unit,
            "label": expected,
            "division": pending_division,
            "preamble": preamble,
            "verses": out,
            "summary": summaries.get(number, ""),
        })
        pending_division = None

    seen = [c["number"] for c in chapters]
    if seen != list(range(1, len(seen) + 1)):
        warnings.append("chapter numbers not 1..n: %s" % seen[:12])
    return chapters, warnings


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------


def safe_name(name: str) -> str:
    """Keep the title a Unicode string; only remove characters Windows forbids."""
    name = name.strip().replace("/", "_").replace("\\", "_")
    return re.sub(r'[<>:"|?*\r\n\t]', "_", name)


class Writer:
    """Writes UTF-8 with BOM by default, per the corpus rule for Han script.

    Note the .txt files already in clean/ are mixed: a sample of 52 gave 44
    no-BOM/CRLF, 8 no-BOM/LF, while every metadata.json carries the BOM.  The
    existing hand-made 聖經 chapter file is no-BOM/CRLF too.  --no-bom and --lf
    are there if you would rather match the neighbours than the rule.
    """

    def __init__(self, root: str, dry_run: bool = False,
                 bom: bool = True, newline: str = "\r\n") -> None:
        self.root = root
        self.dry_run = dry_run
        self.encoding = "utf-8-sig" if bom else "utf-8"
        self.newline = newline
        self.count = 0

    def write(self, relpath: str, text: str) -> None:
        path = os.path.join(self.root, relpath)
        self.count += 1
        if self.dry_run:
            print("  would write %s (%d chars)" % (relpath, len(text)))
            return
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding=self.encoding, newline=self.newline) as fh:
            fh.write(text)


def chapter_text(ch: dict) -> str:
    """One chapter file: verses one per paragraph, blank line between, exactly
    as the 聖經 folder already in the tree is laid out."""
    blocks: List[str] = []
    if ch["division"]:
        blocks.append(ch["division"])
    if ch["preamble"]:
        blocks.append(ch["preamble"])
    for marker, text in ch["verses"]:
        blocks.append(marker + text)
    return "\n\n".join(blocks) + "\n"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def run_edition(wiki: Wiki, edition: dict, writer: Writer, args) -> List[dict]:
    print("\n=== %s (%s) ===" % (edition["key"], edition["root_title"]))
    index_text = wiki.wikitext([edition["root_title"]])[edition["root_title"]]
    books = parse_toc(edition, index_text)
    if args.book:
        books = [b for b in books if args.book in b["name"] or args.book in b["page"]]
    print("books listed: %d" % len(books))
    if not books:
        return []

    base = os.path.join("中國漢文", "clean", str(edition["period"]),
                        str(edition["polity"]), safe_name(str(edition["folder"])))

    # ---- the work's own 目錄 ------------------------------------------------
    preface = ""
    m = re.search(r"^===?\s*新?舊?約?全?書?目錄\s*===?\s*$(.*?)^(?:==|\*)",
                  index_text, re.M | re.S)
    if m:
        preface = clean_inline(m.group(1), args.sup_mode)
    toc_lines = [preface, ""] if preface else []
    last_testament = None
    for b in books:
        if b["testament"] and b["testament"] != last_testament:
            if last_testament is not None:
                toc_lines.append("")
            toc_lines.append(b["testament"])
            last_testament = b["testament"]
        declared = b.get("declared_chapters")
        toc_lines.append("\t".join([
            b["name"],
            "（%s）" % b["abbrev"] if b.get("abbrev") else "",
            "計%s章" % han_number(declared) if declared else "",
        ]).rstrip("\t"))
    writer.write(os.path.join(base, safe_name(str(edition["toc_name"])) + ".txt"),
                 "\n".join(toc_lines) + "\n")

    rows: List[dict] = []
    pages = wiki.wikitext([b["page"] for b in books])

    for b in books:
        text = pages.get(b["page"])
        if text is None:
            print("  !! %s missing" % b["page"])
            continue
        chapters, warnings = parse_book(text, args.sup_mode)
        for w in warnings:
            print("  [%s] %s" % (b["name"], w))
        if args.limit_chapters:
            chapters = chapters[:args.limit_chapters]
        if not chapters:
            print("  !! %s yielded no chapters" % b["name"])
            continue

        # the book's own 目錄 declares how many chapters it has — check it
        declared = b.get("declared_chapters")
        if declared and not args.limit_chapters and declared != len(chapters):
            print("  !! %s: 目錄 declares %d chapters, page yields %d"
                  % (b["name"], declared, len(chapters)))

        bookdir = os.path.join(base, safe_name(b["testament"]), safe_name(b["name"])) \
            if b["testament"] else os.path.join(base, safe_name(b["name"]))

        # per-book 章目
        toc = [("%s\t%s" % (c["label"], c["summary"])).rstrip() for c in chapters]
        writer.write(os.path.join(bookdir, safe_name(b["name"]) + "_目錄.txt"),
                     "\n".join(toc) + "\n")

        for c in chapters:
            writer.write(os.path.join(bookdir, c["label"] + ".txt"), chapter_text(c))
            rows.append({
                "edition": edition["key"],
                "testament": b["testament"],
                "book": b["name"],
                "chapter": c["number"],
                "unit": c["unit"],
                "file": os.path.join(bookdir, c["label"] + ".txt").replace("\\", "/"),
                "verses": len(c["verses"]),
                "chars": sum(len(t) for _, t in c["verses"]),
                "source_url": "https://zh.wikisource.org/wiki/" + b["page"].replace(" ", "_"),
            })
        print("  %-24s %3d chapters, %5d verses"
              % (b["name"], len(chapters), sum(len(c["verses"]) for c in chapters)))

    # ---- metadata.json -----------------------------------------------------
    meta = {
        "schema_version": 1,
        "corpus_root": "中國漢文",
        "macro_region": "中國",
        "period": edition["period"],
        "polity": edition["polity"],
        "is_compilation": True,
        "known_commentaries": [],
    }
    meta.update(edition["metadata"])                      # type: ignore[arg-type]
    meta["source"] = {
        "provider": "維基文庫 zh.wikisource.org",
        "url": "https://zh.wikisource.org/wiki/" + str(edition["root_title"]).replace(" ", "_"),
        "licence": "CC BY-SA 4.0",
        "retrieved": time.strftime("%Y-%m-%d"),
        "scraper": "scrape_bible_wikisource.py " + SCRIPT_VERSION,
    }
    meta["documents"] = [
        {"file": os.path.basename(r["file"]), "path": r["file"],
         "book": r["book"], "chapter": r["chapter"]} for r in rows
    ]
    writer.write(os.path.join(base, "metadata.json"),
                 json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", help=r"corpus dir, e.g. E:\fanyahanwen-corpus\corpus")
    ap.add_argument("--out", help="write the tree here instead (for inspection)")
    ap.add_argument("--edition", action="append",
                    help="only this edition key; repeatable. %s"
                         % ", ".join(str(e["key"]) for e in EDITIONS))
    ap.add_argument("--book", help="only books whose name contains this")
    ap.add_argument("--limit-chapters", type=int, default=0)
    ap.add_argument("--sup-mode", choices=["inline", "bracket", "drop"], default="inline",
                    help="<sup> side-characters: 新遺詔聖經's phonetic marks. "
                         "inline 合利爾斯托斯 | bracket 合利（爾）斯托斯 | drop 合利斯托斯")
    ap.add_argument("--sleep", type=float, default=SLEEP_SECONDS)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-bom", action="store_true",
                    help="write plain UTF-8, matching most .txt already in clean/ "
                         "(default is UTF-8 with BOM, the corpus rule for Han script)")
    ap.add_argument("--lf", action="store_true",
                    help="LF line endings (default CRLF, which most .txt in clean/ use)")
    args = ap.parse_args()

    root = args.out or args.corpus
    if not root:
        ap.error("give --corpus or --out")
    if not args.dry_run and not os.path.isdir(root):
        ap.error("no such directory: %s" % root)

    editions = EDITIONS
    if args.edition:
        wanted = set(args.edition)
        editions = [e for e in EDITIONS if e["key"] in wanted]
        if not editions:
            ap.error("no edition matched %s" % args.edition)

    wiki = Wiki(sleep=args.sleep)
    writer = Writer(root, dry_run=args.dry_run, bom=not args.no_bom,
                    newline="\n" if args.lf else "\r\n")
    rows: List[dict] = []
    for edition in editions:
        rows.extend(run_edition(wiki, edition, writer, args))

    if rows and not args.dry_run:
        index = os.path.join(root, "index_聖經_維基文庫.csv")
        with open(index, "w", encoding=writer.encoding, newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        print("\nindex: %s" % index)

    print("\n%d files, %d chapters" % (writer.count, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
