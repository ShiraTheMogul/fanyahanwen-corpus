"""
Cross-tradition fixtures taken from the Fanyahanwen corpus itself.

Every excerpt below is real corpus text, not invented. They are here because the
first version of the vernacular ruleset scored several of them `not_literary` —
Japanese, Ryukyuan and Vietnamese 漢文 marked down by rules that were matching
ordinary Literary Chinese words. The specific false positives are named in the
comments so that a future change reintroducing one fails loudly.

The point of the file: a scorer for a pan-Asian corpus has to be tested on the
pan-Asian corpus. Testing it on Mencius and modern Mandarin would have passed
while it was quietly rejecting Ryukyu.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from wenyan_scorer import score_text  # noqa: E402

_FAILURES = []

# (tradition, source, text, expected_label, note-on-what-once-broke)
FIXTURES = [
    (
        "日本漢文", "心理新説序 (明治, 筑前国)",
        "電線也、火船也、自鳴鐘也、我邦人唯其物之奇、而不知究其所由來。豈不淺見之甚耶。"
        "夫電線・火船與自鳴鐘、無一不本于科學。然而科學原出于哲學。而心理學實爲哲學之根基矣。"
        "昔者希臘之盛、瑣克剌底・布拉多・亞里私特德等、前後輩出、哲學大興。於是乎、科學始胚胎焉。"
        "後文運移入羅馬。及羅馬滅、夷狄猖獗、哲學幾絶、僧徒纔傳之。降至中世之末、哲學復興。"
        "倍根出於英、垤加爾多出於佛。歐州哲學、由此分爲二派。蓋韓圖及費希的・設林・歇傑爾、"
        "其他獨逸之諸先輩、傳垤加爾多之學、而大成之。",
        "literary",
        "的 inside the transliteration 費希的 (Fichte) was read as a vernacular "
        "linker, because the apparatus stripper was deleting the name-separator "
        "・ as if it were katakana",
    ),
    (
        "日本漢文", "遊鳴門記 (明治, 淡路国)",
        "明治二十九年三月念八日。予與大和北溪・津田某、將僦舟發江井港。雨後陰霽未定。"
        "篙郎前諾而後不肯焉。津田子督促出舟。午後三點時解纜。廻繪崎掛帆。天稍霽。北風寒砭骨。"
        "乃開行廚飛盞、欲藉酒力取温。舟已過津志灣、而未成醉。隨飲隨醒。蓋酒力不能敵風力。"
        "雖風光可賞、奈無防寒策何。抵鳥飼。風力良微。此地磧礫甚鮮美。其大不過于握拳。"
        "其小如雞卵。以見淘汰于波濤之故、皆成楕圓狀。所謂燕石之類歟。",
        "literary",
        "此地磧礫 matched a vernacular adverbial-地 rule; 其大不過于握拳 matched an "
        "experiential-過 rule; 在…之中央 matched a preverbal-在 rule",
    ),
    (
        "琉球漢文", "萬國津梁之鐘銘文 (第一尚氏王朝, 首里城)",
        "琉球國者南海勝地而鍾三韓之秀以大明爲輔車以日域爲唇齒在此二中間湧出之蓬萊島也"
        "舟楫爲萬國之津梁異産至寶充滿十方刹地靈人物遠扇和夏之仁風",
        "literary",
        "unpunctuated, so every punctuation-dependent rule is skipped; it must "
        "still be recognised from the lexically anchored constructions",
    ),
    (
        "琉球漢文", "物外樓記 (第二尚氏王朝)",
        "物外樓者、吾友程君之所築也。君性恬淡、不樂榮利、退居於城南之隅、"
        "闢地數弓、結構斯樓。樓雖不甚宏麗、而竹樹環之、泉石映之。"
        "君日處其中、或讀書、或鼓琴、悠然自得、若忘世者。",
        "literary",
        None,
    ),
    (
        "越南漢文", "平吳大誥 (後黎朝)",
        "仁義之舉、要在安民、弔伐之師、莫先去暴。惟我大越之國、實爲文獻之邦。"
        "山川之封域既殊、南北之風俗亦異。自趙丁李陳之肇造我國、與漢唐宋元而各帝一方。"
        "雖強弱時有不同、而豪傑世未常乏。",
        "literary",
        None,
    ),
    (
        "越南漢文", "藍山實錄重刊序 (後黎朝)",
        "蓋聞創業之君、必有命世之佐、而後能成不世之功。我太祖高皇帝起自藍山、"
        "奮然以除暴救民爲己任。當是時也、天下之士、翕然歸之。",
        "literary",
        None,
    ),
    (
        "control", "modern Mandarin",
        "我今天早上去了一個很大的商店，買了三個蘋果和一些東西。因為天氣很好，"
        "所以我覺得非常開心。你知道嗎？他們都在那裡等著呢。如果明天下雨的話，"
        "我們就不去了。這個問題我已經想了很久，可是還沒有找到答案。",
        "not_literary",
        None,
    ),
    (
        "control", "Qing vernacular fiction",
        "話說那寶玉見了這些人，心裡便有些不自在起來。襲人道：「你又發什麼呆？」"
        "寶玉笑道：「我並沒有發呆，只是想起一件事來。」說著便把手裡的扇子放下了。"
        "眾人都笑了起來，那丫頭們也跟著笑。",
        "not_literary",
        None,
    ),
]


def main() -> int:
    print(f'{"tradition":<10} {"source":<34} {"lc":>7} {"vn":>7} {"share":>7}  label')
    print("-" * 84)
    for tradition, source, text, expected, once_broke in FIXTURES:
        r = score_text(text, segment="whole", min_han=40)["summary"]
        lc, vn = r["lc_rate_mean"], r["vn_rate_mean"]
        share = vn / (lc + vn) if lc + vn else 0.0
        got = r["document_label"]
        ok = got == expected
        mark = " " if ok else "*"
        print(f'{mark}{tradition:<9} {source:<34} {lc:>7.1f} {vn:>7.1f} {share:>6.1%}  {got}')
        if not ok:
            _FAILURES.append(f"{tradition}/{source}: expected {expected}, got {got}")
            print(f'          why: {r["why"]}')
            if once_broke:
                print(f'          this fixture exists because: {once_broke}')

    print("\n" + "=" * 84)
    if _FAILURES:
        for f in _FAILURES:
            print("FAIL " + f)
        return 1
    print(f"all {len(FIXTURES)} cross-tradition fixtures classified correctly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
