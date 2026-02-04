"""
Pulleyblank-aligned core constructions ruleset (v3).

v3 additions:
- richer coverb frames (自/由/從, 以 causal, 為 explanatory, 於/于 locative)
- 云 quoting frames

Notes:
- Frames first. Avoid single-character "magic word" logic.
"""
from __future__ import annotations
import re
from ..rules import Rule

_HAN = r"[\u4e00-\u9fff]"

def guard_de_linker(text: str, m: re.Match) -> bool:
    return not m.group(0).startswith("的")

def guard_yun(text: str, m: re.Match) -> bool:
    return True

RULES = [
    Rule("lc.zhi.negslot_resumptive", "topicalization_exposure", "lc.zhi_negslot",
         re.compile(rf"(未|莫|勿|無|毋)之{_HAN}"), 4.0,
         "Neg + 之 + V (resumptive object placement after negatives)."),

    Rule("lc.zhi.yu_locative", "topicalization_exposure", "lc.zhi_yu_locative",
         re.compile(rf"{_HAN}{{1,12}}之於{_HAN}{{1,12}}"), 2.5,
         "X之於Y locative/topic phrase (nominalized locative)."),

    Rule("lc.suo.nominal", "nominalization", "lc.suo_nominal",
         re.compile(rf"所{_HAN}"), 2.5,
         "所+V nominalization."),

    Rule("lc.ze.exposure", "topicalization_exposure", "lc.ze_exposure",
         re.compile(rf"{_HAN}{{1,20}}則{_HAN}"), 1.8,
         "Exposed NP + 則 + predicate."),

    Rule("lc.sfp.classical", "particles_sentence_type", "lc.sfp_classical",
         re.compile(r"(也|矣|焉|乎|哉|耶|耳)(?=[\u4e00-\u9fff]*[。！？；\s]|$)"),
         1.1, "Classical sentence-type particles (density signal)."),

    # Interrogative 乎 (treat as classical question particle, not oracle-specific)
    Rule("lc.q.hu_interrogative", "particles_sentence_type", "lc.q_hu",
         re.compile(r"(何|奚|安|曷|焉|豈|岂|孰|誰|谁)[\u4e00-\u9fff]{0,20}乎(?=[\u4e00-\u9fff]*[。！？；\s]|$)"),
         3.0, "Question word + ... + 乎 (classical interrogative framing)."),

    # Interrogative ending 不 / 無 (yes-no / alternative question marker in classical registers)
    Rule("lc.q.end_bu_wu", "particles_sentence_type", "lc.q_end_bu_wu",
         re.compile(r"(不|無)\s*(?=[\u4e00-\u9fff]*[。！？；\s]|$)"),
         1.8, "Clause-final 不/無 as an interrogative/alternative marker (classical registers)."),

    # Coverb frames
    Rule("lc.coverb.source_chain", "coverbs", "lc.coverb_source",
         re.compile(rf"(自|由|從){_HAN}{{1,18}}(至於|於|于|而|則|故|可|得|知|見|聞)"),
         2.0,
         "Source/grounds coverbs 自/由/從 with chaining anchors."),

    Rule("lc.coverb.yi_causal", "coverbs", "lc.yi_causal",
         re.compile(rf"以{_HAN}{{2,80}}(故|也)"), 2.0,
         "以 + ... + 故/也 (causal packaging)."),

    Rule("lc.coverb.wei_explain", "coverbs", "lc.wei_explain",
         re.compile(rf"為{_HAN}{{1,24}}(故|也|者)"), 1.2,
         "為 + NP + 故/也/者 (explanatory packaging)."),

    Rule("lc.coverb.yu_locative", "coverbs", "lc.yu_coverb",
         re.compile(rf"(於|于){_HAN}{{1,24}}{_HAN}"), 1.0,
         "Locative 於/于 introducing an NP (broad)."),

    Rule("lc.quote.yun", "discourse", "lc.yun_quote",
         re.compile(r"(云曰|云云|云言|云：)"), 1.6,
         "云 quoting/reporting frames.", guard=guard_yun),

    
    # Oracle-bone divination frames (very high precision)
    # Pattern: (Heavenly Stem + Earthly Branch) + 卜 + X  (often followed by 貞 in divination text)
    Rule("ob.ganzhi_bu", "oracle_bone", "ob.ganzhi_bu",
         re.compile(r"(甲|乙|丙|丁|戊|己|庚|辛|壬|癸)(子|丑|寅|卯|辰|巳|午|未|申|酉|戌|亥)\s*卜[\u4e00-\u9fff]"),
         8.0, "干支日 + 卜 + X divination frame."),
    Rule("ob.zhen_presence", "oracle_bone", "ob.zhen",
         re.compile(r"貞"), 1.8, "貞 occurs (divination register co-signal)."),

    Rule("ob.ganzhi_bu_zhen", "oracle_bone", "ob.ganzhi_bu_zhen",
         re.compile(r"(甲|乙|丙|丁|戊|己|庚|辛|壬|癸)(子|丑|寅|卯|辰|巳|午|未|申|酉|戌|亥)\s*卜[^\n]{0,40}貞"),
         10.0, "干支日 + 卜 ... 貞 (very high-precision divination frame)."),

    Rule("ob.zhen_ganzhi_no_bu", "oracle_bone", "ob.zhen_ganzhi_no_bu",
         re.compile(r"貞[^\n]{0,50}(甲|乙|丙|丁|戊|己|庚|辛|壬|癸)(子|丑|寅|卯|辰|巳|午|未|申|酉|戌|亥)"),
         6.5, "貞 ... 干支 (oracle divination register, sometimes 卜 omitted)."),

    # 告 / 小告 counters in oracle inscriptions (e.g., 二告, 小告)
    Rule("ob.gao_counter", "oracle_bone", "ob.gao_counter",
         re.compile(r"((一|二|三|四|五|六|七|八|九|十)\s*告|小告)"),
         2.8, "告 counters (二告 / 小告) in oracle divination register."),


    # Ten-and-X numeral pattern: 十有二-style (early arithmetic wording)
    Rule("lc.number.ten_you", "numerals", "lc.ten_you",
         re.compile(r"(十|百|千)有(一|二|三|四|五|六|七|八|九)"),
         2.2, "Place-value numerals with 有 (e.g., 十有二)."),

    # 曰 introducing quotations (classical reporting verb)
    Rule("lc.quote.yue", "discourse", "lc.yue_quote",
         re.compile(r"(曰[:：]|曰「|曰『|曰\()"),
         2.5, "曰 introducing direct speech/quotation."),

    # 允 as adverbial 'indeed/really' in early texts, common in oracle bone style (low weight)
    Rule("lc.adverb.yun", "discourse", "lc.yun_adverb",
         re.compile(r"允[\u4e00-\u9fff]"),
         1.2, "允 in adverbial position (low weight; often oracle/early)."),

    # Modern negative signals
    Rule("md.aspect.suffix", "aspect_modern", "md.aspect_suffix",
         re.compile(r"(了|著|着|過|过)(?=[\u4e00-\u9fff，。！？；\s]|$)"), -3.5,
         "Suffixal aspect markers."),

    Rule("md.sfp.modern", "particles_sentence_type", "md.sfp_modern",
         re.compile(r"(嗎|吗|呢|吧|啊|呀|嘛)(?=[。！？；\s]|$)"), -3.0,
         "Modern sentence-final particles."),

    Rule("md.np.de_linker", "noun_phrase", "md.de_linker",
         re.compile(rf"{_HAN}{{1,12}}的{_HAN}{{1,12}}"), -3.0,
         "X的Y linker frames.", guard=guard_de_linker),

    Rule("md.link.paired", "complex_sentences", "md.hypotaxis_paired",
         re.compile(r"(如果.{0,60}就|因為.{0,80}所以|雖然.{0,80}但是)"), -3.2,
         "Paired hypotaxis templates."),

    Rule("md.ge.frame", "noun_phrase", "md.ge_frame",
         re.compile(r"[一二三四五六七八九十百千兩两〇零](個|个)[\u4e00-\u9fff]"), -2.8,
         "NUM+個/个+N general-classifier frames."),
]
