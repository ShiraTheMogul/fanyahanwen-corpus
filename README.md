# 泛亞漢文語料庫 pan-Asian Literary Chinese Corpus (PALCC)

This is a Literary Chinese corpus that represents the language as a pan-Asian lingua franca. It includes a significant body of major, gigantic Chinese texts (Yongle Encyclopaedia's extant transcriptions, Siku Quanshu, etc), and adds texts from Japan, Korea, the Ryukyu Islands, and Vietnam, all of which used Literary Chinese at some point. With respect to China, a diachronic corpus is made; anything from the Shang to modern China, so long as they use Literary Chinese, so long as it is not under copyright or equivalent, is acceptable here. Translations into Literary Chinese are included, accepted, and encouraged. As Yan Fu had said in his translation of Huxley's Theory of Evolution: 「一、譯事三難：信、達、雅。求其信已大難矣，顧信矣不達，雖譯猶不譯也，則達尚焉。」 they must be faithful, fluent, and beautiful. It is very difficult to earn a reader's trust, but if a translator is concerned about it, they will not reach it. There is no reason to exclude such well-thought-out work.

I extend a heartfelt thank you to the tireless contributors at Wikisource for its astounding quantity of Literary Chinese works. To transcribe even a fraction of the leviathan that is Siku Quanshu is a truly remarkable feat, let alone everything else. I have nothing but the utmost respect for those anyone doing any of this for free, let alone releasing it in such an accessible fashion, thus why I chose to do this initially.

This originally began as a corpus of Siku Quanshu 四庫全書 sources taken from Wikisource, plus additional files. It checks all pages on the ZH Wikisource with `Category:四庫全書` and their throughlinks, as well as those on the main 四庫全書 page with "四庫全書" in their name, to construct a corpus for research purposes.  At the time of creation, 3,368 out of 3,593 titles within the text had been digitized (though not all are completely transcribed). This was not the first Siku Quanshu corpus to be made, but in absence of a freely-available or accessible one - a corpus made in 1999 is paid software, and rightfully so, it was one of the first digitization of the work! - I initially decided to make a publicly available one. However, I have not seen a corpus that adds more beyond Siku Quanshu, and so I expanded it to include more texts. 

The given scripts will output CSV, TSV, and JSON indexes for auditing. 

# Statistics
As of 31st January 2026, the corpus contains 744,312,022 characters, comprised of 172,613 chapters amongst 81,323 distinct works. Works range from Wu Ding's reign during the Shang dynasty all the way to works produced this year, from over 10 different countries. This makes it the most inclusive Literary Chinese corpus that I am aware of.

The largest texts are generally encyclopaedias and histories. For example, what remains of the the Yongle Encyclopaedia contains 313,103,58 characters. The History of Korea reaches 57,319,61. 

# On categories
Works are categorised by major nation. With respect to China, Wikisource's dynasty divisions are used. I went from earliest/leftmost categories on their [dynasty division template](https://zh.wikisource.org/wiki/Template:%E6%8C%89%E7%85%A7%E6%9C%9D%E4%BB%A3%E5%88%86%E7%B1%BB) after downloading Siku Quanshu with automatic de-duplication implemented. I did this for efficiency and ease of scraping. I will not pretend to be a historian here, and any disputes regarding any of these divisions (e.g. The two pieces of Tang dynasty literature that was within Empress Wu of Zhou's reign) would fall outside of the data scope to me. 

## How do we know it is Literary Chinese?
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

The tester could be much, MUCH better, but I wanted something quick and dirty to get some decent filtering in. Anything that failed this test goes into `suspected_baihua`, wherein it is subject to human testing to see if it is or not. This is to ensure no early topolect usage gets into the corpus by mistake. This is also useful for diachronic study, of course, so anything that outright fails stays there. As of 22nd Nov '25, I have not yet looked at these myself.

# 關於四庫全書 About Siku Quanshu
Given the historical nature of this work, I feel the need to give a brief overview of the sheer scope of the original work. This is not just a massive amount of text: It is a leviathan comprised of the very essence of historical Chinese literature. The numbers that went into this work are dizzyingly high. *Siku Quanshu* 四庫全書 "The Complete Library of the Four Treasuries" was originally produced in 1782 under the directive of the Qianlong Emperor 乾隆帝 Aisin-Gioro Hongli 愛新覺羅·弘曆 of the Great Qing 大淸. It is one of the largest corpora in the world, with over 3,593 titles of 79,000 *juàn* 卷 (volumes), comprising 2,300,000 pages totalling almost a billion characters. This was during a time before the printing press, so a 361-man review board defined texts that over 3,000 scribes diligently transcribed by hand, rewarded with government positions for their efforts. Only 7 copies were ever made, of which 4 remain in museums across China; one was destroyed during the Second Opium War in 1860, and two were destroyed whilst another damaged during the Taiping Rebellion. Thanks to the others being preserved into the modern day, it has been digitized in proprietary software, allowing it to continue existing for years to come. The work built on previous corpora, including the *Song Si Dashu* 宋四大書 "Four Great Books of Song" and *Yongle Dadian* 永樂大典 "Yongle Encyclopaedia" made in the Ming dynasty. It also came with an Annotated Bibliography named *Siku Quanshu Zongmu Tiyao* 四庫全書總目提要 "Annotated Bibliography of the Four Treasuries," which has been preserved on the Chinese Text Project. Some parts of this have been added to the corpus from Wikisource, but it has not been considered a hard requirement.

