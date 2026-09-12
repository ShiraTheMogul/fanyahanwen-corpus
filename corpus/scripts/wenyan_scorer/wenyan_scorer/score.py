"""
    lc_rate   weighted literary hits per 1000 Han   (>= 0)
    vn_rate   weighted vernacular hits per 1000 Han (>= 0)

    vn_rate >= vn_threshold AND vn share >= 30%  -> not_literary
    lc_rate >= lc_threshold                      -> literary
    a tier-1 construction, no vernacular share   -> literary
    otherwise                                    -> uncertain
"""
from __future__ import annotations

import math
from typing import Any, Dict, List, Optional, Sequence

from .annotation import strip_reading_apparatus
from .rules import DEFAULT_RULESETS, apply_weight_overrides, load_rulesets, load_weights_override, run_rule
from .schema import Rule
from .segment import SegmentMode, segment_text
from .utils import count_han, has_punctuation, per_1000, punctuation_density, strip_markup

Label = str  # "literary" | "not_literary" | "uncertain" | "too_short" | "apparatus_dominant"

# Thresholds set from measured rates, not guessed. Observed on a cross-tradition
# sample from my corpus against modern Mandarin and Qing baihua controls:
#
#   genuine 漢文      lc 204–665   vn 0.0–0.6   vernacular share 0.000–0.002
#   modern Mandarin   lc 125       vn 1529      vernacular share 0.92
#   Qing baihua       lc 136       vn 689       vernacular share 0.83
#
# The separation is in the SHARE. Modern Mandarin has a respectable literary rate
# (125) because 之, 者, 以, 其 and 而 all survive in written Mandarin; what it does
# not have is a low proportion of vernacular evidence. The absolute rates only
# guard against deciding on a handful of hits.
DEFAULT_LC_THRESHOLD = 60.0
DEFAULT_VN_THRESHOLD = 20.0
DEFAULT_VN_SHARE = 0.30
DEFAULT_MIN_HAN = 60

# A share computed from one or two hits is not a share. In the full-corpus scan,
# 363 of 7,648 rejections (4.7%) rested on two vernacular hits or fewer, and
# 373 were under 200 Han characters — e.g. 季主墓碑贊, 76 Han, rejected at a 45%
# "share" on a single 著. 
DEFAULT_MIN_VN_HITS = 3

# Fallback probability, used until a model is fitted. Driven by the literary
# SHARE of evidence plus a saturating term for how much evidence there is at
# all, so that a short text with one hit does not come out as certain. It is
# uncalibrated and says so in the output via `probability_source` — do not read
# it as a real posterior until `wenyan_scorer calibrate` has run.
_FALLBACK_SHARE_SLOPE = 10.0
_FALLBACK_VOLUME_SCALE = 150.0
_FALLBACK_VOLUME_CAP = 300.0


def _fallback_probability(lc_rate: float, vn_rate: float) -> float:
    total = lc_rate + vn_rate
    lc_share = (lc_rate / total) if total > 0 else 0.5
    z = (_FALLBACK_SHARE_SLOPE * (lc_share - 0.5)
         + min(lc_rate, _FALLBACK_VOLUME_CAP) / _FALLBACK_VOLUME_SCALE)
    return _sigmoid(z)


def _sigmoid(z: float) -> float:
    if z >= 0:
        return 1.0 / (1.0 + math.exp(-z))
    e = math.exp(z)
    return e / (1.0 + e)


