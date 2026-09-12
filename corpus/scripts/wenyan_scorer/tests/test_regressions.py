"""
Regression tests — one per defect found in an earlier version, plus behaviour tests.

Run:  python -m pytest tests/ -v
  or: python tests/test_regressions.py     (no pytest needed)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from wenyan_scorer import score_text, strip_reading_apparatus  # noqa: E402
from wenyan_scorer.annotation import KANBUN_MARKS  # noqa: E402
from wenyan_scorer.rules import load_rulesets, run_rule  # noqa: E402
from wenyan_scorer.schema import validate_ruleset  # noqa: E402
from wenyan_scorer.utils import HAN, count_han, iter_by_anchor  # noqa: E402

MENCIUS = ("孟子見梁惠王。王曰：叟不遠千里而來，亦將有以利吾國乎？"
           "孟子對曰：王何必曰利？亦有仁義而已矣。")
LUNYU = ("子曰：學而時習之，不亦說乎？有朋自遠方來，不亦樂乎？"
         "人不知而不慍，不亦君子乎？")
MODERN = ("我今天早上去了一個很大的商店，買了三個蘋果和一些東西。"
          "因為天氣很好，所以我覺得非常開心。你知道嗎？他們都在那裡等著呢。")
# Meiji kanbun, from 心理新説序 (1880s) — modern subject matter, Literary syntax.
MEIJI = ("電線也、火船也、自鳴鐘也、我邦人唯其物之奇、而不知究其所由來。"
         "豈不淺見之甚耶。夫電線・火船與自鳴鐘、無一不本于科學。"
         "然而科學原出于哲學。而心理學實爲哲學之根基矣。")

_FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        _FAILURES.append(name)


# ---------------------------------------------------------------- defect 1
def test_no_count_inflation_from_context_width():
    """an earlier version's overlapping scan advanced one character per match, so a rule with
    variable-width left context fired once per starting position. A single 則 in
    a ten-character sentence produced six hits."""
    pat = re.compile(rf"{HAN}{{1,12}}(?P<anchor>則){HAN}")
    text = "德不孤必有鄰則善矣"
    assert text.count("則") == 1
    n = len(iter_by_anchor(pat, text))
    check("count is not inflated by left-context width", n == 1, f"got {n}, want 1")

    rules = {r.rule_id: r for r in load_rulesets()}
    cnt, _, _ = run_rule(rules["lc.exposure.ze"], text)
    check("lc.exposure.ze counts one 則 once", cnt == 1, f"got {cnt}")


# ---------------------------------------------------------------- defect 2
def test_score_is_length_invariant():
    """an earlier version returned a raw sum, so the same passage scored 0.11 as sentences and
    164.51 as one paragraph against fixed +/-2.0 thresholds."""
    one = score_text(MENCIUS, segment="whole", min_han=10)
    twenty = score_text(MENCIUS * 20, segment="whole", min_han=10)
    a = one["summary"]["lc_rate_mean"]
    b = twenty["summary"]["lc_rate_mean"]
    check("20x the text gives the same rate", abs(a - b) < 0.5, f"{a} vs {b}")
    check("label is stable under repetition",
          one["summary"]["document_label"] == twenty["summary"]["document_label"],
          f'{one["summary"]["document_label"]} vs {twenty["summary"]["document_label"]}')

    para = score_text(MENCIUS, segment="paragraph", min_han=10)
    sent = score_text(MENCIUS, segment="sentence_run", min_han=10)
    check("segmentation mode does not flip the document label",
          para["summary"]["document_label"] == sent["summary"]["document_label"],
          f'{para["summary"]["document_label"]} vs {sent["summary"]["document_label"]}')


# ---------------------------------------------------------------- defect 3
def test_han_range_covers_extensions():
    """an earlier version used [\\u4e00-\\u9fff], excluding Extension A and the supplementary
    planes where oracle-bone, bronze and CJK-variant graphs live."""
    check("Ext A (U+3400) counts as Han", count_han("㐀") == 1)
    check("Ext B (U+20000) counts as Han", count_han("\U00020000") == 1)
    check("compatibility ideograph counts as Han", count_han("豈") == 1)
    check("kokuji 畑 counts as Han", count_han("畑") == 1)
    check("kana does not count as Han", count_han("ひらがな") == 0)


# ---------------------------------------------------------------- defect 4
def test_punctuation_dependent_rules_are_reported_not_silent():
    """an earlier version's particle rules required punctuation and silently returned zero on
    unpunctuated text — exactly the corpora `--segment window` exists for."""
    punct = score_text(LUNYU, segment="whole", min_han=10)
    plain = score_text(re.sub(r"[，。？！、：]", "", LUNYU), segment="whole", min_han=10)
    skipped = plain["segments"][0]["skipped_rules"]
    check("unpunctuated text reports skipped rules", len(skipped) > 0,
          f"skipped={skipped}")
    check("punctuated text skips nothing",
          len(punct["segments"][0]["skipped_rules"]) == 0)
    check("both are still labelled literary",
          punct["summary"]["document_label"] == "literary"
          and plain["summary"]["document_label"] == "literary",
          f'{punct["summary"]["document_label"]} / {plain["summary"]["document_label"]}')


# ---------------------------------------------------------------- defect 5
def test_axes_are_independent():
    """Absence of literary evidence must not read as vernacular evidence."""
    bland = "山高水長。日出月落。風起雲飛。花開草生。鳥鳴魚游。天地悠悠。" * 4
    r = score_text(bland, segment="whole", min_han=10)
    s = r["summary"]
    check("featureless Han text is not called vernacular",
          s["document_label"] != "not_literary",
          f'label={s["document_label"]} vn={s["vn_rate_mean"]}')
    check("featureless Han text has zero vernacular evidence",
          s["vn_rate_mean"] == 0.0, f'vn={s["vn_rate_mean"]}')


# ---------------------------------------------------------------- behaviour
def test_separates_literary_from_modern():
    lit = score_text(MENCIUS + LUNYU, segment="whole", min_han=10)["summary"]
    mod = score_text(MODERN, segment="whole", min_han=10)["summary"]
    check("classical Chinese labelled literary",
          lit["document_label"] == "literary", lit["why"])
    check("modern Mandarin labelled not_literary",
          mod["document_label"] == "not_literary", mod["why"])
    check("modern has essentially no literary evidence",
          mod["lc_rate_mean"] < lit["lc_rate_mean"] / 3,
          f'{mod["lc_rate_mean"]} vs {lit["lc_rate_mean"]}')


def test_meiji_kanbun_is_literary():
    """The case Llinos corrected me on: Meiji-era 漢文 about steamships and
    Descartes is Literary Chinese and must score as such."""
    r = score_text(MEIJI, segment="whole", min_han=10)["summary"]
    check("Meiji kanbun labelled literary", r["document_label"] == "literary", r["why"])
    check("Meiji kanbun has no vernacular evidence", r["vn_rate_mean"] == 0.0,
          f'vn={r["vn_rate_mean"]}')


def test_reading_apparatus_stripped_not_scored():
    lc = "學而時習之不亦說乎"
    annotated = "學㆓而時習㆒之、不亦説ばしからずや乎"
    s = strip_reading_apparatus(annotated)
    check("kana removed", not re.search(r"[぀-ヿ]", s.text), s.text)
    check("kanbun return marks removed",
          not re.search(f"[{KANBUN_MARKS}]", s.text), s.text)
    check("Han survives stripping", count_han(s.text) >= count_han(lc) - 1,
          f"{count_han(s.text)} vs {count_han(lc)}")
    check("apparatus ratio reported", s.kana_ratio > 0, f"{s.kana_ratio}")


def test_apparatus_limit_is_off_by_default():
    """Llinos's correction: her corpus is curated 漢文 and the gate must not
    second-guess it."""
    r = score_text(MEIJI, segment="whole", min_han=10)
    check("no segment refused by default",
          all(s["label"] != "apparatus_dominant" for s in r["segments"]))
    r2 = score_text(MEIJI, segment="whole", min_han=10, apparatus_limit=0.0001)
    check("gate does engage when explicitly asked for",
          any(s["label"] == "apparatus_dominant" for s in r2["segments"])
          or r["segments"][0]["apparatus"]["kana_ratio"] == 0.0)


def test_vernacular_graphs_in_literary_use_do_not_fire():
    """Every vernacular morpheme is written with a graph that has an ordinary
    Literary Chinese life. Matching the bare graph would mark Literary Chinese
    down for using Literary Chinese words."""
    cases = [
        ("都 as capital city", "王建都於洛邑，都城甚大，京都繁盛。"),
        ("在 as main verb",   "王在靈囿，麀鹿攸伏。"),
        ("過 as pass/exceed", "過宋而見孟子，其大不過于握拳。"),
        ("得 as obtain",      "求則得之，舍則失之，不得而見之矣。"),
        ("被 as suffer",      "被褐懷玉，身被堅執銳。"),
        ("著 as compose",     "著書立說，其志可著也。"),
    ]
    for label, text in cases:
        r = score_text(text, segment="whole", min_han=5)["summary"]
        check(f"{label} produces no vernacular evidence",
              r["vn_rate_mean"] == 0.0,
              f'vn={r["vn_rate_mean"]} :: {text}')


def test_ruleset_is_well_formed():
    rules = load_rulesets()
    problems = validate_ruleset(rules)
    check("ruleset validates", not problems, "; ".join(problems[:5]))
    check("every rule cites a source", all(r.cite for r in rules))
    check("both polarities present",
          {r.polarity for r in rules} == {"lc", "vn"})
    ids = [r.rule_id for r in rules]
    check("rule ids unique", len(ids) == len(set(ids)))
    print(f"        ({len(rules)} rules: "
          f"{sum(1 for r in rules if r.polarity == 'lc')} lc, "
          f"{sum(1 for r in rules if r.polarity == 'vn')} vn)")


def test_every_pattern_compiles_and_terminates():
    """A rule whose pattern is accidentally catastrophic would hang the scorer on
    a long text rather than fail loudly."""
    import time
    rules = load_rulesets()
    text = (MENCIUS + LUNYU + MODERN + MEIJI) * 6
    slow = []
    for r in rules:
        t0 = time.time()
        run_rule(r, text, keep_evidence=False)
        dt = time.time() - t0
        if dt > 0.5:
            slow.append((r.rule_id, round(dt, 3)))
    check("no rule is pathologically slow", not slow, str(slow))


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        print(f"\n{t.__name__}")
        t()
    print("\n" + "=" * 60)
    if _FAILURES:
        print(f"{len(_FAILURES)} FAILED: {', '.join(_FAILURES)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
