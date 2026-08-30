# 泛亞漢文語料庫 pan-Asian Literary Chinese Corpus (PALCC)

This is a Literary Chinese corpus that represents the language as a pan-Asian lingua franca. It includes a significant body of major, gigantic Chinese texts (Yongle Encyclopaedia's extant transcriptions, Siku Quanshu, etc), and adds texts from Japan, Korea, the Ryukyu Islands, and Vietnam, all of which used Literary Chinese at some point. With respect to China, a diachronic corpus is made; anything from the Shang to modern China, so long as they use Literary Chinese, so long as it is not under copyright or equivalent, is acceptable here. Translations into Literary Chinese are included, accepted, and encouraged. As Yan Fu had said in his translation of Huxley's Theory of Evolution: 「一、譯事三難：信、達、雅。求其信已大難矣，顧信矣不達，雖譯猶不譯也，則達尚焉。」 they must be faithful, fluent, and beautiful. It is very difficult to earn a reader's trust, but if a translator is concerned about it, they will not reach it. There is no reason to exclude such well-thought-out work.

I extend a heartfelt thank you to the tireless contributors at Wikisource for its astounding quantity of Literary Chinese works. To transcribe even a fraction of the leviathan that is Siku Quanshu is a truly remarkable feat, let alone everything else. I have nothing but the utmost respect for those anyone doing any of this for free, let alone releasing it in such an accessible fashion, thus why I chose to do this initially.

This originally began as a corpus of Siku Quanshu 四庫全書 sources taken from Wikisource, plus additional files. It checks all pages on the ZH Wikisource with `Category:四庫全書` and their throughlinks, as well as those on the main 四庫全書 page with "四庫全書" in their name, to construct a corpus for research purposes.  At the time of creation, 3,368 out of 3,593 titles within the text had been digitized (though not all are completely transcribed). This was not the first Siku Quanshu corpus to be made, but in absence of a freely-available or accessible one - a corpus made in 1999 is paid software, and rightfully so, it was one of the first digitization of the work! - I initially decided to make a publicly available one. However, I have not seen a corpus that adds more beyond Siku Quanshu, and so I expanded it to include more texts.

The given scripts will output CSV, TSV, and JSON indexes for auditing.

# About the Corpus

## Licencing and Referencing
Most Literary Chinese corpora absolutely suck with licencing information; the one corpus I have found that works well in this department is Kanripo, which requires attribution. Others tend to either not give information, not give provenence so information cannot be verified, or neither. This is especially bad for NLP projects where this sort of information is essential to be trustworthy. Fanya Hanwen Corpus ensures that provenence is top priority to ensure academic integrity. 

## Statistics
As of 31st January 2026, the corpus contains 744,312,022 characters, comprised of 172,613 chapters amongst 81,323 distinct works. Works range from Wu Ding's reign during the Shang dynasty all the way to works produced this year, from over 10 different countries. This makes it the most inclusive Literary Chinese corpus that I am aware of.

The largest texts are generally encyclopaedias and histories. For example, what remains of the the Yongle Encyclopaedia contains 313,103,58 characters. The History of Korea reaches 57,319,61.

## Metadata
Every work has its own metadata which contains valuable information about the author, (estimated) year of original publication, sourcing, material, evidence, and other qualities. This makes every work in the corpus fully trackable and accountable to any and all scrutiny, and IDs are assigned for a proper backbone for site-end work. This metadata also makes organising compilations of works easier, as well as given chapters. 

## Regionalisation and periodisation
Works are categorised by macro-nation first, then subdivided into period and polity. With respect to China, Wikisource's dynasty divisions are used. I went from earliest/leftmost categories on their [dynasty division template](https://zh.wikisource.org/wiki/Template:%E6%8C%89%E7%85%A7%E6%9C%9D%E4%BB%A3%E5%88%86%E7%B1%BB) after downloading Siku Quanshu with automatic de-duplication implemented. I did this for efficiency and ease of scraping. I will not pretend to be a historian here, and any disputes regarding any of these divisions (e.g. The two pieces of Tang dynasty literature that was within Empress Wu Zhao of Zhou's reign) would fall outside of the data scope to me.

