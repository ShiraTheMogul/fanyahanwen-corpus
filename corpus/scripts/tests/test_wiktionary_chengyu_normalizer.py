#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from wiktionary_chengyu_normalizer import ChengyuNormalizer, SITES

PAGES_FIELDS = [
    "site","pageid","title","url","revision_id","revision_timestamp","revision_sha1",
    "source_keys","source_categories","categories","title_script","title_codepoints",
    "is_redirect","redirect_target","language_headings","language_tags",
    "category_language_labels","category_language_tags","attestation_tags",
    "provenance_categories","chengyu_signal","yojijukugo_signal","sajaseongeo_signal",
    "definition_count","definition_evidence_count","definition_relation_count","definitions",
    "etymology_count","etymologies","pronunciation_section_count","alternative_form_section_count",
    "explicit_hanja","explicit_hangul","has_zh_see","category_meta_term","han_sequences",
    "hangul_sequences","template_count","raw_path","source_gaps","warnings",
]
DEFINITION_FIELDS = [
    "site","pageid","title","language_heading","language_tag","heading_path","section_kind",
    "raw_definition","plain_definition","relation_template","relation_type",
    "relation_language","relation_target",
]
PRONUNCIATION_FIELDS = [
    "site","pageid","title","url","target_form","reading","language_tag","language_label",
    "system","system_label","source_template","source_type_code",
]
RELATION_FIELDS = [
    "site","pageid","title","url","relation_template","relation_kind","relation_cause",
    "relation_type_code","source_form","target_form","gloss","normalizer_action",
]
SECTION_FIELDS = [
    "site","pageid","title","language_heading","language_tag","level","raw_heading","heading",
    "raw_heading_path","heading_path","section_kind","plain_text","raw_wikitext",
]
TEMPLATE_FIELDS = [
    "site","pageid","title","language_heading","language_tag","heading_path","section_kind",
    "template_name","args_json","raw_template",
]
GROUP_FIELDS = {
    "pages": PAGES_FIELDS,
    "definitions": DEFINITION_FIELDS,
    "pronunciations": PRONUNCIATION_FIELDS,
    "relations": RELATION_FIELDS,
    "sections": SECTION_FIELDS,
    "templates": TEMPLATE_FIELDS,
}