def score_segment(
    raw_text: str,
    rules: Sequence[Rule],
    *,
    keep_evidence: bool = True,
    min_han: int = DEFAULT_MIN_HAN,
    lc_threshold: float = DEFAULT_LC_THRESHOLD,
    vn_threshold: float = DEFAULT_VN_THRESHOLD,
    apparatus_limit: Optional[float] = None,
    strip_apparatus: bool = True,
    model: Optional["LogisticModel"] = None,
) -> Dict[str, Any]:
    """Score one segment.

    `apparatus_limit` is None by default, which means the reading-apparatus
    ratio is measured and reported but never gates the decision. Set it to a
    float to refuse to score segments whose kana/hangul/Latin proportion exceeds
    it — worth doing on uncurated input, unnecessary on a curated 漢文 corpus.
    """
    cleaned = strip_markup(raw_text)
    strip = strip_reading_apparatus(cleaned) if strip_apparatus else None
    text = strip.text if strip else cleaned

    han = count_han(text)
    punctuated = has_punctuation(text)

    result: Dict[str, Any] = {
        "han_chars": han,
        "punctuated": punctuated,
        "punctuation_per_1000_han": round(punctuation_density(text), 2),
        "apparatus": {
            "kana_ratio": round(strip.kana_ratio, 4) if strip else 0.0,
            "hangul_ratio": round(strip.hangul_ratio, 4) if strip else 0.0,
            "latin_ratio": round(strip.latin_ratio, 4) if strip else 0.0,
            "removed": strip.removed_counts if strip else {},
        },
    }

    if apparatus_limit is not None and strip and strip.apparatus_ratio > apparatus_limit:
        result.update({
            "label": "apparatus_dominant",
            "lc_rate": 0.0, "vn_rate": 0.0, "probability_literary": None,
            "probability_source": "not_scored",
            "why": (
                f"apparatus ratio {strip.apparatus_ratio:.3f} exceeds limit "
                f"{apparatus_limit}: the removed script was carrying the grammar, "
                "so the Han skeleton is not a Literary Chinese text"
            ),
            "hits": [], "skipped_rules": [],
        })
        return result

    too_short = han < min_han

    lc_weighted = 0.0
    vn_weighted = 0.0
    hits: List[Dict[str, Any]] = []
    skipped: List[str] = []
    family_counts: Dict[str, int] = {}
    tier_counts: Dict[str, int] = {"lc_tier1": 0, "lc_tier2": 0, "lc_tier3": 0,
                                   "vn_tier1": 0, "vn_tier2": 0, "vn_tier3": 0}
    rule_counts: Dict[str, int] = {}

    for rule in rules:
        count, evidence, was_skipped = run_rule(
            rule, text, keep_evidence=keep_evidence, punctuated=punctuated
        )
        if was_skipped:
            skipped.append(rule.rule_id)
            continue
        if count <= 0:
            continue

        rule_counts[rule.rule_id] = count
        contribution = count * rule.weight
        if rule.polarity == "lc":
            lc_weighted += contribution
        else:
            vn_weighted += contribution

        family_counts[rule.family] = family_counts.get(rule.family, 0) + count
        tier_counts[f"{rule.polarity}_tier{rule.tier}"] += count

        hits.append({
            "rule_id": rule.rule_id,
            "family": rule.family,
            "polarity": rule.polarity,
            "tier": rule.tier,
            "count": count,
            "rate_per_1000_han": round(per_1000(count, han), 3),
            "weight": rule.weight,
            "weighted_rate": round(per_1000(contribution, han), 3),
            "cite": rule.cite,
            "repair": rule.repair,
            "evidence": evidence,
        })

    lc_rate = per_1000(lc_weighted, han)
    vn_rate = per_1000(vn_weighted, han)

    if model is not None:
        prob = model.predict_one(rule_counts, han)
        prob_source = f"calibrated:{model.name}"
    else:
        prob = _fallback_probability(lc_rate, vn_rate)
        prob_source = "uncalibrated_prior"

    if too_short:
        # Score it anyway and report the rates, but act like Putin, do not let them vote.
        #
        # A quarter of my corpus (73,816 of 303,966 documents) falls below the
        # 60-Han minimum — quatrains, inscriptions, colophons, single-line
        # entries. Returning zeros for those threw away real measurements and
        # made a large part of the corpus invisible in the report. The rates are
        # genuinely unreliable at this length (one 矣 in a 20-character poem is
        # 50 per 1000 Han), which is why the label still says so, but "unreliable"
        # is not "unknown" and you can now sort on them.
        label = "too_short"
        why = (f"{han} Han characters is below the {min_han} minimum, so the "
               f"rates below are reported but not trusted: lc {lc_rate:.1f}, "
               f"vn {vn_rate:.1f} per 1000 Han. A single particle in a quatrain "
               f"moves a rate by tens of points.")
    else:
        vn_hit_total = sum(v for k, v in tier_counts.items() if k.startswith("vn_"))
        label, why = _decide(lc_rate, vn_rate, tier_counts, lc_threshold,
                             vn_threshold, vn_hits=vn_hit_total)

    result.update({
        "lc_rate": round(lc_rate, 3),
        "vn_rate": round(vn_rate, 3),
        "label": label,
        "why": why,
        "probability_literary": round(prob, 4),
        "probability_source": prob_source,
        "tier_counts": tier_counts,
        "family_counts": family_counts,
        "skipped_rules": skipped,
        "hits": sorted(hits, key=lambda h: h["weighted_rate"], reverse=True),
    })
    return result


