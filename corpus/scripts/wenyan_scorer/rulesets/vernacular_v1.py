"""
Vernacular Mandarin morphosyntax.
These are the only rules that can push a text AWAY from Literary Chinese.

Design constraint
-----------------
This ruleset exists so that "the text is not Literary Chinese" can be asserted
on positive evidence. It must never be satisfiable merely by a text failing to
use Pulleyblank's constructions, because the pan-Asian corpus is full of
perfectly good 漢文 that happens not to use them: short inscriptions, verse,
parataxis-heavy narrative, and the whole of the Japanese, Korean, Vietnamese,
Ryukyuan and other traditions writing in their own idiom.

So every rule here matches a grammar words that are working in Mandarin;
a structural particle, an aspect suffix, a classifier frame, a paired
conjunction. None of them matches "absence of 之" or "short sentences".

The graph-vs-morpheme trap
--------------------------
Almost every Mandarin grammatical morpheme is written with a graph that has a
perfectly good Literary Chinese life as a content word:

    都  Mandarin 'all'          ←→ Literary 都 'capital city' (都城, 建都)
    在  Mandarin preverbal loc. ←→ Literary 在 'to be at' (王在靈囿)
    了  Mandarin perfective     ←→ Literary 了 'to finish, understand'
    著  Mandarin durative       ←→ Literary 著 zhù 'manifest, compose'
    過  Mandarin experiential   ←→ Literary 過 'to pass, exceed' (過宋)
    得  Mandarin complement     ←→ Literary 得 'to get' (得而)
    把  Mandarin disposal       ←→ Literary 把 'to grasp'
    被  Mandarin passive        ←→ Literary 被 'to suffer, undergo'; and in
                                      Japanese 漢文 an honorific marker
    的  Mandarin linker         ←→ Literary 的 'target, bullseye'

Matching the bare graph would therefore mark Literary Chinese down for using
ordinary Literary Chinese words — exactly the failure this scorer exists to
avoid. Every rule below matches the morpheme in a *position* only
Mandarin puts it in, and several carry explicit exclusions.
"""
from __future__ import annotations

import re

from ..schema import Rule
from ..utils import HAN, HAN_BODY

H = HAN

#: Interpunct characters used to separate the syllables of a transliterated
#: foreign name. The corpus supplied 費希的・設林・歇傑爾 (Fichte, Schelling,
#: Hegel) and 往設因的, in both of which 的 is a phonogram inside a name, not a
#: structural particle. A 的 near an interpunct is almost always in that
#: environment, so the 的 rules refuse it.
_INTERPUNCT = "・·‧･・"


def _not_in_transliteration(text: str, m: "re.Match") -> bool:
    i = m.start("anchor")
    window = text[max(0, i - 6): i + 7]
    return not any(c in window for c in _INTERPUNCT)


