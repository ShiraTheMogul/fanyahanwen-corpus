#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import category_migration_apply as apply_mod


class CategoryMigrationApplyTest(unittest.TestCase):
    def metadata_bytes(self, value: dict) -> bytes:
        return b"\xef\xbb\xbf" + (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

    def write_plan(self, path: Path, metadata_path: str, raw: bytes, membership_actions=None, title_actions=None):
        header = {
            "record": "header",
            "schema": apply_mod.PLAN_SCHEMA,
            "version": apply_mod.PLAN_VERSION,
            "generated_at": "2026-08-29T12:00:00Z",
        }
        work = {
            "record": "work",
            "metadata_path": metadata_path,
            "metadata_sha256": hashlib.sha256(raw).hexdigest(),
            "work_id": "1",
            "title": "測試",
            "membership_actions": membership_actions or [],
            "title_actions": title_actions or [],
        }
        text = "\n".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) for row in (header, work)) + "\n"
        path.write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))

    def action(self, name: str, target: str, proposed: str, confidence: str = "high", existing: str = "") -> dict:
        return {
            "action": name,
            "target_field": target,
            "proposed_value": proposed,
            "confidence": confidence,
            "existing_value": existing,
            "evidence": "fixture",
            "note": "fixture",
        }

    def membership(self, raw: str, canonical: str, origin: str, action: dict) -> dict:
        return {
            "raw_category": raw,
            "canonical_category": canonical,
            "origin": origin,
            "body_occurrences": 1,
            "body_documents": 1,
            "action": action,
        }

    def run_stage(self, root: Path, plan: Path, *, safe_only=False):
        staged = root / "staged"
        staged.mkdir()
        args = argparse.Namespace(
            plan=plan,
            corpus_root=root / "corpus",
            safe_only=safe_only,
            limit=None,
            apply=False,
            overlay=None,
            fail_on_deferred_high=False,
        )
        report, changed, errors = apply_mod.stage_plan(args, root, staged)
        return staged, report, changed, errors

    def fixture(self, root: Path, metadata: dict):
        rel = Path("中國漢文/clean/唐朝/測試/metadata.json")
        target = root / "corpus" / rel
        target.parent.mkdir(parents=True)
        raw = self.metadata_bytes(metadata)
        target.write_bytes(raw)
        return rel, target, raw

    def load_staged(self, staged: Path, rel: Path) -> dict:
        return json.loads((staged / rel).read_bytes().decode("utf-8-sig"))

    def test_safe_keep_moves_source_taxonomy_into_curated_categories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel, _target, raw = self.fixture(root, {"source_categories": ["佛經"]})
            plan = root / "plan.jsonl"
            self.write_plan(plan, rel.as_posix(), raw, [
                self.membership("佛經", "佛經", "source", self.action("keep_controlled_taxonomy", "categories", "佛經", "safe"))
            ])
            staged, report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], errors)
            self.assertEqual([rel], changed)
            result = self.load_staged(staged, rel)
            self.assertEqual(["佛經"], result["categories"])
            self.assertNotIn("source_categories", result)
            self.assertEqual(1, report["counts"]["membership_applied"])

    def test_safe_removal_removes_only_the_planned_origin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel, _target, raw = self.fixture(root, {"categories": ["PD-old"], "source_categories": ["PD-old", "詩"]})
            plan = root / "plan.jsonl"
            self.write_plan(plan, rel.as_posix(), raw, [
                self.membership("PD-old", "PD-old", "curated+source", self.action("delete_structural_noise", "categories/source_categories", "", "safe"))
            ])
            staged, _report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], errors)
            result = self.load_staged(staged, rel)
            self.assertNotIn("categories", result)
            self.assertEqual(["詩"], result["source_categories"])

    def test_high_person_mention_is_structured_without_inventing_taxonomy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel, _target, raw = self.fixture(root, {"source_categories": ["孔子"]})
            plan = root / "plan.jsonl"
            self.write_plan(plan, rel.as_posix(), raw, [
                self.membership("孔子", "孔子", "source", self.action("promote_person_mention", "mentions.people", "孔子"))
            ])
            staged, _report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], errors)
            result = self.load_staged(staged, rel)
            self.assertEqual(["孔子"], result["mentions"]["people"])
            self.assertNotIn("source_categories", result)
            self.assertNotIn("categories", result)

    def test_split_date_keeps_compatible_existing_date_label_and_only_adds_taxonomy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel, _target, raw = self.fixture(root, {"date_label": "2021年", "source_categories": ["民國110年詩"]})
            plan = root / "plan.jsonl"
            self.write_plan(plan, rel.as_posix(), raw, [
                self.membership(
                    "民國110年詩", "民國110年詩", "source",
                    self.action(
                        "split_date_from_category",
                        "date_label + categories",
                        "date_label=民國110年; category=詩",
                        "high",
                        "2021年",
                    ),
                )
            ])
            staged, _report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], errors)
            result = self.load_staged(staged, rel)
            self.assertEqual("2021年", result["date_label"])
            self.assertEqual(["詩"], result["categories"])
            self.assertNotIn("source_categories", result)

    def test_high_author_and_period_promotions_are_applied(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel, _target, raw = self.fixture(root, {"source_categories": ["李白", "唐朝"]})
            plan = root / "plan.jsonl"
            actions = [
                self.membership("李白", "李白", "source", self.action("promote_author_candidate", "authors", "李白")),
                self.membership("唐朝", "唐朝", "source", self.action("promote_period_metadata", "period", "唐朝")),
            ]
            self.write_plan(plan, rel.as_posix(), raw, actions)
            staged, _report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], errors)
            result = self.load_staged(staged, rel)
            self.assertEqual(["李白"], result["authors"])
            self.assertEqual("唐朝", result["period"])
            self.assertNotIn("source_categories", result)

    def test_review_action_is_never_applied(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel, _target, raw = self.fixture(root, {"source_categories": ["宋朝"]})
            plan = root / "plan.jsonl"
            self.write_plan(plan, rel.as_posix(), raw, [
                self.membership("宋朝", "宋朝", "source", self.action("period_path_date_conflict_review", "period", "宋朝", "review"))
            ])
            staged, report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], errors)
            self.assertEqual([], changed)
            self.assertEqual(1, report["counts"]["membership_review"])
            self.assertFalse((staged / rel).exists())

    def test_unknown_high_action_is_deferred_and_left_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel, _target, raw = self.fixture(root, {"source_categories": ["全唐文"]})
            plan = root / "plan.jsonl"
            self.write_plan(plan, rel.as_posix(), raw, [
                self.membership("全唐文", "全唐文", "source", self.action("promote_compilation_membership", "contained_in", "work_id=1; title=全唐文"))
            ])
            staged, report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], errors)
            self.assertEqual([], changed)
            self.assertEqual(1, report["deferred_high_actions"])

    def test_safe_only_skips_high_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel, _target, raw = self.fixture(root, {"source_categories": ["李白"]})
            plan = root / "plan.jsonl"
            self.write_plan(plan, rel.as_posix(), raw, [
                self.membership("李白", "李白", "source", self.action("promote_author_candidate", "authors", "李白"))
            ])
            staged, report, changed, errors = self.run_stage(root, plan, safe_only=True)
            self.assertEqual([], errors)
            self.assertEqual([], changed)
            self.assertEqual(1, report["counts"]["membership_high_skipped"])

    def test_fully_resolved_title_suffix_is_stripped_and_author_promoted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = {"title": "靜夜思 (李白)", "work_base_title": "靜夜思 (李白)"}
            rel, _target, raw = self.fixture(root, metadata)
            plan = root / "plan.jsonl"
            title_action = {
                "current_title": "靜夜思 (李白)",
                "proposed_title": "靜夜思",
                "suffix": "李白",
                "action": self.action("strip_title_author_suffix_promote", "title + authors", "李白"),
            }
            self.write_plan(plan, rel.as_posix(), raw, title_actions=[title_action])
            staged, report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], errors)
            result = self.load_staged(staged, rel)
            self.assertEqual("靜夜思", result["title"])
            self.assertEqual("靜夜思", result["work_base_title"])
            self.assertEqual(["李白"], result["authors"])
            self.assertEqual(1, report["counts"]["title_cleaned"])

    def test_unresolved_title_suffix_prevents_title_stripping(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = {"title": "靜夜思 (李白) (某本)", "work_base_title": "靜夜思 (李白) (某本)"}
            rel, _target, raw = self.fixture(root, metadata)
            plan = root / "plan.jsonl"
            title_actions = [
                {
                    "current_title": metadata["title"], "proposed_title": "靜夜思", "suffix": "李白",
                    "action": self.action("strip_title_author_suffix_promote", "title + authors", "李白"),
                },
                {
                    "current_title": metadata["title"], "proposed_title": "靜夜思", "suffix": "某本",
                    "action": self.action("strip_title_edition_suffix_promote", "title + editions.edition_label", "某本"),
                },
            ]
            self.write_plan(plan, rel.as_posix(), raw, title_actions=title_actions)
            staged, report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], errors)
            result = self.load_staged(staged, rel)
            self.assertEqual(metadata["title"], result["title"])
            self.assertEqual(["李白"], result["authors"])
            self.assertEqual(1, report["counts"]["title_not_cleaned"])

    def test_stale_metadata_hash_aborts_staging_for_that_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel, target, raw = self.fixture(root, {"source_categories": ["PD-old"]})
            plan = root / "plan.jsonl"
            self.write_plan(plan, rel.as_posix(), raw, [
                self.membership("PD-old", "PD-old", "source", self.action("delete_structural_noise", "categories/source_categories", "", "safe"))
            ])
            target.write_bytes(self.metadata_bytes({"source_categories": ["PD-old"], "title": "changed"}))
            staged, _report, changed, errors = self.run_stage(root, plan)
            self.assertEqual([], changed)
            self.assertTrue(any("stale metadata" in error for error in errors))
            self.assertFalse((staged / rel).exists())

    def test_overlay_keeps_bom_and_sets_utf8_filename_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus = root / "corpus"
            rel, _target, _raw = self.fixture(root, {"title": "測試"})
            staged = root / "staged"
            staged_target = staged / rel
            staged_target.parent.mkdir(parents=True)
            staged_target.write_bytes(self.metadata_bytes({"title": "測試", "period": "唐朝"}))
            overlay = root / "overlay.zip"
            apply_mod.write_overlay(overlay, root, corpus, staged, [rel])
            with zipfile.ZipFile(overlay) as archive:
                info = archive.infolist()[0]
                self.assertTrue(info.flag_bits & 0x800)
                self.assertTrue(archive.read(info).startswith(b"\xef\xbb\xbf"))
                self.assertIn("中國漢文", info.filename)


if __name__ == "__main__":
    unittest.main()
