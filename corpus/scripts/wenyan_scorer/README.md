# Wenyan Scorer 文言得手器
This tool takes *Outline of classical Chinese grammar* by Edwin G. Pulleyblank (2000) and creates a model of Literary Chinese syntax from it.

# Introduction
This program makes an auditable implementation of ~92 of the constructions Pulleyblank (2000) describes for Classical and Literary Chinese. The number is a count of implementation decisions, not of anything in the book — Pulleyblank writes prose grammar, and the choice to split, say, 何…之有 from 唯…是… into two separately weighted rules is mine. You can walk across a corpus and receive a rating on how "Wenyan" your texts are, testing whether it meets the metrics or not. It has trouble with really short texts, which will usually be marked `uncertain`; therefore, this is not suited for poetry, as the sample size per poem is too small. Sorry, Li Bai! Alas, poor Hara Saihin!

The program does not care where or when the text was made. It is, in practicality, a bunch of regexes:
```
    Rule(
        "lc.exposure.fu_topic", "exposure", "lc", 2,
        re.compile(rf"(?:^|[。；！？\n])\s*(?P<anchor>夫){H}"),
        3.0,
        "VIII.5d p.74",
        "Clause-initial 夫 as the topic-announcing particle (夫明堂者…). Anchored "
        "to clause start so the noun 夫 'man, husband' does not match.",
    ),
```
Does the text start with 夫? Great! Add a little bit to the score. 

```
    Rule(
        "lc.nom.zhe", "nominalization", "lc", 2,
        re.compile(rf"{H}(?P<anchor>者)(?![{HAN_BODY}]?$)"),
        1.6,
        "VII.2c p.66",
        "者 as pronominal substitute for the head of a noun phrase (耕者, 殺人者). "
        "Tier 2 rather than 1 because 者 survives in modern 記者/作者 compounds.",
    ),
```
Does it 者? The real questions Mencius would be asking if you talked to him about the wonders of Chu speech.

But we see tiers. What's up with that?
```
  tier 1  structurally unavailable in the vernacular. Object preposing under
          negation, 唯…是…, 何…之有, the fusions. If one of these fires and the
          match is real, the text is Literary Chinese.
  tier 2  strong, but reachable by a literary-flavoured modern writer.
  tier 3  density only. Counts of common particles. Individually worthless.
```
The main problem with evaluating Han script languages is that you cannot tell what a language is immediately. No pronunciation, just glyphs and punctuation; the latter of which is absolutely not necessary for Classical or Literary Chinese. Therefore, a possible way to measure is with a tiered system; **what distinguishes Classical Chinese from contemporary topolects?** There are many clear cases:
1. Negation + Pronoun + Verb (未之有也, 莫之能禦, 不我知, 不吾遠): Most, if not all topolects, have lost this completely.
2. 唯/惟/維 + X + 是/之 + Verb (唯利是求, 唯仁之為守): You could use 是 and 之 resumption here too, but 惟 is particularly strong as it died out. 
3. X 之謂 也 (夫子之謂也, 非此之謂也): Notably, this survived into late Literary Chinese and died in topolects.
4. 為 (N) 所 V passive (為三軍所獲, 終為之所擒矣): This is the old equivalent of 被 constructions and forms during the Han dynasty, so post-Qin Literary Chinese can be spotted easily. 
5. 所以 typically means "therefore" in Mandarin, but in Literary Chinese, it is different. The scorer uses Parts of Speech to count stuff, such as `lc.nom.suo_coverb`, as 所, in the case of 所以, is nominalising a coverb phrase, "that by which". This makes it quite effective.
6. 其 … 乎 (其無後乎, 其知道乎): This is quite rare too, but we could talk about this all day, and `pulleyblank_core_v4.py` tells you everything that's covered.
Point is, there are many markers for when you're dealing with these languages, and Literary Chinese writers did and do work under them.

