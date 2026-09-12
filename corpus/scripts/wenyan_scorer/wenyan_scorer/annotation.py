"""
Reading-apparatus stripping.

Kanbun kundoku (Japan), gugyeol and eonhae (Korea) and hanvan (Vietnamese) are 
annotation systems laid over a Literary Chinese text. The Han skeleton underneath 
is Literary Chinese and can be read as such uninhibited. The kana, hangul, return 
marks and glosses are instructions for reading it aloud in another language. They 
are not evidence for the language of the text, so they are removed before scoring
rather than scored. If anything, seeing these is a sign it is Literary Chinese,
as the author would be identifying it.

"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict

from .utils import count_han, nfc

# --- Annotation character ranges -------------------------------------------

#: U+3190-U+319F is the Unicode "Kanbun" block: the kundoku return marks.
#: ㆐ linking, ㆑ レ点 (reverse), ㆒㆓㆔㆕ number points, ㆖㆗㆘ upper/middle/lower,
#: ㆙㆚㆛㆜ 甲乙丙丁 points, ㆝㆞㆟ heaven/earth/man points.
KANBUN_MARKS = "㆐-㆟"

#: Hiragana, katakana, katakana phonetic extensions, half-width katakana.
#: Okurigana and furigana in kanbun; also the grammar of running Japanese.
#:
#: U+30FB ・ is deliberately carved OUT of the katakana block. It is the
#: interpunct, not a kana: it separates the syllables of a transliterated name,
#: as 心理新説序 (1880s 漢文) does in 費希的・設林・歇傑爾 (Fichte, Schelling,
#: Hegel). Stripping it left the 的 of 費希的 looking like a vernacular linker.
KANA = "ぁ-ゟァ-ヺー-ヿㇰ-ㇿｦ-ﾟ"

#: Hangul syllables and jamo. Gugyeol annotation and Korean mixed script.
HANGUL = "ᄀ-ᇿ㄰-㆏ꥠ-꥿가-힯ힰ-퟿"

#: Latin, Cyrillic, and the diacritics that carry Vietnamese quoc-ngu.
LATIN = "A-Za-zÀ-ɏḀ-ỿЀ-ӿ"

#: Combining marks used for tone/reading annotation.
COMBINING = "̀-ͯ⃐-⃿"

_APPARATUS_CLASS = f"[{KANBUN_MARKS}{KANA}{HANGUL}{LATIN}{COMBINING}]"
_APPARATUS_RE = re.compile(_APPARATUS_CLASS)

#: Ruby / interlinear gloss delimiters. A gloss inside these is apparatus even
#: when its content is Han (a Han gloss on a Han word is still a gloss).
_GLOSS_RE = re.compile(
    r"[（(\[【｛{]"          # opening
    r"[^）)\]】｝}]{0,40}"    # short content only; long parentheses are prose
    r"[）)\]】｝}]"
)

#: Ruby markup as it appears in several corpus export formats.
_RUBY_RE = re.compile(r"<(?:ruby|rt|rp|rb)[^>]{0,80}>|</(?:ruby|rt|rp|rb)>")

_DIGIT_RE = re.compile(r"[0-9０-９]")


@dataclass
class StripResult:
    """What `strip_reading_apparatus` did, and how much it had to do."""

    text: str
    """The Han skeleton: what actually gets scored."""

    original: str

    removed_counts: Dict[str, int] = field(default_factory=dict)
    """Characters removed, by apparatus category."""

    kana_ratio: float = 0.0
    """Kana as a proportion of (kana + Han) in the ORIGINAL text.

    This is the number that separates annotation from running Japanese. Sparse
    okurigana over kanbun sits low; kanji-kana majiri bun sits near 0.5.
    """

    hangul_ratio: float = 0.0
    """Hangul as a proportion of (hangul + Han) in the original.

    Same logic for Korean: gugyeol annotation is sparse, hanja-hangul mixed
    script is not.
    """

    latin_ratio: float = 0.0

    @property
    def apparatus_ratio(self) -> float:
        """The largest of the per-script ratios — the single number to compare
        against a threshold."""
        return max(self.kana_ratio, self.hangul_ratio, self.latin_ratio)

    @property
    def total_removed(self) -> int:
        return sum(self.removed_counts.values())


def _ratio(other: int, han: int) -> float:
    denom = other + han
    return (other / denom) if denom else 0.0


def strip_reading_apparatus(text: str, *, strip_glosses: bool = True) -> StripResult:
    """Reduce `text` to its Han skeleton and report how much was apparatus.

    Removes, in order: ruby markup, parenthesised glosses, then every character
    in the kundoku/gugyeol/Latin apparatus classes. Punctuation and Han survive.

    `strip_glosses=False` keeps parenthesised material, which you want when the
    corpus uses parentheses for editorial content you would rather see than
    silently drop.
    """
    original = nfc(text or "")
    work = original

    work = _RUBY_RE.sub("", work)
    if strip_glosses:
        work = _GLOSS_RE.sub("", work)

    counts = {
        "kanbun_marks": len(re.findall(f"[{KANBUN_MARKS}]", work)),
        "kana": len(re.findall(f"[{KANA}]", work)),
        "hangul": len(re.findall(f"[{HANGUL}]", work)),
        "latin": len(re.findall(f"[{LATIN}]", work)),
        "combining": len(re.findall(f"[{COMBINING}]", work)),
    }

    work = _APPARATUS_RE.sub("", work)
    work = _DIGIT_RE.sub("", work)
    # Collapse the whitespace the removals leave behind.
    work = re.sub(r"[ \t　]{2,}", " ", work)

    han = count_han(original)
    return StripResult(
        text=work,
        original=original,
        removed_counts=counts,
        kana_ratio=_ratio(counts["kana"], han),
        hangul_ratio=_ratio(counts["hangul"], han),
        latin_ratio=_ratio(counts["latin"], han),
    )


#: Above this apparatus ratio, the removed material was carrying the grammar,
#: so the Han skeleton is not a Literary Chinese text and must not be scored as
#: one. Deliberately a default rather than a constant — run it over 日本漢文 and
#: move it to where the evidence puts it.
DEFAULT_APPARATUS_LIMIT = 0.25
