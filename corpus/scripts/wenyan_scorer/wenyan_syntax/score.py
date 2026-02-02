"""
Scoring engine integrating:
- rule-based construction hits
- distributional profiles (classifier + pronouns)

Default scalar score is conservative; treat it as a baseline.
"""
from __future__ import annotations
from typing import Any, Dict, List, Literal, Optional

from .segment import segment_text, SegmentMode
from .rules import load_ruleset, run_rule, load_weights_override, apply_weight_overrides
from .utils import count_han, per_1000
from .distributional import classifier_profile, pronoun_profile

Label = Literal["literary_syntax", "modern_syntax", "uncertain"]

def _label_from_score(score: float, *, hi: float = 2.0, lo: float = -2.0) -> Label:
    if score >= hi:
        return "literary_syntax"
    if score <= lo:
        return "modern_syntax"
    return "uncertain"

def _dist_score(clf: Dict[str, int], pro: Dict[str, int], han: int) -> float:
    if han <= 0:
        return 0.0

    ge_rate = per_1000(clf.get("clf_ge_frame", 0), han)
    num_x_n_rate = per_1000(clf.get("clf_num_x_n", 0), han)
    ge2_omit_rate = per_1000(clf.get("clf_ge2_n_deconf", 0), han)

    wo_subj = per_1000(pro.get("pro_wo_subj_start", 0), han)
    wo_obj = per_1000(pro.get("pro_wo_obj_after_verb", 0), han)
    lc_1p = per_1000(pro.get("pro_lc_1p_alt", 0), han)
    md_2p = per_1000(pro.get("pro_md_2p", 0), han)

    score = 0.0

    # Modern pushes
    score += (-1.8) * ge_rate
    score += (-0.6) * num_x_n_rate
    score += (-1.2) * wo_subj
    score += (-1.0) * md_2p

    # Literary pushes (weak to medium)
    if ge2_omit_rate > (num_x_n_rate * 1.2):
        score += (0.9) * ge2_omit_rate
    score += (0.6) * wo_obj
    score += (0.8) * lc_1p

    return score

def score_segments(
    segments: List[str],
    *,
    ruleset: str = "pulleyblank_core_v3",
    weights_override_json: Optional[str] = None,
    keep_evidence: bool = True,
) -> Dict[str, Any]:
    rules = load_ruleset(ruleset)
    if weights_override_json:
        rules = apply_weight_overrides(rules, load_weights_override(weights_override_json))

    seg_results: List[Dict[str, Any]] = []
    for idx, seg in enumerate(segments):
        han = count_han(seg)

        family_counts: Dict[str, int] = {}
        role_counts: Dict[str, int] = {}
        hits = []
        rule_score = 0.0

        for r in rules:
            cnt, ev = run_rule(r, seg, keep_evidence=keep_evidence)
            if cnt <= 0:
                continue
            contrib = cnt * r.weight
            rule_score += contrib
            family_counts[r.family] = family_counts.get(r.family, 0) + cnt
            role_counts[r.role] = role_counts.get(r.role, 0) + cnt
            hits.append({
                "rule_id": r.rule_id,
                "family": r.family,
                "role": r.role,
                "count": cnt,
                "weight": r.weight,
                "contribution": contrib,
                "evidence": ev,
                "notes": r.notes,
            })
        # Oracle-bone score: sum of contributions of oracle-bone family hits
        oracle_score = 0.0
        for h in hits:
            if h["family"] == "oracle_bone":
                oracle_score += h["contribution"]
        oracle_flag = oracle_score >= 8.0

        clf = classifier_profile(seg)
        pro = pronoun_profile(seg)
        dist_score = _dist_score(clf, pro, han)

        role_rates = {k: per_1000(v, han) for k, v in role_counts.items()}
        family_rates = {k: per_1000(v, han) for k, v in family_counts.items()}

        length_factor = min(1.0, han / 200.0) if han > 0 else 0.0
        default_score = (rule_score + dist_score) * length_factor

        seg_results.append({
            "segment_index": idx,
            "han_chars": han,
            "rule_score": rule_score,
            "dist_score": dist_score,
            "default_score": default_score,
            "label": _label_from_score(default_score),
            "family_rates_per_1000": family_rates,
            "role_rates_per_1000": role_rates,
            "oracle": {"oracle_score": oracle_score, "oracle_flag": oracle_flag},
            "distributional": {"classifier": clf, "pronoun": pro},
            "hits": sorted(hits, key=lambda h: abs(h["contribution"]), reverse=True),
            "text": seg,
        })

    if seg_results:
        scores = [s["default_score"] for s in seg_results]
        median = sorted(scores)[len(scores)//2]
        proportions = {"literary_syntax": 0, "modern_syntax": 0, "uncertain": 0}
        for s in seg_results:
            proportions[s["label"]] += 1
        for k in proportions:
            proportions[k] /= float(len(seg_results))
    else:
        median = 0.0
        proportions = {"literary_syntax": 0.0, "modern_syntax": 0.0, "uncertain": 0.0}

    rule_totals: Dict[str, float] = {}
    for s in seg_results:
        for h in s["hits"]:
            rule_totals[h["rule_id"]] = rule_totals.get(h["rule_id"], 0.0) + h["contribution"]
    top_rules = sorted(rule_totals.items(), key=lambda kv: abs(kv[1]), reverse=True)[:20]

    return {
        "segments": seg_results,
        "summary": {
            "segment_count": len(seg_results),
            "median_default_score": median,
            "proportions": proportions,
            "top_rules_by_abs_contribution": [{"rule_id": rid, "contribution": c} for rid, c in top_rules],
        },
        "meta": {"ruleset": ruleset, "weights_override_json": weights_override_json},
    }

def score_text(
    text: str,
    *,
    segment: SegmentMode = "paragraph",
    ruleset: str = "pulleyblank_core_v3",
    weights_override_json: Optional[str] = None,
    keep_evidence: bool = True,
    treat_punct_as_boundaries: bool = True,
    window_size_han: int = 300,
    window_stride_han: int = 200,
) -> Dict[str, Any]:
    segments = segment_text(
        text,
        mode=segment,
        treat_punct_as_boundaries=treat_punct_as_boundaries,
        window_size_han=window_size_han,
        window_stride_han=window_stride_han,
    )
    res = score_segments(
        segments,
        ruleset=ruleset,
        weights_override_json=weights_override_json,
        keep_evidence=keep_evidence,
    )
    res["meta"].update({
        "segment_mode": segment,
        "treat_punct_as_boundaries": treat_punct_as_boundaries,
        "window_size_han": window_size_han,
        "window_stride_han": window_stride_han,
    })
    return res
