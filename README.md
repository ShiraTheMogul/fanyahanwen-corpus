# 泛亞漢文語料庫 pan-Asian Literary Chinese Corpus (PALCC)

This is a Literary Chinese corpus that represents the language as a pan-Asian lingua franca. It includes a significant body of major, gigantic Chinese texts (Yongle Encyclopaedia's extant transcriptions, Siku Quanshu, etc), and adds texts from Japan, Korea, the Ryukyu Islands, and Vietnam, all of which used Literary Chinese at some point. With respect to China, a diachronic corpus is made; anything from the Shang to modern China, so long as they use Literary Chinese, so long as it is not under copyright or equivalent, is acceptable here. Translations into Literary Chinese are included, accepted, and encouraged. As Yan Fu had said in his translation of Huxley's Theory of Evolution: 「一、譯事三難：信、達、雅。求其信已大難矣，顧信矣不達，雖譯猶不譯也，則達尚焉。」 they must be faithful, fluent, and beautiful. It is very difficult to earn a reader's trust, but if a translator is concerned about it, they will not reach it. There is no reason to exclude such well-thought-out work.

I extend a heartfelt thank you to the tireless contributors at Wikisource for its astounding quantity of Literary Chinese works. To transcribe even a fraction of the leviathan that us Siku Quanshu is a truly remarkable feat, let alone everything else. I have nothing but the utmost respect for those anyone doing any of this for free, let alone releasing it in such an accessible fashion, thus why I chose it. 

This originally began as a corpus of Siku Quanshu 四庫全書 sources taken from Wikisource, plus additional files. It checks all pages on the ZH Wikisource with `Category:四庫全書` and their throughlinks, as well as those on the main 四庫全書 page with "四庫全書" in their name, to construct a corpus for research purposes.  At the time of creation, 3,368 out of 3,593 titles within the text had been digitized (though not all are completely transcribed). This was not the first Siku Quanshu corpus to be made, but in absence of a freely-available or accessible one - a corpus made in 1999 is paid software, and rightfully so, it was one of the first digitization of the work! - I initially decided to make a publicly available one. However, I have not seen a corpus that adds more beyond Siku Quanshu, and so I expanded it to include more texts. 

A Chengyu list by Aun (2025) is included as well. 

The given scripts will output CSV, TSV, and JSON indexes for auditing. 

# On categories
Works are categorised by major nation. With respect to China, Wikisource's dynasty divisions are used. I went from earliest/leftmost categories on their [dynasty division template](https://zh.wikisource.org/wiki/Template:%E6%8C%89%E7%85%A7%E6%9C%9D%E4%BB%A3%E5%88%86%E7%B1%BB) after downloading Siku Quanshu with automatic de-duplication implemented. I did this for efficiency and ease of scraping. I will not pretend to be a historian here, and any disputes regarding any of these divisions (e.g. The two pieces of Tang dynasty literature that was within Empress Wu of Zhou's reign) would fall outside of the data scope to me. 

# Siku Quanshu Scraper

## Usage
This program is usable from CLI and the Python Shell.

### Dependencies
Use this before running anything Python-related:
```bash
pip install requests bs4 opencc
```

A lot of filenames are also really really long, so on Windows, you'll want to run your cmd as administrator and smack this in;
```cmd
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v "LongPathsEnabled" /t REG_DWORD /d 1 /f
```


### Run
```bash
python skqs_scraper.py
```
Append `--test` to scrape the first 5 works it finds and see how you like it.

### Parameters
```
TEST_MODE = True
MAX_WORKS = 5
SLEEP_SECONDS = 0.5
SCRAPE_EMPTY_PAGES = True
```
Because some pages are empty, there is an option for whether or not to scrape those pages in `SCRAPE_EMPTY_PAGES`. If you choose to scrape them, it will append `is_empty` to `index.csv` for navigation. Made optional rather than outright cutting for auditing purposes; I consider this itself data.

#### Recommended settings
```
TEST_MODE = False
SLEEP_SECONDS = 1.0
SCRAPE_EMPTY_PAGES = True
```
Please rate-limit the requests to respect the contributors and Wikisource servers. You must also comply with Wikisource's [CC BY-SA 4.0 Licence](https://creativecommons.org/licenses/by-sa/4.0/) when using or redistributing texts.

## File Structure
Naming conventions go as follows:
```
<work_display_title>__juan_<NN>.txt
```