It is a somewhat biassed corpus: Anti-Qing, anti-Manchu, pro-Ming, and other "undesirable" ideologies, including several Daoist and Buddhist texts, were not preserved in this corpus. Despite this, odd texts such as the *Shanhaijing* 山海經 "Classic of Mountains and Seas" can still be found; it seems censorship was quite rare. In total, 2,855 texts were rejected; ergo, while this could have been a 6,448-text corpus, it is simply a 3,593 one (still impressive!). Furthermore, Siku Quanshu does not contain many non-Chinese Literary Chinese texts; Vietnamese, Japanese, Korean, and Ryukyuan texts are largely absent. You will not find, say, Chūzan Seifu 中山世譜 by Sai On 蔡温 in this text, despite it being written in Literary Chinese and a good fit for the Histories category. However, texts such as *Joseon Ji* 朝鮮志 조선지 "Records of Joseon" and *joseonsalyag-yag* 朝鮮史略 조선사 략 약 "A Brief History of Korea" by Ha Ryun 河崙 하륜 do exist, the former case alleged by the editors to be written by a Korean author. Therefore, this corpus should not simply be taken as a monolith of Chinese data, but it will be biased and pro-Qing, pro-Manchu in nature.

Thanks to the digitization of this text, it has been used in numerous corpus linguistic studies and the development of pre-trained AI models such as SikuBERT. Its abundant variety in Literary Chinese prose and genres. 

# 關於欽定古今圖書集成 About the Complete Classics Collection of Ancient China
This is a work so large it was excluded from Siku Quanshu! It is an encyclopaedia similar to the Yongle Encyclopaedia. Begun in 1700 and finished in 1725, it contains over 800,000 pages and 100,000,000 Han characters. The chief architects behind the work were Chen Menglei 陳夢雷 and Jiang Tingxi 蔣廷錫, hired by Aisin-Gioro Huanye 愛新覺羅·玄燁 the Kangxi Emperor 康熙帝, and Aisin-Gioro Yinzhen 愛新覺羅·胤禛 the Yongzheng Emperor 雍正帝 respectively. It contains astrological, geographic, societal, natural, philoophical, educational, and economic content, all of significant diversity. 

# 關於永樂大典 About the Yongle Encyclopaedia 
This is essentially Siku Quanshu before Siku Quanshu existed. It was produced during in 1408 during the Ming dynasty, containing over 11,000 volumes produced by over 100 scholar-officials. Wikipedia surpassed its sheer scale in late 2007: Prior to this, it was the largest encyclopaedia in the world. Only a few copies were ever made; the Jiajing Emperor 	嘉靖帝 Zhu Huocong 朱厚熜 commissioned a copy of it in 1562 and it would be finished 5 years later. Because the original was lost, what we have here is based on that copy. However, only around 400 volumes of this copy exist today, as it was mostly destroyed during the Second Opium War by the English and French, and even more of it during the Boxer Rebellion. Many that were not destroyed were looted by soldiers. What exists today is likely all that will be found. At least one work in Siku Quanshu is recorded as having been found in the Yongle Encyclopaedia of the time, and was chosen to be added to the former: *yùzhì tí jié zhāi máo shījīng yán jiǎngyì* 御製題絜齋毛詩經筵講義 "Imperial Inscription on the Lectures of the Mao Classic of Poetry at the Jiezhai Academy". 

# Limitations
While this is a dizzying level of information, some limitations exist:
- A lot of Wikisource's texts are unpunctuated. While accurate, this will not be representative of how contemporary Literary Chinese is read.
- OCR errors from preliminary documentation of some works may exist. 
- Transcription prejudices by contributors may exist (e.g. A more common character may be used over what the actual text has). This is rare.
- When starting out, I did not account for 第 chapters, only 卷 chapters. Therefore, some works may have slipped through the cracks. I'll probably fix this eventually.
- There may be some Early Mandarin works amongst all this. I do have a topolect-scoring system, but only used it for Yuan, Ming, and Qing dynasty literature as it is outright necessary.
- Chu speech is argued to potentially be a distinct language: Mencius particularly speaks to this effect. However, it remains included in this work as this matter is not *fully* established yet; I am not an expert on this matter, I just know it is discussed and that this corpus may be of use for it. For information, view the bibiography.

