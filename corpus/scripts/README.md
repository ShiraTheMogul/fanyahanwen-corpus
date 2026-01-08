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