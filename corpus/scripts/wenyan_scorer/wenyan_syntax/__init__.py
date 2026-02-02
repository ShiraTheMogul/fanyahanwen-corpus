"""
wenyan_syntax

Pulleyblank-aligned, construction-first syntactic feature extractor for Literary Chinese (文言/漢文)
versus Modern Mandarin grammar signals.

Principle:
- Score constructions, not isolated characters.
- Ambiguous characters only count inside role-bearing frames.
- Prefer auditable output: feature profile + evidence trace.
"""
from .score import score_text, score_segments
from .segment import segment_text
from .rules import load_ruleset, Rule

__all__ = ["score_text", "score_segments", "segment_text", "load_ruleset", "Rule"]
