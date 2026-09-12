"""
Segmentation.

Modes:
  paragraph     split on blank lines (default; matches how the corpus stores works)
  line          one segment per non-empty line
  sentence_run  split on clause-final punctuation
  window        sliding Han-count windows, for unpunctuated texts
  whole         one segment

`window` exists because much premodern material carries no punctuation at all.
Segmenting is only half of that problem: rules whose patterns depend on a
punctuation mark cannot fire on such a text either, which is what
`Rule.requires_punctuation` is for — the scorer reports how many rules it had to
skip instead of silently counting them as zero.
"""
from __future__ import annotations

import re
from typing import List, Literal

from .utils import CLAUSE_END_PUNCT, HAN

SegmentMode = Literal["paragraph", "line", "sentence_run", "window", "whole"]

_SENT_SPLIT_RE = re.compile(f"(?<=[{re.escape(CLAUSE_END_PUNCT)}])")
_HAN_RE = re.compile(HAN)


def segment_text(
    text: str,
    mode: SegmentMode = "paragraph",
    *,
    window_size_han: int = 300,
    window_stride_han: int = 200,
    min_han: int = 0,
) -> List[str]:
    if not text:
        return []

    if mode == "whole":
        segs = [text.strip()]

    elif mode == "paragraph":
        segs = [p.strip() for p in re.split(r"\n\s*\n+", text)]

    elif mode == "line":
        segs = [ln.strip() for ln in text.splitlines()]

    elif mode == "sentence_run":
        flat = re.sub(r"\s+", " ", text.strip())
        segs = [p.strip() for p in _SENT_SPLIT_RE.split(flat)] if flat else []

    elif mode == "window":
        segs = _windows(text, window_size_han, window_stride_han)

    else:
        raise ValueError(f"unknown segmentation mode: {mode!r}")

    out = [s for s in segs if s]
    if min_han > 0:
        out = [s for s in out if len(_HAN_RE.findall(s)) >= min_han]
    return out


def _windows(text: str, size: int, stride: int) -> List[str]:
    if size <= 0 or stride <= 0:
        raise ValueError("window size and stride must be positive")
    chars = list(text)
    han_pos = [i for i, ch in enumerate(chars) if _HAN_RE.match(ch)]
    if not han_pos:
        s = text.strip()
        return [s] if s else []

    segs: List[str] = []
    start_h = 0
    while start_h < len(han_pos):
        end_h = min(len(han_pos) - 1, start_h + size - 1)
        chunk = "".join(chars[han_pos[start_h]: han_pos[end_h] + 1]).strip()
        if chunk:
            segs.append(chunk)
        if end_h == len(han_pos) - 1:
            break
        start_h += stride
    return segs