# Possible improvements
- Improved identification of authors and locations via regex: Right now, we use boilerplates that directly state author and dynasty/time/location which are not used on every page. Possibility for many, MANY false flags left this out for now. Manual addition is difficult given the sheer amount of works. 
- Gathering of the rejected Siku Quanshu texts (Referred to tongue-in-cheek as Siku Jinshu 四庫禁書) to form an unredacted corpus. A reconstruction called 四庫禁燬書叢刊 exists, has 19+ chapters, and is in the Public Domain, but has not been fully transcribed save for 皇明通紀. https://zh.wikisource.org/wiki/%E7%9A%87%E6%98%8E%E5%BE%9E%E4%BF%A1%E9%8C%84
- Find a reliable way to OCR the many PDFs that have not been transcribed. 
- Add Qing dynasty translations of western texts (e.g. 天演論, 歇洛克奇案開場...)

# Bibliography
The following texts were used or otherwise had an influence in the making of the website, the corpus, and more.

- Aisin-Gioro H., Ji Y., & Lu X. (Eds). (2007). 四庫全書 [Complete Library of the Four Treasuries] (Vol. 1–36,381). Wikisource. https://zh.wikisource.org/wiki/%E5%9B%9B%E5%BA%AB%E5%85%A8%E6%9B%B8
- Aun, C. (2025). Cheeaun/chengyu-wordle [JavaScript]. https://github.com/cheeaun/chengyu-wordle (Original work published 2022)
- Behr, W. (2008). Dialects, diachrony, diglossia or all three? Tomb text glimpses into the language(s) of Chǔ [Lecture].
- Editorial Board of the Encyclopedia of China. (2009). 《四庫七閣·四庫全書·四庫全書總目提要》. In 中国大百科全书 [Encyclopedia of China] (2nd ed). 中國大 [China Publishing House].
- Dai, L., Li, T., Yang, Y., Jia, L., Magically Asia Limited, TudorTech System Co., Ltd, & Founder Electronics Company Limited. (1999). Siku Quanshu Online (Version 3.0 (Wenyuange Ed.)) [Computer software]. Digital Heritage Publishing Ltd, East View Information Services. http://skqs.com/
- Guy, R. K. (1987). The emperor’s four treasuries: Scholars and the state in the late Chʻien-lung era. Council on East Asian Studies, Harvard University.
- Han, D. (2022). 朝鲜汉诗选 [Anthology of Korean Sinitic Poetry] (1st ed). 江西教育出版社 [Jiangxi Education Press].
- Lee, J., & Jung, Y. (2025). A Variant Character Dataset for Historical Narratives of Middle and Late Imperial China. Journal of Open Humanities Data, 11, 33. https://doi.org/10.5334/johd.325
- Lichtman, K., & VanPatten, B. (2021). Was Krashen right? Forty years later. Foreign Language Annals, 54(2), 283–305. https://doi.org/10.1111/flan.12552
- Matsumoto J. (2025). 日本漢文の世界 [Nihon kanbun no sekai]. Kambun.jp. https://kambun.jp/
- Meng, K. (2016). 孟子 [The Works of Mencius] (J. Legge & Y. Shi., Trans.; 1st ed.). 中州古籍出版社 [Zhongzhou Ancient Books Publishing House].
- qwert-ly. (2026). Qwert-ly/xtext: Basic nlp(?) of classical Chinese (Version 1.0) [Python, VBA]. https://github.com/Qwert-ly/xtext
- Shi, K. (Ed.). (2024). 日本汉诗选 [Anthology of Japanese Sinitic Poetry] (1st ed, Vols 1–2). 江西教育出版社 [Jiangxi Education Press].
- Sturgeon, D. (2020). Digitizing Premodern Text with the Chinese Text Project. Journal of Chinese History, 4(2), 486–498. https://doi.org/10.1017/jch.2020.19
- Sturgeon, D. (2021). Chinese Text Project: A dynamic digital library of premodern Chinese. Digital Scholarship in the Humanities, 36(Supplement_1), i101–i112. https://doi.org/10.1093/llc/fqz046
- Trilateral Cooperation Secretariat. (2015). 中日韩共同常用八百八汉字表 [Booklet of the 808 Commonly Used Chinese Characters in China, Japan and the ROK]. Trilateral Cooperation Secretariat.
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