RULES = [

    # ------------------------------------------------------------------
    # Structural particles — the core of the vernacular noun phrase.
    # ------------------------------------------------------------------

    Rule(
        "vn.np.de_linker", "noun_phrase", "vn", 1,
        re.compile(rf"{H}(?P<anchor>的)(?=[{HAN_BODY}])(?<!目的)(?<!的確)"),
        6.0,
        "n/a — corresponds to Literary 之, VII.1b p.61",
        "X 的 Y — the vernacular subordinating particle. Pulleyblank himself "
        "identifies 之 as 'etymologically the same word as modern de 的', which "
        "makes this the cleanest single opposition in the pair of rulesets. "
        "Excludes 目的 and 的確, where 的 is not a linker.",
        repair="Vernacular N1 的 N2 → Literary N1 之 N2 (and 之 is commonly "
               "omitted between monosyllables).",
        guard=_not_in_transliteration,
    ),

    Rule(
        "vn.np.de_nominalizer", "noun_phrase", "vn", 1,
        re.compile(rf"{H}(?P<anchor>的)(?=[，。！？；、\s]|$)"),
        6.0,
        "n/a — corresponds to Literary 者, VII.2c p.66",
        "Clause-final 的 nominalising what precedes (我買的, 他說的). The Literary "
        "equivalent is 者.",
        repair="Vernacular VP 的 → Literary VP 者.",
        guard=_not_in_transliteration,
        requires_punctuation=True,
    ),

    # vn.adv.de_adverbial (X 地 + V, the vernacular adverbial suffix) was here
    # and has been REMOVED. On the Fanyahanwen corpus it fired 12 times, every
    # one a false positive on 地 'land, place' as an ordinary Literary noun:
    # 此地磧礫甚鮮美, 其地瓦屋鱗比, 北極出地二十六度. Telling the suffix from the
    # noun needs to know that what precedes is a disyllabic state expression and
    # what follows is a verb, which is a parse, not a regex. A rule that cannot
    # reach acceptable precision on this axis does more harm than the recall it
    # buys, because a false vernacular hit flips a label and a false literary
    # hit only adds noise.

    Rule(
        "vn.cmpl.de_complement", "complement", "vn", 1,
        re.compile(rf"{H}(?P<anchor>得)(?=很|清楚|起來|起来|下去|要命|不得了)"),
        5.5,
        "n/a",
        "V 得 + complement (說得很好, 看得清楚) — the vernacular descriptive "
        "complement. The following-element list was narrowed after 不/多/少/好 "
        "produced false positives on Literary 得 'to get': 所得不足餬口, "
        "天命討罪罪人安得多… Pulleyblank treats that 得 at V.5b p.46.",
    ),

    # ------------------------------------------------------------------
    # Aspect — Pulleyblank XII.1 is explicit that Classical Chinese has no
    # verbal suffixes, only preverbal particles. Suffixal aspect is therefore
    # about as clean a vernacular signal as exists.
    # ------------------------------------------------------------------

    Rule(
        "vn.asp.le", "aspect", "vn", 1,
        re.compile(rf"(?<![既已畢訖悉盡終])(?<![明瞭])"
                   rf"{H}(?P<anchor>了)(?=[，。！？；、\s]|$|[一二三兩两幾几很好多])"),
        6.0,
        "n/a — corresponds to Literary 矣/既, XII.1a p.113, XII.2a p.116",
        "Perfective / change-of-state 了. Pulleyblank derives modern -le from the "
        "verb 了 'to finish' and pairs sentence-final 了 with Classical 矣 "
        "directly, so this is the counterpart of lc.asp.yi_final. The lookbehind "
        "excludes the Literary full verb 了 'finish', which the corpus supplied "
        "an example of: 既遶了、南向福良 'having already gone round it'.",
        repair="Vernacular V 了 → Literary 既 V … 矣, or bare V + 矣.",
    ),

    Rule(
        "vn.asp.zhe", "aspect", "vn", 1,
        # ONE anchor group. The verb restriction is a fixed-width lookbehind so
        # the anchor stays on 著 itself; an alternation with two differently
        # named groups would leave `anchor` unset on half the matches, and
        # `m.start("anchor")` returns -1 for a group that did not participate
        # rather than raising — so every such match would collapse onto the same
        # dedupe key and be counted once.
        re.compile(r"(?<=[看拿帶带穿坐站躺笑等說说想哭睡走跑聽听提舉举捧抱牽牵])"
                   r"(?P<anchor>[著着])(?=[，。！？；、\s]|$|[呢的一二三])"),
        4.5,
        "n/a",
        "Durative 著/着. Narrowed twice. The first version matched 著 before any "
        "boundary and fired in 40,338 documents, 89% of them still literary: "
        "自著, 所著, 理著, 幽誠所著 — all 著 zhù 'to be manifest, to compose', "
        "which is what Literary Chinese overwhelmingly uses this graph for. It "
        "now requires either a following 呢, or a preceding verb from a closed "
        "list that actually takes the durative (看著, 拿著, 笑著, 坐著). Lower "
        "recall, and the recall it loses was never real.",
    ),

    # vn.asp.guo (experiential 過 in suffix position) was here and has been
    # DELETED. The full-corpus scan fired it in 56,541 documents — 19% of the
    # corpus — 133,729 times, and 92% of those documents were still classified
    # literary. Sampling 402,000 characters of unambiguous Literary Chinese
    # (全唐文, 康熙朝實錄) found 33 hits and EVERY ONE was the noun 過 guò 'fault':
    #
    #     極言朕過、  自新改過、  足以補過、  拾遺補過、  豈得無過、
    #     前後愆過、  我略其舊過、 者吾之深過、 陳六事之過
    #
    # The rule keyed on 過 standing before a clause boundary, which is precisely
    # where Literary Chinese puts that noun. It was designed for 去過 / 見過 and
    # could not distinguish them. A version restricted to 過 + 嗎/呢/沒 would be
    # precise and would match almost nothing, and genuinely vernacular text is
    # caught many times over by 的, 了, 個 and 們 anyway. So it goes.

    Rule(
        "vn.asp.zhengzai", "aspect", "vn", 1,
        re.compile(r"(?P<anchor>正在|已經|已经|還沒|还没|沒有|没有)"),
        5.0,
        "n/a — corresponds to Literary 方/已/嘗/未, XII.3 p.119",
        "Disyllabic aspect adverbs: 正在, 已經, 曾經, 沒有. Pulleyblank gives 已經 as "
        "the modern reflex of preverbal 已 (XII.1c p.115) and 未 as the negative "
        "of 既 (XI.2f p.109) — so these are the vernacular halves of pairs whose "
        "Literary halves are in the other ruleset.",
        repair="已經 → 既 or 已; 沒有 V → 未 V; 正在 V → 方 V.",
    ),

    # ------------------------------------------------------------------
    # Sentence-final particles
    # ------------------------------------------------------------------

    Rule(
        "vn.sfp.modern", "sentence_type", "vn", 1,
        re.compile(rf"(?P<anchor>[嗎吗呢吧嘛])(?=[，。！？；、\s]|$)"),
        7.0,
        "n/a — corresponds to Literary 乎/哉/與, XIV.2 p.139",
        "嗎 / 呢 / 吧 / 嘛 in clause-final position. Pulleyblank glosses Literary "
        "final 夫 with modern 吧 (III.1a p.17), which is the pairing.",
        repair="嗎 → 乎; 吧 → 夫; rhetorical 呢 → 哉.",
        requires_punctuation=True,
    ),

    Rule(
        "vn.sfp.a_ya", "sentence_type", "vn", 2,
        re.compile(r"(?P<anchor>[啊呀啦囉咯喔哦])(?=[，。！？；、\s]|$)"),
        3.5,
        "n/a",
        "啊 / 呀 / 啦 and friends. Separated from 嗎/呢/吧 because these are more "
        "often transcriptional (dialogue in a novel, transcribed speech) than "
        "structural.",
        requires_punctuation=True,
    ),

    # ------------------------------------------------------------------
    # Argument structure — constructions with no Literary counterpart at all.
    # ------------------------------------------------------------------

    Rule(
        "vn.arg.ba_disposal", "argument_structure", "vn", 1,
        re.compile(rf"(?P<anchor>把){H}{{1,8}}[給给放到成為为做完掉開开出來来去]"),
        7.0,
        "n/a",
        "把 disposal construction (把書放到桌上). Pulleyblank notes at XII.3d p.120 "
        "that early colloquial 將 works 'like modern bǎ 把' and is careful to say "
        "the Classical futurity particle 將 is 'only superficially' like it — so "
        "the 把 construction proper is vernacular.",
        repair="No Literary equivalent: recast as V + O, or O + 之 preposing.",
    ),

    Rule(
        "vn.arg.bei_agent", "argument_structure", "vn", 2,
        re.compile(rf"(?P<anchor>被){H}{{1,6}}[打殺杀killed罵骂騙骗抓捕殺害偷搶抢]"),
        4.0,
        "n/a — cf. Literary 見/為…所, IV.9 p.35",
        "被 + agent + V agentive passive. Deliberately narrow and only tier 2: "
        "Pulleyblank points out that 被 in the classical language is 'a full "
        "verb, meaning receive, undergo, suffer' (IV.9a p.36), and in Japanese "
        "官府 kanbun 被 is an honorific marker. Bare 被 must never score.",
        repair="Vernacular 被 N V → Literary 見 V 於 N, or 為 N 所 V.",
    ),

    Rule(
        "vn.arg.rang_jiao", "argument_structure", "vn", 2,
        re.compile(rf"(?P<anchor>[讓让叫]){H}{{1,4}}[去來来做說说看走死吃喝]"),
        3.5,
        "n/a — corresponds to Literary 使/令, V.3 p.40",
        "讓 / 叫 as vernacular causatives, where Literary Chinese uses the 使/令 "
        "pivot construction.",
        repair="讓/叫 N V → 使 N V or 令 N V.",
    ),

    # vn.arg.zai_preverbal (在 + place + V) was here and has been REMOVED. It
    # fired 3 times on the corpus, all on Literary 在 as a main verb taking a
    # locative: 其爲島、在海峽之中央小孤嶼也 / 在此二中間湧出之蓬萊島也 /
    # 巳在都下灣泊矣. Distinguishing the vernacular preverbal coverb from the
    # Literary main verb requires knowing whether a verb follows the locative,
    # which needs a parse. The opposition is real — Pulleyblank sets Literary
    # postverbal 於 against modern preverbal coverbs at V.6a.i p.48 — but it is
    # only detectable from the Literary side, and lc.coverb.yu_locative already
    # captures that.

    # ------------------------------------------------------------------
    # Noun phrase shape
    # ------------------------------------------------------------------

    Rule(
        "vn.np.classifier_ge", "noun_phrase", "vn", 1,
        re.compile(rf"(?P<anchor>[一二兩两三四五六七八九十幾几這这那每])[個个]{H}"),
        6.0,
        "n/a — cf. VI.3 p.59",
        "NUM + 個 + N. Pulleyblank notes that Classical numerals modify nouns "
        "directly without a classifier, and that the general classifier only "
        "'begins to appear in Hàn times'; 個 as the general classifier is later "
        "still.",
        repair="NUM 個 N → NUM N (Literary numerals take no classifier).",
    ),

    Rule(
        "vn.np.men_plural", "noun_phrase", "vn", 1,
        re.compile(rf"(?P<anchor>[們们])(?=[，。！？；、\s]|$|[的都也是在])"),
        6.5,
        "n/a",
        "The plural suffix 們. Pulleyblank lists -men 們 first among the features "
        "that make Modern Chinese morphologically unlike the classical language "
        "(I.5 p.10).",
    ),

    Rule(
        "vn.np.zhe_na_demonstrative", "noun_phrase", "vn", 1,
        re.compile(rf"(?P<anchor>[這这那])(?=[個个些裡里裏兒儿麼么樣样時时邊边])"),
        6.0,
        "n/a — corresponds to Literary 是/此/彼/斯/茲, IX.2 p.85",
        "這 / 那 + classifier or bound form. Literary Chinese uses 是, 此, 彼, "
        "斯, 茲.",
        repair="這個 → 此; 那個 → 彼; 這些 → 此諸/是等.",
    ),

    Rule(
        "vn.np.interrogative_modern", "interrogatives", "vn", 1,
        re.compile(r"(?P<anchor>什麼|什么|甚麼|甚么|怎麼|怎么|怎樣|怎样|為什麼|"
                   r"为什么|哪裡|哪里|哪兒|哪儿|多少錢|幾個|几个)"),
        7.5,
        "n/a — corresponds to Literary 何/奚/胡/曷/安, IX.3 p.91",
        "Vernacular interrogatives. These are disyllabic and positionally free; "
        "the Literary series is monosyllabic and preposes before the verb "
        "(IX.3b p.93), so the two systems share nothing.",
        repair="什麼 → 何; 為什麼 → 何以/何為/胡; 怎麼 → 如之何/奈何; 哪裡 → 安/惡乎.",
    ),

    # ------------------------------------------------------------------
    # Clause linkage — paired conjunctions.
    # ------------------------------------------------------------------

    # vn.link.paired_hypotaxis — a bare list of vernacular subordinators — was
    # here and has been REMOVED. It fired 8 times on the corpus, all false:
    #
    #   所以  蓋海底深淵。所以與小鳴門異觀   Literary 所以 'that by which',
    #         which Pulleyblank (V.6a.i p.50) insists 'must always be given its
    #         full value' and does NOT mean 'therefore' in Literary Chinese —
    #         so it belongs in the literary ruleset, where it now is, and
    #         putting it here was straightforwardly a mistake.
    #   雖然  雖然蘸潮之處 / 雖然、人衆而有…   Literary 雖然 'though it is so',
    #         a full clause, exactly as Pulleyblank describes at XV.3a p.157.
    #
    # 而且, 但是, 可是, 只有 and 並且 all decompose into ordinary Literary
    # sequences too. What survives is only the complete paired frame below,
    # which cannot be produced by a Literary text by accident.

    Rule(
        "vn.link.paired_full", "complex_sentence", "vn", 1,
        re.compile(r"(?P<anchor>因為.{0,60}所以|因为.{0,60}所以|"
                   r"雖然.{0,60}但是|虽然.{0,60}但是|"
                   r"如果.{0,60}[就便]|要是.{0,60}[就便]|"
                   r"不但.{0,60}而且|不僅.{0,60}而且)"),
        8.0,
        "n/a — cf. XV.1 p.148",
        "The complete paired frame, matched end to end. Far higher precision "
        "than either half alone.",
    ),

    Rule(
        "vn.adv.dou_all", "adverbs", "vn", 2,
        re.compile(rf"(?<![\u4e00-\u9fff]{{0}})(?P<anchor>都)"
                   rf"(?=[是不很有沒没會会能要想可知覺觉])"),
        2.0,
        "XIII.1c p.128",
        "都 'all' in adverbial position. DEMOTED to weight 2.0 after the scan: "
        "fired in 32,586 documents, 85% still literary. 在 was dropped from the "
        "following set after 提督徐治都在 — 都 inside the personal name 徐治都. "
        "Pulleyblank himself says 都 'is used adverbially in its modern sense of "
        "all in some Hàn texts', so this graph is genuinely ambiguous in later "
        "Literary Chinese and cannot carry a heavy weight. "
        "'is used adverbially in its modern sense of all in some Hàn texts, but "
        "was not usual in Literary Chinese', where 皆 does this work. The "
        "following-element restriction exists because 都 'capital city' (建都, "
        "都邑, 京都) is entirely ordinary Literary Chinese.",
        repair="都 → 皆.",
    ),

    Rule(
        "vn.adv.hen_degree", "adverbs", "vn", 2,
        re.compile(rf"(?P<anchor>很|特別|特别|比較|比较|有點|有点)"
                   rf"(?=[{HAN_BODY}])"),
        4.0,
        "n/a — cf. X.2 p.100, 甚",
        "很 / 特別 / 比較 degree adverbs. Literary Chinese uses 甚, 至, 頗, 殊.\n\n"
        "非常 and 挺 were REMOVED after the full-corpus scan: this rule fired in "
        "54,137 documents, 95% of which were still literary. In 402,000 "
        "characters of Tang prose and Qing veritable records, every hit was one "
        "of these two graphs in ordinary Literary use — 非常 'extraordinary' "
        "(定非常, 露腹心非常) and 挺 'upright, outstanding' (幼挺岐嶷, 壯夫挺劍, "
        "命世挺生, 蹈義挺生, 挺秀). 挺 also turned up inside the Tang official's "
        "name 韋挺. Neither graph can carry the modern degree sense reliably "
        "enough to be worth its false positives.",
        repair="很 → 甚; 比較 → 較.",
    ),

    Rule(
        "vn.q.nandao", "interrogatives", "vn", 1,
        re.compile(r"(?P<anchor>難道|难道|是不是|有沒有|有没有|好不好|對不對|对不对)"),
        7.0,
        "XIV.2b.iii p.142",
        "難道 … 嗎, and the A-not-A question. Pulleyblank glosses Literary 豈 with "
        "modern 難道 explicitly, which makes them a matched pair across the two "
        "rulesets.",
        repair="難道…嗎 → 豈…哉; A不A → A否 / A乎.",
    ),

    Rule(
        "vn.np.shihou", "complex_sentence", "vn", 1,
        re.compile(r"(?P<anchor>的時候|的时候)"),
        4.5,
        "XV.4d p.160",
        "…的時候 marking a temporal clause. Pulleyblank names this as the modern "
        "counterpart of Literary 當…之時 and of bare 時 closing a temporal clause. "
        "Narrowed to the 的 forms only: 以後, 以前 and bare 時候 are ordinary "
        "Literary Chinese and had no business in this list.",
        repair="…的時候 → 當…之時 / 及…也 / …之時.",
    ),

    Rule(
        "vn.cmpl.directional", "complement", "vn", 2,
        re.compile(rf"{H}(?P<anchor>起來|起来|下去|出來|出来|過來|过来|進去|进去)"),
        4.0,
        "n/a",
        "Vernacular directional complements. Literary Chinese has verbs in "
        "series (V.5 p.44) but not this grammaticalised postverbal set.",
    ),

    Rule(
        "vn.cleft.shi_de", "sentence_type", "vn", 2,
        re.compile(rf"(?P<anchor>是){H}{{1,14}}的(?=[，。！？；、\s]|$)"),
        4.0,
        "IX.2a p.85",
        "是 … 的 cleft. Pulleyblank is explicit that 'in Classical Chinese 是 is "
        "not itself a copula' — it is a resumptive demonstrative — so the cleft "
        "frame built on copular 是 is vernacular.",
        requires_punctuation=True,
    ),
]
