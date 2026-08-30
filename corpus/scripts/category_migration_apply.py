#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Iterable

PLAN_SCHEMA = "fanyahanwen.category_migration.application_plan"
PLAN_VERSION = 1
REPORT_SCHEMA = "fanyahanwen.category_migration.application_report"
REPORT_VERSION = 1

SAFE_TAXONOMY_KEEP_ACTIONS = {
    "keep_controlled_taxonomy",
    "keep_pattern_taxonomy",
    "keep_scoped_category",
}

CATEGORY_TRANSFORM_ACTIONS = {
    "normalize_category_traditional",
    "remove_category_namespace",
    "normalize_category",
    "split_category",
    "normalize_religion_text_category",
    "split_period_from_taxonomy",
    "split_period_from_poetry",
    "split_period_from_ci",
    "split_geography_from_han_literary_form",
    "promote_shijing_genre_category",
}

SCALAR_PROMOTION_ACTIONS = {
    "promote_period_metadata": "period",
    "promote_period_from_range_category": "period",
    "promote_polity_metadata": "polity",
    "promote_date_metadata": "date_label",
    "promote_source_period_metadata": "period",
    "promote_source_period_phase_metadata": "period",
    "promote_source_material_metadata": "medium",
    "promote_epigraphic_material_metadata": "medium",
    "promote_oracle_bone_material_metadata": "medium",
}

SCALAR_NORMALIZATION_ACTIONS = {
    "normalize_digital_medium": "medium",
    "normalize_epigraphic_medium": "medium",
}

SUPPORTED_TITLE_ACTIONS = {
    "strip_title_date_suffix_redundant",
    "strip_title_date_suffix_promote",
    "strip_title_edition_suffix_redundant",
    "strip_title_author_suffix_redundant",
    "strip_title_person_role_suffix_redundant",
    "strip_title_author_suffix_promote",
    "strip_title_contributor_suffix_promote",
}

DEFERRED_STRUCTURAL_ACTION_PREFIXES = (
    "promote_compilation_membership",
    "promote_book_grouping_membership",
    "promote_serial_publication_membership",
)


class ApplicationError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent
    parser = argparse.ArgumentParser(
        description=(
            "Apply the exact machine-readable decisions emitted by category_migration.py. "
            "Review actions are never applied. Metadata SHA-256 values are checked before any output is committed."
        )
    )
    parser.add_argument("--plan", type=Path, required=True, help="JSONL plan written by category_migration.py --application-plan.")
    parser.add_argument("--corpus-root", type=Path, default=repo_root / "corpus")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--overlay", type=Path, default=None, help="Write only changed repository-ready metadata.json files to this ZIP.")
    mode.add_argument("--apply", action="store_true", help="Atomically replace the changed metadata.json files in the corpus.")
    parser.add_argument(
        "--safe-only",
        action="store_true",
        help="Apply only planner confidence=safe. By default deterministic high-confidence actions are applied too.",
    )
    parser.add_argument("--limit", type=int, default=None, help="Process at most N work records from the plan; intended for smoke tests.")
    parser.add_argument("--report", type=Path, default=None, help="Optional UTF-8-BOM JSON report. It is never placed inside the overlay ZIP.")
    parser.add_argument(
        "--fail-on-deferred-high",
        action="store_true",
        help="Abort if a high-confidence action is intentionally deferred because its target schema still needs structural resolution.",
    )
    return parser.parse_args()


def clean_text(value: object) -> str:
    return "" if value is None else str(value).strip()


def string_list(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    output: list[str] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, str):
            continue
        text = item.strip()
        if text and text not in seen:
            output.append(text)
            seen.add(text)
    return output


def metadata_bytes(metadata: dict) -> bytes:
    text = json.dumps(metadata, ensure_ascii=False, indent=2) + "\n"
    return b"\xef\xbb\xbf" + text.encode("utf-8")


def metadata_sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def load_metadata(raw: bytes, path: Path) -> dict:
    try:
        value = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ApplicationError(f"{path}: invalid UTF-8/JSON metadata: {exc}") from exc
    if not isinstance(value, dict):
        raise ApplicationError(f"{path}: metadata root is not an object")
    return value


