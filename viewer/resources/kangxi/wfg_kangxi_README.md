# WFG 《康熙字典》 resource

This resource is the source-backed Kangxi dictionary dataset used by the generic Fanya Dictionary Catalogue and by the site's Kangxi character standards.

## Provenance

WFG (Digital Ed.; with Wang, Zhipan 王志攀 / 中華開放古籍協會 and suns99). (2018). 《康熙字典》 [MDict digital edition]. Created 2018-12-12. Based on Wang, Zhipan 王志攀's 《開放康熙》, with WFG's reorganisation, additions and comparison against the 康熙五十五年內府刊本（武英殿刻本）, 同文書局影印本, Wang, Yinzhi 王引之 《康熙字典考證》愛日堂藏本, and 《康熙字典：標點整理本》 (上海辭書出版社, 2008). The package metadata credits 漢典 for image material and records WFG editions in 2015 and 2016, followed by a WFG + suns99 second edition in 2017.

The WFG package identifies the underlying open dataset as CC BY-SA 3.0 and records 漢典 image contributions as CC0 1.0. This derived resource retains that attribution. See https://creativecommons.org/licenses/by-sa/3.0/ and https://creativecommons.org/publicdomain/zero/1.0/ .

Original package digests:

- MDX SHA-256: `562708a52c71ac4395a3155b292e8cd78dcc0d8532a7522632e289bc51dae036`
- MDD SHA-256: `deb0dcefcfaa00d7a13b215a036f8a3bb96a5b7b58da7587786b0358d69541b7`
- Derived SQLite SHA-256: `a118dae8e4efc50b36f63690667977d826c49e433ce3375f0604cfd65e69d2e7`

## Contents

`wfg_kangxi.sqlite3` is read-only application data. It contains:

- 47,043 numbered Kangxi headword occurrences, serials 1–47,043 without gaps;
- 2,881 structured aliases (古文, 異體, redirects, and one WFG digital-key rectification alias);
- 100,216 ordered definition/correction blocks (57,414 音, 40,225 例, 2,577 考證);
- 47,853 original MDD resources, including all 47,043 headword GIFs, stored byte-for-byte;
- 武英殿、同文書局、標點整理本、愛日堂 source coordinates where supplied by WFG;
- WFG-local PUA identities retained for dictionary/search provenance, never emitted as ordinary Character Standard output.

The resource deliberately keeps occurrence identity. WFG's 46,976 primary records contain 67 records with a second printed occurrence, giving the 47,043 Kangxi occurrences. Fifteen 補遺 records encode the radical label plus additional-stroke count in WFG's 部外筆畫 field (for example `山部11`) and put the radical stroke count in the following field; Fanya preserves those raw values while deriving the usable additional and total stroke counts.

## Digital rectification

WFG serial 10,286 (`㩮`) has an empty internal headword field even though its record key and `\3A6E.gif` source image identify U+3A6E `㩮`; Fanya uses that confirmed record key as the interoperable headword.

WFG serial 24,335 is keyed as `腘`, while its headword image (`\8158.gif`) and the Kangxi entry represented by that image identify `𦛢` U+266E2. Fanya stores the dictionary headword as `𦛢` and retains `腘` as an alias of kind `WFG數位字頭`. This is a correction to the modern digital key; it does not rewrite the historical Kangxi source.

## Character Standards

`viewer/config/kangxi_standard.tsv` contains only executable one-character conversion rules. It uses WFG redirects, structured alias-only forms, and headword entries whose whole definition is an unambiguous orthographic cross-reference; polysemous and conflicting relationships are omitted. Input first passes through OpenCC Standard Traditional, then this map is applied.

`viewer/config/kangxi_ancient.tsv` is a separate 古文 preference layer. It takes the first portable Unicode 古文 in WFG source order after Kangxi canonicalisation. Image-only/PUA forms remain dictionary data and are not emitted in plain text.

WFG's 考證 material is exposed in the dictionary browser. It is not automatically converted into a global “rectified” character standard: those records include quotation, reading and textual corrections and do not constitute a complete character-form mapping.