Therefore, for Eastern Zhou work, one would go into the China section, then the Zhou dynasty, then Zhou as a polity, then the Eastern Zhou period of that polity.

Every other nation follows a similar path. There is also a 他 (other) folder for anything that is out of the sinosphere. There is intent to cover this better at a later time when this is actually feasible.

# How do we know it is Literary Chinese?
The listed code is deprecated and a more advanced system was put in place, based on Pulleyblank (2000). 

When scraping the Yuan, Ming, and Qing dynasties, as well as the Republic of China (which has been merged with Taiwanese literature for logistics reasons), I used a Literary Chinese scorer:
```py
# Modern-ish function words (single characters).
# We explicitly *exclude* 在 and 我.
MODERN_UNIGRAMS = [
    "的", "得", "地", "了", "著", "吗", "嗎", "啊", "呀", "呢", "吧", "啦",
    "把", "被", "給", "給", "還", "就", "才", "再", "對",
]

# Common disyllabic / colloquial-ish constructions.
MODERN_BIGRAMS = [
    "時候", "東西", "沒有", "可以", "覺得", "觉得", "知道",
    "怎麼", "為什麼", "怎樣", "怎样", "怎麼樣", "怎么样",
    "一個", "一樣", "已經", "正在", "必須",
    "需要", "可能", "那麼", "所以", "如果", "就是", "那個",
    "這個", "這些", "这些", "那些", "一起", "比較", "比较", "然後", "然后",
    "因為", "比如", "比如說", "特別", "非常", "有點", "有点", "有些",
    "有時候", "有时候", "今天", "現在", "以後", "以后",
]

# Classical sentence-final particles / markers.
CLASSICAL_FINALS = [
    "也", "矣", "焉", "乎", "哉", "耳", "歟", "歟", "云", "歟",
]

# Other classical-ish function words that often cluster near句 boundaries.
CLASSICAL_FN = [
    "者", "之", "其", "若", "乃", "蓋", "蓋", "雖", "尚", "焉", "乎",
    # If a text uses the below then it is almost definitely classical.
    "猶", "允", "聿", "繄", "粵", "吾", "毋", "無", "惡"
]

CLASSICAL_BIGRAMS = [
    "焉哉", "云云", "何以", "何為", "未嘗", "未有", "無不",
]


def compute_wenyan_score(
    text: str, min_chars: int = 200
) -> Tuple[float, Dict[str, Any]]:
    """
    Compute a rough Wenyan-vs-Baihua score for CLEAN text.

    Returns (score, metrics_dict).

    - score > 0  => Wenyan-like
    - score < 0  => Baihua-like
    - For very short texts (len < min_chars), we mark label='unknown'
      and treat score as 0 for routing purposes.
    """
    # Strip whitespace for length statistics
    chars_only = [c for c in text if not c.isspace()]
    n_chars = len(chars_only)

    metrics: Dict[str, Any] = {
        "n_chars": n_chars,
        "modern_density": 0.0,
        "classical_density": 0.0,
        "avg_sentence_len": 0.0,
        "is_poetry": False,
        "label": "unknown",
        "short_text": n_chars < min_chars,
    }

    if n_chars == 0:
        return 0.0, metrics

    # Modern side
    mod_uni = sum(text.count(ch) for ch in MODERN_UNIGRAMS)
    mod_bi = sum(text.count(bg) for bg in MODERN_BIGRAMS)
    modern_density = (mod_uni + 2 * mod_bi) / n_chars
    metrics["modern_density"] = modern_density

    # Classical side
    cls_uni = sum(text.count(ch) for ch in CLASSICAL_FINALS + CLASSICAL_FN)
    cls_bi = sum(text.count(bg) for bg in CLASSICAL_BIGRAMS)
    classical_density = (cls_uni + 2 * cls_bi) / n_chars
    metrics["classical_density"] = classical_density

    # Sentence length (using 。！？ and newlines as crude boundaries)
    sentences = [s.strip() for s in re.split(r"[。！？!?]+|\n+", text) if s.strip()]
    if sentences:
        total_len = sum(len(s) for s in sentences)
        avg_len = total_len / len(sentences)
    else:
        avg_len = 0.0
    metrics["avg_sentence_len"] = avg_len

    # Rough poetry detector: lots of short lines
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if lines:
        short_lines = [ln for ln in lines if 4 <= len(ln) <= 10]
        poetry_ratio = len(short_lines) / len(lines)
        is_poetry = (len(lines) >= 20 and poetry_ratio >= 0.6)
    else:
        is_poetry = False
    metrics["is_poetry"] = is_poetry

    # Combine into a single score.
    # Tuned more by intuition than science:
    #   - classical pushes score up
    #   - modern pushes score down (stronger weight)
    #   - longer sentences & poetry give a small Wenyan boost
    len_score = 0.0
    if avg_len >= 25:
        len_score = 0.3
    elif avg_len >= 15:
        len_score = 0.15

    # It is difficult to make a script that doesn't bias itself against poetry.
    # Some use parataxis, omitting function words a lot.
    # Ergo, our standard definition does not work.

    poetry_boost = 0.25 if is_poetry else 0.0

    score = (
        2.0 * classical_density
        - 3.0 * modern_density
        + len_score
        + poetry_boost
    )

    # For very short texts, we don't trust the decision.
    if n_chars < min_chars:
        metrics["label"] = "unknown"
        return score, metrics

    # Decide label
    if score >= 0:
        metrics["label"] = "wenyan-like"
    else:
        metrics["label"] = "baihua-like"

    return score, metrics
```

