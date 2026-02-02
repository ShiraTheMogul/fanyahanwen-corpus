"""
Segmentation utilities.

Modes:
- paragraph: split on blank lines.
- sentence_run: split on 。！？； (if trusted).
- window: sliding Han-count windows for punctuationless texts.
"""
from __future__ import annotations
import re
from typing import List, Literal

SegmentMode = Literal["paragraph", "sentence_run", "window"]
_SENT_SPLIT_RE = re.compile(r"(?<=[。！？；])")

def segment_text(
    text: str,
    mode: SegmentMode = "paragraph",
    *,
    window_size_han: int = 300,
    window_stride_han: int = 200,
    treat_punct_as_boundaries: bool = True,
) -> List[str]:
    if not text:
        return []

    if mode == "paragraph":
        parts = re.split(r"\n\s*\n+", text)
        return [p.strip() for p in parts if p.strip()]

    if mode == "sentence_run":
        flat = re.sub(r"\s+", " ", text.strip())
        if not flat:
            return []
        if not treat_punct_as_boundaries:
            return [flat]
        return [p.strip() for p in _SENT_SPLIT_RE.split(flat) if p.strip()]

    if mode == "window":
        chars = list(text)
        han_positions = [i for i, ch in enumerate(chars) if "\u4e00" <= ch <= "\u9fff"]
        if not han_positions:
            cleaned = text.strip()
            return [cleaned] if cleaned else []
        segs: List[str] = []
        start_h = 0
        while start_h < len(han_positions):
            end_h = min(len(han_positions) - 1, start_h + window_size_han - 1)
            start_idx = han_positions[start_h]
            end_idx = han_positions[end_h] + 1
            chunk = "".join(chars[start_idx:end_idx]).strip()
            if chunk:
                segs.append(chunk)
            start_h += window_stride_han
        return segs

    raise ValueError(f"unknown segmentation mode: {mode}")