# Example output
This was tested on Fanya Hanwen Corpus on 11th September 2026 as part of an audit. It identified a pretty major hole in my Republican era folder for China, and a couple of fictional novels that got ingested but survived repeated passes. 
```
{
  "documents": 303966,
  "errors": 0,
  "han_chars": 1508935565,
  "elapsed_seconds": 2482.8,
  "docs_per_second": 122.4,
  "labels": {
    "literary": 220333,
    "too_short": 73816,
    "uncertain": 2169,
    "not_literary": 7648
  },
  "labels_by_corpus_root": {
    "中國漢文": {
      "literary": 95374,
      "too_short": 68347,
      "uncertain": 1594,
      "not_literary": 7406
    },
    "日本漢文": {
      "literary": 735,
      "too_short": 115,
      "uncertain": 2,
      "not_literary": 1
    },
    "他漢文": {
      "literary": 40,
      "too_short": 10
    },
    "四庫全書": {
      "literary": 101238,
      "too_short": 1482,
      "uncertain": 231,
      "not_literary": 35
    },
    "新加坡漢文": {
      "too_short": 682,
      "literary": 251,
      "not_literary": 7,
      "uncertain": 22
    },
    "朝鮮漢文": {
      "literary": 11693,
      "too_short": 588,
      "uncertain": 20,
      "not_literary": 10
    },
    "琉球漢文": {
      "literary": 95,
      "uncertain": 1,
      "too_short": 11
    },
    "礦藝大典": {
      "too_short": 496,
      "literary": 1531,
      "not_literary": 157,
      "uncertain": 16
    },
    "維基大典": {
      "literary": 9079,
      "too_short": 2019,
      "uncertain": 272,
      "not_literary": 30
    },
    "越南漢文": {
      "too_short": 66,
      "literary": 297,
      "uncertain": 11,
      "not_literary": 2
    }
```

# Limitations
* **This tool uses a very traditional, and often linguistically inaccurate, model of Literary Chinese grammar.** Specifically, it implicitly splits words by content words 實詞 and function words 虛詞, by gauging works off their use of function words. This is good - as you can plainly see, there are more than enough patterns - but once we go into distributional properties such as adverbials, it will begin to have trouble. 
* **The grammatical accuracy of an individual writer is not measured**; as in, we are not looking for grammar mistakes and using that to discredit Literary Chinese. **What we instead do is score the likelihood based on syntactic markers.** What we do have could be turned into an autocorrect, "spell"checker, or something like that in the future. This may depend on idiom.
* **There is purity testing out the ass in these languages.** This scorer does not care about it, because we aren't trying to exclude thousands of years of work done by many clearly intelligent people, nor are we trying to make modern writers out to suddenly be incompetent because the year has a 20 at the beginning. 
* **It is probably possible to trick the scorer** by crowding many Tier 2-3 lexemes and/or placing them precisely. But at that point, you are probably, intentionally or not, writing Republican-era legal Literary Chinese. Legal Mandarin may trick it, but there are cases of Literary Chinese being used in RoC courts, so it's not like I can't account for this, either. 
* **There are studies implying 吾/我 were ergative-absolutive in Zhou-Qin Classical Chinese,** which is interesting, but seems too unstable for diachronic corpora such as my own. Post-Qin writers began to eventually see it as nominative-accusative as well, and other pronouns are not very tested.
* **This tool may miss rules** that Pulleyblank (2000) missed, like the above one. 

Some rules pertaining to vernacular Mandarin were removed, mainly because we do not tag characters for word class:
* **Aspectual 過** fired in 56,541 documents (19% of the corpus), 92% of which remained literary. Every sampled hit was the literary sense of "fault", e.g. 極言朕過, 改過, 補過, 無過. Its distribution overlaps the literary meaning far too heavily, so it is one of the worst flags that you can add. Oops.
* **Adverbial 地** ended up always hitting the usual sense of "land", e.g. 此地磧礫甚鮮美, 其地瓦屋鱗比. 
* **Preverbal locative 在** always hit 在 as a common-or-garden verb. One of them was the personal name 徐治都在. Big oopsie.
* **非常 and 挺** as degree adverbs; 非常 "extraordinary", 挺 "upright" (命世挺生), and...the Tang official 韋挺! Seize him! But seriously. 非常 can be seen as a normal construction parsed character-by-character, so it isn't a great measure...

