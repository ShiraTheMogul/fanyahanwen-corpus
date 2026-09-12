"""
Mechanical helpers. No linguistic assumptions live here.
"""
from __future__ import annotations

import re
import unicodedata
from typing import Iterator, List

# --- What counts as Han -----------------------------------------------------
# Each entry is (first, last) inclusive.
HAN_RANGES = [
    (0x3400, 0x4DBF),    # CJK Ext A
    (0x4E00, 0x9FFF),    # CJK Unified Ideographs
    (0xF900, 0xFAFF),    # CJK Compatibility Ideographs
    (0x20000, 0x2A6DF),  # Ext B
    (0x2A700, 0x2EBEF),  # Ext C, D, E, F
    (0x2F800, 0x2FA1F),  # Compatibility Supplement
    (0x30000, 0x3134F),  # Ext G
    (0x31350, 0x323AF),  # Ext H
    (0x2EBF0, 0x2EE5D),  # Ext I
    (0x323B0, 0x33479),  # Ext J
]

# Ideographic marks that behave as Han in running text.
HAN_EXTRA = "々〆〇〻"  # 々 〆 〇 〳


def _class_body() -> str:
    parts = []
    for lo, hi in HAN_RANGES:
        parts.append(f"\\U{lo:08x}-\\U{hi:08x}")
    parts.append(re.escape(HAN_EXTRA))
    return "".join(parts)


#: Character class body, WITHOUT the surrounding brackets, so rulesets can
#: compose it: f"[{HAN_BODY}]" for one Han char, f"[^{HAN_BODY}]" to negate.
HAN_BODY = _class_body()

#: Ready-made single-Han-character pattern. Rulesets import this as HAN.
HAN = f"[{HAN_BODY}]"

_HAN_RE = re.compile(HAN)


def count_han(text: str) -> int:
    """Number of Han characters in `text`. This is the denominator for every
    rate the scorer reports, so it has to be right."""
    return len(_HAN_RE.findall(text or ""))


def is_han(ch: str) -> bool:
    return bool(_HAN_RE.match(ch))


def per_1000(count: float, han_chars: int) -> float:
    """Occurrences per 1000 Han characters.

    Why per-1000 and not a raw count: a raw sum grows with text length, so a
    long passage and a short one are not comparable and no fixed threshold can
    mean anything.
    """
    if han_chars <= 0:
        return 0.0
    return (count * 1000.0) / float(han_chars)


# --- Punctuation ------------------------------------------------------------
# Full-width and half-width marks that end a clause when present. Many premodern
# texts have none of these at all; see segment.clause_spans for that case.
CLAUSE_END_PUNCT = "。．！？；!?;｡！？；"
CLAUSE_MID_PUNCT = "，、,，､：:—―"
ALL_PUNCT = CLAUSE_END_PUNCT + CLAUSE_MID_PUNCT + "「」『』（）()《》〈〉【】·‧・…—\"'“”‘’"

_PUNCT_RE = re.compile(f"[{re.escape(ALL_PUNCT)}]")


def has_punctuation(text: str) -> bool:
    return bool(_PUNCT_RE.search(text or ""))


def punctuation_density(text: str) -> float:
    """Punctuation marks per 1000 Han. Near zero means an unpunctuated text,
    which changes which rules can fire — see score.py."""
    return per_1000(len(_PUNCT_RE.findall(text or "")), count_han(text))


# This is because my corpus used Wikisource scrapes to begin with, and sometimes,
# the footer would be imported by mistake.
# Keywords identifying a Wikisource copyright footer. These travel with scraped
# text and are written in modern (often simplified) Chinese. They are not part
# of the work, and on a short document they dominate it: 上帝爲我避難所 is 五言
# verse whose only vernacular hits came from the licence block appended to it —
# "1996年1月1日，这部作品在原著作國家或地區屬於公有領域…".
_LICENCE_WORDS = re.compile(
    r"公有領域|公有领域|原著作國家|原著作国家|版權期限|版权期限|本作品在"
    r"|这部作品|這部作品|維基文庫|维基文库|Public\s?[Dd]omain"
    r"|Creative\s?Commons|CC[ -]BY|著作權保護期|著作权保护期"
)

#: Split points for licence removal. Dropping whole SENTENCES containing a
#: licence keyword, rather than matching a window around it, is the safe form: a
#: first attempt used `[^\n]{0,80}` before the keyword to catch the date prefix,
#: and that leading wildcard swallowed the 80 characters of actual poem in front
#: of the footer — reducing the document to zero Han.
_SENT_SPLIT = re.compile(r"(?<=[。！？\n])")


def strip_markup(text: str) -> str:
    """Remove editorial apparatus that rides along with corpus text: XML/HTML
    tags, bracketed insertions, and Wikisource licence footers.
    """
    text = re.sub(r"<[^>]{0,200}>", "", text)
    text = re.sub(r"\[[^\]]{0,100}\]", "", text)
    if _LICENCE_WORDS.search(text):
        kept = [seg for seg in _SENT_SPLIT.split(text)
                if not _LICENCE_WORDS.search(seg)]
        text = "".join(kept)
    return text


def nfc(text: str) -> str:
    """Normalise to NFC. Compatibility ideographs and some Korean/Japanese
    sources arrive decomposed or in compatibility form; without this the same
    graph can fail to match itself."""
    return unicodedata.normalize("NFC", text or "")


def iter_nonoverlapping(pattern: re.Pattern, text: str) -> Iterator[re.Match]:
    """Standard left-to-right, non-overlapping scan.
    """
    return pattern.finditer(text)


def iter_by_anchor(pattern: re.Pattern, text: str) -> List[re.Match]:
    """Scan allowing overlap, then keep one match per distinct `anchor` position.
    """
    seen = set()
    out: List[re.Match] = []
    i = 0
    n = len(text)
    while i <= n:
        m = pattern.search(text, i)
        if not m:
            break
        try:
            key = m.start("anchor")
        except (IndexError, KeyError):  # pattern has no `anchor` group
            key = -1
        if key < 0:
            # A named group that did not participate in the match reports -1
            # rather than raising. Left unhandled, every such match shares the
            # key -1
            key = m.start()
        if key not in seen:
            seen.add(key)
            out.append(m)
        i = m.start() + 1
    return out