def remove_exact(values: object, target: str) -> tuple[list[object], bool]:
    if not isinstance(values, list):
        return ([] if values is None else list(values) if isinstance(values, tuple) else []), False
    output: list[object] = []
    changed = False
    for value in values:
        if isinstance(value, str) and value == target:
            changed = True
            continue
        output.append(value)
    return output, changed


def add_unique_string(metadata: dict, field: str, value: str) -> bool:
    value = clean_text(value)
    if not value:
        return False
    current = metadata.get(field)
    if current is None:
        metadata[field] = [value]
        return True
    if not isinstance(current, list):
        raise ApplicationError(f"{field} is not an array")
    if value in current:
        return False
    current.append(value)
    return True


def set_scalar(metadata: dict, field: str, value: str, *, expected: str = "", replace_expected: bool = False) -> bool:
    value = clean_text(value)
    if not value:
        raise ApplicationError(f"refusing to set empty scalar {field}")
    current = metadata.get(field)
    current_text = clean_text(current)
    if not current_text:
        metadata[field] = value
        return True
    if current_text == value:
        return False
    if replace_expected and expected and current_text == clean_text(expected):
        metadata[field] = value
        return True
    raise ApplicationError(f"{field} changed unexpectedly: current={current_text!r}, proposed={value!r}")


def remove_category_membership(metadata: dict, raw_category: str, origin: str) -> bool:
    raw_category = clean_text(raw_category)
    if not raw_category:
        return False
    fields: list[str]
    if origin == "source":
        fields = ["source_categories"]
    elif origin == "curated":
        fields = ["categories"]
    elif origin == "curated+source":
        fields = ["categories", "source_categories"]
    elif origin.startswith("derived:"):
        return False
    else:
        raise ApplicationError(f"unknown category origin {origin!r}")

    changed = False
    for field in fields:
        values = metadata.get(field)
        if values is None:
            continue
        if not isinstance(values, list):
            raise ApplicationError(f"{field} is not an array")
        new_values, removed = remove_exact(values, raw_category)
        if removed:
            metadata[field] = new_values
            changed = True
    return changed


def migrate_taxonomy_category(metadata: dict, raw_category: str, canonical: str, origin: str) -> bool:
    changed = remove_category_membership(metadata, raw_category, origin)
    changed = add_unique_string(metadata, "categories", canonical) or changed
    return changed


def parse_pipe_values(value: str) -> list[str]:
    return [part.strip() for part in value.split(" | ") if part.strip()]


def parse_assignments(value: str) -> dict[str, str]:
    output: dict[str, str] = {}
    for part in value.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        key, item = part.split("=", 1)
        key = key.strip()
        item = item.strip()
        if key:
            output[key] = item
    return output


def add_mention(metadata: dict, target_field: str, value: str) -> bool:
    if not target_field.startswith("mentions."):
        raise ApplicationError(f"unsupported mention target {target_field!r}")
    key = target_field.split(".", 1)[1]
    mentions = metadata.get("mentions")
    if mentions is None:
        mentions = {}
        metadata["mentions"] = mentions
    if not isinstance(mentions, dict):
        raise ApplicationError("mentions is not an object")
    current = mentions.get(key)
    if current is None:
        mentions[key] = [value]
        return True
    if not isinstance(current, list):
        raise ApplicationError(f"mentions.{key} is not an array")
    if value in current:
        return False
    current.append(value)
    return True


def add_contributor(metadata: dict, name: str, role: str, target_field: str) -> bool:
    name = clean_text(name)
    role = clean_text(role)
    if not name:
        raise ApplicationError("empty contributor name")
    if target_field == "authors":
        return add_unique_string(metadata, "authors", name)
    if target_field == "editors":
        return add_unique_string(metadata, "editors", name)
    if target_field != "contributors":
        raise ApplicationError(f"unsupported contributor target {target_field!r}")

    current = metadata.get("contributors")
    if current is None:
        current = []
        metadata["contributors"] = current
    if not isinstance(current, list):
        raise ApplicationError("contributors is not an array")
    for entry in current:
        if isinstance(entry, dict) and clean_text(entry.get("name")) == name and clean_text(entry.get("role")) == role:
            return False
        if isinstance(entry, str) and entry == name and not role:
            return False
    item: object = {"name": name, "role": role} if role else name
    current.append(item)
    return True


