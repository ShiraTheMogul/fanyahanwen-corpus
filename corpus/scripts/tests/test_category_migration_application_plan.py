#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import category_migration as migration
import category_migration_apply as apply_mod


class CategoryMigrationApplicationPlanTest(unittest.TestCase):
    def work(self, metadata_path: Path) -> migration.Work:
        return migration.Work(
            metadata_path=metadata_path,
            work_id="42",
            title="測試",
            work_base_title="測試",
            aliases=(),
            date_label="",
            date="",
            year_start=None,
            year_end=None,
            period="",
            polity="",
            macro_region="中國",
            region="",
            medium="",
            object_type="",
            material={},
            is_compilation=False,
            categories=(),
            source_categories=("唐朝",),
            authors=(),
            editors=(),
            contributors=(),
            document_authors=(),
            contained_in=(),
            editions=(),
            sources=(),
            identifiers=(),
            documents=(),
        )

    def test_planner_jsonl_round_trips_into_applier_with_sha_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus = root / "corpus"
            rel = Path("中國漢文/clean/唐朝/測試/metadata.json")
            target = corpus / rel
            target.parent.mkdir(parents=True)
            metadata = {"schema_version": 1, "title": "測試", "source_categories": ["唐朝"]}
            target.write_bytes(b"\xef\xbb\xbf" + (json.dumps(metadata, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))

            work = self.work(rel)
            membership = migration.MembershipAction(
                raw_category="唐朝",
                canonical_category="唐朝",
                origin="source",
                work=work,
                action=migration.Action(
                    "promote_period_metadata",
                    "period",
                    "唐朝",
                    "high",
                    "",
                    "fixture",
                    "fixture",
                ),
            )
            plan = root / "migration.plan.jsonl"
            migration.write_application_plan(
                plan,
                corpus,
                [membership],
                [],
                "2026-08-29T12:00:00Z",
            )
            self.assertTrue(plan.read_bytes().startswith(b"\xef\xbb\xbf"))

            staged = root / "staged"
            staged.mkdir()
            args = argparse.Namespace(
                plan=plan,
                corpus_root=corpus,
                safe_only=False,
                limit=None,
                apply=False,
                overlay=None,
                fail_on_deferred_high=False,
            )
            report, changed, errors = apply_mod.stage_plan(args, root, staged)
            self.assertEqual([], errors)
            self.assertEqual([rel], changed)
            result = json.loads((staged / rel).read_bytes().decode("utf-8-sig"))
            self.assertEqual("唐朝", result["period"])
            self.assertNotIn("source_categories", result)
            self.assertEqual(1, report["counts"]["works_changed"])


if __name__ == "__main__":
    unittest.main()