def _decide(lc_rate, vn_rate, tiers, lc_threshold, vn_threshold,
            vn_share_threshold: float = DEFAULT_VN_SHARE,
            vn_hits: Optional[int] = None,
            min_vn_hits: int = DEFAULT_MIN_VN_HITS):
    """The decision, stated so that the reason is always inspectable.

    The test is the SHARE of evidence that is vernacular, not either rate alone.
    Modern Mandarin scores a respectable literary rate — 之, 者, 以, 其, 而, 所
    and 於 are all alive in written modern Chinese — so an absolute literary
    threshold does not separate the classes. The proportion does, by two orders
    of magnitude.

    A few stray vernacular hits therefore cannot flip a text that is otherwise
    dense with literary constructions, which is the property that matters for a
    pan-Asian corpus: one transliterated name containing 的 must not turn a
    Meiji essay into modern Chinese.
    """
    total = lc_rate + vn_rate
    vn_share = (vn_rate / total) if total > 0 else 0.0

    if (vn_hits is not None and 0 < vn_hits < min_vn_hits
            and vn_rate >= vn_threshold and vn_share >= vn_share_threshold):
        return "uncertain", (
            f"vernacular share is {vn_share:.0%}, but it rests on only "
            f"{vn_hits} hit(s) — below the {min_vn_hits} needed to call it. "
            f"A share computed from one or two matches is not a share."
        )

    if vn_rate >= vn_threshold and vn_share >= vn_share_threshold:
        return "not_literary", (
            f"vernacular evidence {vn_rate:.1f}/1000 Han is {vn_share:.0%} of all "
            f"evidence found (threshold: {vn_rate:.1f} >= {vn_threshold} and "
            f"share >= {vn_share_threshold:.0%})"
        )
    if lc_rate >= lc_threshold:
        note = ""
        if vn_rate > 0:
            note = (f"; the {vn_rate:.1f} of vernacular evidence is only "
                    f"{vn_share:.1%} of the total and does not overturn it")
        return "literary", (
            f"literary evidence {lc_rate:.1f}/1000 Han meets the "
            f"{lc_threshold} threshold{note}"
        )
    if tiers.get("lc_tier1", 0) > 0 and vn_share < vn_share_threshold:
        return "literary", (
            f"{tiers['lc_tier1']} tier-1 construction(s) present — structurally "
            "unavailable in the vernacular — with no countervailing vernacular "
            "evidence"
        )
    return "uncertain", (
        f"literary evidence {lc_rate:.1f} below {lc_threshold}, vernacular "
        f"evidence {vn_rate:.1f} below {vn_threshold}: not enough of either kind "
        "to decide. This is not a vote for 'modern'."
    )


