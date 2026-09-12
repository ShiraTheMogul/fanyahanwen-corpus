"""
Ruleset loading and execution.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple

from .schema import Rule, validate_ruleset
from .utils import has_punctuation, iter_by_anchor, iter_nonoverlapping

_RULESETS = {
    "pulleyblank_core_v4": "wenyan_syntax.rulesets.pulleyblank_core_v4",
    "vernacular_v1": "wenyan_syntax.rulesets.vernacular_v1",
    "idu_experimental": "wenyan_syntax.rulesets.idu_experimental",
}

#: The two rulesets loaded by default. `idu_experimental` is deliberately NOT
#: here — see its module docstring for why it needs review before it counts.
DEFAULT_RULESETS = ("pulleyblank_core_v4", "vernacular_v1")


def load_ruleset(name: str) -> List[Rule]:
    if name not in _RULESETS:
        raise ValueError(
            f"unknown ruleset: {name!r}; known: {sorted(_RULESETS)}"
        )
    import importlib

    mod = importlib.import_module(_RULESETS[name])
    rules: List[Rule] = list(mod.RULES)
    problems = validate_ruleset(rules)
    if problems:
        raise ValueError(f"ruleset {name} is malformed:\n  " + "\n  ".join(problems))
    return rules


def load_rulesets(names: Sequence[str] = DEFAULT_RULESETS) -> List[Rule]:
    out: List[Rule] = []
    for n in names:
        out.extend(load_ruleset(n))
    problems = validate_ruleset(out)
    if problems:
        raise ValueError("combined rulesets are malformed:\n  " + "\n  ".join(problems))
    return out


def load_weights_override(path: str) -> Dict[str, float]:
    data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(data, dict):
        raise ValueError("weights override JSON must be an object")
    return {str(k): float(v) for k, v in data.items()}


def apply_weight_overrides(rules: List[Rule], overrides: Dict[str, float]) -> List[Rule]:
    unknown = set(overrides) - {r.rule_id for r in rules}
    if unknown:
        # Loud, because a typo'd rule id in a weights file otherwise looks like the override didn't do anything and costs an afternoon with a large corpus.
        raise ValueError(f"weights override names unknown rules: {sorted(unknown)}")
    return [r.with_weight(overrides[r.rule_id]) if r.rule_id in overrides else r
            for r in rules]


def run_rule(
    rule: Rule,
    text: str,
    *,
    keep_evidence: bool = True,
    max_evidence: int = 25,
    punctuated: bool | None = None,
) -> Tuple[int, List[Dict[str, Any]], bool]:
    """
    Count hits for one rule.

    Returns (count, evidence, skipped). `skipped` is True when the rule needs punctuation the text does not have.
    """
    if punctuated is None:
        punctuated = has_punctuation(text)
    if rule.requires_punctuation and not punctuated:
        return 0, [], True

    uses_anchor = "anchor" in (rule.regex.groupindex or {})
    matches = iter_by_anchor(rule.regex, text) if uses_anchor else iter_nonoverlapping(rule.regex, text)

    count = 0
    evidence: List[Dict[str, Any]] = []
    for m in matches:
        if rule.guard and not rule.guard(text, m):
            continue
        count += 1
        if keep_evidence and len(evidence) < max_evidence:
            evidence.append({
                "start": m.start(),
                "end": m.end(),
                "match": m.group(0),
            })
    return count, evidence, False