The tester could be much, MUCH better, but I wanted something quick and dirty to get some decent filtering in. Anything that failed this test goes into `suspected_baihua`, wherein it is subject to human testing to see if it is or not. This is to ensure no early topolect usage gets into the corpus by mistake. This is also useful for diachronic study, of course, so anything that outright fails stays there. 

# Limitations
While this is a dizzying level of information, some limitations exist:
- A lot of Wikisource's texts are unpunctuated. While accurate, this will not be representative of how contemporary Literary Chinese is read. A punctuation stripping function is available in the Corpus Viewer for an accurate experience.
- OCR errors from preliminary documentation of some works may exist.
- Transcription prejudices by contributors may exist (e.g. A more common character may be used over what the actual text has). This is rare.
- There may be some Early Mandarin works amongst all this. I do have a topolect-scoring system, but only used it for Yuan, Ming, and Qing dynasty literature as it is outright necessary.
- Chu speech is argued to potentially be a distinct language: Mencius particularly speaks to this effect. However, it remains included in this work as this matter is not *fully* established yet; I am not an expert on this matter, I just know it is discussed and that this corpus may be of use for it. For information, view the bibiography.

# Possible improvements
- Gathering of the rejected Siku Quanshu texts (Referred to tongue-in-cheek as Siku Jinshu 四庫禁書) to form an unredacted corpus. A reconstruction called 四庫禁燬書叢刊 exists, has 19+ chapters, and is in the Public Domain, but has not been fully transcribed save for 皇明通紀. https://zh.wikisource.org/wiki/%E7%9A%87%E6%98%8E%E5%BE%9E%E4%BF%A1%E9%8C%84
- Find a reliable way to OCR the many PDFs that have not been transcribed.

# Bibliography
The following texts were used or otherwise had an influence in the making of the website, the corpus, and more.

