#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import dataclasses
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import category_migration as migration


class FakeCalendarEngine:
    def __init__(self) -> None:
        self.resolve_calls: list[tuple[str, dict[str, object] | None, bool]] = []
        self.prefix_calls: list[tuple[str, dict[str, object] | None, bool]] = []

    def resolve(
        self,
        value: str,
        *,
        context: dict[str, object] | None = None,
        system: str | None = None,
        authority: bool = True,
    ) -> dict[str, object]:
        self.resolve_calls.append((value, context, authority))
        if value == "康熙三年":
            return {
                "resolved": True,
                "kind": "date",
                "source_system": "historical_authority",
                "year": 1664,
                "precision": "year",
            }
        if value == "1664年":
            return {
                "resolved": True,
                "kind": "date",
                "source_system": "gregorian",
                "year": 1664,
                "precision": "year",
            }
        if value == "儒略曆1900年2月29日":
            return {
                "resolved": True,
                "kind": "date",
                "source_system": "julian",
                "year": 1900,
                "month": 3,
                "day": 13,
                "precision": "day",
            }
        return {"resolved": False, "kind": "date"}

    def period_bounds(self, value: str | list[str] | tuple[str, ...]) -> dict[str, object]:
        labels = [value] if isinstance(value, str) else list(value)
        ranges = {
            "三國": (220, 280),
            "唐朝": (618, 907),
            "清朝": (1644, 1912),
            "周朝": (-1046, -256),
            "東周": (-770, -256),
            "戰國時代": (-475, -221),
            "宋": (960, 1279),
        }
        context: tuple[int, int] | None = None
        matched: list[str] = []
        for label in labels:
            bounds = ranges.get(label)
            if bounds is None:
                continue
            if context is None:
                context = bounds
            else:
                intersection = (max(context[0], bounds[0]), min(context[1], bounds[1]))
                if intersection[0] > intersection[1]:
                    continue
                context = intersection
            matched.append(label)
        if context is None:
            return {"resolved": False, "kind": "period_bounds"}
        return {
            "resolved": True,
            "kind": "period_bounds",
            "year_start": context[0],
            "year_end": context[1],
            "labels": matched,
        }

    def resolve_prefix(
        self,
        value: str,
        *,
        context: dict[str, object] | None = None,
        authority: bool = False,
    ) -> dict[str, object]:
        self.prefix_calls.append((value, context, authority))
        if value == "康熙三年刊":
            return {
                "resolved": True,
                "kind": "date",
                "year": 1664,
                "consumed": "康熙三年",
                "rest": "刊",
            }
        return {"resolved": False, "kind": "date"}




class FakeHistoricalAnnotator:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    def annotate(self, text: str, *, metadata: dict[str, object], wanted: dict[str, object]) -> dict[str, object]:
        self.calls.append({"text": text, "metadata": metadata, "wanted": wanted})
        return {
            "resolved": True,
            "authority_available": True,
            "matches": {
                "孔子": [
                    {
                        "kind": "person",
                        "text": "仲尼",
                        "confidence": "high",
                        "candidates": [{"label": "孔丘", "authority_source": "cbdb"}],
                    }
                ]
            },
        }

class IdentityNormalizer:
    def normalize(self, text: str) -> tuple[str, tuple[str, ...]]:
        return text, ()


def make_work(
    *,
    path: str = "中國漢文/clean/三國/曹魏/測試/metadata.json",
    period: str = "曹魏",
    date: str = "",
    date_label: str = "",
    year_start: int | None = None,
    year_end: int | None = None,
    categories: tuple[str, ...] = (),
    source_categories: tuple[str, ...] = (),
    authors: tuple[str, ...] = (),
) -> migration.Work:
    return migration.Work(
        metadata_path=Path(path),
        work_id="1",
        title="測試",
        work_base_title="測試",
        aliases=(),
        date_label=date_label,
        date=date,
        year_start=year_start,
        year_end=year_end,
        period=period,
        polity="曹魏" if period == "曹魏" else "",
        macro_region="",
        region="",
        medium="",
        object_type="",
        material={},
        is_compilation=False,
        categories=categories,
        source_categories=source_categories,
        authors=authors,
        editors=(),
        contributors=(),
        document_authors=(),
        contained_in=(),
        editions=(),
        sources=(),
        identifiers=(),
        documents=(),
    )


class CategoryMigrationCalendarAdapterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.previous = migration._CALENDAR_ENGINE
        self.previous_annotator = migration._HISTORICAL_ANNOTATOR
        self.fake = FakeCalendarEngine()
        self.fake_annotator = FakeHistoricalAnnotator()
        migration._CALENDAR_ENGINE = self.fake
        migration._HISTORICAL_ANNOTATOR = self.fake_annotator

    def tearDown(self) -> None:
        migration._CALENDAR_ENGINE = self.previous
        migration._HISTORICAL_ANNOTATOR = self.previous_annotator

    def test_mention_marker_remains_migration_semantics(self) -> None:
        context = {"period": "清", "polity": "大清"}
        parsed = migration.parse_date_category("康熙三年（提及）", context=context)
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertTrue(parsed.is_mention)
        self.assertEqual(1664, parsed.year)
        self.assertEqual("康熙三年", parsed.source_label)
        self.assertEqual([("康熙三年", context, True)], self.fake.resolve_calls)

    def test_calendar_frame_result_is_consumed_as_normalized_date(self) -> None:
        parsed = migration.parse_date_category("儒略曆1900年2月29日")
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertEqual((1900, 3, 13), (parsed.year, parsed.month, parsed.day))
        self.assertEqual("儒略曆1900年2月29日", parsed.source_label)

    def test_leading_date_uses_authority_aware_prefix_resolution(self) -> None:
        context = {"period": "清"}
        parsed = migration.leading_date_in_suffix("康熙三年刊", context=context)
        self.assertIsNotNone(parsed)
        assert parsed is not None
        date, rest = parsed
        self.assertEqual(1664, date.year)
        self.assertEqual("刊", rest)
        self.assertEqual([("康熙三年刊", context, True)], self.fake.prefix_calls)

    def test_period_bounds_keep_homonymous_child_from_destroying_parent_context(self) -> None:
        bounds = migration.calendar_period_bounds(("周朝", "東周", "戰國時代", "宋"))
        self.assertEqual((-475, -256, ("周朝", "東周", "戰國時代")), bounds)

    def test_parent_period_category_is_redundant_when_path_is_more_specific(self) -> None:
        work = make_work()
        normalizer = IdentityNormalizer()
        indexes = {
            "periods": {"三國": "三國", "曹魏": "曹魏", "唐朝": "唐朝", "清朝": "清朝"},
            "polities": {"曹魏": "曹魏"},
            "macro_regions": {},
            "regions": {},
            "people": set(),
            "titles": {},
        }
        actions = migration.classify_membership(
            work, "三國", "source_categories", "三國", (), normalizer, indexes, {}, {}, None, None, ()
        )
        self.assertEqual(1, len(actions))
        self.assertEqual("remove_geography_period_category_redundant", actions[0].action)
        self.assertEqual("safe", actions[0].confidence)

    def test_normalized_date_blocks_a_period_category_that_cannot_contain_it(self) -> None:
        work = make_work(
            path="中國漢文/clean/清朝/測試/metadata.json",
            period="清朝",
            year_start=1664,
            year_end=1664,
        )
        normalizer = IdentityNormalizer()
        indexes = {
            "periods": {"唐朝": "唐朝", "清朝": "清朝"},
            "polities": {},
            "macro_regions": {},
            "regions": {},
            "people": set(),
            "titles": {},
        }
        actions = migration.classify_membership(
            work, "唐朝", "source_categories", "唐朝", (), normalizer, indexes, {}, {}, None, None, ()
        )
        self.assertEqual("period_category_date_conflict_review", actions[0].action)
        self.assertEqual("review", actions[0].confidence)

    def test_date_that_fits_source_period_but_not_folder_is_kept_for_move_review(self) -> None:
        work = make_work(
            path="中國漢文/clean/唐朝/測試/metadata.json",
            period="唐朝",
            year_start=1664,
            year_end=1664,
        )
        normalizer = IdentityNormalizer()
        indexes = {
            "periods": {"唐朝": "唐朝", "清朝": "清朝"},
            "polities": {},
            "macro_regions": {},
            "regions": {},
            "people": set(),
            "titles": {},
        }
        actions = migration.classify_membership(
            work, "清朝", "source_categories", "清朝", (), normalizer, indexes, {}, {}, None, None, ()
        )
        self.assertEqual("period_path_date_conflict_review", actions[0].action)
        self.assertEqual("review", actions[0].confidence)

    def test_work_date_category_outside_folder_period_is_never_auto_promoted(self) -> None:
        work = make_work(path="中國漢文/clean/唐朝/測試/metadata.json", period="唐朝")
        normalizer = IdentityNormalizer()
        indexes = {
            "periods": {"唐朝": "唐朝", "清朝": "清朝"},
            "polities": {},
            "macro_regions": {},
            "regions": {},
            "people": set(),
            "titles": {},
        }
        date_cat = migration.parse_date_category("康熙三年")
        assert date_cat is not None
        actions = migration.classify_membership(
            work, "康熙三年", "source_categories", "康熙三年", (), normalizer, indexes, {}, {}, None, None, (date_cat,)
        )
        self.assertEqual("date_path_period_conflict_review", actions[0].action)
        self.assertEqual("review", actions[0].confidence)

    def test_date_review_sheet_filter_does_not_match_candidate_substring(self) -> None:
        work = make_work()
        author_candidate = migration.MembershipAction(
            raw_category="李白", canonical_category="李白", origin="source_categories", work=work,
            action=migration.Action("promote_author_candidate", "authors", "李白", "high", "", "", ""),
        )
        date_action = migration.MembershipAction(
            raw_category="康熙三年", canonical_category="康熙三年", origin="source_categories", work=work,
            action=migration.Action("promote_date_metadata", "date_label", "康熙三年", "high", "", "", ""),
        )
        self.assertFalse(migration.is_date_review_action(author_candidate))
        self.assertTrue(migration.is_date_review_action(date_action))


    def test_limit_keeps_global_corpus_hierarchy_out_of_person_inference(self) -> None:
        corpus_root = Path("/corpus")
        metadata_paths = [
            corpus_root / "中國漢文" / "clean" / "漢朝" / "東漢" / "七依" / "metadata.json",
            corpus_root / "中國漢文" / "clean" / "南北朝" / "南梁" / "七錄序" / "metadata.json",
        ]
        hierarchy = migration.hierarchy_labels_from_metadata_paths(metadata_paths, corpus_root)
        self.assertIn("東漢", hierarchy)
        self.assertIn("南梁", hierarchy)
        self.assertNotIn("七依", hierarchy)
        self.assertNotIn("七錄序", hierarchy)

        blocked = migration.person_inference_blocked_labels(
            [make_work()],
            IdentityNormalizer(),
            {},
            hierarchy_labels=hierarchy,
        )
        self.assertIn("東漢", blocked)
        self.assertIn("南梁", blocked)


    def test_safe_period_redundancy_is_not_a_period_review_item(self) -> None:
        work = make_work()
        safe = migration.MembershipAction(
            raw_category="三國", canonical_category="三國", origin="source_categories", work=work,
            action=migration.Action(
                "remove_geography_period_category_redundant", "period", "曹魏", "safe", "period", "", ""
            ),
        )
        review = migration.MembershipAction(
            raw_category="清朝", canonical_category="清朝", origin="source_categories", work=work,
            action=migration.Action(
                "period_category_date_conflict_review", "period", "清朝", "review", "曹魏", "", ""
            ),
        )
        self.assertFalse(migration.is_period_polity_review_action(safe))
        self.assertTrue(migration.is_period_polity_review_action(review))

    def test_people_semantics_contains_only_positive_author_candidates(self) -> None:
        normalizer = IdentityNormalizer()
        mention_only = make_work(
            path="中國漢文/clean/春秋時代/孔子例/metadata.json",
            period="春秋時代",
            categories=("孔子",),
        )
        author_work = make_work(
            path="中國漢文/clean/唐朝/李白例/metadata.json",
            period="唐朝",
            categories=("李白",),
            authors=("李白",),
        )
        semantics = migration.person_semantics(
            [mention_only, author_work],
            normalizer,
            {"孔子", "李白"},
        )
        self.assertNotIn("孔子", semantics)
        self.assertIn("李白", semantics)
        self.assertGreater(int(semantics["李白"].get("author_matches", 0)), 0)

    def test_high_shared_annotation_promotes_person_mention_without_tradition_category(self) -> None:
        work = make_work(
            path="中國漢文/clean/春秋時代/孔子例/metadata.json",
            period="春秋時代",
            categories=("孔子",),
        )
        normalizer = IdentityNormalizer()
        indexes = {
            "periods": {"春秋時代": "春秋時代"},
            "polities": {},
            "macro_regions": {},
            "regions": {},
            "people": {"孔子"},
            "titles": {},
        }
        evidence = migration.Evidence(occurrences=2, documents={"孔子例.txt"})
        evidence.person_annotation_attempts = 1
        evidence.person_annotation_authority_available = True
        evidence.person_annotation_confidences["high"] = 1
        evidence.first_person_annotation = "孔丘 | 孔丘 | cbdb | high"
        actions = migration.classify_membership(
            work, "孔子", "categories", "孔子", (), normalizer, indexes, {}, {}, evidence, None, ()
        )
        self.assertEqual(1, len(actions))
        self.assertEqual("promote_person_mention", actions[0].action)
        self.assertEqual("mentions.people", actions[0].target_field)
        self.assertEqual("孔子", actions[0].proposed_value)
        self.assertNotIn("Confucian", actions[0].proposed_value)

    def test_possible_shared_annotation_stays_person_mention_review(self) -> None:
        work = make_work(
            path="中國漢文/clean/清朝/孔子例/metadata.json",
            period="清朝",
            categories=("孔子",),
        )
        indexes = {
            "periods": {"清朝": "清朝"},
            "polities": {},
            "macro_regions": {},
            "regions": {},
            "people": {"孔子"},
            "titles": {},
        }
        evidence = migration.Evidence(occurrences=1, documents={"孔子例.txt"})
        evidence.person_annotation_attempts = 1
        evidence.person_annotation_authority_available = True
        evidence.person_annotation_confidences["possible"] = 1
        actions = migration.classify_membership(
            work, "孔子", "categories", "孔子", (), IdentityNormalizer(), indexes, {}, {}, evidence, None, ()
        )
        self.assertEqual("person_mention_review", actions[0].action)
        self.assertEqual("review", actions[0].confidence)
        self.assertEqual("mentions.people", actions[0].target_field)

    def test_unconfirmed_body_string_is_not_promoted_as_person(self) -> None:
        work = make_work(
            path="中國漢文/clean/春秋時代/孔子例/metadata.json",
            period="春秋時代",
            categories=("孔子",),
        )
        indexes = {
            "periods": {"春秋時代": "春秋時代"},
            "polities": {},
            "macro_regions": {},
            "regions": {},
            "people": {"孔子"},
            "titles": {},
        }
        evidence = migration.Evidence(occurrences=1, documents={"孔子例.txt"})
        evidence.person_annotation_attempts = 1
        evidence.person_annotation_authority_available = True
        actions = migration.classify_membership(
            work, "孔子", "categories", "孔子", (), IdentityNormalizer(), indexes, {}, {}, evidence, None, ()
        )
        self.assertEqual("person_mention_unconfirmed_review", actions[0].action)
        self.assertEqual("review", actions[0].confidence)

    def test_global_author_semantics_do_not_override_local_confirmed_mention(self) -> None:
        work = make_work(
            path="中國漢文/clean/宋朝/李白例/metadata.json",
            period="宋朝",
            categories=("李白",),
        )
        indexes = {
            "periods": {"宋朝": "宋朝"},
            "polities": {},
            "macro_regions": {},
            "regions": {},
            "people": {"李白"},
            "titles": {},
        }
        semantics = {
            "李白": {
                "author_matches": 1,
                "works_with_authors": 10,
                "author_ratio": 0.1,
                "title_parenthetical_matches": 0,
                "authorial_compilation_matches": 0,
                "preamble_author_matches": 0,
                "cbdb_author_matches": 0,
                "cbdb_roles": "",
                "semantic": "potential author grouping",
            }
        }
        evidence = migration.Evidence(occurrences=1, documents={"李白例.txt"})
        evidence.person_annotation_attempts = 1
        evidence.person_annotation_authority_available = True
        evidence.person_annotation_confidences["high"] = 1
        actions = migration.classify_membership(
            work, "李白", "categories", "李白", (), IdentityNormalizer(), indexes, {}, semantics, evidence, None, ()
        )
        self.assertEqual("promote_person_mention", actions[0].action)

    def test_people_review_excludes_person_mention_review(self) -> None:
        work = make_work()
        mention = migration.MembershipAction(
            raw_category="孔子", canonical_category="孔子", origin="source_categories", work=work,
            action=migration.Action("person_mention_review", "mentions.people", "孔子", "review", "", "", ""),
        )
        author = migration.MembershipAction(
            raw_category="李白", canonical_category="李白", origin="source_categories", work=work,
            action=migration.Action("author_role_review", "authors", "李白", "review", "", "", ""),
        )
        self.assertFalse(migration.is_people_review_action(mention))
        self.assertTrue(migration.is_person_mention_review_action(mention))
        self.assertTrue(migration.is_people_review_action(author))

    def test_annotation_context_uses_normalized_path_period_when_no_firm_date(self) -> None:
        work = make_work(path="中國漢文/clean/三國/曹魏/測試/metadata.json", period="曹魏")
        metadata = migration.annotation_metadata_for_work(work)
        self.assertEqual(220, metadata.get("year_start"))
        self.assertEqual(280, metadata.get("year_end"))
        self.assertEqual("曹魏", metadata.get("period"))

    def test_figure_alias_groups_validate_identity_without_creating_tradition_taxonomy(self) -> None:
        groups = migration.figure_alias_groups_from_terms(
            SCRIPTS / "category_audit_terms.json", IdentityNormalizer()
        )
        self.assertIn("孔子", groups)
        self.assertIn("仲尼", groups["孔子"])
        self.assertNotIn("Confucianism", groups["孔子"])

    def test_body_scan_uses_shared_annotator_for_figure_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = make_work(
                path="中國漢文/clean/春秋時代/孔子例/metadata.json",
                period="春秋時代",
                year_start=-500,
                year_end=-500,
                categories=("孔子",),
            )
            work_dir = root / work.metadata_path.parent
            work_dir.mkdir(parents=True)
            (work_dir / "正文.txt").write_text("仲尼曰：學而時習之。", encoding="utf-8-sig")
            work = dataclasses.replace(work, documents=({"file": "正文.txt", "body_start_line": 1},))
            indexes = {
                "periods": {"春秋時代": "春秋時代"},
                "polities": {},
                "macro_regions": {},
                "regions": {},
                "people": {"孔子"},
                "titles": {},
            }
            evidence, issues, scanned = migration.scan_body_evidence(
                root,
                [work],
                IdentityNormalizer(),
                indexes,
                0,
                {"孔子": ("孔子", "孔丘", "仲尼")},
            )
            self.assertEqual([], issues)
            self.assertEqual(1, scanned)
            item = evidence[(work.metadata_path, "孔子")]
            self.assertEqual(1, item.occurrences)
            self.assertEqual(1, item.person_annotation_confidences["high"])
            self.assertEqual("仲尼 | 孔丘 | cbdb | high", item.first_person_annotation)
            self.assertEqual(-500, self.fake_annotator.calls[0]["metadata"]["year_start"])

    def test_old_python_calendar_arithmetic_is_not_present(self) -> None:
        self.assertFalse(hasattr(migration, "chinese_integer"))
        self.assertFalse(hasattr(migration, "calendar_year_bases"))
        self.assertFalse(hasattr(migration, "parse_date_label"))


if __name__ == "__main__":
    unittest.main()