This is where character tagging would help. Traditional models defined content words 實詞 and function words 虛詞, which is implicitly what this model does. However, the adverbial 地 and locative 在 need a broad noun/verb model at minimum to separate from their literary meanings. This applies whether you want a "stative verb" model that collapses verbs and adjectives into one broad category or something else. As there are around 30,000 Han characters that you can expect to see used in this corpus at the absolute minimum (and this is lowballing it), I choose life, and will not do the tagging. 

There are some models for part-of-speech (PoS) tagging:
* Chiu, T., Lu, Q., Xu, J., Xiong, D., & Lo, F. (2015). PoS Tagging for Classical Chinese Text. In Q. Lu & H. H. Gao (Eds), Chinese Lexical Semantics (pp. 448–456). Springer International Publishing. https://doi.org/10.1007/978-3-319-27194-1_44
* Huang, L., Peng, Y., Wang, H., & Wu, Z. (2002). Statistical Part-of-Speech Tagging for Classical Chinese. In P. Sojka, I. Kopeček, & K. Pala (Eds), Text, Speech and Dialogue (pp. 115–122). Springer. https://doi.org/10.1007/3-540-46154-X_15
* Wang, D., Liu, C., Zhao, Z., Shen, S., Zhu, Z., Li, B., Hu, H., Wu, M., Lin, L., Zhao, X., & Wang, X. (2023). GujiBERT and GujiGPT: Construction of Intelligent Information Processing Foundation Language Models for Ancient Texts (Version 1). arXiv. https://doi.org/10.48550/ARXIV.2307.05354

But I did not use any of them. I imagine combining Chiu *et al* (2015) and Huang *et al* (2002) may garner some interesting results, as Chiu *et al* handle Ming-Qing texts, whilst Huang *et al* (2002) handle Zhou-Qin texts. 

# References 
* Chiu, T., Lu, Q., Xu, J., Xiong, D., & Lo, F. (2015). PoS Tagging for Classical Chinese Text. In Q. Lu & H. H. Gao (Eds), Chinese Lexical Semantics (pp. 448–456). Springer International Publishing. https://doi.org/10.1007/978-3-319-27194-1_44
* Huang, L., Peng, Y., Wang, H., & Wu, Z. (2002). Statistical Part-of-Speech Tagging for Classical Chinese. In P. Sojka, I. Kopeček, & K. Pala (Eds), Text, Speech and Dialogue (pp. 115–122). Springer. https://doi.org/10.1007/3-540-46154-X_15
* Pulleyblank, E. G. (2000). Outline of classical Chinese grammar (Repr). UBC Press.
* Wang, D., Liu, C., Zhao, Z., Shen, S., Zhu, Z., Li, B., Hu, H., Wu, M., Lin, L., Zhao, X., & Wang, X. (2023). GujiBERT and GujiGPT: Construction of Intelligent Information Processing Foundation Language Models for Ancient Texts (Version 1). arXiv. https://doi.org/10.48550/ARXIV.2307.05354
* Yang, B. (2016). 文言语法 [Literary Chinese Grammar] (1st ed). 中华书局 [Zhonghua Book Company].
* Yip, P.-C., & Rimmington, D. (2016). Chinese: A comprehensive grammar (Second edition). Routledge.

# Licence
As a supporter of the [Free Software Movement](https://www.fsf.org/about/) and its values, this is published under a [GNU General Public Licence v3.0](https://www.gnu.org/licenses/gpl-3.0.en.html). Contributions are encouraged. 
