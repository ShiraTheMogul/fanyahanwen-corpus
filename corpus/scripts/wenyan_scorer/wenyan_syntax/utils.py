"""
Mechanical helpers (no linguistic assumptions).
"""
from __future__ import annotations
import re
from typing import Iterator

_HAN_RE = re.compile(r"[\u4e00-\u9fff]")

def count_han(text: str) -> int:
    return len(_HAN_RE.findall(text or ""))

def per_1000(count: int, han_chars: int) -> float:
    if han_chars <= 0:
        return 0.0
    return (count * 1000.0) / float(han_chars)

def iter_overlapping_matches(pattern: re.Pattern, text: str) -> Iterator[re.Match]:
    i = 0
    while i < len(text):
        m = pattern.search(text, i)
        if not m:
            break
        yield m
        i = m.start() + 1
