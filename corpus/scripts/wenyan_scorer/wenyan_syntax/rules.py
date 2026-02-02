"""
Rule definitions and execution.
"""
from __future__ import annotations
from dataclasses import dataclass
import json
import re
from pathlib import Path
from typing import Callable, Dict, List, Optional, Pattern

from .utils import iter_overlapping_matches

GuardFn = Callable[[str, re.Match], bool]

@dataclass(frozen=True)
class Rule:
    rule_id: str
    family: str
    role: str
    regex: Pattern[str]
    weight: float
    notes: str = ""
    guard: Optional[GuardFn] = None

def load_ruleset(name: str = "pulleyblank_core_v3") -> List[Rule]:
    if name == "pulleyblank_core_v3":
        from .rulesets.pulleyblank_core_v3 import RULES
        return RULES
    raise ValueError(f"unknown ruleset: {name}")

def load_weights_override(path: str) -> Dict[str, float]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("weights override JSON must be an object")
    return {str(k): float(v) for k, v in data.items()}

def apply_weight_overrides(rules: List[Rule], overrides: Dict[str, float]) -> List[Rule]:
    out: List[Rule] = []
    for r in rules:
        if r.rule_id in overrides:
            out.append(Rule(r.rule_id, r.family, r.role, r.regex, overrides[r.rule_id], r.notes, r.guard))
        else:
            out.append(r)
    return out

def run_rule(rule: Rule, text: str, *, keep_evidence: bool = True, max_evidence: int = 25):
    cnt = 0
    ev = []
    for m in iter_overlapping_matches(rule.regex, text):
        if rule.guard and not rule.guard(text, m):
            continue
        cnt += 1
        if keep_evidence and len(ev) < max_evidence:
            ev.append({"start": m.start(), "end": m.end(), "match": m.group(0)})
    return cnt, ev
