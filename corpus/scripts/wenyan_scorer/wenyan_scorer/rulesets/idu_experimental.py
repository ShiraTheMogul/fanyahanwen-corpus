"""
Korean idu (吏讀) clerical orthography — EXPERIMENTAL, NOT LOADED BY DEFAULT.

Idu is not annotation laid over a Literary Chinese text; it is Korean written
with hanja, in Korean word order, using graphs as phonetic grammatical morphemes
— 是白 (이삷), 爲白 (하삷), 爲去乃 (하거나), 乙良 (을랑), 是如 (이다), 叱分 (뿐).
There is no Literary Chinese skeleton underneath to strip back to, so a document
in idu genuinely is not Literary Chinese and this is a legitimate vernacular
signal in principle.

It is off because every graph involved is an ordinary Literary word — 是 'this',
白 'to state', 爲 'do', 乙 'second stem', 良 'good', 如 'like', 叱 'scold',
分 'divide' — and only the sequences are idu. A false positive marks genuine
朝鮮漢文 down for being Korean, which is the failure this scorer exists to avoid,
and these have never been tested against 朝鮮漢文.

    --rulesets pulleyblank_core_v4,vernacular_v1,idu_experimental

Look at what it fires on before trusting a weight here.
"""
from __future__ import annotations

import re

from ..schema import Rule

RULES = [
    Rule(
        "idu.verbal_endings", "idu", "vn", 2,
        re.compile(r"(?P<anchor>爲白|是白|爲去乃|爲乎|是乎|爲良|是良|爲旀|是旀)"),
        4.0,
        "n/a — outside Pulleyblank's scope",
        "Idu verbal endings written with hanja as phonograms (하삷, 이삷, 하거나, "
        "하온, 이온). Korean morphology, not Literary Chinese syntax.",
    ),
    Rule(
        "idu.case_particles", "idu", "vn", 2,
        re.compile(r"(?P<anchor>乙良|叱分|是如|矣身|段置|亦中|果亦)"),
        4.0,
        "n/a — outside Pulleyblank's scope",
        "Idu case and focus particles (을랑, 뿐, 이다, 의몸, 딴두, 아해, 과여).",
    ),
    Rule(
        "idu.honorific_frames", "idu", "vn", 3,
        re.compile(r"(?P<anchor>敎是|進賜|白等|白去乎)"),
        2.5,
        "n/a — outside Pulleyblank's scope",
        "Idu honorific and petition formulae. Tier 3: 敎是 in particular occurs "
        "in ordinary Literary Chinese contexts too.",
    ),
]
