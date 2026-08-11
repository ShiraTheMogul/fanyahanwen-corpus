#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import importlib.util
from pathlib import Path
import sys
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "wiktionary_chengyu_scraper.py"
spec = importlib.util.spec_from_file_location("wiktionary_chengyu_scraper", MODULE_PATH)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
assert spec.loader
spec.loader.exec_module(mod)


def raw_page(site, title, text, source_categories=None, pageid=1):
    return {
        "site": site,
        "pageid": pageid,
        "title": title,
        "url": f"https://example.invalid/{title}",
        "source_keys": ["test"],
        "source_categories": source_categories or [],
        "categories": [{"title": value} for value in (source_categories or [])],
        "revision": {"revid": 10, "timestamp": "2026-01-01T00:00:00Z", "sha1": "x"},
        "wikitext": text.strip(),
    }


class WiktionaryChengyuScraperTest(unittest.TestCase):
    def test_source_inventory_contains_all_agreed_wikis(self):
        keys = {source.key for source in mod.SOURCE_SEEDS}
        self.assertIn("en_chinese_chengyu", keys)
        self.assertIn("en_chengyu_by_language", keys)
        self.assertIn("zh_han_chengyu", keys)
        self.assertIn("en_japanese_yojijukugo", keys)
        self.assertIn("ja_yojijukugo", keys)
        self.assertIn("en_korean_four_character", keys)
        self.assertIn("ko_hanja_idioms", keys)

    def test_parse_english_multilanguage_page(self):
        text = """
==Chinese==
===Etymology===
From {{w|Mencius}}.
===Idiom===
# to force something to grow too quickly
====Descendants====
* {{desc|ko|화룡점정}}

==Korean==
===Etymology===
Sino-Korean from 畵龍點睛.
===Noun===
화룡점정 • (hanja 畵龍點睛)
# finishing touch
""".strip()
        sections = mod.parse_sections(text)
        self.assertEqual([s.language_tag for s in sections[:3]], ["zh", "zh", "zh"])
        self.assertTrue(any(s.language_tag == "ko" for s in sections))
        self.assertTrue(any(s.kind == "etymology" for s in sections))
        korean = [s for s in sections if s.language_tag == "ko" and s.kind == "definitions"][0]
        self.assertEqual(mod.definition_lines(korean, "enwiktionary"), ["finishing touch"])

    def test_japanese_template_headings_are_resolved_but_raw_heading_is_preserved(self):
        text = """
=={{L|ja}}==
==={{idiom}}===
# 一つの事で多くの利益を得る事。
===={{etym}}====
英語のことわざの翻訳。
""".strip()
        sections = mod.parse_sections(text)
        self.assertEqual(sections[0].raw_heading, "{{L|ja}}")
        self.assertEqual(sections[0].heading, "Japanese")
        self.assertEqual(sections[0].language_tag, "ja")
        self.assertEqual(sections[1].raw_heading, "{{idiom}}")
        self.assertEqual(sections[1].kind, "definitions")
        self.assertEqual(sections[2].kind, "etymology")

    def test_parse_japanese_plain_headings_still_works(self):
        text = """
==日本語==
===成句===
# 一つの事で多くの利益を得る事。
====語源====
英語のことわざの翻訳。
""".strip()
        sections = mod.parse_sections(text)
        self.assertEqual(sections[0].language_tag, "ja")
        self.assertEqual(sections[1].kind, "definitions")
        self.assertEqual(sections[2].kind, "etymology")

    def test_korean_linked_hanja_is_recovered(self):
        raw = raw_page(
            "kowiktionary",
            "각골난망",
            """
==한국어==
===명사===
* 어원: 한자 [[刻骨難忘]]
# 잊을 수 없음.
""",
            ["분류:한국어 한자성어"],
        )
        row, *_rest = mod.extract_one(raw, "raw/kowiktionary/1.json")
        self.assertIn("刻骨難忘", row["explicit_hanja"])
        self.assertNotIn("hangul_title_without_explicit_hanja", row["source_gaps"])

    def test_korean_etymology_template_hanja_is_recovered(self):
        raw = raw_page(
            "kowiktionary",
            "고금동서",
            """
==한국어==
===명사===
{{어원|古今東西|고금동서|언어=한국어|형태=한자어 독음}}
# 옛날과 지금, 동양과 서양.
""",
            ["분류:한국어 한자성어"],
        )
        row, *_rest = mod.extract_one(raw, "raw/kowiktionary/1.json")
        self.assertIn("古今東西", row["explicit_hanja"])
        self.assertTrue(any("古今東西" in item for item in row["etymologies"]))

    def test_korean_empty_hash_then_indented_definition_is_definition_evidence(self):
        raw = raw_page(
            "kowiktionary",
            "자력갱생",
            """
==한국어==
===명사===
#
:* 다른 사람의 지원을 받지 않고 어려운 일을 잘 헤쳐나가는 것을 비유한 말
""",
            ["분류:한국어 한자성어"],
        )
        row, _sections, _templates, definitions, _relations, _pronunciations = mod.extract_one(
            raw, "raw/kowiktionary/1.json"
        )
        self.assertEqual(row["definition_evidence_count"], 1)
        self.assertEqual(row["definition_count"], 1)
        self.assertIn("어려운 일을", row["definitions"][0])
        self.assertEqual(len(definitions), 1)

    def test_korean_plain_definition_bullet_fallback(self):
        raw = raw_page(
            "kowiktionary",
            "고육지책",
            """
==한국어==
===명사===
*어원: 한자 [[苦肉之策]].
*난해한 상황을 빠져나오기 위해 어쩔 수 없이 꾸며 낸 계책을 뜻한다.
#
:*
""",
            ["분류:한국어 한자성어"],
        )
        row, *_rest = mod.extract_one(raw, "raw/kowiktionary/1.json")
        self.assertIn("苦肉之策", row["explicit_hanja"])
        self.assertEqual(row["definition_count"], 1)
        self.assertIn("난해한 상황", row["definitions"][0])

    def test_korean_etymology_link_without_hanja_label_is_hanja_evidence(self):
        raw = raw_page(
            "kowiktionary",
            "권모술수",
            """
==한국어==
===명사===
* 어원: [[權謀術數]]
# 목적 달성을 위해 수단과 방법을 가리지 않는 온갖 술책.
""",
            ["분류:한국어 한자성어"],
        )
        row, *_rest = mod.extract_one(raw, "raw/kowiktionary/1.json")
        self.assertIn("權謀術數", row["explicit_hanja"])
        self.assertNotIn("hangul_title_without_explicit_hanja", row["source_gaps"])

    def test_zh_see_poj_is_pronunciation_not_separate_lexical_definition(self):
        raw = raw_page(
            "enwiktionary",
            "put-khó-su-gī",
            """
==Chinese==
{{zh-see|不可思議|poj}}
""",
            ["Category:Chinese chengyu", "Category:Hokkien chengyu"],
        )
        row, _sections, _templates, _definitions, relations, pronunciations = mod.extract_one(
            raw, "raw/enwiktionary/1.json"
        )
        self.assertTrue(row["has_zh_see"])
        self.assertNotIn("source_page_without_definition_evidence", row["source_gaps"])
        self.assertNotIn("latin_or_ascii_title_without_pronunciation_relation", row["warnings"])
        self.assertEqual(relations[0]["normalizer_action"], "pronunciation")
        self.assertEqual(pronunciations[0]["target_form"], "不可思議")
        self.assertEqual(pronunciations[0]["reading"], "put-khó-su-gī")
        self.assertEqual(pronunciations[0]["language_tag"], "nan")
        self.assertEqual(pronunciations[0]["system"], "poj")

    def test_zh_see_explicit_variant_reason_is_kept(self):
        raw = raw_page(
            "enwiktionary",
            "一倡百和",
            """
==Chinese==
{{zh-see|一唱百和|v}}
""",
            ["Category:Chinese chengyu"],
        )
        row, _sections, _templates, _definitions, relations, _pronunciations = mod.extract_one(
            raw, "raw/enwiktionary/1.json"
        )
        self.assertTrue(row["has_zh_see"])
        self.assertEqual(relations[0]["relation_kind"], "variant")
        self.assertEqual(relations[0]["relation_cause"], "modern_variant")
        self.assertEqual(relations[0]["normalizer_action"], "ignore_nonlemma_form")

    def test_zh_see_without_type_is_preserved_but_cause_is_not_guessed(self):
        raw = raw_page(
            "enwiktionary",
            "一举两得",
            """
==Chinese==
{{zh-see|一舉兩得}}
""",
            ["Category:Chinese chengyu"],
        )
        row, _sections, _templates, _definitions, relations, _pronunciations = mod.extract_one(
            raw, "raw/enwiktionary/1.json"
        )
        self.assertEqual(relations[0]["target_form"], "一舉兩得")
        self.assertEqual(relations[0]["relation_cause"], "")
        self.assertNotIn("source_page_without_definition_evidence", row["source_gaps"])

    def test_template_only_definition_relation_is_evidence(self):
        raw = raw_page(
            "enwiktionary",
            "一去不返",
            """
==Chinese==
===Idiom===
# {{syn of|zh|一去不復返|t=gone forever}}
""",
            ["Category:Chinese chengyu"],
        )
        row, _sections, _templates, definitions, _relations, _pronunciations = mod.extract_one(
            raw, "raw/enwiktionary/1.json"
        )
        self.assertEqual(row["definition_evidence_count"], 1)
        self.assertEqual(row["definition_relation_count"], 1)
        self.assertNotIn("source_page_without_definition_evidence", row["source_gaps"])
        self.assertEqual(definitions[0]["relation_type"], "synonym_of")
        self.assertEqual(definitions[0]["relation_target"], "一去不復返")

    def test_non_gloss_template_produces_plain_definition(self):
        raw = raw_page(
            "enwiktionary",
            "哀鳴啾啾",
            """
==Japanese==
===Noun===
# {{non-gloss|sound of intense wailing}}
""",
            ["Category:Japanese yojijukugo"],
        )
        row, *_rest = mod.extract_one(raw, "raw/enwiktionary/1.json")
        self.assertEqual(row["definitions"], ["sound of intense wailing"])

    def test_hokkien_chinese_wiktionary_category_signal(self):
        labels, tags = mod.category_language_signals(["Category:泉漳話成語", "Category:漢語成語"])
        self.assertIn("Hokkien", labels)
        self.assertIn("nan", tags)
        self.assertIn("zh", tags)

    def test_deterministic_spread_sample_uses_full_range(self):
        items = [mod.PageInventory("enwiktionary", i, f"term{i:02d}", 0) for i in range(10)]
        sample = mod.deterministic_spread_sample(items, 4)
        self.assertEqual([item.title for item in sample], ["term00", "term03", "term06", "term09"])

    def test_japanese_category_meta_term_is_flagged_without_definition_warning(self):
        raw = raw_page(
            "jawiktionary",
            "四字熟語",
            "=={{L|ja}}==\n説明。",
            ["カテゴリ:四字熟語"],
        )
        row, *_rest = mod.extract_one(raw, "raw/jawiktionary/1.json")
        self.assertTrue(row["category_meta_term"])
        self.assertNotIn("source_page_without_definition_evidence", row["source_gaps"])


    def test_english_adverb_is_definition_section(self):
        raw = raw_page(
            "enwiktionary",
            "遮二無二",
            """
==Japanese==
===Adverb===
# [[madly]], [[headlong]]
# [[recklessly]], [[regardless]]
""",
            ["Category:Japanese yojijukugo"],
        )
        row, *_rest = mod.extract_one(raw, "raw/enwiktionary/1.json")
        self.assertEqual(row["definition_count"], 2)
        self.assertNotIn("source_page_without_definition_evidence", row["source_gaps"])

    def test_korean_eogu_and_ko_etym_sino_are_understood(self):
        raw = raw_page(
            "kowiktionary",
            "불언실행",
            """
== 한국어 ==
=== 어원 ===
* {{ko-etym-sino|不言實行}}
=== 발음 ===
{{ko-IPA}}
=== 어구 ===
{{ko-pos|어구|한자=不言實行}}
# {{lb|ko|한자성어}} 말이 아닌 행동을 함
""",
            ["분류:한국어 한자성어"],
        )
        row, *_rest = mod.extract_one(raw, "raw/kowiktionary/1.json")
        self.assertIn("不言實行", row["explicit_hanja"])
        self.assertEqual(row["definitions"], ["말이 아닌 행동을 함"])
        self.assertNotIn("hangul_title_without_explicit_hanja", row["source_gaps"])

    def test_korean_foreign_language_template_is_not_a_definition(self):
        raw = raw_page(
            "kowiktionary",
            "언어도단",
            """
== 한국어 ==
=== 명사 ===
*어원: 한자 [[言語道斷]].
#
:*
{{외국어|
* 독일어(de):
* 러시아어(ru):
* 영어(en):
|
* 일본어(ja):
* 중국어(zh):
}}
""",
            ["분류:한국어 한자성어"],
        )
        row, _sections, _templates, definitions, *_rest = mod.extract_one(raw, "raw/kowiktionary/1.json")
        self.assertEqual(definitions, [])
        self.assertEqual(row["definition_count"], 0)
        self.assertIn("source_page_without_definition_evidence", row["source_gaps"])

    def test_korean_unmarked_prose_definition_is_kept(self):
        raw = raw_page(
            "kowiktionary",
            "천재일우",
            """
== 한국어 ==
=== 명사 ===
천 년에 한 번 만난다는 뜻으로, 좀처럼 마주치기 어려운 좋은 기회를 뜻한다.
*어원: 한자 [[千載一遇]].
#
:*
{{외국어|* 독일어(de):}}
""",
            ["분류:한국어 한자성어"],
        )
        row, *_rest = mod.extract_one(raw, "raw/kowiktionary/1.json")
        self.assertEqual(row["definition_count"], 1)
        self.assertIn("좋은 기회", row["definitions"][0])

    def test_japanese_audit_headings_resolve_synonyms_translations_related_and_antonyms(self):
        text = """
=={{L|ja}}==
==={{idiom}}===
# 定義。
===={{syn}}====
* 類義語
===={{ant}}====
* 反義語
===={{rel}}====
* 関連語
===={{trans}}====
* 翻訳
"""
        sections = mod.parse_sections(text)
        by_raw = {section.raw_heading: section for section in sections}
        self.assertEqual(by_raw["{{syn}}"].kind, "synonyms")
        self.assertEqual(by_raw["{{ant}}"].kind, "antonyms")
        self.assertEqual(by_raw["{{rel}}"].kind, "related_terms")
        self.assertEqual(by_raw["{{trans}}"].kind, "translations")

    def test_chinese_wiktionary_localized_synonym_template_is_definition_relation(self):
        raw = raw_page(
            "zhwiktionary",
            "耳屬於垣",
            """
==漢語==
===成語===
# {{之同義詞|zh|屬垣有耳|gloss=表示有人竊聽}}
""",
            ["Category:漢語成語"],
        )
        row, _sections, _templates, definitions, *_rest = mod.extract_one(raw, "raw/zhwiktionary/1.json")
        self.assertEqual(row["definition_relation_count"], 1)
        self.assertEqual(definitions[0]["relation_type"], "synonym_of")
        self.assertEqual(definitions[0]["relation_target"], "屬垣有耳")
        self.assertNotIn("source_page_without_definition_evidence", row["source_gaps"])

    def test_japanese_alt_form_template_is_form_relation_evidence(self):
        raw = raw_page(
            "jawiktionary",
            "自画自讃",
            """
=={{L|ja}}==
==={{noun}}===
# {{alt form|ja|自画自賛}}
""",
            ["カテゴリ:四字熟語"],
        )
        row, _sections, _templates, definitions, *_rest = mod.extract_one(raw, "raw/jawiktionary/1.json")
        self.assertEqual(row["definition_relation_count"], 1)
        self.assertEqual(definitions[0]["relation_type"], "alternative_form_of")
        self.assertEqual(definitions[0]["relation_target"], "自画自賛")
        self.assertEqual(definitions[0]["relation_language"], "ja")

    def test_balanced_template_parser_keeps_nested_arguments(self):
        raw = "zh-pron|m=hua4 long2|cat={{l|zh|成語}}|foo=bar"
        name, args = mod.parse_template(raw)
        self.assertEqual(name, "zh-pron")
        self.assertEqual(args["m"], "hua4 long2")
        self.assertEqual(args["cat"], "{{l|zh|成語}}")
        self.assertEqual(args["foo"], "bar")

    def test_title_script_classification(self):
        self.assertEqual(mod.title_script_class("畫龍點睛"), "han")
        self.assertEqual(mod.title_script_class("화룡점정"), "hangul")
        self.assertEqual(mod.title_script_class("bē-phok-ké-phok"), "latin_or_ascii")
        self.assertIn("han", mod.title_script_class("畫り"))

    def test_redirect_is_preserved_not_followed(self):
        raw = raw_page("enwiktionary", "画龙点睛", "#REDIRECT [[畫龍點睛]]", pageid=2)
        row, *_rest = mod.extract_one(raw, "raw/enwiktionary/2.json")
        self.assertTrue(row["is_redirect"])
        self.assertEqual(row["redirect_target"], "畫龍點睛")


    def test_chinese_pos_and_definition_headings_are_definition_sections(self):
        raw = raw_page(
            "zhwiktionary",
            "馬革裹屍",
            """
==漢語==
===動詞===
# [[英勇]][[作戰]]，[[戰死]][[沙場]]
""",
            ["Category:漢語成語"],
        )
        row, *_rest = mod.extract_one(raw, "raw/zhwiktionary/1.json")
        self.assertEqual(row["definitions"], ["英勇作戰，戰死沙場"])

        sections = mod.parse_sections("==漢語==\n===俗語===\n# 定義\n===釋義===\n# 第二義")
        self.assertTrue(all(section.kind == "definitions" for section in sections[1:]))

    def test_japanese_compound_pos_heading_is_definition_section(self):
        raw = raw_page(
            "jawiktionary",
            "極悪非道",
            """
=={{L|ja}}==
==={{noun}}・{{adjectivenoun}}===
# 人道に外れて極めて悪いこと。
""",
            ["カテゴリ:四字熟語"],
        )
        row, sections, *_rest = mod.extract_one(raw, "raw/jawiktionary/1.json")
        self.assertEqual(sections[1]["section_kind"], "definitions")
        self.assertEqual(row["definition_count"], 1)

    def test_japanese_adv_heading_template_is_definition_section(self):
        raw = raw_page(
            "jawiktionary",
            "遮二無二",
            """
=={{L|ja}}==
==={{adv}}===
# 他のことは考えず、強引に物事を進めるさま。
""",
            ["カテゴリ:四字熟語"],
        )
        row, *_rest = mod.extract_one(raw, "raw/jawiktionary/1.json")
        self.assertEqual(row["definition_count"], 1)

    def test_english_non_gloss_n_g_template_is_preserved(self):
        raw = raw_page(
            "enwiktionary",
            "旌旗蔽日",
            """
==Chinese==
===Idiom===
# {{n-g|Describing a vast and mighty army.}}
""",
            ["Category:Chinese chengyu"],
        )
        row, *_rest = mod.extract_one(raw, "raw/enwiktionary/1.json")
        self.assertEqual(row["definitions"], ["Describing a vast and mighty army."])

    def test_definition_link_template_can_supply_display_text(self):
        raw = raw_page(
            "enwiktionary",
            "日進月歩",
            """
==Japanese==
===Noun===
# {{l|en|[[daily]] and [[monthly]] [[progress]]; [[steady]] progress}}
""",
            ["Category:Japanese yojijukugo"],
        )
        row, *_rest = mod.extract_one(raw, "raw/enwiktionary/1.json")
        self.assertIn("daily and monthly progress", row["definitions"][0])

    def test_named_hanja_parameter_on_any_korean_template_is_explicit_evidence(self):
        raw = raw_page(
            "kowiktionary",
            "어부지리",
            """
==한국어==
===명사===
{{표제어|언어=한국어|한자=漁夫之利}}
# 두 사람이 다투는 사이에 제삼자가 이익을 얻음.
""",
            ["분류:한국어 한자성어"],
        )
        row, *_rest = mod.extract_one(raw, "raw/kowiktionary/1.json")
        self.assertEqual(row["explicit_hanja"], ["漁夫之利"])
        self.assertNotIn("hangul_title_without_explicit_hanja", row["source_gaps"])

    def test_korean_definition_directly_under_language_heading_is_kept(self):
        raw = raw_page(
            "kowiktionary",
            "무지몽매",
            """
==한국어==
{{ko-IPA}}
# 지식이 없고, 어리석고 어두움.
""",
            ["분류:한국어 한자성어"],
        )
        row, *_rest = mod.extract_one(raw, "raw/kowiktionary/1.json")
        self.assertEqual(row["definition_count"], 1)

    def test_ja_see_is_nonlemma_form_relation_not_definition_gap(self):
        raw = raw_page(
            "enwiktionary",
            "傍目八目",
            """
==Japanese==
{{ja-see|岡目八目}}
""",
            ["Category:Japanese yojijukugo"],
        )
        row, _sections, _templates, _definitions, relations, _pronunciations = mod.extract_one(
            raw, "raw/enwiktionary/1.json"
        )
        self.assertEqual(relations[0]["target_form"], "岡目八目")
        self.assertEqual(relations[0]["normalizer_action"], "ignore_nonlemma_form")
        self.assertNotIn("source_page_without_definition_evidence", row["source_gaps"])

    def test_zh_pron_arguments_become_raw_pronunciation_evidence(self):
        raw = raw_page(
            "enwiktionary",
            "一石二鳥",
            """
==Chinese==
===Pronunciation===
{{zh-pron|m=yīshí'èrniǎo|c=jat1 sek6 ji6 niu5|mn=it-se̍k-jī-niáu|cat=cy}}
===Idiom===
# one action achieving two aims
""",
            ["Category:Chinese chengyu"],
        )
        _row, _sections, _templates, _definitions, _relations, pronunciations = mod.extract_one(
            raw, "raw/enwiktionary/1.json"
        )
        by_system = {row["system"]: row for row in pronunciations}
        self.assertEqual(by_system["pinyin"]["reading"], "yīshí'èrniǎo")
        self.assertEqual(by_system["jyutping"]["reading"], "jat1 sek6 ji6 niu5")
        self.assertEqual(by_system["poj"]["reading"], "it-se̍k-jī-niáu")

    def test_ja_pron_and_kanjitab_supply_kana_readings(self):
        raw = raw_page(
            "jawiktionary",
            "四面楚歌",
            """
=={{L|ja}}==
{{ja-kanjitab|し|めん|そ|か}}
==={{pron}}===
{{ja-pron|しめんそか|acc=1}}
==={{idiom}}===
# 定義。
""",
            ["カテゴリ:四字熟語"],
        )
        _row, _sections, _templates, _definitions, _relations, pronunciations = mod.extract_one(
            raw, "raw/jawiktionary/1.json"
        )
        self.assertEqual([p["reading"] for p in pronunciations if p["language_tag"] == "ja"], ["しめんそか"])

        raw2 = raw_page(
            "jawiktionary",
            "温故知新",
            """
=={{L|ja}}==
{{ja-kanjitab|おん|こ|ち|しん}}
==={{idiom}}===
# 定義。
""",
            ["カテゴリ:四字熟語"],
        )
        *_prefix, pronunciations2 = mod.extract_one(raw2, "raw/jawiktionary/2.json")
        self.assertEqual(pronunciations2[0]["reading"], "おんこちしん")

    def test_korean_hangul_title_is_reading_for_unique_explicit_hanja(self):
        raw = raw_page(
            "kowiktionary",
            "박리다매",
            """
==한국어==
===명사===
{{한국어 명사|한자=薄利多賣}}
# 이익을 적게 남기고 많이 팖.
""",
            ["분류:한국어 한자성어"],
        )
        _row, _sections, _templates, _definitions, _relations, pronunciations = mod.extract_one(
            raw, "raw/kowiktionary/1.json"
        )
        self.assertEqual(pronunciations[0]["target_form"], "薄利多賣")
        self.assertEqual(pronunciations[0]["reading"], "박리다매")
        self.assertEqual(pronunciations[0]["system"], "hangul")


    def test_ng_and_nested_zh_m_display_text_are_definition_evidence(self):
        raw = raw_page(
            "enwiktionary",
            "曾參殺人",
            """
==Chinese==
===Idiom===
# {{ng|Used as a metaphor for a false report becoming believable through repetition.}}
# {{n-g|A phrase praising something as {{zh-m|絕妙}}.}}
""",
            ["Category:Chinese chengyu"],
        )
        row, _sections, _templates, definitions, _relations, _pronunciations = mod.extract_one(
            raw, "raw/enwiktionary/1.json"
        )
        self.assertEqual(row["definition_count"], 2)
        self.assertIn("false report", definitions[0]["plain_definition"])
        self.assertIn("絕妙", definitions[1]["plain_definition"])

    def test_yojijukugo_heading_is_definition_bearing(self):
        raw = raw_page(
            "jawiktionary",
            "生生世世",
            """
=={{L|ja}}==
=== 四字熟語 ===
# いつまでも、永遠に。
""",
            ["カテゴリ:四字熟語"],
        )
        row, *_rest = mod.extract_one(raw, "raw/jawiktionary/1.json")
        self.assertEqual(row["definition_count"], 1)
        self.assertNotIn("source_page_without_definition_evidence", row["source_gaps"])

    def test_japanese_headword_templates_supply_explicit_kana_readings(self):
        raw = raw_page(
            "jawiktionary",
            "四百四病",
            """
=={{L|ja}}==
{{ja-idiom|しひゃくしびょう}}
==={{idiom}}===
# 定義。
""",
            ["カテゴリ:四字熟語"],
        )
        *_prefix, pronunciations = mod.extract_one(raw, "raw/jawiktionary/1.json")
        readings = [p["reading"] for p in pronunciations if p["language_tag"] == "ja"]
        self.assertIn("しひゃくしびょう", readings)

        raw2 = raw_page(
            "enwiktionary",
            "臥薪嘗胆",
            """
==Japanese==
{{ja-pos|idiom|がしん しょうたん}}
===Idiom===
# enduring hardship for a purpose
""",
            ["Category:Japanese yojijukugo"],
        )
        *_prefix2, pronunciations2 = mod.extract_one(raw2, "raw/enwiktionary/2.json")
        self.assertIn("がしん しょうたん", [p["reading"] for p in pronunciations2])

    def test_unknown_zh_see_type_is_preserved_without_parser_warning(self):
        raw = raw_page(
            "enwiktionary",
            "半斤八両",
            """
==Chinese==
{{zh-see|半斤八兩|dsv}}
""",
            ["Category:Chinese chengyu"],
        )
        row, _sections, _templates, _definitions, relations, _pronunciations = mod.extract_one(
            raw, "raw/enwiktionary/1.json"
        )
        self.assertEqual(relations[0]["relation_type_code"], "dsv")
        self.assertEqual(relations[0]["relation_cause"], "")
        self.assertEqual(row["warnings"], [])
        self.assertNotIn("source_page_without_definition_evidence", row["source_gaps"])



    def test_old_level_two_pos_keeps_last_explicit_language_context(self):
        raw = raw_page(
            "kowiktionary",
            "안분지족",
            """
== 한국어 ==
{{ko-IPA}}
== 명사 ==
*어원: 한자 [[安分知足]]
# 편안한 마음으로 제 분수를 지키며 만족할 줄을 앎.
""",
            ["분류:한국어 한자성어"],
        )
        _row, sections, _templates, definitions, _relations, _pronunciations = mod.extract_one(
            raw, "raw/kowiktionary/1.json"
        )
        noun = next(section for section in sections if section["heading"] == "명사")
        self.assertEqual(noun["language_tag"], "ko")
        self.assertEqual(definitions[0]["language_tag"], "ko")

    def test_old_zhwiktionary_hanzi_language_heading_is_source_specific_chinese(self):
        raw = raw_page(
            "zhwiktionary",
            "自食其果",
            """
==漢字==
===發音===
{{zh-pron|m=zìshíqíguǒ}}
===成語===
# 做了壞事，自己要承擔後果。
""",
            ["Category:漢語成語"],
        )
        _row, sections, _templates, definitions, _relations, _pronunciations = mod.extract_one(
            raw, "raw/zhwiktionary/1.json"
        )
        self.assertEqual(next(section for section in sections if section["heading"] == "成語")["language_tag"], "zh")
        self.assertEqual(definitions[0]["language_tag"], "zh")



    def test_korean_explicit_hanja_line_does_not_absorb_etymology_citations(self):
        raw = raw_page(
            "kowiktionary",
            "위편삼절",
            """
== 한국어 ==
=== 명사 ===
*어원: 한자 [[韋編三絶]].. 사마천의 사기 «공자세가»(孔子世家): 孔子晩而喜易 徐彖繫象說卦文言 獨易[[韋編三絶]]
{{ko-IPA}}
# 책을 아주 열심히 읽는다는 뜻.
""",
            ["분류:한국어 한자성어"],
        )
        row, _sections, _templates, _definitions, _relations, pronunciations = mod.extract_one(
            raw, "raw/kowiktionary/1.json"
        )
        self.assertEqual(row["explicit_hanja"], ["韋編三絶"])
        self.assertEqual(pronunciations[0]["target_form"], "韋編三絶")



if __name__ == "__main__":
    unittest.main()