- Chen, Gaohua 陳高華, & Chen, Zhichao 陳智超. (2020). 中国古代史史料学：商殷史史料. 中国社会科学院古代史研究所. https://lishisuo.cssn.cn/xsyj/gdwhs/202001/t20200116_5078822.shtml
- Liu, Kexin 刘克新, Wu, Xiaohong 吴小红, Guo, Zhiyu 郭之虞, Yuan, Sixun 原思训, Ding, Xingfang 丁杏芳, Fu, Dongpo 傅东坡, & Pan, Yan 潘岩. (2021). Radiocarbon dating of oracle bones of late Shang period in ancient China. *Radiocarbon, 63*(1), 155–175. https://doi.org/10.1017/RDC.2020.90
- Rao, Zongyi 饒宗頤. (1959). 殷代貞卜人物通考. 香港大學出版社. https://books.google.com/books?id=7kKaEDNc_V8C
- Song, Zhenhao 宋鎮豪, & Liu, Yuan 劉源. (2006). 甲骨学殷商史研究. 福建人民出版社. https://books.google.com/books?id=RJBOAAAAIAAJ
- Xu, Zixiao 許子瀟. (2023). 甲骨文所見「𠂤組貞人」的初步研究. *饒宗頤國學院院刊, 10*, 1–48. https://jas.hkbu.edu.hk/content/dam/jas-assets/publications/bulletin-of-the-jao-tsung-i-academy-of-sinology/issue---10/i10-1.pdf
- Xia–Shang–Zhou Chronology Project Expert Group 夏商周断代工程专家组. (2022). 夏商周断代工程报告. 科学出版社. https://book.sciencereading.cn/shop/book/Booksimple/show.do?id=BE074EF533E8D2705E053010B0A0A412D000
- Yi, B. (2019). 字統网 [zi.tools] [Browser]. Retrieved August 21, 2026, from https://zi.tools/
- Aisin-Gioro H., Ji Y., & Lu X. (Eds). (2007). 四庫全書 [Complete Library of the Four Treasuries] (Vol. 1–36,381). Wikisource. https://zh.wikisource.org/wiki/%E5%9B%9B%E5%BA%AB%E5%85%A8%E6%9B%B8
- Aun, C. (2025). Cheeaun/chengyu-wordle [JavaScript]. https://github.com/cheeaun/chengyu-wordle (Original work published 2022)
- Behr, W. (2008). Dialects, diachrony, diglossia or all three? Tomb text glimpses into the language(s) of Chǔ [Lecture].
- Editorial Board of the Encyclopedia of China. (2009). 《四庫七閣·四庫全書·四庫全書總目提要》. In 中国大百科全书 [Encyclopedia of China] (2nd ed). 中國大 [China Publishing House].
- Dai, L., Li, T., Yang, Y., Jia, L., Magically Asia Limited, TudorTech System Co., Ltd, & Founder Electronics Company Limited. (1999). Siku Quanshu Online (Version 3.0 (Wenyuange Ed.)) [Computer software]. Digital Heritage Publishing Ltd, East View Information Services. http://skqs.com/
- Guy, R. K. (1987). The emperor’s four treasuries: Scholars and the state in the late Chʻien-lung era. Council on East Asian Studies, Harvard University.
- Harvard University, Academia Sinica, & Peking University. (2025, May). *China Biographical Database*. Retrieved August 21, 2026, from https://projects.iq.harvard.edu/cbdb
- Ho, D. (with Notepad++ contributors). (n.d.). *Notepad++* [Computer software]. Retrieved August 28, 2026, from https://github.com/notepad-plus-plus/notepad-plus-plus
- Han, D. (2022). 朝鲜汉诗选 [Anthology of Korean Sinitic Poetry] (1st ed). 江西教育出版社 [Jiangxi Education Press].
- Lee, J., & Jung, Y. (2025). A Variant Character Dataset for Historical Narratives of Middle and Late Imperial China. Journal of Open Humanities Data, 11, 33. https://doi.org/10.5334/johd.325
- Lichtman, K., & VanPatten, B. (2021). Was Krashen right? Forty years later. Foreign Language Annals, 54(2), 283–305. https://doi.org/10.1111/flan.12552
- Matsumoto J. (2025). 日本漢文の世界 [Nihon kanbun no sekai]. Kambun.jp. https://kambun.jp/
- Meng, K. (2016). 孟子 [The Works of Mencius] (J. Legge & Y. Shi., Trans.; 1st ed.). 中州古籍出版社 [Zhongzhou Ancient Books Publishing House].
- Pulleyblank, E. G. (2000). Outline of classical Chinese grammar (Repr). UBC Press.
- qwert-ly. (2026). Qwert-ly/xtext: Basic nlp(?) of classical Chinese (Version 1.0) [Python, VBA]. https://github.com/Qwert-ly/xtext
- Shi, K. (Ed.). (2024). 日本汉诗选 [Anthology of Japanese Sinitic Poetry] (1st ed, Vols 1–2). 江西教育出版社 [Jiangxi Education Press].
- Sturgeon, D. (2020). Digitizing Premodern Text with the Chinese Text Project. Journal of Chinese History, 4(2), 486–498. https://doi.org/10.1017/jch.2020.19
- Sturgeon, D. (2021). Chinese Text Project: A dynamic digital library of premodern Chinese. Digital Scholarship in the Humanities, 36(Supplement_1), i101–i112. https://doi.org/10.1093/llc/fqz046
- Takekoshi 竹越, Takeshi. 孝(2011). 『兼滿漢語滿洲套話清文啓蒙』満洲文字注音一覧表. KOTONOHA, (101).
- Trilateral Cooperation Secretariat. (2015). 中日韩共同常用八百八汉字表 [Booklet of the 808 Commonly Used Chinese Characters in China, Japan and the ROK]. Trilateral Cooperation Secretariat.
- untunt. (2025). Nk2028/zhongyuan-data [Python]. nk2028. https://github.com/nk2028/zhongyuan-data (Original work published 2023)
- untunt. (2025). Nk2028/menggu-ziyun-data [Python]. nk2028. https://github.com/nk2028/menggu-ziyun-data (Original work published 2025)
- Wang D., Liu C., Liu L., Liu J., Hu H., Shen S., & Li B. (2022). SikuBERT与SikuRoBERTa:面向数字人文的《四库全书》预训练模型构建及应用研究 [Construction and Application of Pre-trained Models of Siku Quanshu in Orientation to Digital Humanities]. 图书馆论坛 [Literary Tribune], 42(6), 14. https://doi.org/10.3969/j.issn.1002-1167.2022.06.005
- Wang, D., Liu, C., & Zhu, Z. (2021). SikuBERT (Version 2.0) [Computer software]. Nanjing Agricultural University. https://huggingface.co/SIKU-BERT/sikubert, https://github.com/hsc748NLP/SikuBERT-for-digital-humanities-and-classical-Chinese-information-processing, https://gitee.com/onesleepyjoker/SikuBERT-for-digital-humanities-and-classical-Chinese-information-processing
- Wu, L. 吴留营 (2022). 琉球汉诗选 [Anthology of Ryukyu Sinitic Poetry] (1st ed). 江西教育出版社 [Jiangxi Education Press].
- Huxley, T. H. (1898). 天演論 [Theory of Evolution] (F. Yan, Trans.). In 譯例言 [Evolution and Ethics] (Digitized ed.). Wikisource. https://zh.wikisource.org/wiki/%E5%A4%A9%E6%BC%94%E8%AB%96/%E8%AD%AF%E4%BE%8B%E8%A8%80
- Yan, Y. (2023). 越南汉诗选 [Anthology of Vietnamese Sinitic Poetry] (1st ed, Vols 1–2). 江西教育出版社 [Jiangxi Education Press].

# Acknowledgements
As I am not experienced with API usage, ChatGPT 5.1 was used to assist the creation of this work.

Thank you to Maxim Klyashtornyy 修朙 for their incredible assistance in the development of the variant mapping used in this project. I also thank them for their persistent, patient, and insightful feedback to ensure the quality of this work.

# Licence
Wikisource distributes its texts under a [Creative Commons Attribution-ShareAlike 4.0 (CC BY-SA) Licence](https://creativecommons.org/licenses/by-sa/4.0/). Therefore, this code is also provided under that licence. See the [Legal Code](https://creativecommons.org/licenses/by-sa/4.0/legalcode.en) and [LICENCE](/LICENCE) for more information.