def ensure_material(metadata: dict) -> dict:
    material = metadata.get("material")
    if material is None:
        material = {}
        metadata["material"] = material
    if not isinstance(material, dict):
        raise ApplicationError("material is not an object")
    return material


def set_material_species(metadata: dict, proposed_json: str, expected: str) -> bool:
    try:
        proposed = json.loads(proposed_json)
    except json.JSONDecodeError as exc:
        raise ApplicationError(f"invalid material.species JSON proposal: {exc}") from exc
    if not isinstance(proposed, dict):
        raise ApplicationError("material.species proposal is not an object")
    material = ensure_material(metadata)
    current = material.get("species")
    if current == proposed:
        return False
    if current is None:
        material["species"] = proposed
        return True
    current_display = json.dumps(current, ensure_ascii=False, sort_keys=True, separators=(",", ":")) if isinstance(current, dict) else clean_text(current)
    expected_display = clean_text(expected)
    # Planner compact JSON is key-sorted; compare semantically when possible.
    try:
        expected_value = json.loads(expected_display) if expected_display.startswith("{") else expected_display
    except json.JSONDecodeError:
        expected_value = expected_display
    if current == expected_value:
        material["species"] = proposed
        return True
    raise ApplicationError(f"material.species changed unexpectedly: current={current_display}")


def action_allowed(action: dict, safe_only: bool) -> bool:
    confidence = clean_text(action.get("confidence"))
    if confidence == "review":
        return False
    if confidence == "safe":
        return True
    return confidence == "high" and not safe_only


def action_status_bucket(action: dict, safe_only: bool) -> str | None:
    confidence = clean_text(action.get("confidence"))
    if confidence == "review":
        return "review"
    if confidence == "high" and safe_only:
        return "high_skipped"
    if confidence not in {"safe", "high"}:
        return "unsupported_confidence"
    return None