def score_text(
    text: str,
    *,
    segment: SegmentMode = "paragraph",
    rulesets: Sequence[str] = DEFAULT_RULESETS,
    weights_override_json: Optional[str] = None,
    keep_evidence: bool = True,
    window_size_han: int = 300,
    window_stride_han: int = 200,
    min_han: int = DEFAULT_MIN_HAN,
    lc_threshold: float = DEFAULT_LC_THRESHOLD,
    vn_threshold: float = DEFAULT_VN_THRESHOLD,
    apparatus_limit: Optional[float] = None,
    model: Optional["LogisticModel"] = None,
) -> Dict[str, Any]:
    rules = load_rulesets(rulesets)
    if weights_override_json:
        rules = apply_weight_overrides(rules, load_weights_override(weights_override_json))

    segments = segment_text(
        text, mode=segment,
        window_size_han=window_size_han,
        window_stride_han=window_stride_han,
    )

    seg_results = []
    for i, seg in enumerate(segments):
        r = score_segment(
            seg, rules,
            keep_evidence=keep_evidence, min_han=min_han,
            lc_threshold=lc_threshold, vn_threshold=vn_threshold,
            apparatus_limit=apparatus_limit, model=model,
        )
        r["segment_index"] = i
        r["text"] = seg
        seg_results.append(r)

    return {
        "segments": seg_results,
        "summary": _summarise(seg_results, lc_threshold, vn_threshold),
        "meta": {
            "rulesets": list(rulesets),
            "rule_count": len(rules),
            "segment_mode": segment,
            "lc_threshold": lc_threshold,
            "vn_threshold": vn_threshold,
            "min_han": min_han,
            "apparatus_limit": apparatus_limit,
            "weights_override_json": weights_override_json,
            "model": model.name if model else None,
        },
    }


def _summarise(seg_results: List[Dict[str, Any]], lc_threshold: float = DEFAULT_LC_THRESHOLD,
               vn_threshold: float = DEFAULT_VN_THRESHOLD) -> Dict[str, Any]:
    scored = [s for s in seg_results if s["label"] in ("literary", "not_literary", "uncertain")]
    if not scored:
        return {
            "segment_count": len(seg_results),
            "scored_segment_count": 0,
            "document_label": "too_short",
            "note": "no segment had enough Han characters to score",
        }

    total_han = sum(s["han_chars"] for s in scored)
    # Han-weighted means, so one long paragraph is not outvoted by several short
    # ones. Both means are over the same denominator, so they stay comparable.
    lc_mean = sum(s["lc_rate"] * s["han_chars"] for s in scored) / total_han
    vn_mean = sum(s["vn_rate"] * s["han_chars"] for s in scored) / total_han

    counts: Dict[str, int] = {}
    for s in seg_results:
        counts[s["label"]] = counts.get(s["label"], 0) + 1

    probs = [s["probability_literary"] for s in scored if s["probability_literary"] is not None]
    probs.sort()
    median_prob = probs[len(probs) // 2] if probs else None

    doc_label, why = _decide(
        lc_mean, vn_mean,
        {"lc_tier1": sum(s.get("tier_counts", {}).get("lc_tier1", 0) for s in scored)},
        lc_threshold, vn_threshold,
    )

    contrib: Dict[str, float] = {}
    for s in scored:
        for h in s["hits"]:
            contrib[h["rule_id"]] = contrib.get(h["rule_id"], 0.0) + h["weighted_rate"]

    return {
        "segment_count": len(seg_results),
        "scored_segment_count": len(scored),
        "han_chars": total_han,
        "lc_rate_mean": round(lc_mean, 3),
        "vn_rate_mean": round(vn_mean, 3),
        "document_label": doc_label,
        "why": why,
        "median_probability_literary": median_prob,
        "label_counts": counts,
        "top_rules": [
            {"rule_id": k, "weighted_rate": round(v, 3)}
            for k, v in sorted(contrib.items(), key=lambda kv: kv[1], reverse=True)[:20]
        ],
    }


# Imported late to avoid a circular import at module load.
from .calibrate import LogisticModel  # noqa: E402
