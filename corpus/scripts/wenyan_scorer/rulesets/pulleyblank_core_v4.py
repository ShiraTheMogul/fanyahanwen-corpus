"""
Literary Chinese constructions, after Pulleyblank.

Pulleyblank, E. G. (2000). *Outline of Classical Chinese Grammar* (Repr).
Vancouver: UBC Press. Every `cite` below is a section and page in that volume.

Scope note
----------
These are the constructions of the *core inherited grammar* — what every 漢文
tradition writes on top of, whether the author was in Luoyang, Kyoto, Hanseong,
Thang Long, Shuri, Malacca, or writing 維基大典 last week. Nothing here requires
a text to look Warring States, and nothing here requires it to be Chinese. A
rule that fired only on pre-Qin Chinese usage would be measuring period, not
register, and would mark 日本漢文 or 越南漢文 down for not being the Mencius.

Polarity and tier
-----------------
Every rule here is polarity 'lc': it is positive evidence, never negative. The
absence of these constructions is not evidence of anything — short texts,
parataxis-heavy verse and plain narrative all lack most of them. Only the
vernacular ruleset can push a text away from Literary Chinese.

  tier 1  structurally unavailable in the vernacular. Object preposing under
          negation, 唯…是…, 何…之有, the fusions. If one of these fires and the
          match is real, the text is Literary Chinese.
  tier 2  strong, but reachable by a literary-flavoured modern writer.
  tier 3  density only. Counts of common particles. Individually worthless.

Reading the regexes
-------------------
`HAN` is one Han character across every CJK block (see utils.HAN_BODY), not the
Basic-Multilingual-Plane-only range v3 used.

`(?P<anchor>X)` marks the diagnostic element. Hits are counted once per distinct
anchor position, so a rule may carry variable-width left context without being
counted once per possible starting offset.
"""
from __future__ import annotations

import re

from ..schema import Rule
from ..utils import HAN, HAN_BODY

H = HAN

# Frequent character sets, named so the patterns read as grammar not soup.
NEG_P = "不弗非否叵"              # p/f-series negatives, XI.1
NEG_M = "毋無无勿亡罔莫未微靡蔑末"  # m/w-series negatives, XI.2
NEG_ALL = NEG_P + NEG_M
PRO_OBJ = "之我吾余予己爾汝女朕"   # pronouns that prepose under negation, IX.1e
SFP = "也矣焉乎哉耳耶邪與歟"        # sentence-final particles
INTERROG = "何奚胡曷盍安焉惡烏誰孰疇"  # interrogative pronouns, IX.3
COVERB = "於于乎以與為自由從及至比逮迨當"

