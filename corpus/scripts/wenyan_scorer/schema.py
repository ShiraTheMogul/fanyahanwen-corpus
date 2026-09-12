from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable, Dict, List, Literal, Optional, Pattern

#: A guard runs after a regex matches and can reject the match on context the
#: regex cannot express. Returning False drops the hit.
GuardFn = Callable[[str, "re.Match"], bool]

Polarity = Literal["lc", "vn"]
"""'lc' = evidence the text is Literary Chinese.
   'vn' = evidence the text is vernacular (modern Mandarin or early baihua).

   These are NOT opposites and are never summed. A text can show both (a
   Ming-Qing text quoting a classic), or neither (a short fragment)."""

Tier = Literal[1, 2, 3]
"""1: near-decisive. The construction is structurally unavailable in the
      Mandarin. 唯…是…, 何…之有, Neg+PRO+V object preposing.
   2: strong but not decisive. 所+V, 者…也 predication, 以…為…
   3: density only. Bare particle counts. Individually worthless, informative
      in aggregate, and heavily down-weighted."""


@dataclass(frozen=True)
class Rule:
    rule_id: str
    family: str
    polarity: Polarity
    tier: Tier
    regex: Pattern[str]
    weight: float
    cite: str
    """Pulleyblank section and page, e.g. 'VIII.1 p.69'. 'n/a' for rules that
    do not come from him (the Mandarin side is sourced from Yip 2016, but incomplete)."""

    notes: str = ""

    guard: Optional[GuardFn] = None

    repair: Optional[str] = None
    """For a violation rule: what the Literary Chinese equivalent would be."""

    requires_punctuation: bool = False
    """True if this rule's pattern depends on a punctuation mark being present."""

    def with_weight(self, w: float) -> "Rule":
        return Rule(
            self.rule_id, self.family, self.polarity, self.tier, self.regex, w,
            self.cite, self.notes, self.guard, self.repair, self.requires_punctuation,
        )


def validate_ruleset(rules: List[Rule]) -> List[str]:
    """Return a list of problems. Empty list means the ruleset is well-formed."""
    problems: List[str] = []
    seen: Dict[str, int] = {}
    for r in rules:
        seen[r.rule_id] = seen.get(r.rule_id, 0) + 1
        if r.polarity == "lc" and r.weight <= 0:
            problems.append(f"{r.rule_id}: polarity 'lc' but weight {r.weight} <= 0")
        if r.polarity == "vn" and r.weight <= 0:
            problems.append(
                f"{r.rule_id}: polarity 'vn' but weight {r.weight} <= 0 — "
                "vernacular weights are positive on their own axis, not negative"
            )
        if not r.cite:
            problems.append(f"{r.rule_id}: empty cite")
        if r.tier not in (1, 2, 3):
            problems.append(f"{r.rule_id}: tier {r.tier} not in 1..3")
    for rid, n in seen.items():
        if n > 1:
            problems.append(f"{rid}: defined {n} times")
    return problems