Two directories are outputted automatically:
```
siku_quanshu_corpus/
  ├── raw/         ← minimally processed Wikisource extraction
  ├── clean/       ← lightly normalized text (templates removed, PD notices stripped, etc.)
  ├── index.csv    ← CSV index (UTF-8 BOM; Excel-friendly)
  ├── index.tsv    ← TSV index (UTF-8 BOM)
  └── index.json   ← JSON index (pretty, structured, recommended for programmatic use)
  ```
`raw/` describes the text as it appears from the API, including all details. `clean/` removes templates, user-created notes, and Public Domain notices, making it easier for research. As a reader, I recommend `raw/`; as a researcher, I recommend `clean/`. Because some texts I have added are from a personal archive, these files do not have raws and only occur in `clean/`.

### Inner Directories
Saved pages go into four folders based on Siku Quanshu's broad categories, each with their own subcategories, which is reflected in the corpus for accuracy and stylistic analysis. 
- Classics 經部 (755 texts) - Classical texts as defined by Confucius, along with commentaries from the Han to Ming dynasties, including Neo-Confucianist texts.
- Histories 史部 (365 texts) - Historical documents; this includes anything from annals to biographies, seasonal records, and catalogues.
- The Masters 子部 (998 texts) - A broad stroke of philosophy, arts, and sciences; Legalism, Daoism, Buddhism, and Confucianism are covered (albeit with censorship of Buddhist and Daoist texts), as well as military strategy, healthcare, divination, encyclopaedias, and novels. 
- Belle-Lettres 集部 (1260 texts) - Predominantly poetry and literary critique of it; texts that are not in the above categories.

For example:
```
siku_quanshu_corpus/
  raw/
    經部/                    ← top-level SKQS section (jing, shi, zi, ji)
      小學類/                ← category1 (broad interior category)
        訓詁之屬/            ← category2 (finer interior category)
          爾雅注疏/          ← work folder (safe / normalised title)
            爾雅注疏__juan_01.txt
            爾雅注疏__juan_02.txt
            …
      … other categories / works …
    史部/
    子部/
    集部/
    Uncategorized/           ← works with no reliable section/category info (GitHub ver. is manually organised post-download)
      三因極一病證方論/
        三因極一病證方論__juan_01.txt
        …

  clean/
    經部/
      小學類/
        訓詁之屬/
          爾雅注疏/
            爾雅注疏__juan_01.txt
            …
    史部/
    子部/
    集部/
	四庫全書總目提要/ ← *Siku Quanshu Zongmu Tiyao* "Annotated Bibliography of the Four Treasuries," made a year post-publication to describe contents in brief.
      ...

  index.csv  ← metadata in comma-separated form
  index.tsv  ← metadata in tab-separated form
  index.json  ← pretty version
```

## Index
The index is manifested in `index.csv`, `index.tsv`, and `index.json` form. 

```
| Column             | Description                                    |
| ------------------ | ---------------------------------------------- |
| `work_title`       | Name of the work                               |
| `pageid`           | Wikisource page ID                             |
| `page_title`       | Subpage (e.g., `三因極一病證方論/卷八`)     |
| `juan_index`       | Position in reading order (01, 02, 03...)      |
| `raw_path`         | File path to RAW text (or empty if skipped)    |
| `clean_path`       | File path to CLEAN text (or empty if skipped)  |
| `char_count_raw`   | Character length of the extracted text         |
| `char_count_clean` | Character length after cleaning                |
| `is_empty_page`    | `1 = empty or incomplete` page from Wikisource |
| `author`    		 | The text's stated author.					  |
| `times`    		 | The text's stated time period (e.g. Song 宋)	  |
```

e.g.
```
{
  "work_title": "三因極一病證方論",		← Title of the work.
  "display_title": "三因極一病證方論",		← Display title seen on Wikisource (in case it differs)
  "section": "子部",						← Broad category
  "category1": "醫家類",					← Upper category
  "category2": "方書之屬",				← Lower category
  "author": "陳言",						← Authorship (for stylometry, % of works being from x author, etc)
  "times": "宋",							← Time period or location (for diachronics)
  "pageid_work": 762009,
  "pageid_juan": 762010,
  "juan_index": 1,
  "juan_title": "三因極一病證方論/卷一",
  "raw_path": "raw/子部/醫家類/方書之屬/三因極一病證方論/三因極一病證方論__juan_01.txt",
  "clean_path": "clean/子部/醫家類/方書之屬/三因極一病證方論/三因極一病證方論__juan_01.txt",
  "is_empty": false						← Whether the chapter is empty (for auditing)
}
```