RULES = [

    # ------------------------------------------------------------------
    # VIII. Topicalization and Exposure  — the highest-precision family.
    # ------------------------------------------------------------------

    Rule(
        "lc.prepose.neg_pronoun_object", "exposure", "lc", 1,
        re.compile(rf"(?P<anchor>[{NEG_ALL}])[{PRO_OBJ}]{H}"),
        7.0,
        "II.3c.ii p.14; VIII.1 p.69; IX.1e p.84",
        "Negative + pronoun object + verb (未之有也, 莫之能禦, 不我知, 不吾遠). "
        "Pulleyblank: 'when a verb is negated, unstressed personal pronouns are "
        "placed between the negative particle and the verb.' The vernacular has "
        "no such rule — it puts the object after the verb — so this word order "
        "cannot be produced by accident.",
    ),

    Rule(
        "lc.prepose.shi_zhi_resumption", "exposure", "lc", 1,
        re.compile(rf"{H}{{1,8}}(?P<anchor>[是之])(?=[{NEG_ALL}]?{H})"
                   rf"(?![{SFP}])"),
        2.0,
        "VIII.1 p.70",
        "Preposed object recapitulated by 之 or 是 placed IN FRONT of the verb "
        "(戎狄是膺, 寡人之從君而西也). Low weight because the pattern alone is "
        "weak; the high-precision version is lc.prepose.wei_shi below.",
    ),

    Rule(
        "lc.prepose.wei_shi", "exposure", "lc", 1,
        re.compile(rf"(?P<anchor>[唯惟維]){H}{{1,10}}[是之]{H}"),
        9.0,
        "VIII.1 p.71; XIII.2a p.131",
        "唯/惟/維 + X + 是/之 + V (唯利是求, 唯仁之為守). Restrictive exposure with "
        "resumptive preposing. Nothing in any vernacular register produces this.",
    ),

    Rule(
        "lc.prepose.zhi_wei_ye", "exposure", "lc", 1,
        re.compile(rf"{H}{{1,10}}(?P<anchor>之謂)(也|矣)?"),
        8.0,
        "VIII.1 p.71",
        "X 之謂 也 (夫子之謂也, 非此之謂也). Pulleyblank calls this the stereotyped "
        "survival of preposed-object recapitulation into later Literary Chinese, "
        "which makes it a good marker for post-classical 漢文 specifically.",
    ),

    Rule(
        "lc.exposure.ruofu", "exposure", "lc", 1,
        re.compile(r"(?P<anchor>若夫|乃若)"),
        6.0,
        "VIII.5e p.75",
        "若夫 / 乃若 'but as for…' introducing a contrasted topic.",
    ),

    Rule(
        "lc.exposure.fu_topic", "exposure", "lc", 2,
        re.compile(rf"(?:^|[。；！？\n])\s*(?P<anchor>夫){H}"),
        3.0,
        "VIII.5d p.74",
        "Clause-initial 夫 as the topic-announcing particle (夫明堂者…). Anchored "
        "to clause start so the noun 夫 'man, husband' does not match.",
    ),

    Rule(
        "lc.exposure.ze", "exposure", "lc", 2,
        re.compile(rf"{H}{{1,12}}(?P<anchor>則){H}"),
        1.8,
        "VIII.3 p.72; XV.2c.i p.154",
        "Exposed NP + 則 (士則茲不悅) and the 則 of apodosis. Counted once per 則 "
        "by anchor — in v3 this rule fired once per starting offset and a single "
        "則 could contribute twenty hits.",
    ),

    Rule(
        "lc.exposure.zhi_yu", "exposure", "lc", 1,
        re.compile(rf"{H}{{1,10}}(?P<anchor>之於|之于){H}"),
        6.0,
        "V.6b.vii p.56; VIII.4 p.73",
        "X 之於 Y — a coverbal phrase given its own subject and nominalised by "
        "inserting 之 (寡人之於國也, 君子之於禽獸也). English cannot nominalise a "
        "preposition and neither can the vernacular.",
    ),

    Rule(
        "lc.exposure.shi_gu_shi_yi", "exposure", "lc", 1,
        re.compile(r"(?P<anchor>是故|是以|於是乎|是用)"),
        5.0,
        "IX.2a p.86; XV.5b p.162",
        "是故 / 是以 / 於是乎 — sentence connectives whose word order comes from "
        "preposing the object of 故/以 (Pulleyblank: 是以 'because of that', in "
        "contrast to 以是).",
    ),

    # ------------------------------------------------------------------
    # VII. Nominalization
    # ------------------------------------------------------------------

    Rule(
        "lc.nom.suo_coverb", "nominalization", "lc", 1,
        re.compile(r"(?P<anchor>所以|所與|所為|所由|所自|所從)"),
        5.5,
        "VII.2d p.68; V.6a.i p.50",
        "所 + coverb (所以 'that by which', 所與 'those with whom'). Pulleyblank is "
        "explicit that 所以 'must always be given its full value… it does not have "
        "the meaning therefore which it has acquired in the modern language', so "
        "this is the pattern, not the modern conjunction.",
    ),

    Rule(
        "lc.nom.suo_verb", "nominalization", "lc", 2,
        re.compile(rf"(?P<anchor>所)(?![以與為由自從謂])[{HAN_BODY}]"),
        3.0,
        "VII.2d p.68",
        "所 + V nominalising the object (所殺, 所有, 所知). Excludes the coverb "
        "compounds handled above and 所謂, which survives into modern usage.",
    ),

    Rule(
        "lc.nom.wei_suo_passive", "nominalization", "lc", 1,
        re.compile(rf"(?P<anchor>為){H}{{0,10}}所{H}"),
        7.5,
        "IV.9b p.37",
        "為 (N) 所 V passive (為三軍所獲, 終為之所擒矣). Pulleyblank dates the 所 "
        "form to about the beginning of the Han and it stays productive through "
        "all later Literary Chinese, which makes it valuable for post-classical "
        "and non-Chinese 漢文.",
    ),

    Rule(
        "lc.nom.zhe_ye", "nominalization", "lc", 2,
        re.compile(rf"(?P<anchor>者){H}{{0,24}}也"),
        3.2,
        "III.1 p.15; VII.2c p.66",
        "者 … 也 — relative-clause subject with 者 as head, closed by the noun-"
        "predication particle 也 (畏天者也, 仁者無敵). The canonical verbless "
        "predication frame.",
    ),

    Rule(
        "lc.nom.zhe", "nominalization", "lc", 2,
        re.compile(rf"{H}(?P<anchor>者)(?![{HAN_BODY}]?$)"),
        1.6,
        "VII.2c p.66",
        "者 as pronominal substitute for the head of a noun phrase (耕者, 殺人者). "
        "Tier 2 rather than 1 because 者 survives in modern 記者/作者 compounds.",
    ),

    Rule(
        "lc.nom.you_zhe", "nominalization", "lc", 1,
        re.compile(rf"(?P<anchor>有){H}{{1,20}}者"),
        4.0,
        "IV.7 p.31; XIII.3a p.135",
        "有 … 者 — existential with a 者-headed relative clause as pseudo-subject "
        "(宋人有閔其苗之不長而揠之者). Pulleyblank: 'since this construction has no "
        "parallel in the modern language, the pseudo-subject is often "
        "misinterpreted as a locative phrase.'",
    ),

    Rule(
        "lc.nom.zhi_subject_verb", "nominalization", "lc", 1,
        re.compile(rf"{H}(?P<anchor>之)(?=[{NEG_ALL}]?[{HAN_BODY}](?:也|矣|者))"),
        4.5,
        "VII.2b p.64",
        "之 inserted between subject and verb to nominalise a clause "
        "(王之不王, 古之為關也, 民之歸仁也). Pulleyblank notes this was 'already "
        "becoming obsolescent by the Han period' and is 'quite foreign to Modern "
        "Chinese' — the strongest single marker of the nominalising 之.",
    ),

    Rule(
        "lc.nom.qi_nominal", "nominalization", "lc", 2,
        re.compile(rf"(?P<anchor>其)[{NEG_ALL}]?{H}(?=也|矣|乎)"),
        3.0,
        "VII.2b p.64; IX.1c.iii p.80",
        "其 + V as substitute for N + 之 in a nominalised clause (其知道乎, "
        "比其反也).",
    ),

    # ------------------------------------------------------------------
    # III. Noun predication
    # ------------------------------------------------------------------

    Rule(
        "lc.pred.fei_ye", "noun_predication", "lc", 1,
        re.compile(rf"(?P<anchor>非){H}{{1,16}}也"),
        6.0,
        "III.1 p.15; XI.1d p.106",
        "非 X 也 — the special negative of noun predication. Pulleyblank gives the "
        "formula A (非) B 也 directly. The vernacular negates a nominal with 不是.",
        repair="Modern 不是 X → Literary 非 X 也.",
    ),

    Rule(
        "lc.pred.fei_bare", "noun_predication", "lc", 2,
        re.compile(rf"(?P<anchor>非)(?![常凡)]){H}"),
        2.2,
        "XI.1d p.106",
        "非 negating a noun or nominalised phrase. Excludes 非常 and 非凡, which "
        "are ordinary modern adjectives.",
    ),

    Rule(
        "lc.pred.ye_final", "noun_predication", "lc", 3,
        re.compile(rf"(?P<anchor>也)(?=[，。；、！？\s]|$)"),
        1.0,
        "III.1 p.15; XII.2b p.118",
        "Clause-final 也. Density signal only: the structurally diagnostic uses "
        "are caught by the 者…也, 非…也 and 之…也 frames above. Needs punctuation.",
        requires_punctuation=True,
    ),

    Rule(
        "lc.pred.ye_yi_yi", "noun_predication", "lc", 1,
        re.compile(r"(?P<anchor>也已矣|也已|也矣)"),
        6.5,
        "III.1e p.19; XII.2c p.118",
        "也已 / 也已矣 — the aspect particle 已 after a verbless noun predicate, "
        "and its enlarged forms. Pulleyblank treats 也已 as a phonetic fusion.",
    ),

    Rule(
        "lc.pred.ye_hu_fusions", "noun_predication", "lc", 1,
        re.compile(r"(?P<anchor>也乎|也與|也歟|也邪|也耶)"),
        7.0,
        "I.4d p.9; III.1a p.16; XIV.2a.ii p.139",
        "也乎 and its fusions 與/歟/邪/耶 turning a noun predicate into a question. "
        "Pulleyblank: 與 predominates in the Lu texts (Lunyu, Mencius), 邪 in other "
        "Warring States texts — but all of them stay productive in later 漢文.",
    ),

    Rule(
        "lc.pred.wei_copula", "noun_predication", "lc", 2,
        re.compile(rf"(?P<anchor>為){H}{{1,10}}(?=也|矣|乎|$)"),
        2.0,
        "III.2 p.20",
        "為 as copula 'to be' with a subjective complement (孟子為卿於齊).",
    ),

    Rule(
        "lc.pred.yue_naming", "noun_predication", "lc", 2,
        re.compile(rf"(?P<anchor>[曰謂])之?{H}{{1,4}}(?=[。，；\s]|$)"),
        1.4,
        "III.3 p.21; IV.8f p.33",
        "曰 / 謂 as copula of naming, 'is called' (老而無妻曰鰥, 命之曰同).",
        requires_punctuation=True,
    ),

    # ------------------------------------------------------------------
    # IV-V. Verbal predicates, passives, coverbs
    # ------------------------------------------------------------------

    Rule(
        "lc.pass.jian_yu", "passive", "lc", 1,
        re.compile(rf"(?P<anchor>見){H}{{1,10}}[於于]{H}"),
        7.0,
        "IV.9a p.36",
        "見 V 於 N — passive marked by 見 with the agent introduced by 於 "
        "(吾長見笑於大方之家).",
    ),

    Rule(
        "lc.pass.jian_verb", "passive", "lc", 2,
        re.compile(rf"(?P<anchor>見)(?=[殺伐辱疑笑欺害虜擒執囚廢逐放誅戮背保用知遇])"),
        4.0,
        "IV.9a p.35",
        "見 + transitive V as passive marker (盆成括見殺, 百姓之不見保). Restricted "
        "to a closed list of verbs that actually attest this, because 見 + V is "
        "otherwise just 'see' plus a verb.",
    ),

    Rule(
        "lc.coverb.yu_locative", "coverbs", "lc", 2,
        re.compile(rf"{H}(?P<anchor>[於于]){H}"),
        1.5,
        "V.6b.ii p.53; V.6b.iv p.54",
        "於/于 introducing a locative complement after the main verb "
        "(王立於沼上, 移其民於河東). 於 is the single most characteristic coverb of "
        "Literary Chinese; the vernacular uses preverbal 在/到/從.",
        repair="Modern preverbal 在/到 + place + V → Literary V + 於 + place.",
    ),

    Rule(
        "lc.coverb.yu_comparative", "coverbs", "lc", 1,
        re.compile(rf"(?P<anchor>[多少大小高下長短貴賤強弱善美惡難易遠近先後重輕])[於于]{H}"),
        5.0,
        "IV.2 p.24; V.6b.iv p.55",
        "Adjective + 於 — comparative degree (民之多於鄰國也, 天下莫強焉). The "
        "vernacular uses 比 before the verb.",
        repair="Modern A 比 B ADJ → Literary A ADJ 於 B.",
    ),

    Rule(
        "lc.coverb.yan_fusion", "coverbs", "lc", 1,
        re.compile(rf"{H}(?P<anchor>焉)(?=[，。；、！？\s]|$)"),
        5.0,
        "I.4e p.9; V.6b.vi p.56; IX.1c.v p.80",
        "Postverbal 焉 as the fusion of 於 + 之 'in it, to it, than it' "
        "(於我心有戚戚焉, 天下莫強焉). Pulleyblank: 焉 'can have all the possible "
        "meanings of 於 + 之'.",
        requires_punctuation=True,
    ),

    Rule(
        "lc.coverb.yi_wei", "coverbs", "lc", 1,
        re.compile(rf"(?P<anchor>以){H}{{0,12}}為{H}"),
        4.5,
        "V.6a.i p.49",
        "以 X 為 Y — 'take X to be Y, regard X as Y' (百姓皆以王為愛也). "
        "Pulleyblank stresses that in the classical language the two words 'must "
        "still be construed separately', unlike the modern compound 以為.",
    ),

    Rule(
        "lc.coverb.you_wu_yi", "coverbs", "lc", 1,
        re.compile(r"(?P<anchor>有以|無以|无以|有所以|無所以)"),
        6.0,
        "V.6a.i p.49",
        "有以 / 無以 'have (not have) that whereby' (亦將有以利吾國乎). Pulleyblank "
        "treats the missing 所 as a regular omission, which makes the bare form "
        "diagnostic.",
    ),

    Rule(
        "lc.coverb.yi_instrumental", "coverbs", "lc", 2,
        re.compile(rf"(?P<anchor>以){H}{{1,8}}(?=[，。；]|{H})"),
        0.9,
        "V.6a.i p.47",
        "以 as instrumental/causal coverb (殺人以梃, 以五十步笑百步). Low weight: 以 "
        "is frequent and also survives in modern written registers.",
    ),

    Rule(
        "lc.coverb.source_chain", "coverbs", "lc", 2,
        re.compile(rf"(?P<anchor>[自由從]){H}{{1,12}}(?:至於|至于|而|則|來|往|出|入)"),
        2.5,
        "V.6a.v p.52",
        "自 / 由 / 從 'from' in spatial, temporal or logical sense, with a "
        "chaining anchor (自楚之滕, 由湯至於武丁, 自生民以來).",
    ),

    Rule(
        "lc.coverb.ji_when", "coverbs", "lc", 2,
        re.compile(rf"(?P<anchor>[及比逮迨當]){H}{{1,12}}(?:之時|也|矣)"),
        4.0,
        "V.6d p.57; XV.4c p.158; XV.4d p.160",
        "及 / 比 / 逮 / 迨 / 當 introducing a temporal clause, closed by 也 or 之時 "
        "(及其使人也, 比其反也, 當堯之時). The 之時 form is what the vernacular "
        "writes as …的時候.",
        repair="Modern …的時候 → Literary 當…之時 or 及…也.",
    ),

    Rule(
        "lc.verb.pivot_causative", "compound_predicate", "lc", 2,
        re.compile(rf"(?P<anchor>[使令遣]){H}{{1,6}}{H}"),
        1.8,
        "V.3 p.40",
        "Pivot construction with 使 / 令 'cause, order' (王使人來曰, 是使民養生喪死). "
        "Also the 'supposing' use, XV.2b.ii p.151.",
    ),

    Rule(
        "lc.verb.de_er", "compound_predicate", "lc", 1,
        re.compile(r"(?P<anchor>得而|不得而|可得而|弗得而)"),
        5.5,
        "V.5b p.46",
        "得 (而) V — 'get to, manage to' in a serial-verb rather than clause-object "
        "construction (君不得而臣, 民不可得而治也).",
    ),

    Rule(
        "lc.verb.ke_wei", "compound_predicate", "lc", 1,
        re.compile(r"(?P<anchor>可謂)"),
        5.0,
        "V.4a p.43",
        "可謂 X 矣 'may be called X' (可謂孝矣, 何如斯可謂之士矣).",
    ),

    Rule(
        "lc.verb.er_serial", "compound_predicate", "lc", 3,
        re.compile(rf"{H}(?P<anchor>而)(?![已後今])[{HAN_BODY}]"),
        0.8,
        "V.5a p.44",
        "而 linking verbs in series. Density signal: 而 is ubiquitous in Literary "
        "Chinese and essentially absent from the spoken vernacular, but it is "
        "also the easiest particle for a modern writer to sprinkle in.",
    ),

    Rule(
        "lc.verb.er_hou", "compound_predicate", "lc", 2,
        re.compile(r"(?P<anchor>而後|然後|而后|然后)"),
        2.6,
        "XV.4f p.161",
        "而後 / 然後 'afterwards' introducing the second or main clause.",
    ),

    Rule(
        "lc.verb.er_yi", "restriction", "lc", 1,
        re.compile(r"(?P<anchor>而已矣|而已|耳矣)"),
        6.5,
        "I.4d p.9; XIII.2d p.134",
        "而已 'then stop' = 'only', and its contraction 耳. Pulleyblank derives 耳 "
        "from 而已 directly (亦有仁義而已矣).",
    ),

    # ------------------------------------------------------------------
    # IX. Pronouns and interrogatives
    # ------------------------------------------------------------------

    Rule(
        "lc.pro.first_person_lc", "pronouns", "lc", 2,
        re.compile(rf"(?P<anchor>[吾余予朕台卬])(?=[{HAN_BODY}])"),
        3.0,
        "IX.1a p.76",
        "吾 / 余 / 予 / 朕 / 台 / 卬 — the Literary first person series. 我 is "
        "deliberately absent: it is shared with the vernacular and counting it "
        "would penalise nothing and reward noise.",
    ),

    Rule(
        "lc.pro.second_person_lc", "pronouns", "lc", 2,
        re.compile(rf"(?P<anchor>[汝女爾若乃戎])(?=[{HAN_BODY}])"
                   rf"(?<![幾如假])"),
        1.6,
        "IX.1b p.77",
        "汝 / 女 / 爾 / 若 / 乃 second person. Low weight and necessarily noisy, "
        "since every one of these graphs writes a homophonous non-pronoun "
        "(若 'like', 乃 'then', 爾 'thus') — Pulleyblank discusses exactly this "
        "overlap.",
    ),

    Rule(
        "lc.pro.qi_possessive", "pronouns", "lc", 2,
        re.compile(rf"(?P<anchor>其)[{HAN_BODY}]"),
        1.2,
        "IX.1c.iii p.80; VII.1b p.62",
        "其 as substitute for N + 之, possessive or nominalising (其妻, 其來). "
        "Density-ish: common, but genuinely rare in the spoken vernacular, which "
        "uses 他的.",
        repair="Modern 他的/她的/它的 + N → Literary 其 + N.",
    ),

    Rule(
        "lc.pro.zhi_object", "pronouns", "lc", 2,
        re.compile(rf"{H}(?P<anchor>之)(?=[，。；、！？\s]|$)"),
        2.4,
        "IX.1c.i p.79",
        "之 as object pronoun in postverbal position (殺之, 命之). Anchored to a "
        "following boundary so the subordinating 之 of N之N is not counted here.",
        requires_punctuation=True,
    ),

    Rule(
        "lc.pro.zhu_fusion", "pronouns", "lc", 1,
        re.compile(rf"(?P<anchor>諸)(?=[，。；！？\s]|$)|(?P<a2>有諸|之諸)"),
        6.0,
        "I.4d p.9; XIV.2a.iii p.140",
        "諸 as the fusion 之 + 乎 in clause-final position (有諸 'is it so?'), and "
        "as 之 + 於 (加諸彼). Clause-final 諸 is unambiguous; 諸侯-type 諸 'all, the "
        "class of' is excluded by the boundary requirement.",
        requires_punctuation=True,
    ),

    Rule(
        "lc.pro.reflexive_ji_zi", "pronouns", "lc", 2,
        re.compile(rf"(?P<anchor>[己自相])(?=[{HAN_BODY}])"),
        1.3,
        "IX.1d p.83; XIII.4a p.136; XIII.4b p.136",
        "己 reflexive pronoun, 自 reflexive pronominal adverb, 相 reciprocal "
        "(正己而後發, 王自殺, 獸相食). Pulleyblank distinguishes 自 (always "
        "immediately preverbal) from 己 (any position).",
    ),

    Rule(
        "lc.q.interrog_object_prepose", "interrogatives", "lc", 1,
        re.compile(rf"(?P<anchor>[{INTERROG}])(?=[{HAN_BODY}])(?![{SFP}如若許多時])"),
        4.0,
        "II.3c.i p.14; IX.3 p.91",
        "Interrogative pronoun preceding its verb (吾誰欺, 何愛一牛, 沛然誰能禦之). "
        "Pulleyblank: 'interrogative pronoun objects precede the verb' — a rule "
        "of the classical language throughout, and gone from the vernacular.",
    ),

    Rule(
        "lc.q.he_yi_wei", "interrogatives", "lc", 1,
        re.compile(r"(?P<anchor>何以|何為|何故|奚以|胡為|曷為|何由|惡乎|烏乎)"),
        5.5,
        "IX.3b p.93; IX.3c p.96",
        "何以 / 何為 / 何故 / 惡乎 — interrogative preposed as object of a coverb. "
        "惡乎 is Pulleyblank's 'wū hū', equivalent to 於何.",
    ),

    Rule(
        "lc.q.rare_interrogatives", "interrogatives", "lc", 1,
        re.compile(r"(?P<anchor>[奚胡曷盍疇])"),
        6.0,
        "IX.3b p.95; XI.1f p.107",
        "奚 / 胡 / 曷 / 盍 / 疇. Pulleyblank treats 盍 as the contraction of 何不 and "
        "曷, 疇 as preclassical. These graphs have essentially no other life in "
        "written Chinese, so a hit is close to decisive.",
    ),

    Rule(
        "lc.q.shu_yu", "interrogatives", "lc", 1,
        re.compile(r"(?P<anchor>孰與|孰若|與其)"),
        6.5,
        "IX.3a.ii p.93; XII.4e p.125",
        "孰與 / 孰若 comparison, and 與其 … 寧/不如 preference (禮與其奢也寧儉).",
    ),

    Rule(
        "lc.q.he_zhi_you", "interrogatives", "lc", 1,
        re.compile(rf"(?P<anchor>何){H}{{1,6}}之有"),
        9.0,
        "VIII.1 p.70; IX.3b p.94",
        "何 X 之有 — interrogative with the object preposed and recapitulated by 之 "
        "(何遲之有, 何陋之有). One of the sharpest tests in the language.",
    ),

    Rule(
        "lc.q.ru_zhi_he", "interrogatives", "lc", 1,
        re.compile(r"(?P<anchor>如之何|若之何|如何|若何|奈何|奈之何)"),
        5.0,
        "IV.8g p.34; IX.3b p.94",
        "如之何 / 若之何 / 奈何 — the double-object idiom with 何 as second object. "
        "Pulleyblank derives 奈 from a fusion of 若之.",
    ),

    # ------------------------------------------------------------------
    # XI. Negation
    # ------------------------------------------------------------------

    Rule(
        "lc.neg.rare_graphs", "negation", "lc", 1,
        re.compile(r"(?P<anchor>[弗叵罔靡蔑毋])"),
        6.0,
        "XI.1c p.104; XI.1e p.106; XI.2d p.109; XI.2h p.110; XI.2i p.110; XI.2a p.107",
        "弗 / 叵 / 罔 / 靡 / 蔑 / 毋. Pulleyblank analyses 弗 as bù + 之 and 叵 as a "
        "contraction of 不可. None of these graphs is available to a vernacular "
        "writer, so a hit is near-decisive.",
    ),

    Rule(
        "lc.neg.wu_prohibitive", "negation", "lc", 2,
        re.compile(rf"(?P<anchor>[勿毋])(?=[{HAN_BODY}])"),
        4.5,
        "XI.2a p.107; XI.2b p.108",
        "勿 / 毋 prohibitive 'do not' (勿毀之矣, 王無罪歲). Pulleyblank notes 勿 may "
        "incorporate the object pronoun, parallel to 弗.",
        repair="Modern 別 / 不要 + V → Literary 勿 + V or 毋 + V.",
    ),

    Rule(
        "lc.neg.mo_indefinite", "negation", "lc", 1,
        re.compile(rf"(?P<anchor>莫)(?=[{HAN_BODY}])(?!名其妙)"),
        5.0,
        "XI.2e p.109; XIII.3b p.136",
        "莫 'no one, nothing, none' defining the scope of the subject "
        "(民莫之死也, 天下莫強焉). Excludes the modern set phrase 莫名其妙.",
    ),

    Rule(
        "lc.neg.mo_ruo", "negation", "lc", 1,
        re.compile(r"(?P<anchor>莫若|莫如|不若|不如)(?=[^\s])"),
        3.5,
        "XIII.3b p.136",
        "莫若 / 莫如 'nothing is better than' = 'it is best to'; 不若 / 不如 "
        "comparative.",
    ),

    Rule(
        "lc.neg.wei_not_yet", "negation", "lc", 2,
        re.compile(rf"(?P<anchor>未)(?![來知免])[{HAN_BODY}]"),
        3.0,
        "XI.2f p.109; XII.1b p.114",
        "未 'not yet' — the aspectual negative opposed to 既. Excludes 未來 and the "
        "modern-ish 未知/未免.",
        repair="Modern 還沒(有) + V → Literary 未 + V.",
    ),

    Rule(
        "lc.neg.wei_chang", "negation", "lc", 1,
        re.compile(r"(?P<anchor>未嘗|未始|未曾)"),
        6.0,
        "XII.3b p.119; XII.3g p.121",
        "未嘗 / 未始 'never yet'. Pulleyblank: 嘗 with 矣 in the affirmative, "
        "未嘗 … 也 in the negative.",
    ),

    Rule(
        "lc.neg.wei_if_not", "negation", "lc", 1,
        re.compile(rf"(?P<anchor>微)(?=[{HAN_BODY}])(?![笑小妙弱薄型生物]"
                   rf"|服|信)"),
        3.0,
        "XI.2g p.110; XV.2b.vii p.154",
        "微 as the m-negative of nouns, 'if it were not for' (微管仲, 吾其被髮左衽矣). "
        "Excludes the common modern compounds of 微 'small'.",
    ),

    # ------------------------------------------------------------------
    # XII. Aspect, time, mood
    # ------------------------------------------------------------------

    Rule(
        "lc.asp.ji_preverbal", "aspect", "lc", 2,
        re.compile(rf"(?P<anchor>既)(?![然而])[{HAN_BODY}]"),
        4.0,
        "XII.1a p.113",
        "既 as preverbal perfective 'already, having done' (既得之矣, 文王既沒). "
        "Modern Chinese has 已經 and the suffix 了; 既 survives only in 既然/既而, "
        "which are excluded here and handled separately.",
        repair="Modern V + 了 (完成) → Literary 既 + V … 矣.",
    ),

    Rule(
        "lc.asp.yi_final", "aspect", "lc", 1,
        re.compile(rf"(?P<anchor>矣)"),
        4.0,
        "XII.2a p.116",
        "矣 — sentential perfect. Pulleyblank argues at length that 矣 is "
        "aspectual and corresponds to modern sentence-final 了. It has no life at "
        "all outside Literary Chinese, so no boundary test is needed: the graph "
        "itself is the evidence.",
        repair="Modern sentence-final 了 → Literary 矣.",
    ),

    Rule(
        "lc.asp.chang_ceng", "aspect", "lc", 2,
        re.compile(rf"(?P<anchor>[嘗甞])(?=[{HAN_BODY}])(?![試嘗])"),
        3.5,
        "XII.3b p.119",
        "嘗 as preverbal past-tense particle 'once' (吾嘗聞大勇於夫子矣).",
    ),

    Rule(
        "lc.mood.qi_hu", "modality", "lc", 1,
        re.compile(rf"(?P<anchor>其){H}{{1,12}}乎"),
        6.0,
        "XII.4a p.123; XIV.2b.ii p.142",
        "其 … 乎 — the modal 其 of rhetorical questions expecting agreement "
        "(其無後乎, 其知道乎). Pulleyblank: 'like is it not … in English.'",
    ),

    Rule(
        "lc.mood.gai_shu", "modality", "lc", 2,
        re.compile(r"(?P<anchor>蓋|庶幾|殆|寧|無寧|毋寧)"),
        3.5,
        "XII.4b p.124; XII.4c p.124; XII.4e p.125",
        "蓋 introductory particle, 庶幾 'almost, one hopes', 殆 'maybe', "
        "寧/無寧 'rather'.",
    ),

    # ------------------------------------------------------------------
    # XIII. Inclusion and restriction
    # ------------------------------------------------------------------

    Rule(
        "lc.incl.jie_ju", "inclusion", "lc", 2,
        re.compile(rf"(?P<anchor>[皆舉俱咸悉畢並竝])(?=[{HAN_BODY}])"),
        3.2,
        "XIII.1c p.127; XIII.1d p.129; XIII.1g p.131",
        "皆 / 舉 / 俱 / 咸 / 悉 / 畢 / 並 'all, together'. Pulleyblank explicitly "
        "contrasts 皆 with modern 都, and notes 都 'was not usual in Literary "
        "Chinese' — so 都 is on the vernacular side and these are here.",
        repair="Modern 都 → Literary 皆.",
    ),

    Rule(
        "lc.incl.fan_ge_mei", "inclusion", "lc", 2,
        re.compile(rf"(?P<anchor>[凡各每]|諸侯|諸君)(?=[{HAN_BODY}]|$)"),
        2.2,
        "XIII.1a p.126; XIII.1b p.127; XIII.1e p.130; XIII.1f p.130",
        "凡 'all' introducing an exposed NP, 各 'each', 每 'every, whenever', "
        "諸 'members of the class of'.",
    ),

    Rule(
        "lc.restr.wei_only", "restriction", "lc", 2,
        re.compile(rf"(?P<anchor>[唯惟維])(?=[{HAN_BODY}])(?!一|独|獨有)"),
        3.5,
        "XIII.2a p.131",
        "唯 / 惟 / 維 'only'. The preclassical copula surviving as a restrictive "
        "particle (唯利之求, 惟義所在).",
    ),

    Rule(
        "lc.restr.du_tu", "restriction", "lc", 2,
        re.compile(rf"(?P<anchor>獨|非獨|不唯|非唯|徒|特|直|但)(?=[{HAN_BODY}])"),
        1.8,
        "XIII.2b p.133; XIII.2c p.133",
        "獨 / 徒 / 特 / 直 / 但 'only', and the 非獨 / 不唯 'not only' frames.",
    ),

    Rule(
        "lc.some.huo", "inclusion", "lc", 2,
        re.compile(rf"(?P<anchor>或)(?=[{HAN_BODY}])(?![者許])"),
        2.6,
        "XIII.3a p.134",
        "或 'some one, some' defining the subject as one out of a set "
        "(或百步而後止). Pulleyblank relates it to 有. Excludes 或者 and 或許.",
    ),

    # ------------------------------------------------------------------
    # XIV. Sentence types
    # ------------------------------------------------------------------

    Rule(
        "lc.q.bu_yi_hu", "interrogatives", "lc", 1,
        re.compile(rf"(?P<anchor>不亦){H}{{1,6}}乎"),
        9.0,
        "XIV.2b.i p.141",
        "不亦 … 乎 — the standard rhetorical question with an adjective "
        "(不亦樂乎, 不亦宜乎). Pulleyblank: 'a common construction found in all "
        "texts of the classical period.'",
    ),

    Rule(
        "lc.q.qi", "interrogatives", "lc", 1,
        re.compile(rf"(?P<anchor>[豈岂])(?=[{HAN_BODY}])"),
        6.0,
        "XIV.2b.iii p.142",
        "豈 introducing a rhetorical question expecting a negative answer "
        "(豈能獨樂哉). Pulleyblank glosses it with modern 難道 — which is "
        "therefore a vernacular rule, not this one.",
        repair="Modern 難道 … 嗎 → Literary 豈 … 哉/乎.",
    ),

    Rule(
        "lc.q.yong_ju", "interrogatives", "lc", 1,
        re.compile(r"(?P<anchor>庸詎|庸遽|詎|渠能|巨能)"),
        6.5,
        "XIV.2b.iv p.144",
        "庸 / 詎 / 巨 / 遽 / 渠 in rhetorical questions expecting a negative answer.",
    ),

    Rule(
        "lc.q.wu_nai_hu", "interrogatives", "lc", 1,
        re.compile(rf"(?P<anchor>無乃|毋乃|得無|得毋){H}{{0,10}}乎"),
        8.0,
        "XIV.2b.v p.144",
        "無乃 … 乎 / 得無 … 乎 'would it not be…?' (無乃不可乎). Pulleyblank explains "
        "the 亦/乃 as blocking the reading of 無 as 'not have'.",
    ),

    Rule(
        "lc.q.kuang", "interrogatives", "lc", 1,
        re.compile(rf"(?P<anchor>而況|何況|況){H}{{0,12}}乎"),
        6.0,
        "XIV.2b.viii p.146",
        "而況 … 乎 'how much the more/less' (而況不為管仲者乎).",
    ),

    Rule(
        "lc.excl.zai", "sentence_type", "lc", 1,
        re.compile(r"(?P<anchor>哉)"),
        5.5,
        "XIV.3a p.146",
        "哉 — exclamatory final particle (哀哉, 大哉言矣). Like 矣, the graph has no "
        "vernacular life, so no boundary test is required.",
    ),

    Rule(
        "lc.q.hu_final", "sentence_type", "lc", 2,
        re.compile(rf"(?P<anchor>乎)(?=[，。；、！？\s]|$)"),
        3.0,
        "XIV.2a.i p.139",
        "Clause-final 乎 turning a statement into a question (賢者亦樂此乎). "
        "Distinguished from the coverb 乎 (V.6b.iii p.54) by the boundary.",
        requires_punctuation=True,
    ),

    Rule(
        "lc.q.fou_alternative", "sentence_type", "lc", 1,
        re.compile(rf"{H}(?P<anchor>否)(?=[乎，。；、！？\s]|$)"),
        5.5,
        "XI.1b p.103; XIV.2a.iv p.140",
        "Clause-final 否 forming an alternative question or answering 'no' "
        "(動心否乎, 知可否).",
        requires_punctuation=True,
    ),

    Rule(
        "lc.imp.qing", "sentence_type", "lc", 2,
        re.compile(rf"(?P<anchor>請)(?=[{HAN_BODY}])(?![求問客柬帖])"),
        2.4,
        "XIV.1b p.138",
        "請 'I beg of you' turning an imperative into a request (王請度之, "
        "臣請為王言樂). Pulleyblank notes its own subject is first person.",
    ),

    # ------------------------------------------------------------------
    # XV. Complex sentences
    # ------------------------------------------------------------------

    Rule(
        "lc.cond.gou", "complex_sentence", "lc", 1,
        re.compile(rf"(?P<anchor>苟)(?=[{HAN_BODY}])"),
        6.0,
        "XV.2b.iii p.152",
        "苟 'if, if by chance' introducing a conditional (苟為善, 苟有其備).",
    ),

    Rule(
        "lc.cond.ruo_ru", "complex_sentence", "lc", 2,
        re.compile(rf"(?P<anchor>[若如])(?=[{HAN_BODY}])(?![干果此是何])"),
        1.2,
        "XV.2b.i p.150",
        "若 / 如 'if'. Deliberately weak: both graphs also write 'like', a second "
        "person pronoun and part of 如果, and Pulleyblank spends a page on the "
        "overlap. Excludes 如果 and 如此/若是, which are modern or formulaic.",
    ),

    Rule(
        "lc.cond.cheng_xin", "complex_sentence", "lc", 2,
        re.compile(rf"(?P<anchor>誠){H}{{1,8}}(?:也|則|矣)"),
        3.5,
        "XV.2b.iv p.153",
        "誠 'truly, really' grammaticalised as a conditional marker "
        "(誠如是也, 民歸之). Pulleyblank explicitly compares modern 如果 "
        "'if really' — so 如果 belongs to the vernacular ruleset.",
    ),

    Rule(
        "lc.conc.sui", "complex_sentence", "lc", 1,
        re.compile(rf"(?P<anchor>雖)(?!然[，。；]?$)(?=[{HAN_BODY}])"),
        5.0,
        "XV.3a p.156",
        "雖 'although, even if' standing alone before a clause (雖大國必畏之矣, "
        "雖不得魚無後災). Pulleyblank insists that in Classical Chinese 雖然 'must "
        "always be given its full value as a clause' — so bare 雖 is the "
        "Literary form and 雖然 as a bare conjunction is the modern one.",
        repair="Modern 雖然 … 但是 → Literary 雖 … 而 / 雖 … 猶.",
    ),

    Rule(
        "lc.conc.zong", "complex_sentence", "lc", 2,
        re.compile(rf"(?P<anchor>縱)(?=[{HAN_BODY}])(?![橫容])"),
        3.0,
        "XV.3d p.158",
        "縱 'even though' introducing a concessive (縱弗能死).",
    ),

    Rule(
        "lc.then.si_ji", "complex_sentence", "lc", 2,
        re.compile(rf"(?P<anchor>斯){H}"),
        3.0,
        "IX.2d p.88; XV.2c.ii p.155",
        "斯 'then' introducing an apodosis (觀過斯知仁矣), and 斯 'this' in the "
        "Lunyu and Tan Gong.",
    ),

    Rule(
        "lc.cause.gu", "complex_sentence", "lc", 3,
        re.compile(rf"(?P<anchor>故)(?=[{HAN_BODY}])(?![事鄉意障])"),
        1.2,
        "XV.5b p.162",
        "故 'therefore' as connective, and 以 … 之故 'because of'. Density only: "
        "故 survives in modern formal written Chinese.",
    ),

    Rule(
        "lc.time.xi_zhe", "complex_sentence", "lc", 2,
        re.compile(r"(?P<anchor>昔者|古者|今者|向者|曩者|初|是時)"),
        2.6,
        "XII.3a p.119; XII.3h p.122; XV.4e p.161",
        "Time expressions in topic position: 昔者 / 古者 'formerly, in ancient "
        "times', 初 'previously' opening a narrative flashback.",
    ),

    # ------------------------------------------------------------------
    # VI. Numerals
    # ------------------------------------------------------------------

    Rule(
        "lc.num.you_and", "numerals", "lc", 1,
        re.compile(r"(?P<anchor>[十百千萬万])有[一二三四五六七八九十餘余]"),
        6.5,
        "VI.4 p.60",
        "Place-value numeral with 有 'and' (十有二, 五百有餘歲). Pulleyblank gives "
        "this its own section; it is unavailable to the vernacular, which "
        "juxtaposes or uses 零/多.",
    ),

    Rule(
        "lc.num.jiang_approx", "numerals", "lc", 2,
        re.compile(r"(?P<anchor>將)[一二三四五六七八九十百千萬万]"),
        3.0,
        "VI.1 p.58",
        "將 with a numeral in the sense 'approximately' (將五十里也).",
    ),

    # ------------------------------------------------------------------
    # X. Adverbs
    # ------------------------------------------------------------------

    Rule(
        "lc.adv.ran_expressive", "adverbs", "lc", 2,
        re.compile(rf"{H}(?P<anchor>然)(?=[{HAN_BODY}])(?![而後则則后])"),
        2.4,
        "X.5 p.102; IX.1c.vi p.81",
        "然 as expressive-adverb suffix (卒然問, 油然作雲, 芒芒然歸), and 然 'it is so' "
        "as a complete predicate. Excludes 然而 / 然後.",
    ),

    Rule(
        "lc.adv.yi_also", "adverbs", "lc", 2,
        re.compile(rf"(?P<anchor>亦)(?=[{HAN_BODY}])"),
        2.8,
        "X p.99; III.1b p.18",
        "亦 'also' as a sentence adverb usable before verbless noun predicates. "
        "Modern Chinese uses 也 in this sense, which is why 也 is ambiguous and "
        "亦 is not.",
        repair="Modern 也 (= 'also') → Literary 亦.",
    ),

    # ------------------------------------------------------------------
    # Discourse
    # ------------------------------------------------------------------

    Rule(
        "lc.disc.yue_quote", "discourse", "lc", 2,
        re.compile(rf"(?P<anchor>曰)(?=[「『（(“]|{H})"),
        2.6,
        "III.3 p.21; IX.1c.vii p.82",
        "曰 introducing direct speech. Pulleyblank contrasts it aspectually with "
        "云: 曰 'say on a particular occasion', 云 'say without time reference'.",
    ),

    Rule(
        "lc.disc.yun", "discourse", "lc", 2,
        re.compile(r"(?P<anchor>云云|詩云|書云|云爾|傳云|經云|子云)"),
        4.5,
        "IX.1c.vii p.82",
        "云 introducing or closing a quotation from a book (詩云), and 云爾 "
        "'say thus'. Restricted to these frames because bare 云 is also the "
        "simplified graph for 雲 'cloud'.",
    ),
]