def apply_membership_action(metadata: dict, item: dict, safe_only: bool) -> tuple[str, str]:
    action = item.get("action") if isinstance(item.get("action"), dict) else {}
    name = clean_text(action.get("action"))
    confidence = clean_text(action.get("confidence"))
    raw = clean_text(item.get("raw_category"))
    canonical = clean_text(item.get("canonical_category"))
    origin = clean_text(item.get("origin"))
    target = clean_text(action.get("target_field"))
    proposed = clean_text(action.get("proposed_value"))
    expected = clean_text(action.get("existing_value"))

    blocked = action_status_bucket(action, safe_only)
    if blocked:
        return blocked, "planner action is not eligible for automatic application"

    if name in SAFE_TAXONOMY_KEEP_ACTIONS:
        changed = migrate_taxonomy_category(metadata, raw, canonical or proposed or raw, origin)
        return ("applied" if changed else "no_change"), "kept as curated taxonomy"

    if confidence == "safe" and (name.startswith("remove_") or name.startswith("delete_")):
        changed = remove_category_membership(metadata, raw, origin)
        return ("applied" if changed else "no_change"), "removed redundant/noise category membership"

    if name in CATEGORY_TRANSFORM_ACTIONS:
        changed = False
        if raw:
            changed = remove_category_membership(metadata, raw, origin)
        values = parse_pipe_values(proposed or canonical)
        if not values:
            return "deferred_high", "category transform has no usable proposed category"
        for value in values:
            changed = add_unique_string(metadata, "categories", value) or changed
        return ("applied" if changed else "no_change"), "migrated category into curated taxonomy"

    if name == "promote_period_and_split_taxonomy":
        assignments = parse_assignments(proposed)
        period = assignments.get("period", "")
        category = assignments.get("category", "")
        if not period or not category:
            return "deferred_high", "period/category composite proposal is incomplete"
        changed = set_scalar(metadata, "period", period)
        changed = add_unique_string(metadata, "categories", category) or changed
        changed = remove_category_membership(metadata, raw, origin) or changed
        return ("applied" if changed else "no_change"), "split chronology from taxonomy"

    if name in SCALAR_PROMOTION_ACTIONS:
        field = SCALAR_PROMOTION_ACTIONS[name]
        replace_expected = name in {"promote_source_period_phase_metadata"}
        changed = set_scalar(metadata, field, proposed, expected=expected, replace_expected=replace_expected)
        changed = remove_category_membership(metadata, raw, origin) or changed
        return ("applied" if changed else "no_change"), f"promoted {field}"

    if name in SCALAR_NORMALIZATION_ACTIONS:
        field = SCALAR_NORMALIZATION_ACTIONS[name]
        changed = set_scalar(metadata, field, proposed, expected=expected, replace_expected=True)
        changed = remove_category_membership(metadata, raw, origin) or changed
        return ("applied" if changed else "no_change"), f"normalized {field}"

    if name in {"promote_geographic_metadata", "promote_geographic_metadata_from_text_category"}:
        if target not in {"macro_region", "polity", "region"}:
            return "deferred_high", f"unsupported geographic target {target!r}"
        changed = set_scalar(metadata, target, proposed)
        changed = remove_category_membership(metadata, raw, origin) or changed
        return ("applied" if changed else "no_change"), f"promoted {target}"

    if name == "promote_material_metadata":
        if target != "medium":
            return "deferred_high", "animal/species material proposal needs its explicit structured material schema"
        changed = set_scalar(metadata, "medium", proposed)
        changed = remove_category_membership(metadata, raw, origin) or changed
        return ("applied" if changed else "no_change"), "promoted medium"

    if name == "promote_bronze_material_detail":
        material = ensure_material(metadata)
        current = clean_text(material.get("type"))
        if current and current != proposed:
            raise ApplicationError(f"material.type changed unexpectedly: current={current!r}, proposed={proposed!r}")
        changed = current != proposed
        material["type"] = proposed
        return ("applied" if changed else "no_change"), "promoted material.type"

    if name.startswith("normalize_species_"):
        changed = set_material_species(metadata, proposed, expected)
        return ("applied" if changed else "no_change"), "normalized existing material.species names"

    if name in {"promote_date_mention", "promote_person_mention", "promote_polity_period_mention"}:
        changed = add_mention(metadata, target, proposed)
        changed = remove_category_membership(metadata, raw, origin) or changed
        return ("applied" if changed else "no_change"), f"promoted {target}"

    if name == "split_date_from_category":
        assignments = parse_assignments(proposed)
        date_label = assignments.get("date_label", "")
        category = assignments.get("category", "")
        if not date_label or not category:
            return "deferred_high", "date/category composite proposal is incomplete"
        existing_source = clean_text(metadata.get("date_label") or metadata.get("date"))
        if existing_source:
            if expected and existing_source != expected:
                raise ApplicationError(
                    f"date metadata changed unexpectedly: current={existing_source!r}, planned={expected!r}"
                )
            changed = False
        else:
            changed = set_scalar(metadata, "date_label", date_label)
        changed = add_unique_string(metadata, "categories", category) or changed
        changed = remove_category_membership(metadata, raw, origin) or changed
        return ("applied" if changed else "no_change"), "split date metadata from taxonomy"

    if name == "promote_author_candidate":
        changed = add_unique_string(metadata, "authors", proposed)
        changed = remove_category_membership(metadata, raw, origin) or changed
        return ("applied" if changed else "no_change"), "promoted author"

    if name == "promote_contributor_role_candidate":
        assignments = parse_assignments(proposed.replace("; role=", ";role="))
        if assignments:
            # A role proposal starts with a bare name, so parse it separately.
            first = proposed.split(";", 1)[0].strip()
            role = assignments.get("role", "")
        else:
            first, role = proposed, ""
        changed = add_contributor(metadata, first, role, target)
        changed = remove_category_membership(metadata, raw, origin) or changed
        return ("applied" if changed else "no_change"), f"promoted contributor role to {target}"

    if name.startswith(DEFERRED_STRUCTURAL_ACTION_PREFIXES):
        return "deferred_high", "parent/grouping/publication structure must be resolved before writing its schema"

    return "deferred_high", f"no deterministic applier registered for {name}"


