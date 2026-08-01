# Jejueo source register

## Purpose

This note records the evidence used for the first Sino-Jejueo character-reading import and separates material that is ready for database use from material that still needs acquisition or textual review.

## Modern linguistic sources

### Yang, Yang & O’Grady, *Jejueo: The Language of Korea’s Jeju Island*

- Bibliographic form used by the importer: Changyong Yang, Sejung Yang, and William O’Grady. 2020. *Jejueo: The Language of Korea’s Jeju Island*. Honolulu: University of Hawai‘i Press.
- Data used here: the Koreanic and Chinese number table supplied in `Sino-Jejueo.xlsx`, checked against the published table.
- Correction made during review: `三 ᄉᆞᆸ` was corrected to `三 ᄉᆞᆷ`; the modern alternate is `삼`, not `십`.
- Publisher page: https://uhpress.hawaii.edu/title/jejueo-the-language-of-koreas-jeju-island/

### Jejueo-English Basic Dictionary

- Prepared by Changyong Yang, William O’Grady, and Sejung Yang to accompany the book.
- Data used here: `漢拏山 할락산 hallagsan`.
- Dictionary: https://sites.google.com/a/hawaii.edu/jejueo/jejueo-english-basic-dictionary-%EC%A0%9C%EC%A3%BC%EC%96%B4-%EC%98%81%EC%96%B4-%EA%B8%B0%EC%B4%88-%EC%82%AC%EC%A0%84
- The reported total of 53 Chinese loans has **not** yet been treated as verified corpus data. The exact list or its underlying source must be obtained first.

### *A Sketch Grammar of Jejueo*

- Authors: William O’Grady, Sejung Yang, and Changyong Yang.
- Use: project-wide reference for phonology, morphophonology, grammatical terminology, spelling, and interpretation of the dictionary’s romanisation.
- Guide page: https://sites.google.com/a/hawaii.edu/jejueo/a-sketch-grammar-of-jejueo
- This source is documentation, not blanket permission to infer unattested Hanja readings.

## Historical Literary Chinese sources

### 濟州風土錄

- Correct title: `濟州風土錄`, not `濟州島風土錄`.
- Author: 金淨 (Kim Jeong).
- Location: `冲庵集` / `冲庵先生集`, 卷四.
- Composition: apparently written in 1521 as a reply after the author’s exile to Jeju beginning in 1520.
- Edition history: the first edition of the collected works was printed in 1552; this is distinct from the date of composition.
- Contents include climate, housing, beliefs, speech, customs, geography, products, flora, fauna, and the author’s experience of exile.
- Full transcription: https://zh.wikisource.org/zh/%E5%86%B2%E5%BA%B5%E5%85%88%E7%94%9F%E9%9B%86/%E5%8D%B7%E5%9B%9B
- A 17-page facsimile extract has been prepared separately as `濟州風土錄_冲庵先生集卷四_影印.pdf`.

#### Corpus warning

This is an unusually valuable early witness, but it is not a neutral ethnography. Kim Jeong writes as an exiled mainland literatus and often judges Jeju through a strongly normative Confucian framework. Descriptions and lexical evidence should be preserved; his evaluations should not be silently converted into corpus facts.

There is also published textual-critical work showing that modern fair copies of `濟州風土錄` can contain misread characters. The scan, the chosen transcription, and any emendations therefore need separate provenance.

### 南槎錄

- Correct title: `南槎錄`; `南差錄` is a graphic substitution.
- Author: 金尙憲 (Kim Sang-heon).
- Record described: his Jeju mission and stay in 1601–1602.
- Edition history: a first printed edition is commonly dated 1669; that is not the date of the journey.
- Value: diary-form evidence concerning Jeju administration, society, customs, natural environment, economy, language, local names, and earlier written sources.
- Modern annotated edition: 제주문화원, `역주 남사록 상` (2008) and `역주 남사록 하` (2009). The upper volume is described as including a facsimile.
- Upper-volume catalogue page: https://jejucc.kr/data/ebook.htm?act=view&page=11&seq=626
- Lower-volume catalogue page: https://jejucc.kr/data/ebook.htm?act=view&page=11&seq=628

#### Acquisition status

The work has been identified bibliographically, but the actual facsimile or ebook file has not yet been acquired in this work package. Do not create a corpus document from catalogue prose alone.

## Database modelling rule

A syllable segmented from a Hanja compound is **not automatically a general standalone reading of that character**.

For example, `漢拏山 할락산 hallagsan` supports these contextual segments:

- 漢 — 할 — hal
- 拏 — 락 — lag
- 山 — 산 — san

Those values are stored in `compound_*` fields and retain the full attestation. They are not stored as unrestricted direct readings. This prevents the dictionary from claiming, without evidence, that Jejueo generally reads `漢` as `할` in every context.