# Special Works Scraper

A more elaborate scraper that grabs works with varying modes. It is a little scattered, but if you add stuff to `WORKS` it'll grab it off Wikisource. It is built from the Siku Quanshu script, so assume the structure and stuff above is what happens. 

# 正字 Zhengzi & 正名 Zhengming

These are cleaners; Zhengzi erases non-Han script characters, Zhengming is a mass renamer in case you mess up a scrape and don't want to face the consequences. 

# Corpus Summariser

After scraping, you can generate a summary report:

```bash
python skqs_summary.py siku_quanshu_corpus/index.csv
```

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
- Aisin-Gioro H., Ji Y., & Lu X. (Eds). (2007). 四庫全書 [Complete Library of the Four Treasuries] (Vol. 1–36,381). Wikisource. https://zh.wikisource.org/wiki/%E5%9B%9B%E5%BA%AB%E5%85%A8%E6%9B%B8
- Aun, C. (2025). Cheeaun/chengyu-wordle [JavaScript]. https://github.com/cheeaun/chengyu-wordle (Original work published 2022)
- Behr, W. (2008). Dialects, diachrony, diglossia or all three? Tomb text glimpses into the language(s) of Chǔ [Lecture].
- Editorial Board of the Encyclopedia of China. (2009). 《四庫七閣·四庫全書·四庫全書總目提要》. In 中国大百科全书 [Encyclopedia of China] (2nd ed). 中國大 [China Publishing House].
- Dai, L., Li, T., Yang, Y., Jia, L., Magically Asia Limited, TudorTech System Co., Ltd, & Founder Electronics Company Limited. (1999). Siku Quanshu Online (Version 3.0 (Wenyuange Ed.)) [Computer software]. Digital Heritage Publishing Ltd, East View Information Services. http://skqs.com/
- Guy, R. K. (1987). The emperor’s four treasuries: Scholars and the state in the late Chʻien-lung era. Council on East Asian Studies, Harvard University.
- Matsumoto J. (2025). 日本漢文の世界 [Nihon kanbun no sekai]. Kambun.jp. https://kambun.jp/
- Meng, K. (2016). 孟子 [The Works of Mencius] (J. Legge & Y. Shi., Trans.; 1st ed.). 中州古籍出版社 [Zhongzhou Ancient Books Publishing House].
- Sturgeon, D. (2020). Digitizing Premodern Text with the Chinese Text Project. Journal of Chinese History, 4(2), 486–498. https://doi.org/10.1017/jch.2020.19
- Sturgeon, D. (2021). Chinese Text Project: A dynamic digital library of premodern Chinese. Digital Scholarship in the Humanities, 36(Supplement_1), i101–i112. https://doi.org/10.1093/llc/fqz046
- Wang D., Liu C., Liu L., Liu J., Hu H., Shen S., & Li B. (2022). SikuBERT与SikuRoBERTa:面向数字人文的《四库全书》预训练模型构建及应用研究 [Construction and Application of Pre-trained Models of Siku Quanshu in Orientation to Digital Humanities]. 图书馆论坛 [Literary Tribune], 42(6), 14. https://doi.org/10.3969/j.issn.1002-1167.2022.06.005
- Wang, D., Liu, C., & Zhu, Z. (2021). SikuBERT (Version 2.0) [Computer software]. Nanjing Agricultural University. https://huggingface.co/SIKU-BERT/sikubert, https://github.com/hsc748NLP/SikuBERT-for-digital-humanities-and-classical-Chinese-information-processing, https://gitee.com/onesleepyjoker/SikuBERT-for-digital-humanities-and-classical-Chinese-information-processing


# Acknowledgements
As I am not experienced with API usage, ChatGPT 5.1 was used to assist the creation of this work. 

# Licence
Wikisource distributes its texts under a [Creative Commons Attribution-ShareAlike 4.0 (CC BY-SA) Licence](https://creativecommons.org/licenses/by-sa/4.0/). Therefore, this code is also provided under that licence. See the [Legal Code](https://creativecommons.org/licenses/by-sa/4.0/legalcode.en) and [LICENCE](/LICENCE) for more information.