def apply_title_metadata(metadata: dict, item: dict, safe_only: bool) -> tuple[str, str]:
    action = item.get("action") if isinstance(item.get("action"), dict) else {}
    name = clean_text(action.get("action"))
    blocked = action_status_bucket(action, safe_only)
    if blocked:
        return blocked, "title action is not eligible for automatic application"
    if name not in SUPPORTED_TITLE_ACTIONS:
        return "deferred_high", f"title action {name} needs schema review before automatic stripping"

    proposed = clean_text(action.get("proposed_value"))
    expected = clean_text(action.get("existing_value"))
    target = clean_text(action.get("target_field"))
    changed = False
    if name == "strip_title_date_suffix_promote":
        changed = set_scalar(metadata, "date_label", proposed, expected=expected, replace_expected=False)
    elif name == "strip_title_author_suffix_promote":
        changed = add_unique_string(metadata, "authors", proposed)
    elif name == "strip_title_contributor_suffix_promote":
        assignments = parse_assignments(proposed.replace("; role=", ";role="))
        person = proposed.split(";", 1)[0].strip()
        role = assignments.get("role", "")
        target_field = "authors" if "authors" in target else "contributors"
        changed = add_contributor(metadata, person, role, target_field)
    return ("applied" if changed else "no_change"), "prepared structured title-suffix metadata"


def apply_title_cleanup(metadata: dict, items: list[dict], safe_only: bool) -> tuple[bool, str]:
    if not items:
        return False, ""
    applicable = []
    proposed_titles: set[str] = set()
    current_titles: set[str] = set()
    for item in items:
        action = item.get("action") if isinstance(item.get("action"), dict) else {}
        name = clean_text(action.get("action"))
        if action_status_bucket(action, safe_only) is not None or name not in SUPPORTED_TITLE_ACTIONS:
            return False, "at least one suffix remains review/deferred; clean title is preserved"
        proposed_titles.add(clean_text(item.get("proposed_title")))
        current_titles.add(clean_text(item.get("current_title")))
        applicable.append(item)
    if len(proposed_titles) != 1 or len(current_titles) != 1:
        return False, "title actions disagree about current/proposed title"
    proposed = next(iter(proposed_titles))
    current = next(iter(current_titles))
    if not proposed:
        return False, "empty proposed title"

    actual = clean_text(metadata.get("title"))
    if actual not in {current, proposed}:
        raise ApplicationError(f"title changed unexpectedly: current metadata={actual!r}, planned={current!r}")
    changed = False
    if actual != proposed:
        metadata["title"] = proposed
        changed = True
    if clean_text(metadata.get("work_base_title")) == current:
        metadata["work_base_title"] = proposed
        changed = True
    return changed, "stripped fully resolved source-added title suffixes"


def prune_empty_migration_fields(metadata: dict) -> bool:
    """Remove empty containers created by migration without touching unrelated metadata."""
    changed = False
    for field in ("categories", "source_categories"):
        if metadata.get(field) == []:
            metadata.pop(field, None)
            changed = True
    mentions = metadata.get("mentions")
    if isinstance(mentions, dict):
        for key in list(mentions):
            if mentions.get(key) == []:
                mentions.pop(key, None)
                changed = True
        if not mentions:
            metadata.pop("mentions", None)
            changed = True
    return changed


def validate_relative_metadata_path(value: str) -> Path:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or path.name != "metadata.json":
        raise ApplicationError(f"unsafe metadata path in plan: {value!r}")
    return path


def iter_plan(path: Path) -> tuple[dict, Iterable[dict]]:
    handle = path.open("r", encoding="utf-8-sig")
    try:
        first = handle.readline()
        if not first:
            raise ApplicationError("application plan is empty")
        header = json.loads(first)
        if not isinstance(header, dict) or header.get("record") != "header":
            raise ApplicationError("application plan is missing its header record")
        if header.get("schema") != PLAN_SCHEMA or int(header.get("version", 0)) != PLAN_VERSION:
            raise ApplicationError(f"unsupported application plan schema/version: {header.get('schema')!r} v{header.get('version')!r}")

        def records() -> Iterable[dict]:
            try:
                for line_number, line in enumerate(handle, start=2):
                    if not line.strip():
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError as exc:
                        raise ApplicationError(f"plan line {line_number}: invalid JSON: {exc}") from exc
                    if not isinstance(record, dict) or record.get("record") != "work":
                        raise ApplicationError(f"plan line {line_number}: expected a work record")
                    yield record
            finally:
                handle.close()

        return header, records()
    except Exception:
        handle.close()
        raise