def write_csv(path, fields, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            data = {field: "" for field in fields}
            data.update(row)
            writer.writerow(data)


def read_csv(path):
    with path.open("r", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


class NormalizerFixture:
    def __init__(self, root):
        self.root = Path(root)
        self.rows = {(group, site): [] for group in GROUP_FIELDS for site in SITES}

    def add(self, group, site, **row):
        row.setdefault("site", site)
        self.rows[(group, site)].append(row)

    def page(self, site, pageid, title, *, script="han", language_tags="zh",
             category_language_tags="", attestation_tags="zh",
             definition_evidence_count="1", category_meta_term="False",
             provenance_categories=""):
        self.add(
            "pages", site,
            pageid=str(pageid), title=title, url=f"https://example.test/{pageid}",
            revision_id=f"r{pageid}", revision_timestamp="2026-08-10T00:00:00Z",
            revision_sha1=f"sha{pageid}", source_keys="fixture",
            source_categories="Category:fixture", categories="Category:fixture",
            title_script=script, title_codepoints=str(len(title)),
            language_headings="Chinese", language_tags=language_tags,
            category_language_tags=category_language_tags,
            attestation_tags=attestation_tags,
            chengyu_signal="True", yojijukugo_signal="False",
            sajaseongeo_signal="False",
            definition_evidence_count=str(definition_evidence_count),
            category_meta_term=category_meta_term,
            provenance_categories=provenance_categories,
        )

    def materialize(self):
        for group, fields in GROUP_FIELDS.items():
            for site in SITES:
                write_csv(
                    self.root / group / f"{site}.csv",
                    fields,
                    self.rows[(group, site)],
                )

    def run(self):
        self.materialize()
        output = self.root / "normalized"
        ChengyuNormalizer(self.root, output).run()
        return output


class ChengyuNormalizerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = NormalizerFixture(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def forms(self, output):
        return read_csv(output / "forms.csv")

    def family_of(self, output, text):
        row = next(row for row in self.forms(output) if row["form_text"] == text)
        return row["family_id"]

    def test_synonym_does_not_merge_families(self):
        self.fixture.page("enwiktionary", 1, "塞翁失馬")
        self.fixture.page("enwiktionary", 2, "塞翁之馬")
        self.fixture.add(
            "definitions", "enwiktionary",
            pageid="1", title="塞翁失馬", language_tag="zh",
            heading_path="Chinese > Idiom", section_kind="definitions",
            raw_definition="{{syn of|zh|塞翁之馬}}",
            relation_template="syn of", relation_type="synonym_of",
            relation_language="zh", relation_target="塞翁之馬",
        )
        output = self.fixture.run()
        self.assertNotEqual(
            self.family_of(output, "塞翁失馬"),
            self.family_of(output, "塞翁之馬"),
        )

    def test_zh_see_variant_merges(self):
        self.fixture.page("enwiktionary", 1, "画龙点睛", definition_evidence_count="0")
        self.fixture.page("enwiktionary", 2, "畫龍點睛")
        self.fixture.add(
            "relations", "enwiktionary",
            pageid="1", title="画龙点睛", relation_template="zh-see",
            relation_kind="variant", source_form="画龙点睛", target_form="畫龍點睛",
            normalizer_action="ignore_nonlemma_form",
        )
        output = self.fixture.run()
        self.assertEqual(
            self.family_of(output, "画龙点睛"),
            self.family_of(output, "畫龍點睛"),
        )
        row = next(row for row in self.forms(output) if row["form_text"] == "画龙点睛")
        self.assertIn("nonlemma_variant", row["statuses"])

    def test_poj_page_becomes_reading_not_form(self):
        self.fixture.page(
            "enwiktionary", 1, "put-khó-su-gī",
            script="latin_or_ascii", language_tags="zh",
            attestation_tags="zh || nan", definition_evidence_count="0",
        )
        self.fixture.add(
            "relations", "enwiktionary",
            pageid="1", title="put-khó-su-gī", relation_template="zh-see",
            relation_kind="pronunciation", relation_cause="peh_oe_ji",
            relation_type_code="poj", source_form="put-khó-su-gī",
            target_form="不可思議", normalizer_action="pronunciation",
        )
        self.fixture.add(
            "pronunciations", "enwiktionary",
            pageid="1", title="put-khó-su-gī", url="https://example.test/1",
            target_form="不可思議", reading="put-khó-su-gī", language_tag="nan",
            language_label="Hokkien", system="poj", system_label="Pe̍h-ōe-jī",
            source_template="zh-see", source_type_code="poj",
        )
        output = self.fixture.run()
        form_texts = {row["form_text"] for row in self.forms(output)}
        self.assertIn("不可思議", form_texts)
        self.assertNotIn("put-khó-su-gī", form_texts)
        readings = read_csv(output / "readings.csv")
        self.assertTrue(any(row["reading"] == "put-khó-su-gī" for row in readings))
        attestations = read_csv(output / "attestations.csv")
        self.assertEqual(attestations[0]["attestation_kind"], "pronunciation_page")

    def test_english_korean_headword_uses_full_hanja_parameter(self):
        self.fixture.page(
            "enwiktionary", 1, "유전무죄 무전유죄",
            script="hangul", language_tags="ko", attestation_tags="ko",
        )
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="유전무죄 무전유죄", language_tag="ko",
            section_kind="etymology", template_name="ko-etym-sino",
            args_json=json.dumps({"1": "有錢", "2": "having money"}, ensure_ascii=False),
            raw_template="{{ko-etym-sino|有錢|having money}}",
        )
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="유전무죄 무전유죄", language_tag="ko",
            section_kind="definitions", template_name="ko-noun",
            args_json=json.dumps({"hanja": "有錢無罪 無錢有罪"}, ensure_ascii=False),
            raw_template="{{ko-noun|hanja=有錢無罪 無錢有罪}}",
        )
        output = self.fixture.run()
        form_texts = {row["form_text"] for row in self.forms(output)}
        self.assertIn("有錢無罪 無錢有罪", form_texts)
        self.assertNotIn("有錢", form_texts)

    def test_multiple_hanja_spellings_on_one_hangul_headword_merge(self):
        self.fixture.page(
            "enwiktionary", 1, "억강부약",
            script="hangul", language_tags="ko", attestation_tags="ko",
        )
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="억강부약", language_tag="ko",
            section_kind="definitions", template_name="ko-noun",
            args_json=json.dumps({"hanja": "[[抑強扶弱]]/[[抑强扶弱]]"}, ensure_ascii=False),
            raw_template="{{ko-noun|hanja=[[抑強扶弱]]/[[抑强扶弱]]}}",
        )
        output = self.fixture.run()
        self.assertEqual(
            self.family_of(output, "抑強扶弱"),
            self.family_of(output, "抑强扶弱"),
        )
        self.assertNotIn(
            "[[抑強扶弱]]/[[抑强扶弱]]",
            {row["form_text"] for row in self.forms(output)},
        )

    def test_zh_forms_explicit_variants_merge(self):
        self.fixture.page("enwiktionary", 1, "畫龍點睛")
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="畫龍點睛", language_tag="zh",
            template_name="zh-forms",
            args_json=json.dumps(
                {"s": "画龙点睛", "alt": "畫龍點晴"},
                ensure_ascii=False,
            ),
            raw_template="{{zh-forms|s=画龙点睛|alt=畫龍點晴}}",
        )
        output = self.fixture.run()
        family = self.family_of(output, "畫龍點睛")
        self.assertEqual(family, self.family_of(output, "画龙点睛"))
        self.assertEqual(family, self.family_of(output, "畫龍點晴"))

    def test_ja_kanjitab_alt_merges(self):
        self.fixture.page(
            "enwiktionary", 1, "画竜点睛",
            language_tags="ja", attestation_tags="ja",
        )
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="画竜点睛", language_tag="ja",
            template_name="ja-kanjitab",
            args_json=json.dumps({"alt": "画龍点睛"}, ensure_ascii=False),
            raw_template="{{ja-kanjitab|alt=画龍点睛}}",
        )
        output = self.fixture.run()
        self.assertEqual(
            self.family_of(output, "画竜点睛"),
            self.family_of(output, "画龍点睛"),
        )

    def test_erhua_gloss_is_not_mistaken_for_target(self):
        self.fixture.page("enwiktionary", 1, "一星半點兒")
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="一星半點兒", language_tag="zh",
            template_name="zh-erhua form of",
            args_json=json.dumps({"1": "a tiny bit"}),
            raw_template="{{zh-erhua form of|a tiny bit}}",
        )
        output = self.fixture.run()
        self.assertEqual({row["form_text"] for row in self.forms(output)}, {"一星半點兒"})
        unresolved = read_csv(output / "diagnostics" / "unresolved_form_relations.csv")
        self.assertEqual(unresolved[0]["reason"], "no_explicit_word_target")

    def test_erhua_explicit_word_parameter_merges(self):
        self.fixture.page("enwiktionary", 1, "竹籃兒打水")
        self.fixture.page("enwiktionary", 2, "竹籃打水")
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="竹籃兒打水", language_tag="zh",
            template_name="zh-erhua form of",
            args_json=json.dumps({"1": "wasted effort", "word": "竹籃打水"}, ensure_ascii=False),
            raw_template="{{zh-erhua form of|wasted effort|word=竹籃打水}}",
        )
        output = self.fixture.run()
        self.assertEqual(
            self.family_of(output, "竹籃兒打水"),
            self.family_of(output, "竹籃打水"),
        )

    def test_category_meta_term_is_excluded(self):
        self.fixture.page(
            "jawiktionary", 1, "四字熟語",
            language_tags="ja", attestation_tags="ja",
            category_meta_term="True",
        )
        output = self.fixture.run()
        self.assertEqual(self.forms(output), [])
        excluded = read_csv(output / "diagnostics" / "excluded_meta_terms.csv")
        self.assertEqual(excluded[0]["title"], "四字熟語")

    def test_definition_and_entry_languages_stay_separate(self):
        self.fixture.page(
            "enwiktionary", 1, "一石二鳥",
            language_tags="ja", attestation_tags="ja",
        )
        self.fixture.add(
            "definitions", "enwiktionary",
            pageid="1", title="一石二鳥", language_heading="Japanese",
            language_tag="ja", heading_path="Japanese > Noun",
            section_kind="definitions", raw_definition="kill two birds with one stone",
            plain_definition="kill two birds with one stone",
        )
        output = self.fixture.run()
        sense = read_csv(output / "senses.csv")[0]
        self.assertEqual(sense["entry_language_tag"], "ja")
        self.assertEqual(sense["definition_language_tag"], "en")

    def test_provenance_is_separate_from_etymology(self):
        self.fixture.page(
            "enwiktionary", 1, "不恥下問",
            provenance_categories="Category:Chinese chengyu derived from the Analects",
        )
        output = self.fixture.run()
        provenance = read_csv(output / "provenances.csv")[0]
        self.assertEqual(provenance["source_title"], "Analects")
        self.assertEqual(read_csv(output / "etymologies.csv"), [])

    def test_initialism_page_attaches_to_target_without_becoming_form(self):
        self.fixture.page(
            "enwiktionary", 1, "yygq",
            script="latin_or_ascii", definition_evidence_count="1",
        )
        self.fixture.page("enwiktionary", 2, "陰陽怪氣")
        self.fixture.add(
            "definitions", "enwiktionary",
            pageid="1", title="yygq", language_tag="zh",
            heading_path="Chinese > Idiom", section_kind="definitions",
            raw_definition="{{initialism of|zh|陰陽怪氣}}",
            relation_template="initialism of", relation_type="initialism_of",
            relation_language="zh", relation_target="陰陽怪氣",
        )
        output = self.fixture.run()
        form_texts = {row["form_text"] for row in self.forms(output)}
        self.assertNotIn("yygq", form_texts)
        self.assertIn("陰陽怪氣", form_texts)
        attestations = read_csv(output / "attestations.csv")
        initialism_attestation = next(row for row in attestations if row["page_title"] == "yygq")
        self.assertEqual(initialism_attestation["attestation_kind"], "derived_non_han_page")
        unmapped = read_csv(output / "diagnostics" / "unmapped_pages.csv")
        self.assertFalse(any(row["title"] == "yygq" for row in unmapped))


    def test_cjkv_explicit_forms_merge_cross_language_family(self):
        self.fixture.page("enwiktionary", 1, "畫龍點睛")
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="畫龍點睛", language_tag="zh",
            heading_path="Chinese > Idiom > Descendants", section_kind="descendants",
            template_name="CJKV",
            args_json=json.dumps({
                "2": "がりょうてんせい",
                "3": "화룡점정",
                "j": "画竜点睛",
                "k": "畵龍點睛",
            }, ensure_ascii=False),
            raw_template="{{CJKV||がりょうてんせい|j=画竜点睛|화룡점정|k=畵龍點睛}}",
        )
        output = self.fixture.run()
        family = self.family_of(output, "畫龍點睛")
        self.assertEqual(family, self.family_of(output, "画竜点睛"))
        self.assertEqual(family, self.family_of(output, "畵龍點睛"))
        readings = read_csv(output / "readings.csv")
        self.assertTrue(any(r["reading"] == "がりょうてんせい" and r["language_tag"] == "ja" for r in readings))
        self.assertTrue(any(r["reading"] == "화룡점정" and r["language_tag"] == "ko" for r in readings))

    def test_ja_gv_merges_explicit_glyph_variant(self):
        self.fixture.page("enwiktionary", 1, "畫龍點睛", language_tags="ja", attestation_tags="ja")
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="畫龍點睛", language_tag="ja", template_name="ja-gv",
            args_json=json.dumps({"1": "画竜点睛"}, ensure_ascii=False),
            raw_template="{{ja-gv|画竜点睛}}",
        )
        output = self.fixture.run()
        self.assertEqual(self.family_of(output, "畫龍點睛"), self.family_of(output, "画竜点睛"))

    def test_two_way_korean_lexeme_bridge_merges_hanja_variants(self):
        self.fixture.page("enwiktionary", 1, "화룡점정", script="hangul", language_tags="ko", attestation_tags="ko")
        self.fixture.add(
            "templates", "enwiktionary",
            pageid="1", title="화룡점정", language_tag="ko", template_name="ko-noun",
            args_json=json.dumps({"hanja": "畵龍點睛"}, ensure_ascii=False),
            raw_template="{{ko-noun|hanja=畵龍點睛}}",
        )
        self.fixture.page("enwiktionary", 2, "畫龍點睛", language_tags="ko", attestation_tags="ko")
        self.fixture.add(
            "definitions", "enwiktionary",
            pageid="2", title="畫龍點睛", language_tag="ko",
            heading_path="Korean > Noun", section_kind="definitions",
            raw_definition="{{hanja form of|화룡점정}}", plain_definition="",
            relation_template="hanja form of", relation_type="hanja_form_of",
            relation_language="ko", relation_target="화룡점정",
        )
        output = self.fixture.run()
        self.assertEqual(self.family_of(output, "畵龍點睛"), self.family_of(output, "畫龍點睛"))

    def test_shared_korean_reading_without_hangul_anchor_does_not_merge(self):
        self.fixture.page("enwiktionary", 1, "甲乙丙丁", language_tags="ko", attestation_tags="ko")
        self.fixture.page("enwiktionary", 2, "戊己庚辛", language_tags="ko", attestation_tags="ko")
        for pageid, title in (("1", "甲乙丙丁"), ("2", "戊己庚辛")):
            self.fixture.add(
                "definitions", "enwiktionary", pageid=pageid, title=title, language_tag="ko",
                heading_path="Korean > Noun", section_kind="definitions",
                raw_definition="{{hanja form of|가나다라}}", plain_definition="",
                relation_template="hanja form of", relation_type="hanja_form_of",
                relation_language="ko", relation_target="가나다라",
            )
        output = self.fixture.run()
        self.assertNotEqual(self.family_of(output, "甲乙丙丁"), self.family_of(output, "戊己庚辛"))

    def test_duplicate_reading_templates_on_same_page_collapse(self):
        self.fixture.page("enwiktionary", 1, "一石二鳥", language_tags="ja", attestation_tags="ja")
        for template, code in (("ja-pron", "1"), ("ja-noun", "1")):
            self.fixture.add(
                "pronunciations", "enwiktionary", pageid="1", title="一石二鳥", url="https://example.test/1",
                target_form="一石二鳥", reading="いっせきにちょう", language_tag="ja", language_label="Japanese",
                system="kana", system_label="Kana", source_template=template, source_type_code=code,
            )
        output = self.fixture.run()
        readings = read_csv(output / "readings.csv")
        self.assertEqual(1, len([r for r in readings if r["reading"] == "いっせきにちょう"]))


if __name__ == "__main__":
    unittest.main()