def write_report(path: Path, report: dict) -> None:
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    path.write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))


def write_overlay(path: Path, repo_root: Path, corpus_root: Path, staged_root: Path, changed_paths: list[Path]) -> None:
    try:
        corpus_prefix = corpus_root.resolve().relative_to(repo_root.resolve())
    except ValueError as exc:
        raise ApplicationError("--overlay requires --corpus-root to be inside this repository") from exc
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        now = time.localtime()[:6]
        for rel in sorted(changed_paths, key=lambda value: value.as_posix()):
            arcname = (corpus_prefix / rel).as_posix()
            data = (staged_root / rel).read_bytes()
            info = zipfile.ZipInfo(arcname, date_time=now)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100644 & 0xFFFF) << 16
            if any(ord(char) > 127 for char in arcname):
                info.flag_bits |= 0x800
            archive.writestr(info, data)


def atomic_write(target: Path, data: bytes) -> None:
    temporary = target.with_name(f".{target.name}.category-migration-{os.getpid()}.tmp")
    try:
        temporary.write_bytes(data)
        try:
            os.chmod(temporary, target.stat().st_mode)
        except OSError:
            pass
        os.replace(temporary, target)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def stage_plan(args: argparse.Namespace, repo_root: Path, staged_root: Path) -> tuple[dict, list[Path], list[str]]:
    plan_path = args.plan.expanduser().resolve()
    corpus_root = args.corpus_root.expanduser().resolve()
    header, records = iter_plan(plan_path)
    counts: collections.Counter[str] = collections.Counter()
    action_counts: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    changed_paths: list[Path] = []
    errors: list[str] = []
    deferred_examples: list[dict[str, str]] = []
    work_records = 0

    for record in records:
        if args.limit is not None and work_records >= max(args.limit, 0):
            break
        work_records += 1
        counts["works_seen"] += 1
        try:
            rel = validate_relative_metadata_path(clean_text(record.get("metadata_path")))
            target = (corpus_root / rel).resolve()
            try:
                target.relative_to(corpus_root)
            except ValueError as exc:
                raise ApplicationError(f"plan path escapes corpus root: {rel}") from exc
            if not target.is_file():
                raise ApplicationError(f"missing metadata file: {rel}")
            raw = target.read_bytes()
            expected_hash = clean_text(record.get("metadata_sha256"))
            actual_hash = metadata_sha256(raw)
            if not expected_hash or actual_hash != expected_hash:
                raise ApplicationError(
                    f"stale metadata: {rel}; planned SHA-256 {expected_hash or '(missing)'}, current {actual_hash}"
                )
            metadata = load_metadata(raw, rel)
            original = json.dumps(metadata, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

            for item in record.get("membership_actions") or []:
                if not isinstance(item, dict):
                    continue
                action = item.get("action") if isinstance(item.get("action"), dict) else {}
                name = clean_text(action.get("action")) or "(missing action)"
                status, reason = apply_membership_action(metadata, item, args.safe_only)
                counts[f"membership_{status}"] += 1
                action_counts[name][status] += 1
                if status == "deferred_high" and len(deferred_examples) < 200:
                    deferred_examples.append({"metadata_path": rel.as_posix(), "action": name, "reason": reason})

            title_items = [item for item in (record.get("title_actions") or []) if isinstance(item, dict)]
            for item in title_items:
                action = item.get("action") if isinstance(item.get("action"), dict) else {}
                name = clean_text(action.get("action")) or "(missing action)"
                status, reason = apply_title_metadata(metadata, item, args.safe_only)
                counts[f"title_{status}"] += 1
                action_counts[name][status] += 1
                if status == "deferred_high" and len(deferred_examples) < 200:
                    deferred_examples.append({"metadata_path": rel.as_posix(), "action": name, "reason": reason})
            title_changed, title_reason = apply_title_cleanup(metadata, title_items, args.safe_only)
            if title_items:
                counts["title_cleaned" if title_changed else "title_not_cleaned"] += 1
                if not title_changed and title_reason and len(deferred_examples) < 200:
                    # Only record this once per work; individual action reasons are above.
                    deferred_examples.append({"metadata_path": rel.as_posix(), "action": "title_cleanup", "reason": title_reason})

            prune_empty_migration_fields(metadata)
            final = json.dumps(metadata, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            if final != original:
                stage = staged_root / rel
                stage.parent.mkdir(parents=True, exist_ok=True)
                stage.write_bytes(metadata_bytes(metadata))
                changed_paths.append(rel)
                counts["works_changed"] += 1
            else:
                counts["works_unchanged"] += 1
        except (ApplicationError, OSError) as exc:
            errors.append(str(exc))
            if len(errors) >= 100:
                break

    deferred_high = sum(counter.get("deferred_high", 0) for counter in action_counts.values())
    report = {
        "schema": REPORT_SCHEMA,
        "version": REPORT_VERSION,
        "plan": str(plan_path),
        "plan_generated_at": header.get("generated_at"),
        "mode": "apply" if args.apply else ("overlay" if args.overlay else "dry-run"),
        "safe_only": bool(args.safe_only),
        "counts": dict(sorted(counts.items())),
        "deferred_high_actions": deferred_high,
        "action_status": {name: dict(sorted(counter.items())) for name, counter in sorted(action_counts.items())},
        "deferred_examples": deferred_examples,
        "errors": errors,
    }
    return report, changed_paths, errors


def main() -> int:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent.resolve()
    corpus_root = args.corpus_root.expanduser().resolve()
    plan = args.plan.expanduser().resolve()
    if not plan.is_file():
        print(f"ERROR: plan does not exist: {plan}", file=sys.stderr)
        return 2
    if not corpus_root.is_dir():
        print(f"ERROR: corpus root does not exist: {corpus_root}", file=sys.stderr)
        return 2
    if args.overlay is not None:
        overlay = args.overlay.expanduser().resolve()
        if not overlay.parent.is_dir():
            print(f"ERROR: overlay directory does not exist: {overlay.parent}", file=sys.stderr)
            return 2
        if overlay.suffix.lower() != ".zip":
            print("ERROR: --overlay must end in .zip", file=sys.stderr)
            return 2
    else:
        overlay = None
    if args.report is not None:
        report_path = args.report.expanduser().resolve()
        if not report_path.parent.is_dir():
            print(f"ERROR: report directory does not exist: {report_path.parent}", file=sys.stderr)
            return 2
    else:
        report_path = None

    with tempfile.TemporaryDirectory(prefix="fanyahanwen-category-migration-") as temporary:
        staged_root = Path(temporary)
        report, changed_paths, errors = stage_plan(args, repo_root, staged_root)
        if errors:
            if report_path:
                write_report(report_path, report)
            print("ERROR: application preflight failed; no metadata files were written.", file=sys.stderr)
            for error in errors[:20]:
                print(f"  - {error}", file=sys.stderr)
            if len(errors) > 20:
                print(f"  - ... {len(errors) - 20} more", file=sys.stderr)
            return 2

        if args.fail_on_deferred_high and report.get("deferred_high_actions", 0):
            if report_path:
                write_report(report_path, report)
            print(
                f"ERROR: {report['deferred_high_actions']} high-confidence action(s) are intentionally deferred; no output committed.",
                file=sys.stderr,
            )
            return 2

        if overlay is not None:
            write_overlay(overlay, repo_root, corpus_root, staged_root, changed_paths)
            print(f"Overlay: {overlay}", file=sys.stderr)
        elif args.apply:
            for rel in sorted(changed_paths, key=lambda value: value.as_posix()):
                atomic_write(corpus_root / rel, (staged_root / rel).read_bytes())
            print(f"Applied metadata files: {len(changed_paths):,}", file=sys.stderr)
        else:
            print("Dry run only: no metadata files written. Use --overlay or --apply to commit the staged changes.", file=sys.stderr)

        if report_path:
            write_report(report_path, report)
            print(f"Report: {report_path}", file=sys.stderr)

        counts = report.get("counts", {})
        print(
            "Works: "
            f"{counts.get('works_seen', 0):,} seen; "
            f"{counts.get('works_changed', 0):,} would change; "
            f"{report.get('deferred_high_actions', 0):,} high-confidence actions deferred; "
            f"{counts.get('membership_review', 0) + counts.get('title_review', 0):,} review actions protected.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
