#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime as dt
import json
import hashlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path
from typing import Iterable, Sequence

from category_audit import SheetSpec, read_json, write_xlsx
from calendar_engine_client import CalendarEngineClient
from historical_annotator_client import HistoricalAnnotatorClient


_CALENDAR_ENGINE: CalendarEngineClient | None = None
_HISTORICAL_ANNOTATOR: HistoricalAnnotatorClient | None = None


def calendar_engine() -> CalendarEngineClient:
    """Return the one shared Rails calendar-engine process for this audit run.

    Python owns only the process transport. All date grammar, numeral parsing,
    epochs, calendar conversions, and historical nomenclature stay in Ruby's
    CalendarEngine.
    """
    global _CALENDAR_ENGINE
    if _CALENDAR_ENGINE is None:
        _CALENDAR_ENGINE = CalendarEngineClient()
    return _CALENDAR_ENGINE


def historical_annotator() -> HistoricalAnnotatorClient:
    """Return the shared Rails named-entity annotator process for this run.

    Python supplies text, metadata context, and the person-category surface forms
    it wants checked. CbdbAutoAnnotator remains the sole owner of person scoring,
    temporal gates, ambiguity handling, and Literary-Chinese syntax heuristics.
    """
    global _HISTORICAL_ANNOTATOR
    if _HISTORICAL_ANNOTATOR is None:
        _HISTORICAL_ANNOTATOR = HistoricalAnnotatorClient()
    return _HISTORICAL_ANNOTATOR


@dataclasses.dataclass(frozen=True)
class Work:
    metadata_path: Path
    work_id: str
    title: str
    work_base_title: str
    aliases: tuple[str, ...]
    date_label: str
    date: str
    year_start: int | None
    year_end: int | None
    period: str
    polity: str
    macro_region: str
    region: str
    medium: str
    object_type: str
    material: dict
    is_compilation: bool
    categories: tuple[str, ...]
    source_categories: tuple[str, ...]
    authors: tuple[str, ...]
    editors: tuple[str, ...]
    contributors: tuple[str, ...]
    document_authors: tuple[str, ...]
    contained_in: tuple[dict, ...]
    editions: tuple[dict, ...]
    sources: tuple[str, ...]
    identifiers: tuple[dict, ...]
    documents: tuple[dict, ...]
    metadata_sha256: str = ""


@dataclasses.dataclass
class Evidence:
    occurrences: int = 0
    documents: set[str] = dataclasses.field(default_factory=set)
    first_document: str = ""
    first_snippet: str = ""
    person_annotation_confidences: collections.Counter[str] = dataclasses.field(default_factory=collections.Counter)
    person_annotation_documents: set[str] = dataclasses.field(default_factory=set)
    person_annotation_attempts: int = 0
    person_annotation_authority_available: bool = False
    first_person_annotation: str = ""


@dataclasses.dataclass
class PreamblePersonEvidence:
    roles: collections.Counter[str] = dataclasses.field(default_factory=collections.Counter)
    documents: set[str] = dataclasses.field(default_factory=set)
    first_document: str = ""
    first_snippet: str = ""


@dataclasses.dataclass(frozen=True)
class Action:
    action: str
    target_field: str
    proposed_value: str
    confidence: str
    existing_value: str
    evidence: str
    note: str


@dataclasses.dataclass(frozen=True)
class MembershipAction:
    raw_category: str
    canonical_category: str
    origin: str
    work: Work
    action: Action
    body_occurrences: int = 0
    body_documents: int = 0
    body_coverage: float = 0.0


@dataclasses.dataclass(frozen=True)
class TitleAction:
    work: Work
    current_title: str
    proposed_title: str
    suffix: str
    action: Action


@dataclasses.dataclass(frozen=True)
class DateCategory:
    raw: str
    canonical: str
    year: int
    month: int | None
    day: int | None
    is_mention: bool

    @property
    def specificity(self) -> int:
        if self.day is not None:
            return 3
        if self.month is not None:
            return 2
        return 1

    @property
    def source_label(self) -> str:
        return re.sub(r"\s*[（(]提及[)）]\s*$", "", self.canonical.strip())

    @property
    def label(self) -> str:
        """Absolute Gregorian-equivalent label used for comparison/reporting."""
        value = f"{self.year}年"
        if self.month is not None:
            value += f"{self.month}月"
        if self.day is not None:
            value += f"{self.day}日"
        return value


class Traditionalizer:
    """Category/title normalizer backed by OpenCC.

    OpenCC's phrase dictionaries are the authority for Simplified->Traditional
    conversion.  The older Unihan kTraditionalVariant path remains available only
    as an explicit compatibility fallback because kTraditionalVariant is a
    variant relation, not a Simplified-Chinese conversion table.
    """

    def __init__(
        self,
        mapping_path: Path | None,
        ambiguous: set[str],
        forced: dict[str, str],
        phrase_overrides: dict[str, str] | None = None,
        *,
        backend: str = "opencc",
        opencc_config: str = "s2t.json",
    ) -> None:
        self.mapping: dict[str, str] = {}
        self.ambiguous = set(ambiguous)
        self.auto_ambiguous: set[str] = set()
        self.forced = forced
        self.phrase_overrides = tuple(
            sorted(
                ((str(source), str(target)) for source, target in (phrase_overrides or {}).items() if str(source)),
                key=lambda pair: (-len(pair[0]), pair[0]),
            )
        )
        self.mapping_path = mapping_path
        self.backend = backend
        self.opencc_config = opencc_config
        self.opencc = None
        self.opencc_cli = ""
        self.cache: dict[str, str] = {}
        self.loaded = False

        if backend == "opencc":
            self._load_opencc()
        elif backend == "unihan":
            if mapping_path is not None and mapping_path.is_file():
                self._load_unihan(mapping_path)
        else:
            raise ValueError(f"unknown traditionalization backend: {backend}")

    @property
    def backend_name(self) -> str:
        if self.backend == "opencc" and self.opencc is not None:
            return f"OpenCC Python ({self.opencc_config})"
        if self.backend == "opencc" and self.opencc_cli:
            return f"OpenCC CLI ({self.opencc_config})"
        if self.backend == "unihan":
            return "Unihan kTraditionalVariant compatibility fallback"
        return self.backend

    def _load_opencc(self) -> None:
        try:
            import opencc  # type: ignore

            self.opencc = opencc.OpenCC(self.opencc_config)
            # Fail immediately if the config/resource path is invalid.
            self.opencc.convert("汉字")
            self.loaded = True
            return
        except (ImportError, ModuleNotFoundError):
            self.opencc = None
        except Exception as exc:
            raise RuntimeError(f"OpenCC Python backend could not load {self.opencc_config}: {exc}") from exc

        executable = shutil.which("opencc")
        if executable:
            self.opencc_cli = executable
            # A real conversion test catches missing s2t.json resources early.
            result = subprocess.run(
                [executable, "-c", self.opencc_config],
                input="汉字\n",
                text=True,
                capture_output=True,
                encoding="utf-8",
                errors="strict",
            )
            if result.returncode != 0:
                raise RuntimeError(
                    f"OpenCC CLI could not load {self.opencc_config}: {result.stderr.strip() or result.stdout.strip()}"
                )
            self.loaded = True
            return

        raise RuntimeError(
            "OpenCC is required for category/title traditionalization. Install the Python package "
            "(`pip install opencc`) or the OpenCC command-line program, then rerun. "
            "Use --traditional-backend unihan only for an intentional compatibility test."
        )

    def _load_unihan(self, path: Path) -> None:
        candidates: dict[str, set[str]] = collections.defaultdict(set)
        with path.open("r", encoding="utf-8-sig", errors="strict") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "\tkTraditionalVariant\t" not in line:
                    continue
                left, right = line.split("\tkTraditionalVariant\t", 1)
                parts = left.split()
                if len(parts) < 2:
                    continue
                source = parts[1]
                for codepoint in re.findall(r"U\+([0-9A-Fa-f]{4,6})", right):
                    try:
                        candidates[source].add(chr(int(codepoint, 16)))
                    except ValueError:
                        pass
        for source, targets in candidates.items():
            if source in targets:
                continue
            if len(targets) == 1:
                self.mapping[source] = next(iter(targets))
            elif len(targets) > 1:
                self.auto_ambiguous.add(source)
        self.loaded = True

    def preload(self, values: Iterable[str]) -> None:
        """Bulk-convert known corpus strings when only the OpenCC CLI is available.

        This avoids launching one process for every category. JSON string literals
        make embedded tabs/newlines safe while OpenCC converts the Han text inside
        each line.
        """
        if self.backend != "opencc" or not self.opencc_cli:
            return
        pending = sorted(
            {
                unicodedata.normalize("NFC", str(value).strip())
                for value in values
                if str(value).strip() and unicodedata.normalize("NFC", str(value).strip()) not in self.cache
            }
        )
        if not pending:
            return
        with tempfile.TemporaryDirectory(prefix="fanya-opencc-") as directory:
            input_path = Path(directory) / "input.jsonl"
            output_path = Path(directory) / "output.jsonl"
            with input_path.open("w", encoding="utf-8") as handle:
                for value in pending:
                    handle.write(json.dumps(value, ensure_ascii=False) + "\n")
            result = subprocess.run(
                [self.opencc_cli, "-c", self.opencc_config, "-i", str(input_path), "-o", str(output_path)],
                text=True,
                capture_output=True,
                encoding="utf-8",
                errors="strict",
            )
            if result.returncode != 0:
                raise RuntimeError(f"OpenCC batch conversion failed: {result.stderr.strip() or result.stdout.strip()}")
            converted_lines = output_path.read_text(encoding="utf-8").splitlines()
            if len(converted_lines) != len(pending):
                raise RuntimeError(
                    f"OpenCC batch conversion returned {len(converted_lines)} lines for {len(pending)} inputs"
                )
            for source, line in zip(pending, converted_lines):
                try:
                    self.cache[source] = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise RuntimeError(f"OpenCC produced invalid JSON-line output for {source!r}: {line!r}") from exc

    def _opencc_convert(self, value: str) -> str:
        if value in self.cache:
            return self.cache[value]
        if self.opencc is not None:
            converted = self.opencc.convert(value)
            self.cache[value] = converted
            return converted
        if self.opencc_cli:
            result = subprocess.run(
                [self.opencc_cli, "-c", self.opencc_config],
                input=value,
                text=True,
                capture_output=True,
                encoding="utf-8",
                errors="strict",
            )
            if result.returncode != 0:
                raise RuntimeError(f"OpenCC conversion failed: {result.stderr.strip() or result.stdout.strip()}")
            converted = result.stdout
            self.cache[value] = converted
            return converted
        raise RuntimeError("OpenCC backend is not loaded")

    def normalize(self, text: str) -> tuple[str, tuple[str, ...]]:
        value = unicodedata.normalize("NFC", text.strip())
        if self.backend == "opencc":
            return self._opencc_convert(value), ()

        # Explicit compatibility fallback only.  Keep the old conservative
        # behavior for reproducing older audit runs when requested.
        for source, target in self.phrase_overrides:
            value = value.replace(source, target)
        unresolved: list[str] = []
        out: list[str] = []
        for char in value:
            if char in self.forced:
                out.append(self.forced[char])
                continue
            if char in self.ambiguous or char in self.auto_ambiguous:
                out.append(char)
                unresolved.append(char)
                continue
            out.append(self.mapping.get(char, char))
        return "".join(out), tuple(dict.fromkeys(unresolved))


@dataclasses.dataclass(frozen=True)
class CbdbPersonCandidate:
    person_id: str
    primary_name: str
    matched_name: str
    primary_match: bool
    year_start: int | None
    year_end: int | None


@dataclasses.dataclass(frozen=True)
class CbdbRoleEvidence:
    person_id: str
    primary_name: str
    matched_name: str
    text_title: str
    role: str
    role_label: str


class CbdbAuthority:
    """Read-only exact-name/text-role access to the local CBDB SQLite.

    The Rails viewer already maintains CBDB under viewer/data.  This small Python
    facade reuses that source for the migration planner; it does not download,
    copy, or modify CBDB.
    """

    PERSON_ID_COLUMNS = ("c_personid", "person_id")
    PERSON_NAME_COLUMNS = ("c_name_chn", "c_name_ch", "name_chn")
    ALT_NAME_COLUMNS = ("c_alt_name_chn", "c_altname_chn", "c_name_chn", "alt_name_chn")
    BIRTH_COLUMNS = ("c_birthyear", "birthyear")
    DEATH_COLUMNS = ("c_deathyear", "deathyear")
    FL_EARLIEST_COLUMNS = ("c_fl_earliest_year", "fl_earliest_year")
    FL_LATEST_COLUMNS = ("c_fl_latest_year", "fl_latest_year")
    INDEX_YEAR_COLUMNS = ("c_index_year", "index_year")
    FIRST_YEAR_COLUMNS = ("c_firstyear", "firstyear")
    LAST_YEAR_COLUMNS = ("c_lastyear", "lastyear")

    def __init__(self, path: Path) -> None:
        self.path = path.expanduser().resolve()
        uri = self.path.as_uri() + "?mode=ro"
        self.db = sqlite3.connect(uri, uri=True)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA query_only = ON")
        self.person_cache: dict[str, tuple[CbdbPersonCandidate, ...]] = {}
        self.text_role_cache: dict[str, tuple[tuple[str, str, str], ...]] = {}
        self.tables = {
            row[0]
            for row in self.db.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')")
        }
        if "BIOG_MAIN" not in self.tables:
            raise RuntimeError(f"CBDB BIOG_MAIN is missing: {self.path}")
        self.biog_columns = self._table_columns("BIOG_MAIN")
        self.person_id_col = self._choose(self.biog_columns, self.PERSON_ID_COLUMNS)
        self.person_name_col = self._choose(self.biog_columns, self.PERSON_NAME_COLUMNS)
        if not self.person_id_col or not self.person_name_col:
            raise RuntimeError("CBDB BIOG_MAIN does not expose recognizable person id/name columns")
        self.alt_columns = self._table_columns("ALTNAME_DATA") if "ALTNAME_DATA" in self.tables else []
        self.alt_person_id_col = self._choose(self.alt_columns, self.PERSON_ID_COLUMNS)
        self.alt_name_col = self._choose(self.alt_columns, self.ALT_NAME_COLUMNS)

        self.biog_text_columns = self._table_columns("BIOG_TEXT_DATA") if "BIOG_TEXT_DATA" in self.tables else []
        self.text_columns = self._table_columns("TEXT_CODES") if "TEXT_CODES" in self.tables else []
        self.text_role_columns = self._table_columns("TEXT_ROLE_CODES") if "TEXT_ROLE_CODES" in self.tables else []
        self.bt_person_col = self._choose(self.biog_text_columns, self.PERSON_ID_COLUMNS)
        self.bt_text_col = self._choose(self.biog_text_columns, ("c_textid", "text_id"))
        self.bt_role_col = self._choose(self.biog_text_columns, ("c_role_id", "role_id"))
        self.text_id_col = self._choose(self.text_columns, ("c_textid", "text_id"))
        self.text_title_chn_col = self._choose(self.text_columns, ("c_title_chn", "title_chn"))
        self.text_title_col = self._choose(self.text_columns, ("c_title", "title"))
        self.role_id_col = self._choose(self.text_role_columns, ("c_role_id", "role_id"))
        self.role_chn_col = self._choose(self.text_role_columns, ("c_role_desc_chn", "role_desc_chn"))
        self.role_en_col = self._choose(self.text_role_columns, ("c_role_desc", "role_desc"))

    def close(self) -> None:
        self.db.close()

    def _table_columns(self, table: str) -> list[str]:
        safe = table.replace('"', '""')
        return [str(row[1]) for row in self.db.execute(f'PRAGMA table_info("{safe}")')]

    @staticmethod
    def _choose(columns: Sequence[str], candidates: Sequence[str]) -> str:
        lookup = {column.lower(): column for column in columns}
        for candidate in candidates:
            if candidate.lower() in lookup:
                return lookup[candidate.lower()]
        return ""

    @staticmethod
    def _quote(value: str) -> str:
        return '"' + value.replace('"', '""') + '"'

    def _selected_expr(self, column: str, alias: str) -> str:
        return f"{self._quote(column)} AS {self._quote(alias)}" if column else f"NULL AS {self._quote(alias)}"

    def _person_select_sql(self, where_sql: str) -> str:
        birth = self._choose(self.biog_columns, self.BIRTH_COLUMNS)
        death = self._choose(self.biog_columns, self.DEATH_COLUMNS)
        fl_first = self._choose(self.biog_columns, self.FL_EARLIEST_COLUMNS)
        fl_last = self._choose(self.biog_columns, self.FL_LATEST_COLUMNS)
        index_year = self._choose(self.biog_columns, self.INDEX_YEAR_COLUMNS)
        first_year = self._choose(self.biog_columns, self.FIRST_YEAR_COLUMNS)
        last_year = self._choose(self.biog_columns, self.LAST_YEAR_COLUMNS)
        return (
            "SELECT "
            + ", ".join(
                [
                    self._selected_expr(self.person_id_col, "person_id"),
                    self._selected_expr(self.person_name_col, "primary_name"),
                    self._selected_expr(birth, "birth_year"),
                    self._selected_expr(death, "death_year"),
                    self._selected_expr(fl_first, "fl_earliest"),
                    self._selected_expr(fl_last, "fl_latest"),
                    self._selected_expr(index_year, "index_year"),
                    self._selected_expr(first_year, "first_year"),
                    self._selected_expr(last_year, "last_year"),
                ]
            )
            + " FROM BIOG_MAIN WHERE "
            + where_sql
        )

    @staticmethod
    def _row_year(row: sqlite3.Row, keys: Sequence[str]) -> int | None:
        for key in keys:
            value = row[key]
            if value is None or str(value).strip() == "":
                continue
            try:
                return int(value)
            except (TypeError, ValueError):
                continue
        return None

    def _candidate_from_row(self, row: sqlite3.Row, matched_name: str, primary_match: bool) -> CbdbPersonCandidate:
        return CbdbPersonCandidate(
            person_id=str(row["person_id"]),
            primary_name=clean_text(row["primary_name"]) or matched_name,
            matched_name=matched_name,
            primary_match=primary_match,
            year_start=self._row_year(row, ("birth_year", "fl_earliest", "index_year", "first_year")),
            year_end=self._row_year(row, ("death_year", "fl_latest", "index_year", "last_year")),
        )

    def resolve_labels(self, labels: Iterable[str]) -> dict[str, tuple[CbdbPersonCandidate, ...]]:
        wanted = sorted({clean_text(label) for label in labels if clean_text(label)})
        unresolved = [label for label in wanted if label not in self.person_cache]
        for start in range(0, len(unresolved), 300):
            chunk = unresolved[start : start + 300]
            placeholders = ",".join("?" for _ in chunk)
            rows_by_label: dict[str, dict[str, CbdbPersonCandidate]] = collections.defaultdict(dict)
            sql = self._person_select_sql(f"{self._quote(self.person_name_col)} IN ({placeholders})")
            for row in self.db.execute(sql, chunk):
                matched = clean_text(row["primary_name"])
                candidate = self._candidate_from_row(row, matched, True)
                rows_by_label[matched][candidate.person_id] = candidate

            if self.alt_person_id_col and self.alt_name_col:
                alt_sql = (
                    f"SELECT {self._quote(self.alt_person_id_col)} AS person_id, "
                    f"{self._quote(self.alt_name_col)} AS matched_name FROM ALTNAME_DATA "
                    f"WHERE {self._quote(self.alt_name_col)} IN ({placeholders})"
                )
                alt_rows = list(self.db.execute(alt_sql, chunk))
                ids = sorted({str(row["person_id"]) for row in alt_rows if clean_text(row["person_id"])})
                primary_rows: dict[str, sqlite3.Row] = {}
                for id_start in range(0, len(ids), 300):
                    id_chunk = ids[id_start : id_start + 300]
                    id_ph = ",".join("?" for _ in id_chunk)
                    person_sql = self._person_select_sql(f"{self._quote(self.person_id_col)} IN ({id_ph})")
                    for row in self.db.execute(person_sql, id_chunk):
                        primary_rows[str(row["person_id"])] = row
                for alt in alt_rows:
                    person_id = str(alt["person_id"])
                    matched = clean_text(alt["matched_name"])
                    primary = primary_rows.get(person_id)
                    if primary is None:
                        continue
                    candidate = self._candidate_from_row(primary, matched, False)
                    rows_by_label[matched].setdefault(candidate.person_id, candidate)

            for label in chunk:
                candidates = tuple(
                    sorted(
                        rows_by_label.get(label, {}).values(),
                        key=lambda candidate: (
                            0 if candidate.primary_match else 1,
                            candidate.year_start if candidate.year_start is not None else 99999,
                            candidate.person_id,
                        ),
                    )
                )
                self.person_cache[label] = candidates
        return {label: self.person_cache.get(label, ()) for label in wanted if self.person_cache.get(label)}

    @staticmethod
    def contextual_candidates(candidates: Sequence[CbdbPersonCandidate], work: Work) -> tuple[CbdbPersonCandidate, ...]:
        values = tuple(candidates)
        if len(values) <= 1:
            return values
        work_start = work.year_start
        work_end = work.year_end
        if work_start is None and work_end is None:
            primary = tuple(candidate for candidate in values if candidate.primary_match)
            return primary if len(primary) == 1 else values
        left = work_start if work_start is not None else work_end
        right = work_end if work_end is not None else work_start
        assert left is not None and right is not None
        viable: list[CbdbPersonCandidate] = []
        for candidate in values:
            c_left = candidate.year_start if candidate.year_start is not None else candidate.year_end
            c_right = candidate.year_end if candidate.year_end is not None else candidate.year_start
            if c_left is None or c_right is None:
                continue
            if c_right >= left and c_left <= right:
                viable.append(candidate)
        if viable:
            primary = [candidate for candidate in viable if candidate.primary_match]
            if len(primary) == 1:
                return tuple(primary)
            return tuple(viable)
        primary = tuple(candidate for candidate in values if candidate.primary_match)
        return primary if len(primary) == 1 else values

    @staticmethod
    def normalize_role(role_chn: str, role_en: str) -> str:
        """Preserve CBDB's intellectual-role distinctions where possible."""
        cn = re.sub(r"\s+", "", clean_text(role_chn))
        en = clean_text(role_en).lower()
        if "author" in en or cn in {"作者", "著者", "撰者", "撰", "著", "作", "編著", "編著者", "撰著者"}:
            return "author"
        if "translator" in en or "translat" in en or "翻譯" in cn or "翻译" in cn or cn in {"譯者", "译者"}:
            return "translator"
        if "proofread" in en or "校對" in cn or "校对" in cn:
            return "proofreader"
        if "collat" in en or cn in {"校者", "校勘者", "校讎者", "校雠者"}:
            return "collator"
        if "annotat" in en or "註疏" in cn or "注疏" in cn:
            return "annotator"
        if "comment" in en or "註釋" in cn or "注释" in cn or "評點" in cn or "评点" in cn:
            return "commentator"
        if "editorial associate" in en or "編輯助理" in cn or "编辑助理" in cn:
            return "editorial_associate"
        if "compiler" in en or "編纂" in cn or "编纂" in cn:
            return "compiler"
        if "editor" in en or "編輯" in cn or "编辑" in cn:
            return "editor"
        if "publisher" in en or "出版者" in cn:
            return "publisher"
        if "donor" in en or "捐助" in cn:
            return "donor"
        return ""

    def preload_text_roles(self, person_ids: Iterable[str]) -> None:
        """Batch-load CBDB text-role rows to avoid one SQLite query per person."""
        wanted = sorted({clean_text(value) for value in person_ids if clean_text(value)})
        unresolved = [person_id for person_id in wanted if person_id not in self.text_role_cache]
        if not unresolved:
            return
        required = (
            self.bt_person_col,
            self.bt_text_col,
            self.bt_role_col,
            self.text_id_col,
            self.role_id_col,
        )
        if not all(required) or not self.text_title_chn_col:
            for person_id in unresolved:
                self.text_role_cache[person_id] = ()
            return

        def qualified(alias: str, column: str, output: str) -> str:
            if not column:
                return f"NULL AS {self._quote(output)}"
            return f"{alias}.{self._quote(column)} AS {self._quote(output)}"

        for start in range(0, len(unresolved), 300):
            chunk = unresolved[start : start + 300]
            placeholders = ",".join("?" for _ in chunk)
            sql = f"""
                SELECT
                  {qualified('bt', self.bt_person_col, 'person_id')},
                  {qualified('tc', self.text_title_chn_col, 'title_chn')},
                  {qualified('tc', self.text_title_col, 'title_en')},
                  {qualified('rc', self.role_chn_col, 'role_cn')},
                  {qualified('rc', self.role_en_col, 'role_en')}
                FROM BIOG_TEXT_DATA bt
                JOIN TEXT_CODES tc ON tc.{self._quote(self.text_id_col)} = bt.{self._quote(self.bt_text_col)}
                LEFT JOIN TEXT_ROLE_CODES rc ON rc.{self._quote(self.role_id_col)} = bt.{self._quote(self.bt_role_col)}
                WHERE bt.{self._quote(self.bt_person_col)} IN ({placeholders})
            """
            rows_by_person: dict[str, list[tuple[str, str, str]]] = collections.defaultdict(list)
            for row in self.db.execute(sql, chunk):
                person_id = clean_text(row["person_id"])
                title = clean_text(row["title_chn"])
                role_cn = clean_text(row["role_cn"])
                role_en = clean_text(row["role_en"])
                role = self.normalize_role(role_cn, role_en)
                if person_id and title and role:
                    rows_by_person[person_id].append((title, role, role_cn or role_en))
            for person_id in chunk:
                self.text_role_cache[person_id] = tuple(rows_by_person.get(person_id, ()))

    def _person_text_roles(self, person_id: str) -> tuple[tuple[str, str, str], ...]:
        if person_id not in self.text_role_cache:
            self.preload_text_roles([person_id])
        return self.text_role_cache.get(person_id, ())

    def role_evidence_for_work(
        self,
        label: str,
        candidates: Sequence[CbdbPersonCandidate],
        work: Work,
        normalizer: Traditionalizer,
    ) -> tuple[CbdbRoleEvidence, ...]:
        # Exact CBDB person-to-text role evidence is stronger than a chronology
        # overlap heuristic. A later edition or transcription can legitimately
        # carry an old author's work, so test every namesake against CBDB's text
        # relation first; dates are only useful when no text-role match exists.
        candidate_people = tuple(candidates)
        if not candidate_people:
            return ()
        title_values: set[str] = set()
        for value in (work.title, work.work_base_title, *work.aliases):
            if not value:
                continue
            clean, _suffixes = split_trailing_parentheticals(value)
            for candidate_title in (value, clean):
                if candidate_title:
                    title_values.add(normalize_name(normalizer, candidate_title))
        if not title_values:
            return ()
        matches: list[CbdbRoleEvidence] = []
        for person in candidate_people:
            for title, role, role_label in self._person_text_roles(person.person_id):
                if normalize_name(normalizer, title) not in title_values:
                    continue
                matches.append(
                    CbdbRoleEvidence(
                        person_id=person.person_id,
                        primary_name=person.primary_name,
                        matched_name=label,
                        text_title=title,
                        role=role,
                        role_label=role_label,
                    )
                )
        return tuple(
            dict.fromkeys(matches)
        )


def discover_cbdb_path(repo_root: Path, explicit: Path | None) -> Path | None:
    if explicit is not None:
        path = explicit.expanduser().resolve()
        return path if path.is_file() else None
    data_root = repo_root / "viewer" / "data"
    candidates = [path for path in data_root.glob("cbdb*.sqlite3") if path.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda path: (path.name, path.stat().st_mtime))


def traditionalization_prewarm_values(works: Sequence[Work]) -> set[str]:
    values: set[str] = set()
    for work in works:
        for value in (
            work.title,
            work.work_base_title,
            work.date_label,
            work.period,
            work.polity,
            work.macro_region,
            work.region,
            work.medium,
            *work.aliases,
            *work.categories,
            *work.source_categories,
            *work.authors,
            *work.editors,
            *work.contributors,
            *work.document_authors,
            *work.sources,
        ):
            if value:
                values.add(value)
    return values


def cbdb_candidate_category_labels(
    works: Sequence[Work], normalizer: Traditionalizer, blocked_labels: set[str], rules: dict
) -> set[str]:
    controlled = rules.get("_controlled_taxonomy_nodes") or set()
    known_compilations = {normalize_name(normalizer, value) for value in rules.get("known_compilation_titles") or []}
    labels: set[str] = set()
    for work in works:
        for raw, _origin in unique_memberships(work):
            canonical, _ = canonical_label(normalizer, raw)
            if canonical in blocked_labels or canonical in controlled or canonical in known_compilations:
                continue
            if looks_like_person_label(canonical):
                labels.add(canonical)
    return labels


def infer_cbdb_role_evidence(
    works: Sequence[Work],
    normalizer: Traditionalizer,
    authority: CbdbAuthority,
    cbdb_people: dict[str, tuple[CbdbPersonCandidate, ...]],
) -> dict[tuple[Path, str], tuple[CbdbRoleEvidence, ...]]:
    evidence: dict[tuple[Path, str], tuple[CbdbRoleEvidence, ...]] = {}
    for work in works:
        seen: set[str] = set()
        for raw, _origin in unique_memberships(work):
            canonical, _ = canonical_label(normalizer, raw)
            if canonical in seen or canonical not in cbdb_people:
                continue
            seen.add(canonical)
            matches = authority.role_evidence_for_work(canonical, cbdb_people[canonical], work, normalizer)
            if matches:
                evidence[(work.metadata_path, canonical)] = matches
    return evidence

def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent
    parser = argparse.ArgumentParser(
        description=(
            "Turn category-audit evidence into a metadata migration plan. The planner does not "
            "write metadata: it produces a smaller review workbook that separates safe removals, "
            "metadata promotions, mentions, compilation membership, material evidence, and genuine taxonomy."
        )
    )
    parser.add_argument("--corpus-root", type=Path, default=script_dir.parent)
    parser.add_argument("--rules", type=Path, default=script_dir / "category_migration_rules.json")
    parser.add_argument(
        "--traditional-backend",
        choices=("opencc", "unihan"),
        default="opencc",
        help="Simplified->Traditional normalizer (default: OpenCC; unihan is a compatibility fallback only).",
    )
    parser.add_argument(
        "--opencc-config",
        default="s2t.json",
        help="OpenCC configuration used for category/title normalization (default: s2t.json).",
    )
    parser.add_argument(
        "--traditional-map",
        type=Path,
        default=repo_root / "viewer" / "resources" / "unihan" / "kTraditionalVariant.txt",
        help="Legacy Unihan mapping used only with --traditional-backend unihan.",
    )
    parser.add_argument(
        "--cbdb",
        type=Path,
        default=None,
        help="Optional CBDB SQLite. By default the planner uses the newest viewer/data/cbdb*.sqlite3 if present.",
    )
    parser.add_argument(
        "--no-cbdb",
        action="store_true",
        help="Disable CBDB person/text-role verification even when a local CBDB SQLite is available.",
    )
    parser.add_argument("--output", type=Path, default=Path.cwd() / "category_migration.xlsx")
    parser.add_argument(
        "--application-plan",
        type=Path,
        default=None,
        help=(
            "Also write a UTF-8-BOM JSONL application plan for category_migration_apply.py. "
            "This still does not modify metadata.json."
        ),
    )
    parser.add_argument("--skip-body-evidence", action="store_true")
    parser.add_argument(
        "--include-master-actions",
        action="store_true",
        help="Also write the very large row-level Migration Actions sheet. Topic sheets and summaries are written by default.",
    )
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--progress-every", type=int, default=1000)
    return parser.parse_args()


def clean_text(value: object) -> str:
    return "" if value is None else str(value).strip()


HASH_U_ESCAPE = re.compile(r"#U([0-9A-Fa-f]{4})")


def decode_semantic_path_component(value: str) -> str:
    """Decode BMP Han #UXXXX path spelling for read-only inference.

    Imported paths can place literal digits immediately after an encoded graph
    (for example ``#U66f8102#U5e74`` = ``書102年``), so greedily reading five
    or six hexadecimal characters can manufacture an impossible codepoint.
    For category inference we only need the overwhelmingly common BMP Han
    escapes. Supplementary-plane escapes are left untouched instead of guessed.
    This helper never renames or rewrites a path.
    """
    def replace(match: re.Match[str]) -> str:
        codepoint = int(match.group(1), 16)
        if 0x3400 <= codepoint <= 0x4DBF or 0x4E00 <= codepoint <= 0x9FFF or 0xF900 <= codepoint <= 0xFAFF:
            return chr(codepoint)
        return match.group(0)

    return HASH_U_ESCAPE.sub(replace, value)


def semantic_path_parts(path: Path) -> tuple[str, ...]:
    return tuple(decode_semantic_path_component(part) for part in path.parts)


def semantic_path_text(path: Path) -> str:
    return "/".join(semantic_path_parts(path))


def string_list(value: object) -> tuple[str, ...]:
    if not isinstance(value, list):
        return ()
    result: list[str] = []
    seen: set[str] = set()
    for item in value:
        text = clean_text(item)
        if text and text not in seen:
            seen.add(text)
            result.append(text)
    return tuple(result)


def source_strings(value: object) -> tuple[str, ...]:
    """Flatten legacy string sources and newer structured source objects for matching."""
    if not isinstance(value, list):
        return ()
    seen: set[str] = set()
    result: list[str] = []
    for item in value:
        if isinstance(item, str):
            candidates = (item,)
        elif isinstance(item, dict):
            candidates = tuple(
                clean_text(item.get(key))
                for key in ("kind", "source", "source_label", "title", "name", "citation", "url", "license", "creator", "digital_editor")
            )
        else:
            candidates = ()
        for candidate in candidates:
            text = clean_text(candidate)
            if text and text not in seen:
                seen.add(text)
                result.append(text)
    return tuple(result)


def material_object(value: object) -> dict:
    return dict(value) if isinstance(value, dict) else {}


def compact_json(value: object) -> str:
    if not value:
        return ""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def contributor_names(value: object) -> tuple[str, ...]:
    if not isinstance(value, list):
        return ()
    result: list[str] = []
    for item in value:
        if isinstance(item, dict):
            name = clean_text(item.get("name"))
        else:
            name = clean_text(item)
        if name:
            result.append(name)
    return tuple(dict.fromkeys(result))


def nested_document_authors(metadata: dict) -> tuple[str, ...]:
    names: list[str] = []
    for document in metadata.get("documents") or []:
        if isinstance(document, dict):
            names.extend(string_list(document.get("authors")))
    for edition in metadata.get("editions") or []:
        if not isinstance(edition, dict):
            continue
        for document in edition.get("documents") or []:
            if isinstance(document, dict):
                names.extend(string_list(document.get("authors")))
    return tuple(dict.fromkeys(names))


def integer_value(value: object) -> int | None:
    text = clean_text(value)
    if not re.fullmatch(r"-?\d+", text):
        return None
    try:
        return int(text)
    except (TypeError, ValueError):
        return None


def hierarchy_labels_from_metadata_paths(paths: Sequence[Path], corpus_root: Path) -> set[str]:
    """Return structural directory labels without reading every metadata file.

    --limit is a row-processing limit, not a semantic-universe limit. The
    migration already enumerates every metadata.json path before slicing the
    requested sample, so collect intermediate directories from that same list.
    This keeps test runs from mistaking corpus periods such as 東漢 or 南梁 for
    personal names merely because those period directories fall outside the
    first N works.

    The immediate work directory is excluded: work titles are not structural
    period/geography vocabulary.
    """
    labels: set[str] = set()
    for path in paths:
        try:
            parts = path.relative_to(corpus_root).parts
        except ValueError:
            continue
        try:
            clean_index = parts.index("clean")
        except ValueError:
            continue
        for label in parts[clean_index + 1 : -2]:
            value = clean_text(label)
            if value:
                labels.add(value)
    return labels


def discover_works(
    corpus_root: Path, limit: int | None
) -> tuple[list[Work], list[tuple[str, str]], set[str]]:
    works: list[Work] = []
    issues: list[tuple[str, str]] = []
    all_paths = sorted(corpus_root.rglob("metadata.json"), key=lambda path: path.as_posix())
    hierarchy_labels = hierarchy_labels_from_metadata_paths(all_paths, corpus_root)
    paths = all_paths
    if limit is not None:
        paths = paths[: max(0, limit)]
    for path in paths:
        rel = path.relative_to(corpus_root)
        try:
            raw_metadata = path.read_bytes()
            metadata = json.loads(raw_metadata.decode("utf-8-sig"))
            if not isinstance(metadata, dict):
                raise ValueError("top-level JSON value is not an object")
            metadata_digest = hashlib.sha256(raw_metadata).hexdigest()
        except Exception as exc:
            issues.append((rel.as_posix(), f"metadata read error: {exc}"))
            continue
        documents_value = metadata.get("documents")
        documents = tuple(item for item in documents_value if isinstance(item, dict)) if isinstance(documents_value, list) else ()
        contained_value = metadata.get("contained_in")
        contained = tuple(item for item in contained_value if isinstance(item, dict)) if isinstance(contained_value, list) else ()
        editions_value = metadata.get("editions")
        editions = tuple(item for item in editions_value if isinstance(item, dict)) if isinstance(editions_value, list) else ()
        identifiers_value = metadata.get("identifiers")
        identifiers = tuple(item for item in identifiers_value if isinstance(item, dict)) if isinstance(identifiers_value, list) else ()
        works.append(
            Work(
                metadata_path=rel,
                work_id=clean_text(metadata.get("work_id")),
                title=clean_text(metadata.get("title") or metadata.get("work_base_title") or path.parent.name),
                work_base_title=clean_text(metadata.get("work_base_title")),
                aliases=string_list(metadata.get("aliases")),
                date_label=clean_text(metadata.get("date_label")),
                date=clean_text(metadata.get("date")),
                year_start=integer_value(metadata.get("year_start") or metadata.get("year")),
                year_end=integer_value(metadata.get("year_end") or metadata.get("year")),
                period=clean_text(metadata.get("period")),
                polity=clean_text(metadata.get("polity")),
                macro_region=clean_text(metadata.get("macro_region")),
                region=clean_text(metadata.get("region")),
                medium=clean_text(metadata.get("medium")),
                object_type=clean_text(metadata.get("object_type")),
                material=material_object(metadata.get("material")),
                is_compilation=bool(metadata.get("is_compilation")),
                categories=string_list(metadata.get("categories")),
                source_categories=string_list(metadata.get("source_categories")),
                authors=string_list(metadata.get("authors")),
                editors=string_list(metadata.get("editors")),
                contributors=contributor_names(metadata.get("contributors")),
                document_authors=nested_document_authors(metadata),
                contained_in=contained,
                editions=editions,
                sources=source_strings(metadata.get("sources")),
                identifiers=identifiers,
                documents=documents,
                metadata_sha256=metadata_digest,
            )
        )
    return works, issues, hierarchy_labels


def load_rules(path: Path) -> dict:
    data = read_json(path)
    if not isinstance(data, dict):
        raise ValueError("migration rules must be a JSON object")

    # Old audit revisions stored deterministic epoch arithmetic in this rules
    # file. CalendarEngine is now the only owner of that knowledge. Discard the
    # legacy keys at the boundary so they cannot silently become a second source
    # of truth even if an older rules file still contains them.
    data.pop("calendar_year_bases", None)
    data.pop("era_year_bases", None)
    return data


def strip_namespace(label: str) -> str:
    return re.sub(r"^(?:分類|分类|Category):\s*", "", label).strip()


def normalize_name(normalizer: Traditionalizer, value: str) -> str:
    return normalizer.normalize(strip_namespace(value))[0]


def canonical_label(normalizer: Traditionalizer, raw: str) -> tuple[str, tuple[str, ...]]:
    return normalizer.normalize(strip_namespace(raw))


def calendar_context_for_work(work: Work) -> dict[str, object]:
    """Pass work context to the shared authority resolver without overriding it.

    year_start/year_end are deliberately omitted here. HistoricalDateResolver
    treats explicit numeric years as authoritative metadata and would otherwise
    short-circuit the category/title expression currently being tested.
    """
    context: dict[str, object] = {}
    parts = work.metadata_path.parts
    if parts:
        context["corpus_root"] = parts[0]
    for key, value in (("period", work.period), ("polity", work.polity), ("region", work.region)):
        if value:
            context[key] = value
    return context


def corpus_hierarchy_labels(work: Work) -> tuple[str, ...]:
    """Return only the authoritative folder hierarchy surrounding one work.

    metadata_path is relative to corpus/.  Everything after clean and before the
    work directory is corpus placement; the work directory and metadata.json are
    not chronology labels.
    """
    parts = work.metadata_path.parts
    try:
        clean_index = parts.index("clean")
    except ValueError:
        return ()
    return tuple(parts[clean_index + 1 : -2])


def normalized_hierarchy_labels(work: Work, normalizer: Traditionalizer) -> tuple[str, ...]:
    return tuple(
        normalize_name(normalizer, value)
        for value in corpus_hierarchy_labels(work)
        if clean_text(value)
    )


def calendar_period_bounds(labels: str | Sequence[str]) -> tuple[int, int, tuple[str, ...]] | None:
    """Ask Rails for the established historical bounds of period/path labels.

    Python does not own dynasty boundaries. CalendarEngine exposes the existing
    Rails period authority table and performs path-range intersection there.
    """
    value: object
    if isinstance(labels, str):
        value = labels
    else:
        value = list(labels)
    try:
        response = calendar_engine().period_bounds(value)
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"shared CalendarEngine unavailable while checking period bounds {value!r}: {exc}") from exc
    if not response.get("resolved"):
        return None
    start = response.get("year_start")
    end = response.get("year_end")
    if start is None or end is None:
        return None
    matched = tuple(str(item) for item in response.get("labels", []) if str(item))
    return int(start), int(end), matched


def work_absolute_year_range(
    work: Work,
    work_date_categories: Sequence[DateCategory] = (),
    *,
    context: dict[str, object] | None = None,
) -> tuple[int, int] | None:
    """Return firm work-level absolute chronology for migration safety checks.

    Mention dates are intentionally excluded. Exact numeric chronology wins,
    followed by the materialized Gregorian date and date_label. Category dates
    are used only when all non-mention categories converge on one absolute year.
    Broad ca values are not used here because many were derived from the folder
    itself and would make a folder-consistency test circular.
    """
    if work.year_start is not None or work.year_end is not None:
        left = work.year_start if work.year_start is not None else work.year_end
        right = work.year_end if work.year_end is not None else work.year_start
        assert left is not None and right is not None
        return min(left, right), max(left, right)

    for value in (work.date, work.date_label):
        if not value:
            continue
        parsed = parse_existing_date_label(value, context=context)
        if parsed is not None:
            return parsed[0], parsed[0]

    years = {item.year for item in work_date_categories if not item.is_mention}
    if len(years) == 1:
        year = next(iter(years))
        return year, year
    return None


def ranges_overlap(left: tuple[int, int], right: tuple[int, int]) -> bool:
    return left[0] <= right[1] and right[0] <= left[1]


def annotation_metadata_for_work(work: Work) -> dict[str, object]:
    """Build the chronology context consumed by the existing Rails annotator.

    Firm normalized dates win. When no firm date exists, the corpus hierarchy is
    converted to the same period bounds already exposed by CalendarEngine from
    the annotator's period table. This gives the annotator a useful future-person
    gate even for a specific folder label it does not itself name directly.
    """
    metadata: dict[str, object] = {}
    parts = work.metadata_path.parts
    if parts:
        metadata["corpus_root"] = parts[0]
    for key, value in (("period", work.period), ("polity", work.polity), ("region", work.region)):
        if value:
            metadata[key] = value
    if work.date_label:
        metadata["date_label"] = work.date_label
    if work.date:
        metadata["date"] = work.date
    if work.authors:
        metadata["authors"] = list(work.authors)

    firm = work_absolute_year_range(work, context=calendar_context_for_work(work))
    if firm is not None:
        metadata["year_start"], metadata["year_end"] = firm
        return metadata

    path_bounds = calendar_period_bounds(corpus_hierarchy_labels(work))
    if path_bounds is not None:
        metadata["year_start"], metadata["year_end"] = path_bounds[:2]
    return metadata


def is_date_review_action(item: MembershipAction) -> bool:
    """Select actual date actions without matching the 'date' inside candidate."""
    action = item.action.action
    target = item.action.target_field
    return (
        action.startswith(("date_", "promote_date_", "remove_date_", "split_date_", "era_year_"))
        or "_date_" in action
        or "mentions.dates" in target
        or target == "date_label"
        or target.startswith("date_label ")
        or target.startswith("date_label+")
        or target.startswith("date_label +")
    )


def is_people_review_action(item: MembershipAction) -> bool:
    """Author/contributor-role review only; mentions have their own review sheet."""
    if item.action.confidence != "review":
        return False
    action = item.action.action
    target = item.action.target_field
    if "person_mention" in action or target == "mentions.people":
        return False
    return (
        target.startswith("authors")
        or target.startswith("contributors")
        or "author" in action
        or "contributor" in action
        or "person_role" in action
        or "person_preamble_role" in action
    )


def is_person_mention_review_action(item: MembershipAction) -> bool:
    if item.action.confidence != "review":
        return False
    return "person_mention" in item.action.action or item.action.target_field == "mentions.people"


def is_period_polity_review_action(item: MembershipAction) -> bool:
    """Period/polity review contains only unresolved cases; safe redundancies auto-remove."""
    if item.action.confidence != "review":
        return False
    return any(token in item.action.action for token in ("period", "polity", "geograph"))


def parse_date_category(canonical: str, context: dict[str, object] | None = None) -> DateCategory | None:
    """Resolve one category label through the shared Rails CalendarEngine.

    The optional 提及 marker belongs to category semantics, so this script strips
    that wrapper and sends the calendrical expression itself to CalendarEngine.
    It never computes a calendar year locally.
    """
    mention = False
    value = canonical.strip()
    mention_match = re.search(r"\s*[（(]提及[)）]\s*$", value)
    if mention_match:
        mention = True
        value = value[: mention_match.start()].strip()

    try:
        response = calendar_engine().resolve(value, context=context)
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"shared CalendarEngine unavailable while resolving {value!r}: {exc}") from exc

    if not response.get("resolved") or response.get("kind") != "date" or response.get("year") is None:
        return None

    month = response.get("month")
    day = response.get("day")
    return DateCategory(
        raw=canonical,
        canonical=canonical,
        year=int(response["year"]),
        month=int(month) if month is not None else None,
        day=int(day) if day is not None else None,
        is_mention=mention,
    )


def looks_like_unmapped_era_year(canonical: str) -> bool:
    value = re.sub(r"\s*[（(]提及[)）]\s*$", "", canonical.strip())
    return bool(re.fullmatch(r"[\u3400-\u9fff\uf900-\ufaff]{1,10}(?:元|[〇零一二三四五六七八九十百千0-9]+)年", value))


def parse_existing_date_label(value: str, context: dict[str, object] | None = None) -> tuple[int, int | None, int | None] | None:
    parsed = parse_date_category(value, context=context)
    if parsed is not None and not parsed.is_mention:
        return parsed.year, parsed.month, parsed.day
    return None


def date_compatible(candidate: DateCategory, existing: tuple[int, int | None, int | None]) -> bool:
    year, month, day = existing
    if candidate.year != year:
        return False
    if candidate.month is not None and month is not None and candidate.month != month:
        return False
    if candidate.day is not None and day is not None and candidate.day != day:
        return False
    return True


def compilation_parts(label: str) -> tuple[str, str, str] | None:
    match = re.fullmatch(r"(.+?)(?:\s*[（(]([^()（）]+)[)）])?/卷([^/]+)", label)
    if not match:
        return None
    return match.group(1).strip(), clean_text(match.group(2)), match.group(3).strip()


def volume_only(label: str) -> bool:
    return bool(re.fullmatch(r"卷(?:第)?[〇零一二三四五六七八九十百千萬万0-9]+", label))


def resolve_document_path(corpus_root: Path, work: Work, document: dict) -> Path | None:
    candidates: list[Path] = []
    declared = clean_text(document.get("path"))
    file_name = clean_text(document.get("file"))
    if declared:
        path = Path(declared)
        candidates.append(path if path.is_absolute() else corpus_root / path)
    if file_name:
        candidates.append(corpus_root / work.metadata_path.parent / file_name)
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if resolved.is_file():
            return resolved
    return None


def read_body(path: Path, body_start_line: object) -> str:
    with path.open("r", encoding="utf-8-sig", errors="strict", newline=None) as handle:
        text = handle.read()
    try:
        start = int(body_start_line)
    except (TypeError, ValueError):
        start = 1
    if start <= 1:
        return text
    return "".join(text.splitlines(keepends=True)[start - 1 :])


def body_snippet(text: str, pos: int, length: int, radius: int = 34) -> str:
    left = max(0, pos - radius)
    right = min(len(text), pos + length + radius)
    value = re.sub(r"\s+", " ", text[left:right]).strip()
    return ("..." if left else "") + value + ("..." if right < len(text) else "")


def unique_memberships(work: Work) -> list[tuple[str, str]]:
    labels = list(dict.fromkeys(work.categories + work.source_categories))
    rows: list[tuple[str, str]] = []
    for label in labels:
        curated = label in work.categories
        source = label in work.source_categories
        origin = "curated+source" if curated and source else ("curated" if curated else "source")
        rows.append((label, origin))
    return rows


TRAILING_PARENTHETICAL = re.compile(r"\s*[（(]([^()（）]{1,160})[）)]\s*$")


def split_trailing_parentheticals(title: str) -> tuple[str, tuple[str, ...]]:
    base = title.rstrip()
    suffixes: list[str] = []
    while base:
        match = TRAILING_PARENTHETICAL.search(base)
        if not match:
            break
        suffix = match.group(1).strip()
        proposed = base[: match.start()].rstrip()
        if not suffix or not proposed or proposed == base:
            break
        suffixes.insert(0, suffix)
        base = proposed
    return base, tuple(suffixes)


CONTRIBUTOR_ROLE_SUFFIXES = {
    "譯": "translator", "译": "translator",
    "編": "compiler/editor", "编": "compiler/editor",
    "校": "collator",
    "注": "commentator", "註": "commentator",
    "撰": "author", "著": "author",
}
FORMULAIC_ROLE_STEMS = {"奉敕", "奉詔", "奉诏", "奉命", "敕撰", "欽定", "钦定"}


def split_contributor_role_suffix(value: str) -> tuple[str, str] | None:
    role_chars = "".join(re.escape(char) for char in CONTRIBUTOR_ROLE_SUFFIXES)
    match = re.fullmatch(rf"(.{{1,60}}?)([{role_chars}])", value.strip())
    if not match:
        return None
    name = match.group(1).strip()
    # A one-character stem is very often a genuine two-character personal name
    # ending in 著 (for example 馮著), not a role-marked credit. Formulae such as
    # 奉敕撰 describe circumstances of composition and must not create a person.
    if len(name) < 2 or name in FORMULAIC_ROLE_STEMS:
        return None
    return name, CONTRIBUTOR_ROLE_SUFFIXES[match.group(2)]


def title_parenthetical_tokens(title: str, normalizer: Traditionalizer) -> set[str]:
    _base, suffixes = split_trailing_parentheticals(title)
    tokens: set[str] = set()
    for value in suffixes:
        if not value.strip():
            continue
        canonical = normalize_name(normalizer, value)
        tokens.add(canonical)
        role = split_contributor_role_suffix(canonical)
        if role is not None:
            tokens.add(normalize_name(normalizer, role[0]))
    return tokens


def leading_date_in_suffix(value: str, context: dict[str, object] | None = None) -> tuple[DateCategory, str] | None:
    """Ask CalendarEngine to split a deterministic/authority-backed leading date."""
    try:
        response = calendar_engine().resolve_prefix(value, context=context, authority=True)
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"shared CalendarEngine unavailable while splitting {value!r}: {exc}") from exc

    if not response.get("resolved") or response.get("kind") != "date" or response.get("year") is None:
        return None

    month = response.get("month")
    day = response.get("day")
    consumed = str(response.get("consumed") or "").strip()
    if not consumed:
        return None
    date = DateCategory(
        raw=consumed,
        canonical=consumed,
        year=int(response["year"]),
        month=int(month) if month is not None else None,
        day=int(day) if day is not None else None,
        is_mention=False,
    )
    return date, str(response.get("rest") or "").strip()


def existing_edition_labels(work: Work, normalizer: Traditionalizer) -> set[str]:
    result: set[str] = set()
    for edition in work.editions:
        label = clean_text(edition.get("edition_label"))
        if label:
            result.add(normalize_name(normalizer, label))
    return result


def looks_like_edition_suffix(value: str) -> bool:
    return bool(re.fullmatch(r".{1,48}(?:本|版|校本|刻本|抄本|鈔本|寫本|影印本|譯本)$", value))


def source_periodisation_for(work: Work, rules: dict) -> dict | None:
    haystack_parts = [work.title, work.work_base_title, work.metadata_path.as_posix(), semantic_path_text(work.metadata_path), *work.sources]
    for identifier in work.identifiers:
        haystack_parts.extend((clean_text(identifier.get("scheme")), clean_text(identifier.get("value"))))
    haystack = "\n".join(part for part in haystack_parts if part)
    for row in rules.get("source_periodisations") or []:
        if not isinstance(row, dict):
            continue
        patterns = [clean_text(value) for value in row.get("source_patterns") or [] if clean_text(value)]
        if patterns and any(re.search(pattern, haystack) for pattern in patterns):
            return row
    return None


def looks_like_person_label(label: str) -> bool:
    if not re.fullmatch(r"[\u3400-\u9fff\uf900-\ufaff]{2,6}", label):
        return False
    blocked_suffixes = (
        "朝", "國", "国", "年", "月", "日", "卷", "篇", "類", "类", "本", "版",
        "集", "詩", "诗", "詞", "词", "文", "書", "书", "經", "经", "教", "寺",
        "志", "誌", "記", "记", "錄", "录", "學", "学", "術", "术", "論", "论",
        "史", "法", "制", "體", "体", "語", "语", "歌", "賦", "赋", "曲", "銘", "铭",
        "句", "市", "省", "縣", "县", "州", "郡", "節", "节", "季", "代", "頁", "页",
    )
    if label.startswith(("卷第", "第")) and any(char.isdigit() or char in "一二三四五六七八九十百千" for char in label):
        return False
    return not label.endswith(blocked_suffixes)


def person_inference_blocked_labels(
    works: Sequence[Work],
    normalizer: Traditionalizer,
    rules: dict,
    hierarchy_labels: Iterable[str] = (),
) -> set[str]:
    """Labels that must never become people merely from title/category coincidence.

    Periods, polities, regions and controlled/scoped semantic labels can occur in
    source-added parentheses too.  Treating one such coincidence as evidence of a
    person contaminated the person authority set (for example 西晉 and 礦藝).
    """
    blocked = {normalize_name(normalizer, value) for value in controlled_taxonomy_nodes(rules)}
    blocked.update(normalize_name(normalizer, value) for value in rules.get("tradition_labels") or [] if clean_text(value))
    blocked.update(normalize_name(normalizer, value) for value in rules.get("person_inference_exclusions") or [] if clean_text(value))
    blocked.update(normalize_name(normalizer, value) for value in hierarchy_labels if clean_text(value))
    for work in works:
        for value in (work.period, work.polity, work.macro_region, work.region):
            if value:
                blocked.add(normalize_name(normalizer, value))
    for row in rules.get("source_periodisations") or []:
        if not isinstance(row, dict):
            continue
        for key in ("phase_labels", "unknown_phase_labels", "base_period_labels"):
            for value in row.get(key) or []:
                if clean_text(value):
                    blocked.add(normalize_name(normalizer, value))
    return blocked


def infer_authorial_compilation_people(
    works: Sequence[Work],
    normalizer: Traditionalizer,
    rules: dict,
    blocked_labels: set[str],
) -> dict[tuple[Path, str], str]:
    """Infer one source-category author inside explicitly author-organized anthologies.

    Wikisource categories such as 全唐文/卷0628 and 全唐詩/卷… are
    organizational evidence: individual work pages normally carry the anthology
    volume plus the author category.  Use this only when exactly one plausible
    personal-name category survives all period/taxonomy/maintenance exclusions.
    The result remains a high-confidence migration proposal, never a silent write.
    """
    patterns = [
        re.compile(clean_text(row.get("pattern")))
        for row in (rules.get("authorial_compilation_patterns") or [])
        if isinstance(row, dict) and clean_text(row.get("pattern"))
    ]
    if not patterns:
        return {}
    controlled = rules.get("_controlled_taxonomy_nodes") or set()
    known_compilations = {normalize_name(normalizer, value) for value in rules.get("known_compilation_titles") or []}
    evidence: dict[tuple[Path, str], str] = {}
    for work in works:
        memberships = [(raw, canonical_label(normalizer, raw)[0]) for raw, _origin in unique_memberships(work)]
        anthology_surfaces = [
            strip_namespace(raw)
            for raw, _canonical in memberships
            if any(pattern.search(strip_namespace(raw)) for pattern in patterns)
        ]
        if not anthology_surfaces:
            continue
        candidates: list[str] = []
        for _raw, canonical in memberships:
            if canonical in blocked_labels or canonical in controlled or canonical in known_compilations:
                continue
            if not looks_like_person_label(canonical):
                continue
            candidates.append(canonical)
        candidates = list(dict.fromkeys(candidates))
        if len(candidates) != 1:
            continue
        evidence[(work.metadata_path, candidates[0])] = anthology_surfaces[0]
    return evidence


def infer_people_from_title_parentheses(
    works: Sequence[Work],
    normalizer: Traditionalizer,
    min_matches: int,
    single_match_memberships: int,
    blocked_labels: set[str] | None = None,
) -> set[str]:
    memberships: collections.Counter[str] = collections.Counter()
    parenthetical_matches: collections.Counter[str] = collections.Counter()
    for work in works:
        categories = {canonical_label(normalizer, raw)[0] for raw, _origin in unique_memberships(work)}
        for category in categories:
            memberships[category] += 1
        tokens = title_parenthetical_tokens(work.title, normalizer)
        for category in categories & tokens:
            if category in (blocked_labels or set()):
                continue
            if looks_like_person_label(category):
                parenthetical_matches[category] += 1
    return {
        category
        for category, matches in parenthetical_matches.items()
        if matches >= min_matches
        or (matches >= 1 and memberships[category] >= single_match_memberships)
    }


def infer_people_from_repeated_title_suffixes(
    works: Sequence[Work], normalizer: Traditionalizer, min_matches: int
) -> set[str]:
    counts: collections.Counter[str] = collections.Counter()
    for work in works:
        _base, suffixes = split_trailing_parentheticals(work.title)
        for suffix in suffixes:
            canonical = normalize_name(normalizer, suffix)
            if 3 <= len(canonical) <= 4 and looks_like_person_label(canonical):
                counts[canonical] += 1
    return {name for name, count in counts.items() if count >= min_matches}


def build_indexes(works: Sequence[Work], normalizer: Traditionalizer, figure_names: set[str]) -> dict:
    periods: dict[str, str] = {}
    polities: dict[str, str] = {}
    macro_regions: dict[str, str] = {}
    regions: dict[str, str] = {}
    people: set[str] = set(figure_names)
    titles: dict[str, list[Work]] = collections.defaultdict(list)

    for work in works:
        if work.period:
            periods[normalize_name(normalizer, work.period)] = work.period
        if work.polity:
            polities[normalize_name(normalizer, work.polity)] = work.polity
        if work.macro_region:
            macro_regions[normalize_name(normalizer, work.macro_region)] = work.macro_region
        if work.region:
            regions[normalize_name(normalizer, work.region)] = work.region
        for person in work.authors + work.editors + work.contributors + work.document_authors:
            people.add(normalize_name(normalizer, person))
        for title in (work.title, work.work_base_title, *work.aliases):
            if title:
                titles[normalize_name(normalizer, title)].append(work)
                stripped_title, suffixes = split_trailing_parentheticals(title)
                if suffixes and stripped_title:
                    titles[normalize_name(normalizer, stripped_title)].append(work)
    return {
        "periods": periods,
        "polities": polities,
        "macro_regions": macro_regions,
        "regions": regions,
        "people": people,
        "titles": titles,
    }


def polity_candidate(label: str, polities: dict[str, str]) -> str:
    if label in polities:
        return label
    if label.endswith("朝") and label[:-1] in polities:
        return label[:-1]
    return ""


def period_candidate(label: str, periods: dict[str, str]) -> str:
    if label in periods:
        return label
    if label.endswith("朝") and label in periods:
        return label
    return ""


def configured_period_candidate(
    label: str, indexes: dict, normalizer: Traditionalizer, rules: dict
) -> str:
    """Return the corpus period key represented by a source-category label.

    The return value is always the normalized *target* period key.  This matters
    for source synonyms such as 商殷朝 -> 商朝: returning the alias itself would
    make an otherwise matching structured period look like a conflict.
    """
    aliases = rules.get("period_aliases") or {}
    for alias, target in aliases.items():
        if normalize_name(normalizer, alias) != label:
            continue
        target_norm = normalize_name(normalizer, target)
        return target_norm if target_norm in indexes["periods"] else ""
    return period_candidate(label, indexes["periods"])


def hierarchy_period_candidates(
    work: Work, indexes: dict, normalizer: Traditionalizer, rules: dict
) -> tuple[str, ...]:
    """Return recognized period targets already encoded by the corpus path."""
    output: list[str] = []
    for label in normalized_hierarchy_labels(work, normalizer):
        candidate = configured_period_candidate(label, indexes, normalizer, rules)
        if candidate and candidate not in output:
            output.append(candidate)
    return tuple(output)


def period_prefixed_taxonomy(
    label: str, indexes: dict, normalizer: Traditionalizer, rules: dict
) -> tuple[str, str, str] | None:
    """Split labels such as 清朝法律 or 清代奏摺 when the suffix is taxonomy.

    Only explicit dynasty-style prefixes (…朝) and configured …代 aliases are
    considered.  This deliberately avoids interpreting short strings such as
    唐詩 here; poetry has its own established migration rule below.
    """
    candidates: list[tuple[str, str, str]] = []
    for period_norm, display in indexes["periods"].items():
        if period_norm.endswith("朝") and label.startswith(period_norm) and len(label) > len(period_norm):
            candidates.append((period_norm, period_norm, label[len(period_norm):]))
    for alias, target in (rules.get("origin_prefix_aliases") or {}).items():
        alias_norm = normalize_name(normalizer, alias)
        target_norm = normalize_name(normalizer, target)
        if target_norm not in indexes["periods"]:
            continue
        if label.startswith(alias_norm) and len(label) > len(alias_norm):
            candidates.append((alias_norm, target_norm, label[len(alias_norm):]))
    if not candidates:
        return None
    prefix, target_period, suffix = max(candidates, key=lambda row: len(row[0]))
    if not suffix:
        return None
    controlled = rules.get("_controlled_taxonomy_nodes") or set()
    if suffix not in controlled and taxonomy_pattern_match(suffix, rules) is None:
        return None
    return prefix, target_period, suffix


def geography_candidate(label: str, indexes: dict) -> tuple[str, str]:
    field_names = {
        "macro_regions": "macro_region",
        "polities": "polity",
        "regions": "region",
    }
    for index_name, target_field in field_names.items():
        values = indexes[index_name]
        candidate = polity_candidate(label, values) if index_name == "polities" else label
        if candidate in values:
            return target_field, candidate
    return "", ""


def figure_names_from_terms(terms_path: Path, normalizer: Traditionalizer) -> set[str]:
    if not terms_path.is_file():
        return set()
    data = read_json(terms_path)
    result: set[str] = set()
    for group in data.get("groups") or []:
        if not isinstance(group, dict):
            continue
        for entry in group.get("entries") or []:
            if not isinstance(entry, dict) or clean_text(entry.get("kind")) != "figure":
                continue
            label = clean_text(entry.get("label"))
            if label:
                result.add(normalize_name(normalizer, label))
            for alias in entry.get("aliases") or []:
                text = clean_text(alias)
                if text:
                    result.add(normalize_name(normalizer, text))
    return result


def figure_alias_groups_from_terms(terms_path: Path, normalizer: Traditionalizer) -> dict[str, tuple[str, ...]]:
    """Return figure-name surface groups for mention verification only.

    The audit file groups figures under intellectual/religious traditions for
    discovery. That grouping is not a migration taxonomy rule. Here it is used
    only to let a source category such as 孔子 be corroborated by an attested
    alias such as 仲尼 before the shared annotator decides whether the occurrence
    is a plausible person reference in this work's chronology and syntax.
    """
    if not terms_path.is_file():
        return {}
    data = read_json(terms_path)
    result: dict[str, tuple[str, ...]] = {}
    for group in data.get("groups") or []:
        if not isinstance(group, dict):
            continue
        for entry in group.get("entries") or []:
            if not isinstance(entry, dict) or clean_text(entry.get("kind")) != "figure":
                continue
            raw_forms = [clean_text(entry.get("label"))]
            raw_forms.extend(clean_text(value) for value in entry.get("aliases") or [])
            raw_forms = [value for value in raw_forms if value]
            normalized = [normalize_name(normalizer, value) for value in raw_forms]
            surfaces = tuple(dict.fromkeys([*raw_forms, *normalized]))
            for key in normalized:
                if key:
                    result[key] = surfaces
    return result


def read_preamble(path: Path, body_start_line: object) -> str:
    try:
        start = int(body_start_line)
    except (TypeError, ValueError):
        start = 1
    if start <= 1:
        return ""
    lines: list[str] = []
    with path.open("r", encoding="utf-8-sig", errors="strict", newline=None) as handle:
        for index, line in enumerate(handle, start=1):
            if index >= start:
                break
            lines.append(line)
    return "".join(lines)


def scan_preamble_person_evidence(
    corpus_root: Path,
    works: Sequence[Work],
    normalizer: Traditionalizer,
    controlled_taxonomy: set[str],
    progress_every: int,
    seed_people: set[str] | None = None,
    blocked_labels: set[str] | None = None,
) -> tuple[dict[tuple[Path, str], PreamblePersonEvidence], list[tuple[str, str]], int]:
    """Find explicit source-added credits before body_start_line.

    Corpus text headers often preserve strings such as `隋天竺三藏法師闍那崛多譯`.
    They are ideal evidence for deciding what a personal-name category means, but
    they must stay outside ordinary body-mention counts. This pass reads only the
    declared preamble and only promotes a name when a role marker is explicit.
    """
    evidence: dict[tuple[Path, str], PreamblePersonEvidence] = {}
    issues: list[tuple[str, str]] = []
    scanned_documents = 0
    role_chars = "".join(re.escape(char) for char in CONTRIBUTOR_ROLE_SUFFIXES)

    for work_index, work in enumerate(works, start=1):
        candidates: dict[str, set[str]] = collections.defaultdict(set)
        for raw, _origin in unique_memberships(work):
            canonical, _unresolved = canonical_label(normalizer, raw)
            if canonical in controlled_taxonomy or canonical in (blocked_labels or set()) or not looks_like_person_label(canonical):
                continue
            candidates[canonical].update({raw.strip(), canonical})
        if not candidates:
            continue

        for document in work.documents:
            path = resolve_document_path(corpus_root, work, document)
            if path is None:
                continue
            try:
                preamble = read_preamble(path, document.get("body_start_line"))
            except (OSError, UnicodeDecodeError) as exc:
                issues.append((work.metadata_path.as_posix(), f"preamble read error: {exc}"))
                continue
            if not preamble:
                continue
            scanned_documents += 1
            try:
                rel_document = path.relative_to(corpus_root).as_posix()
            except ValueError:
                rel_document = str(path)

            for canonical, aliases in candidates.items():
                found_roles: list[str] = []
                known_person = canonical in (seed_people or set())
                # 著 is a normal lexical verb as well as an author-credit marker.
                # It may confirm the role of an already-known person, but it must
                # not discover a new "person" such as 荔枝 from 荔枝著譜.  Reversed
                # author formulae are likewise unsafe for discovery because
                # "著者 <work title>" is common.
                discovery_forward_chars = "譯译編编校注註撰"
                discovery_reverse_chars = "譯译編编校注註"
                for alias in sorted((a for a in aliases if a), key=lambda value: (-len(value), value)):
                    for match in re.finditer(rf"{re.escape(alias)}\s*([{role_chars}])", preamble):
                        marker = match.group(1)
                        if known_person or marker in discovery_forward_chars:
                            found_roles.append(CONTRIBUTOR_ROLE_SUFFIXES[marker])
                    # Less common reversed credit: 譯者張三 / 編張三.
                    for match in re.finditer(rf"([{role_chars}])(?:者)?\s*{re.escape(alias)}", preamble):
                        marker = match.group(1)
                        if known_person or marker in discovery_reverse_chars:
                            found_roles.append(CONTRIBUTOR_ROLE_SUFFIXES[marker])
                if not found_roles:
                    continue
                key = (work.metadata_path, canonical)
                item = evidence.setdefault(key, PreamblePersonEvidence())
                for role in found_roles:
                    item.roles[role] += 1
                item.documents.add(rel_document)
                if not item.first_snippet:
                    item.first_document = rel_document
                    # Preambles are intentionally short; preserve one compact evidence line.
                    compact = re.sub(r"\s+", " ", preamble).strip()
                    item.first_snippet = compact[:240] + ("..." if len(compact) > 240 else "")

        if progress_every > 0 and work_index % progress_every == 0:
            print(f"Preamble credits: {work_index:,}/{len(works):,} works", file=sys.stderr)

    return evidence, issues, scanned_documents


def candidate_aliases_for_work(
    work: Work,
    normalizer: Traditionalizer,
    indexes: dict,
    figure_aliases: dict[str, tuple[str, ...]] | None = None,
) -> dict[str, set[str]]:
    result: dict[str, set[str]] = collections.defaultdict(set)
    periods = indexes["periods"]
    polities = indexes["polities"]
    macro_regions = indexes["macro_regions"]
    regions = indexes["regions"]
    people = indexes["people"]
    figure_aliases = figure_aliases or {}
    for raw, _origin in unique_memberships(work):
        raw_surface = unicodedata.normalize("NFC", strip_namespace(raw))
        canonical, _ = canonical_label(normalizer, raw)
        date_cat = parse_date_category(canonical, context=calendar_context_for_work(work))
        if date_cat is not None and date_cat.is_mention:
            result[canonical].add(date_cat.source_label)
            raw_date = re.sub(r"\s*[（(]提及[)）]\s*$", "", raw_surface).strip()
            if raw_date:
                result[canonical].add(raw_date)
            continue
        if canonical in people:
            result[canonical].add(canonical)
            result[canonical].update(figure_aliases.get(canonical, ()))
            if raw_surface:
                result[canonical].add(raw_surface)
        if canonical in periods:
            result[canonical].add(canonical)
            if raw_surface:
                result[canonical].add(raw_surface)
        p_candidate = polity_candidate(canonical, polities)
        if p_candidate:
            result[canonical].add(p_candidate)
            result[canonical].add(p_candidate + "朝")
            if raw_surface:
                result[canonical].add(raw_surface)
        if canonical in macro_regions or canonical in regions:
            result[canonical].add(canonical)
            if raw_surface:
                result[canonical].add(raw_surface)
    return result


def _record_person_annotation(
    item: Evidence,
    rel_document: str,
    matches: Sequence[dict],
    *,
    authority_available: bool,
) -> None:
    item.person_annotation_attempts += 1
    item.person_annotation_authority_available = (
        item.person_annotation_authority_available or authority_available
    )
    for match in matches:
        if clean_text(match.get("kind")) != "person":
            continue
        confidence = clean_text(match.get("confidence")) or "possible"
        item.person_annotation_confidences[confidence] += 1
        item.person_annotation_documents.add(rel_document)
        if not item.first_person_annotation:
            candidates = match.get("candidates") if isinstance(match.get("candidates"), list) else []
            first = candidates[0] if candidates and isinstance(candidates[0], dict) else {}
            label = clean_text(first.get("label") or first.get("local_label"))
            authority = clean_text(first.get("authority_source"))
            surface = clean_text(match.get("text"))
            details = [value for value in (surface, label, authority, confidence) if value]
            item.first_person_annotation = " | ".join(details)


def scan_body_evidence(
    corpus_root: Path,
    works: Sequence[Work],
    normalizer: Traditionalizer,
    indexes: dict,
    progress_every: int,
    figure_aliases: dict[str, tuple[str, ...]] | None = None,
) -> tuple[dict[tuple[Path, str], Evidence], list[tuple[str, str]], int]:
    evidence: dict[tuple[Path, str], Evidence] = {}
    issues: list[tuple[str, str]] = []
    scanned_documents = 0
    for work_index, work in enumerate(works, start=1):
        candidates = candidate_aliases_for_work(work, normalizer, indexes, figure_aliases)
        if not candidates:
            continue
        person_candidates = {
            canonical: aliases
            for canonical, aliases in candidates.items()
            if canonical in indexes["people"]
        }
        annotation_metadata: dict[str, object] | None = None
        for document in work.documents:
            path = resolve_document_path(corpus_root, work, document)
            if path is None:
                continue
            try:
                body = read_body(path, document.get("body_start_line"))
            except (OSError, UnicodeDecodeError) as exc:
                issues.append((work.metadata_path.as_posix(), f"body read error: {exc}"))
                continue
            scanned_documents += 1
            try:
                rel_document = path.relative_to(corpus_root).as_posix()
            except ValueError:
                rel_document = str(path)

            person_hits: set[str] = set()
            for canonical, aliases in candidates.items():
                for alias in aliases:
                    if not alias:
                        continue
                    count = body.count(alias)
                    if count <= 0:
                        continue
                    key = (work.metadata_path, canonical)
                    item = evidence.setdefault(key, Evidence())
                    item.occurrences += count
                    item.documents.add(rel_document)
                    if canonical in person_candidates:
                        person_hits.add(canonical)
                    if not item.first_snippet:
                        pos = body.find(alias)
                        item.first_document = rel_document
                        item.first_snippet = body_snippet(body, pos, len(alias))

            if person_hits:
                if annotation_metadata is None:
                    annotation_metadata = annotation_metadata_for_work(work)
                wanted = {
                    canonical: sorted(person_candidates[canonical])
                    for canonical in person_hits
                }
                try:
                    response = historical_annotator().annotate(
                        body, metadata=annotation_metadata, wanted=wanted
                    )
                    if not response.get("resolved"):
                        raise RuntimeError(clean_text(response.get("error")) or "annotation request failed")
                    matches = response.get("matches") if isinstance(response.get("matches"), dict) else {}
                    authority_available = bool(response.get("authority_available"))
                    for canonical in person_hits:
                        item = evidence.setdefault((work.metadata_path, canonical), Evidence())
                        rows = matches.get(canonical) if isinstance(matches.get(canonical), list) else []
                        _record_person_annotation(
                            item, rel_document, rows, authority_available=authority_available
                        )
                except (OSError, RuntimeError, json.JSONDecodeError) as exc:
                    issues.append((work.metadata_path.as_posix(), f"person annotation check failed: {exc}"))
                    for canonical in person_hits:
                        item = evidence.setdefault((work.metadata_path, canonical), Evidence())
                        item.person_annotation_attempts += 1

        if progress_every > 0 and work_index % progress_every == 0:
            print(f"Body evidence: {work_index:,}/{len(works):,} works", file=sys.stderr)
    return evidence, issues, scanned_documents


def person_annotation_status(evidence: Evidence | None) -> str:
    if evidence is None or evidence.occurrences <= 0:
        return "absent"
    if evidence.person_annotation_confidences.get("high", 0) > 0:
        return "high"
    if evidence.person_annotation_confidences.get("possible", 0) > 0:
        return "possible"
    if evidence.person_annotation_attempts > 0 and not evidence.person_annotation_authority_available:
        return "authority_unavailable"
    if evidence.person_annotation_attempts > 0:
        return "unconfirmed"
    return "not_checked"


def person_annotation_evidence_text(evidence: Evidence | None) -> str:
    if evidence is None:
        return ""
    bits = [f"exact body occurrences: {evidence.occurrences}"]
    high = evidence.person_annotation_confidences.get("high", 0)
    possible = evidence.person_annotation_confidences.get("possible", 0)
    if high or possible:
        bits.append(f"shared annotator: high={high}, possible={possible}")
    if evidence.first_person_annotation:
        bits.append(f"first annotation: {evidence.first_person_annotation}")
    return "; ".join(bits)


def person_semantics(
    works: Sequence[Work],
    normalizer: Traditionalizer,
    people: set[str],
    preamble_evidence: dict[tuple[Path, str], PreamblePersonEvidence] | None = None,
    authorial_compilation_evidence: dict[tuple[Path, str], str] | None = None,
    cbdb_people: dict[str, tuple[CbdbPersonCandidate, ...]] | None = None,
    cbdb_role_evidence: dict[tuple[Path, str], tuple[CbdbRoleEvidence, ...]] | None = None,
) -> dict[str, dict[str, float | int | str]]:
    """Summarize only category labels with positive authorship evidence.

    Identity alone is deliberately insufficient. A label does not enter People
    Semantics merely because CBDB knows a person with that name, or because the
    string occurs in the body. Those signals created large mention/topic queues
    without helping the category migration decide authorship.
    """
    stats: dict[str, dict[str, int]] = collections.defaultdict(lambda: collections.Counter())
    preamble_roles: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    cbdb_roles: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for work in works:
        authors = {normalize_name(normalizer, value) for value in work.authors + work.document_authors}
        other_roles = {normalize_name(normalizer, value) for value in work.editors + work.contributors}
        has_authors = bool(authors)
        title_tokens = title_parenthetical_tokens(work.title, normalizer)
        for raw, _origin in unique_memberships(work):
            canonical, _ = canonical_label(normalizer, raw)
            if canonical not in people:
                continue
            row = stats[canonical]
            row["works"] += 1
            if canonical in title_tokens:
                row["title_parenthetical_matches"] += 1
            if (authorial_compilation_evidence or {}).get((work.metadata_path, canonical)):
                row["authorial_compilation_matches"] += 1
            if has_authors:
                row["works_with_authors"] += 1
            if canonical in authors:
                row["author_matches"] += 1
            if canonical in other_roles:
                row["other_role_matches"] += 1
            preamble = (preamble_evidence or {}).get((work.metadata_path, canonical))
            if preamble and preamble.roles:
                row["preamble_role_matches"] += 1
                preamble_roles[canonical].update(preamble.roles)
                if "author" in preamble.roles:
                    row["preamble_author_matches"] += 1
            direct_roles = (cbdb_role_evidence or {}).get((work.metadata_path, canonical), ())
            if direct_roles:
                row["cbdb_text_role_matches"] += 1
                roles_this_work = {item.role for item in direct_roles if item.role}
                if "author" in roles_this_work:
                    row["cbdb_author_matches"] += 1
                for role in roles_this_work:
                    cbdb_roles[canonical][role] += 1

    output: dict[str, dict[str, float | int | str]] = {}
    for person, row in stats.items():
        # Positive authorship evidence is the admission rule. This intentionally
        # excludes famous/serious names that merely occur as subjects or mentions.
        author_signal = any((
            int(row.get("author_matches", 0)) > 0,
            int(row.get("title_parenthetical_matches", 0)) > 0,
            int(row.get("authorial_compilation_matches", 0)) > 0,
            int(row.get("preamble_author_matches", 0)) > 0,
            int(row.get("cbdb_author_matches", 0)) > 0,
        ))
        if not author_signal:
            continue

        denominator = row["works_with_authors"]
        ratio = row["author_matches"] / denominator if denominator else 0.0
        role_summary = ", ".join(
            f"{role}={count}" for role, count in preamble_roles.get(person, collections.Counter()).most_common()
        )
        cbdb_role_summary = ", ".join(
            f"{role}={count}" for role, count in cbdb_roles.get(person, collections.Counter()).most_common()
        )
        cbdb_candidate_count = len((cbdb_people or {}).get(person, ()))
        cbdb_direct_author = int(row.get("cbdb_author_matches", 0))
        cbdb_non_author_roles = sum(
            count for role, count in cbdb_roles.get(person, collections.Counter()).items() if role != "author"
        )

        if int(row.get("preamble_author_matches", 0)) > 0:
            semantic = "explicit author role in source-added document preamble"
        elif cbdb_direct_author > 0 and cbdb_non_author_roles == 0:
            semantic = "CBDB-verified author grouping"
        elif cbdb_direct_author > 0:
            semantic = "CBDB author evidence present; category behaviour still mixed/unresolved"
        elif int(row.get("authorial_compilation_matches", 0)) > 0:
            semantic = "author grouping in an author-organized source anthology"
        elif (row["author_matches"] >= 3 and ratio >= 0.8) or row["title_parenthetical_matches"] >= 2:
            semantic = "likely author grouping"
        else:
            semantic = "potential author grouping; evidence requires review"
        output[person] = {
            **row,
            "author_ratio": ratio,
            "preamble_roles": role_summary,
            "cbdb_candidates": cbdb_candidate_count,
            "cbdb_roles": cbdb_role_summary,
            "semantic": semantic,
        }
    return output

def work_people(work: Work, normalizer: Traditionalizer) -> tuple[set[str], set[str]]:
    authors = {normalize_name(normalizer, value) for value in work.authors + work.document_authors}
    others = {normalize_name(normalizer, value) for value in work.editors + work.contributors}
    return authors, others


def existing_containment_ids(work: Work) -> set[str]:
    result: set[str] = set()
    for row in work.contained_in:
        value = clean_text(row.get("work_id"))
        if value:
            result.add(value)
    return result


def category_rule_match(label: str, rows: Sequence[dict]) -> dict | None:
    for row in rows:
        if not isinstance(row, dict):
            continue
        pattern = clean_text(row.get("pattern"))
        if pattern and re.search(pattern, label):
            return row
    return None


def exact_map(rules: dict, key: str) -> dict[str, object]:
    value = rules.get(key)
    return value if isinstance(value, dict) else {}


def controlled_taxonomy_nodes(rules: dict) -> set[str]:
    nodes = {clean_text(value) for value in rules.get("controlled_taxonomy_labels") or [] if clean_text(value)}
    nodes.update(clean_text(value) for value in rules.get("tradition_labels") or [] if clean_text(value))
    for row in rules.get("taxonomy_edges") or []:
        if not isinstance(row, dict):
            continue
        for key in ("child", "parent"):
            value = clean_text(row.get(key))
            if value:
                nodes.add(value)
    return nodes


def shijing_genre_for_work(work: Work, rules: dict) -> tuple[str, str]:
    """Infer only the broad 詩經 genre already implicit in corpus structure.

    The corpus already stores the received 詩經 hierarchy in its path/collection
    organisation. Do not invent parallel metadata for 國風、小雅、大雅、各頌、
    or 什. Their only migration use here is to infer the broad literary category
    風、雅、 or 頌.
    """
    config = rules.get("shijing_structure")
    if not isinstance(config, dict):
        return "", ""
    scope_pattern = clean_text(config.get("work_scope_pattern"))
    path_text = semantic_path_text(work.metadata_path)
    if scope_pattern and not re.search(scope_pattern, path_text):
        return "", ""

    sections = config.get("sections") if isinstance(config.get("sections"), dict) else {}
    path_parts = set(semantic_path_parts(work.metadata_path))
    matched: list[tuple[str, str]] = []
    for label, row in sections.items():
        if not isinstance(row, dict) or label not in path_parts:
            continue
        genre = clean_text(row.get("genre"))
        if genre:
            matched.append((label, genre))

    # If path structure is incomplete, a source/curated section label can still
    # confirm the broad genre, but only inside an already identified 詩經 work.
    if not matched:
        memberships = {strip_namespace(clean_text(value)) for value in (*work.categories, *work.source_categories)}
        for label, row in sections.items():
            if not isinstance(row, dict) or label not in memberships:
                continue
            genre = clean_text(row.get("genre"))
            if genre:
                matched.append((label, genre))

    genres = {genre for _label, genre in matched}
    if len(genres) != 1:
        return "", ""
    genre = next(iter(genres))
    evidence = " | ".join(label for label, value in matched if value == genre)
    return genre, evidence


def shijing_structure_action(work: Work, canonical: str, rules: dict) -> Action | None:
    """Remove duplicated received-structure labels when the corpus path carries them.

    This deliberately does not create new collection fields. The existing corpus
    organisation remains authoritative; 風、雅、頌 are added separately as broad
    genre categories by shijing_genre_for_work().
    """
    config = rules.get("shijing_structure")
    if not isinstance(config, dict):
        return None
    scope_pattern = clean_text(config.get("work_scope_pattern"))
    path_text = semantic_path_text(work.metadata_path)
    if scope_pattern and not re.search(scope_pattern, path_text):
        return None

    root_labels = {clean_text(value) for value in config.get("root_labels") or [] if clean_text(value)}
    sections = config.get("sections") if isinstance(config.get("sections"), dict) else {}
    group_pattern = clean_text(config.get("group_pattern"))
    is_structure_label = canonical in root_labels or canonical in sections or bool(group_pattern and re.fullmatch(group_pattern, canonical))
    if not is_structure_label:
        return None

    path_parts = set(semantic_path_parts(work.metadata_path))
    if canonical in path_parts or canonical in root_labels:
        genre = ""
        row = sections.get(canonical)
        if isinstance(row, dict):
            genre = clean_text(row.get("genre"))
        note = "The received 詩經 organisation is already encoded by the corpus path; do not duplicate it as flat taxonomy."
        if genre:
            note += f" The broad literary category {genre} is inferred separately."
        if group_pattern and re.fullmatch(group_pattern, canonical):
            note += " 什 remains only the existing received structural grouping; it is not promoted to a genre or new metadata field."
        return Action(
            "remove_shijing_structure_category",
            "categories/source_categories",
            "",
            "safe",
            canonical,
            "received 詩經 structure already present in corpus organisation",
            note,
        )

    ordered_parts = list(semantic_path_parts(work.metadata_path))
    structural_parts: list[str] = []
    try:
        root_index = ordered_parts.index("詩經")
    except ValueError:
        root_index = -1
    if root_index >= 0:
        for part in ordered_parts[root_index + 1 :]:
            if part in sections or (group_pattern and re.fullmatch(group_pattern, part)):
                structural_parts.append(part)

    path_structure = " > ".join(structural_parts) or "(no received structural label visible in path)"
    return Action(
        "shijing_structure_category_review",
        "categories/source_categories",
        "",
        "review",
        canonical,
        f"category={canonical}; path_structure={path_structure}",
        "The category and existing 《詩經》 organisation disagree or cannot be reconciled mechanically. Review which source is correct; do not create parallel collection metadata.",
    )


def serial_publication_parts(label: str, rules: dict) -> tuple[str, str] | None:
    exclusions = {clean_text(value) for value in rules.get("serial_publication_generic_exclusions") or [] if clean_text(value)}
    if label in exclusions:
        return None
    patterns = [clean_text(value) for value in rules.get("serial_publication_patterns") or [] if clean_text(value)]
    if not patterns or not any(re.search(pattern, label) for pattern in patterns):
        return None
    match = re.fullmatch(r"(.+?)\s*[（(]([^()（）]+)[)）]", label)
    if match:
        return match.group(1).strip(), match.group(2).strip()
    return label.strip(), ""


def likely_compilation_title(label: str, rules: dict) -> bool:
    if label in set(rules.get("compilation_title_exclusions") or []):
        return False
    if len(label) < 3:
        return False
    for pattern in rules.get("likely_compilation_title_patterns") or []:
        if re.search(clean_text(pattern), label):
            return True
    return False


def configured_period_range(label: str, rules: dict) -> str:
    for row in rules.get("period_range_categories") or []:
        if not isinstance(row, dict):
            continue
        pattern = clean_text(row.get("pattern"))
        target = clean_text(row.get("period"))
        if pattern and target and re.fullmatch(pattern, label):
            return target
    return ""


def taxonomy_pattern_match(label: str, rules: dict) -> dict | None:
    for row in rules.get("taxonomy_keep_patterns") or []:
        if not isinstance(row, dict):
            continue
        pattern = clean_text(row.get("pattern"))
        if pattern and re.fullmatch(pattern, label):
            return row
    return None


def qualified_person_label(label: str, indexes: dict) -> tuple[str, str] | None:
    match = re.fullmatch(r"(.+?)\s*[（(]([^()（）]{1,16})[)）]", label)
    if not match:
        return None
    base, qualifier = match.group(1).strip(), match.group(2).strip()
    if base not in indexes.get("people", set()):
        return None
    qualifier_is_context = (
        qualifier in indexes.get("periods", {})
        or qualifier in indexes.get("polities", {})
        or qualifier.endswith(("朝", "代"))
    )
    return (base, qualifier) if qualifier_is_context else None



def species_name_key(normalizer: Traditionalizer, value: object) -> str:
    """Normalize one taxonomic/common-name token for exact registry lookup.

    OpenCC handles the Han portion of a full name, so a value such as
    ``Mauremys mutica / 黄喉拟水龟 / Yellow pond turtle`` can be compared
    against the Traditional-Chinese registry without touching the Latin or
    English portions.  Punctuation/case normalization is deliberately small:
    this is an exact-name registry, not fuzzy taxonomic inference.
    """
    text = clean_text(value)
    if not text:
        return ""
    text = unicodedata.normalize("NFC", text)
    text = normalizer.normalize(text)[0]
    text = text.replace("’", "'").replace("–", "-").replace("—", "-")
    text = re.sub(r"\s+", " ", text).strip()
    return text.casefold()


def species_name_tokens(value: object) -> list[tuple[str, str]]:
    """Return labelled name tokens from material.species.

    material.species may be the preferred object form or a legacy/full-name
    string.  Slash/semicolon/pipe-separated full names are accepted so all of
    these can converge on the same structure:

      Mauremys mutica
      黃喉擬水龜
      Yellow pond turtle
      Mauremys mutica / 黃喉擬水龜 / Yellow pond turtle
    """
    values: list[tuple[str, str]] = []
    if isinstance(value, dict):
        for field in (
            "scientific_name",
            "scientific_name_full",
            "latin_name",
            "common_name_zh",
            "common_name_en",
            "common_name",
            "name",
            "full_name",
        ):
            text = clean_text(value.get(field))
            if text:
                values.append((field, text))
    else:
        text = clean_text(value)
        if text:
            values.append(("species", text))

    output: list[tuple[str, str]] = []
    for field, text in values:
        output.append((field, text))
        for part in re.split(r"\s*(?:/|／|\||;|；)\s*", text):
            part = part.strip()
            if part and part != text:
                output.append((field, part))
    # Stable de-duplication keeps diagnostics readable.
    return list(dict.fromkeys(output))


def species_registry_rows(rules: dict) -> list[dict]:
    return [row for row in (rules.get("animal_species_registry") or []) if isinstance(row, dict)]


def species_registry_actions(work: Work, normalizer: Traditionalizer, rules: dict) -> list[Action]:
    """Normalize an *existing* species identification; never invent one.

    The registry is a vocabulary/authority aid.  Its archaeological-context
    notes do not prove that a particular oracle bone belongs to that taxon.
    A work therefore enters this function only through names already present in
    material.species.  Broad material.animal values such as 牛、龜、鱉 are
    intentionally ignored as species evidence.
    """
    species_value = work.material.get("species")
    if not species_value:
        return []

    rows = species_registry_rows(rules)
    if not rows:
        return []

    alias_index: dict[str, set[int]] = collections.defaultdict(set)
    row_aliases: list[set[str]] = []
    for index, row in enumerate(rows):
        aliases: set[str] = set()
        for field in ("scientific_name", "scientific_name_full", "common_name_zh", "common_name_en"):
            key = species_name_key(normalizer, row.get(field))
            if key:
                aliases.add(key)
        for alias in row.get("aliases") or []:
            key = species_name_key(normalizer, alias)
            if key:
                aliases.add(key)
        row_aliases.append(aliases)
        for alias in aliases:
            alias_index[alias].add(index)

    tokens = species_name_tokens(species_value)
    matched_rows: set[int] = set()
    matched_fields: list[str] = []
    for field, token in tokens:
        indexes = alias_index.get(species_name_key(normalizer, token), set())
        if indexes:
            matched_rows.update(indexes)
            matched_fields.append(f"{field}={token}")

    if not matched_rows:
        return []

    if len(matched_rows) > 1:
        candidates = [clean_text(rows[index].get("scientific_name")) for index in sorted(matched_rows)]
        return [Action(
            "species_identification_conflict",
            "material.species",
            " / ".join(value for value in candidates if value),
            "review",
            compact_json(species_value) if isinstance(species_value, dict) else clean_text(species_value),
            "multiple species-registry names match the existing species value",
            "The existing names point at more than one taxon. Resolve the specimen identification from its catalogue/zooarchaeological evidence before normalizing names.",
        )]

    index = next(iter(matched_rows))
    row = rows[index]
    aliases = row_aliases[index]

    # If a structured record contains a scientific/common-name field that
    # clearly names something outside the selected row, do not overwrite it.
    if isinstance(species_value, dict):
        contradictory: list[str] = []
        for field in ("scientific_name", "scientific_name_full", "latin_name", "common_name_zh", "common_name_en"):
            existing = clean_text(species_value.get(field))
            if not existing:
                continue
            key = species_name_key(normalizer, existing)
            if key not in aliases:
                # Only call this a contradiction when it looks like a real name,
                # not a free-text note accidentally stored alongside the fields.
                if field.startswith("scientific") or field == "latin_name" or alias_index.get(key):
                    contradictory.append(f"{field}={existing}")
        if contradictory:
            return [Action(
                "species_identification_conflict",
                "material.species",
                clean_text(row.get("scientific_name")),
                "review",
                compact_json(species_value),
                "registry match conflicts with another structured species-name field",
                "Conflicting fields: " + " | ".join(contradictory) + ". Preserve the current identification until specimen-level evidence resolves it.",
            )]

    proposed: dict[str, object] = {}
    for field in ("scientific_name", "common_name_zh", "common_name_en"):
        value = clean_text(row.get(field))
        if value:
            proposed[field] = value
    if isinstance(species_value, dict):
        legacy_name_fields = {
            "scientific_name", "scientific_name_full", "latin_name",
            "common_name_zh", "common_name_en", "common_name", "name", "full_name",
        }
        for key, value in species_value.items():
            if key not in legacy_name_fields:
                proposed[key] = value

    existing_display = compact_json(species_value) if isinstance(species_value, dict) else clean_text(species_value)
    proposed_display = compact_json(proposed)
    if isinstance(species_value, dict) and compact_json(species_value) == proposed_display:
        return []

    scientific_key = species_name_key(normalizer, row.get("scientific_name"))
    scientific_match = any(
        species_name_key(normalizer, token) in {scientific_key, species_name_key(normalizer, row.get("scientific_name_full"))}
        for _field, token in tokens
    )
    full_name_input = not isinstance(species_value, dict) and bool(re.search(r"/|／|\||;|；", clean_text(species_value)))
    action_name = "normalize_species_full_name" if full_name_input else "normalize_species_names"
    status = clean_text(row.get("oracle_use_status"))
    contexts = "、".join(clean_text(value) for value in (row.get("oracle_contexts") or row.get("archaeological_contexts") or []) if clean_text(value))
    context_note = f" Registry context: {status}" + (f" ({contexts})" if contexts else "") + "." if status else ""

    return [Action(
        action_name,
        "material.species",
        proposed_display,
        "safe" if scientific_match else "high",
        existing_display,
        "unique species-registry match: " + " | ".join(dict.fromkeys(matched_fields)),
        "Normalize the existing taxon to scientific_name + Traditional-Chinese common_name_zh + English common_name_en. The registry standardizes names only; it is not specimen-level evidence for the identification." + context_note,
    )]


def material_profile_actions(work: Work, normalizer: Traditionalizer, rules: dict) -> list[Action]:
    """Plan carrier/material metadata independently of category retention.

    medium is the broad carrier/support (紙、骨、龜甲、金、竹、木、帛、石、數位...).
    material stores object-specific detail, such as animal/anatomical source,
    optional species identification, or a documented metal/alloy analysis.
    A biological material can therefore preserve, when supported, fields such as:

      material.species.scientific_name
      material.species.common_name_zh
      material.species.common_name_en

    Species is optional: a catalogue saying only 牛 or 龜 must not be inflated
    into a modern species identification. Epigraphic categories such as 甲骨文
    and 金文 remain categories even when they also provide material evidence.
    """
    actions: list[Action] = []
    categories = {canonical_label(normalizer, raw)[0] for raw, _origin in unique_memberships(work)}
    edition_text = " ".join(existing_edition_labels(work, normalizer))
    path_text = "\n".join(
        value for value in (
            work.metadata_path.as_posix(),
            semantic_path_text(work.metadata_path),
        ) if value
    )
    source_text = "\n".join(work.sources)
    title_text = "\n".join(value for value in (work.title, work.work_base_title, edition_text) if value)
    author_text = "\n".join(work.authors)
    haystack = "\n".join(
        value for value in (
            path_text,
            title_text,
            work.object_type,
            source_text,
            author_text,
        ) if value
    )
    current_medium = normalize_name(normalizer, work.medium) if work.medium else ""
    legacy_digital_medium = bool(work.medium and work.medium.strip().lower() in {"digital", "born-digital", "born digital"})
    profile_current_medium = normalize_name(normalizer, "數位") if legacy_digital_medium else current_medium
    material_type = clean_text(work.material.get("type"))

    def profile_matches(profile: dict) -> bool:
        checks: list[bool] = []
        for key, target in (
            ("pattern", haystack),
            ("path_pattern", path_text),
            ("source_pattern", source_text),
            ("title_pattern", title_text),
            ("author_pattern", author_text),
        ):
            pattern = clean_text(profile.get(key))
            if pattern:
                checks.append(bool(re.search(pattern, target, flags=re.IGNORECASE)))
        return bool(checks) and all(checks)

    for profile in rules.get("material_source_profiles") or []:
        if not isinstance(profile, dict):
            continue
        proposed = clean_text(profile.get("medium"))
        if not proposed or not profile_matches(profile):
            continue
        proposed_norm = normalize_name(normalizer, proposed)
        if profile_current_medium == proposed_norm:
            break
        if not work.medium:
            actions.append(Action(
                "promote_source_material_metadata",
                "medium",
                proposed,
                "high",
                "",
                clean_text(profile.get("name")) or "configured source/witness material profile",
                clean_text(profile.get("note")) or "The source/witness family identifies the carrier.",
            ))
        else:
            actions.append(Action(
                "source_material_metadata_conflict",
                "medium",
                proposed,
                "review",
                work.medium,
                clean_text(profile.get("name")) or "configured source/witness material profile",
                f"The source/witness profile proposes medium={proposed}, but structured medium already says {work.medium}. Review whether the two values describe different witnesses.",
            ))
        break

    if legacy_digital_medium:
        actions.append(Action(
            "normalize_digital_medium",
            "medium",
            "數位",
            "safe",
            work.medium,
            "legacy English digital-medium value",
            "Use 數位 as the canonical corpus medium label for born-digital works.",
        ))

    if current_medium == normalize_name(normalizer, "金文"):
        actions.append(Action(
            "normalize_epigraphic_medium",
            "medium",
            "金",
            "high",
            work.medium,
            "legacy medium value 金文 describes the inscription class, not the physical carrier",
            "Keep 金文 in categories. Use medium=金 as the broad metal carrier; exact metal or alloy belongs in material.",
        ))
    elif current_medium == normalize_name(normalizer, "甲骨文"):
        if material_type:
            actions.append(Action(
                "normalize_epigraphic_medium",
                "medium",
                material_type,
                "high",
                work.medium,
                "material.type supplies the physical support behind legacy medium=甲骨文",
                "Keep 甲骨文 in categories and use the identified physical support in medium.",
            ))
        else:
            actions.append(Action(
                "oracle_bone_material_review",
                "medium + material",
                "龜甲 / 骨（待辨）",
                "review",
                work.medium,
                "legacy medium=甲骨文 does not identify turtle shell versus bone",
                "Keep 甲骨文 as taxonomy. Resolve the physical carrier separately; do not infer animal or species without object-specific evidence. Species-level identifications belong under material.species.",
            ))
    elif current_medium == normalize_name(normalizer, "簡牘"):
        if material_type in {"竹", "木", "竹簡", "木牘"}:
            proposed = "竹" if material_type in {"竹", "竹簡"} else "木"
            actions.append(Action(
                "normalize_epigraphic_medium",
                "medium",
                proposed,
                "high",
                work.medium,
                "material.type resolves legacy medium=簡牘",
                "Keep any useful 簡牘/竹簡/木牘 classification separately from the physical support.",
            ))
        else:
            actions.append(Action(
                "slip_material_review",
                "medium + material",
                "竹 / 木（待辨）",
                "review",
                work.medium,
                "legacy medium=簡牘 does not distinguish bamboo from wood",
                "Resolve the support from catalogue or object metadata before migration.",
            ))

    if "金文" in categories and not work.medium:
        actions.append(Action(
            "promote_epigraphic_material_metadata",
            "medium",
            "金",
            "high",
            "",
            "金文 category identifies a metal-inscription context",
            "Keep 金文 as a category. 金 is intentionally broad; do not infer copper, bronze, iron, or an alloy recipe without object-specific evidence.",
        ))
    if "甲骨文" in categories and not work.medium:
        if material_type:
            proposed_medium = "竹" if material_type == "竹簡" else "木" if material_type == "木牘" else material_type
            actions.append(Action(
                "promote_oracle_bone_material_metadata",
                "medium",
                proposed_medium,
                "high",
                "",
                "material.type already identifies the physical support",
                "Keep 甲骨文 as taxonomy. Use the existing material identification for medium; preserve any animal/species/anatomical detail under material.",
            ))
        else:
            actions.append(Action(
                "oracle_bone_material_review",
                "medium + material",
                "龜甲 / 骨（待辨）",
                "review",
                "",
                "甲骨文 category identifies the inscription class but not the support",
                "Keep 甲骨文 as a category. Resolve turtle shell versus bone and biological source from catalogue/object evidence. If research reaches species level, record material.species.scientific_name plus Chinese and English common names.",
            ))

    bronze_patterns = [clean_text(value) for value in rules.get("bronze_material_patterns") or [] if clean_text(value)]
    if bronze_patterns and any(re.search(pattern, haystack) for pattern in bronze_patterns):
        if normalize_name(normalizer, material_type) != normalize_name(normalizer, "青銅"):
            existing = compact_json(work.material)
            actions.append(Action(
                "promote_bronze_material_detail" if not material_type else "bronze_material_detail_conflict",
                "material.type",
                "青銅",
                "high" if not material_type else "review",
                existing,
                "explicit 青銅/青銅器 wording in object/source metadata",
                "Record 青銅 as the object material. Leave material.alloy unset unless a source identifies the actual alloy or analytical composition for this object.",
            ))

    actions.extend(species_registry_actions(work, normalizer, rules))
    return actions


def classify_membership(
    work: Work,
    raw: str,
    origin: str,
    canonical: str,
    unresolved_chars: tuple[str, ...],
    normalizer: Traditionalizer,
    indexes: dict,
    rules: dict,
    semantics: dict[str, dict[str, float | int | str]],
    evidence: Evidence | None,
    preamble_evidence: PreamblePersonEvidence | None,
    work_date_categories: Sequence[DateCategory],
) -> list[Action]:
    actions: list[Action] = []
    safe_remove_rules = rules.get("safe_remove_rules") or []
    scoped_rules = rules.get("scoped_keep_rules") or []
    semantic_map = exact_map(rules, "category_normalizations")
    material_map = exact_map(rules, "material_categories")
    material_review_map = exact_map(rules, "material_review_categories")
    animal_materials = exact_map(rules, "animal_materials")
    known_compilation_titles = set(rules.get("known_compilation_titles") or [])
    tradition_labels = set(rules.get("tradition_labels") or [])
    controlled_taxonomy = rules.get("_controlled_taxonomy_nodes") or set()
    book_grouping_labels = set(rules.get("book_grouping_labels") or [])

    rule = category_rule_match(canonical, safe_remove_rules)
    if rule is not None:
        actions.append(
            Action(
                action=clean_text(rule.get("action")) or "delete_category",
                target_field="categories/source_categories",
                proposed_value="",
                confidence=clean_text(rule.get("confidence")) or "safe",
                existing_value=canonical,
                evidence=clean_text(rule.get("name")),
                note=clean_text(rule.get("note")),
            )
        )
        return actions

    if volume_only(canonical):
        return [
            Action(
                "delete_structural_noise",
                "categories/source_categories",
                "",
                "safe",
                canonical,
                "bare volume label",
                "A volume number by itself is document structure, not corpus taxonomy.",
            )
        ]

    calendar_context = calendar_context_for_work(work)

    range_period = configured_period_range(canonical, rules)
    if range_period:
        target_norm = normalize_name(normalizer, range_period)
        work_period_norm = normalize_name(normalizer, work.period) if work.period else ""
        path_periods = hierarchy_period_candidates(work, indexes, normalizer, rules)
        work_range = work_absolute_year_range(work, work_date_categories, context=calendar_context)
        target_bounds = calendar_period_bounds(range_period)
        if work_range and target_bounds and not ranges_overlap(work_range, target_bounds[:2]):
            return [Action(
                "period_range_category_date_conflict_review", "period", range_period, "review", work.period,
                f"firm work chronology {work_range[0]}..{work_range[1]} falls outside {range_period} bounds {target_bounds[0]}..{target_bounds[1]}",
                "Do not promote a source period classification when the normalized work date contradicts it. Review the source category and corpus placement together.",
            )]
        if work_period_norm == target_norm or target_norm in path_periods:
            return [Action(
                "remove_period_range_category_redundant", "period", work.period or range_period, "safe", work.period,
                f"source date-range label maps to period {range_period}, already represented by structured metadata/corpus hierarchy",
                "This range is dynasty/period classification, not the date of every individual work. Keep the curated placement and remove the source range category.",
            )]
        if not work.period:
            if path_periods:
                return [Action(
                    "period_range_category_path_conflict_review", "period / corpus path", range_period, "review", " / ".join(corpus_hierarchy_labels(work)),
                    f"configured source range maps to {range_period}, while canonical corpus path contains period(s) {', '.join(path_periods)}",
                    "The corpus hierarchy is authoritative for placement. Do not populate a conflicting period automatically; review this as a possible scraped-category error or genuine folder mismatch.",
                )]
            return [Action(
                "promote_period_from_range_category", "period", range_period, "high", "",
                f"configured source range maps to period {range_period}",
                "Populate period metadata; do not copy the dynasty-wide date range into the work's date_label.",
            )]
        return [Action(
            "period_range_category_conflict_review", "period", range_period, "review", work.period,
            f"configured source range maps to {range_period} but structured period differs",
            "Review the source chronology. A dynasty-wide range category must not overwrite a specific work date or curated corpus placement.",
        )]

    date_cat = parse_date_category(canonical, context=calendar_context)
    if date_cat is not None:
        if date_cat.is_mention:
            return [
                Action(
                    "promote_date_mention",
                    "mentions.dates",
                    date_cat.source_label,
                    "high",
                    work.date_label,
                    f"category explicitly says 提及; absolute equivalent {date_cat.label}",
                    "Keep the mentioned historical date expression distinct from the work's own date; the date resolver can supply its absolute year.",
                )
            ]
        plain_dates = [item for item in work_date_categories if not item.is_mention]
        tuples = {(item.year, item.month, item.day) for item in plain_dates}
        years = {item.year for item in plain_dates}
        existing_source = work.date_label or work.date
        existing = parse_existing_date_label(existing_source, context=calendar_context) if existing_source else None
        if len(years) > 1:
            return [
                Action(
                    "date_metadata_conflict",
                    "date_label",
                    date_cat.source_label,
                    "review",
                    work.date_label,
                    "multiple incompatible date categories on this work",
                    "Do not choose a work date automatically when category evidence disagrees.",
                )
            ]
        path_bounds = calendar_period_bounds(corpus_hierarchy_labels(work))
        if path_bounds and not ranges_overlap((date_cat.year, date_cat.year), path_bounds[:2]):
            return [
                Action(
                    "date_path_period_conflict_review",
                    "date_label / period / corpus path",
                    date_cat.source_label,
                    "review",
                    work.date_label or work.date or work.period,
                    f"absolute date {date_cat.year} falls outside canonical path period bounds {path_bounds[0]}..{path_bounds[1]} ({'/'.join(path_bounds[2])})",
                    "The date may expose one of the small number of genuinely misfiled works, or the source category may be wrong. Do not move the work or discard the date automatically.",
                )
            ]
        most_specific = max(plain_dates, key=lambda item: item.specificity) if plain_dates else date_cat
        if existing and date_compatible(date_cat, existing):
            return [
                Action(
                    "remove_date_category_redundant",
                    "date_label",
                    existing_source,
                    "safe",
                    existing_source,
                    "category agrees with existing date metadata",
                    "The date belongs in date metadata and the category can be removed.",
                )
            ]
        if not existing_source:
            if date_cat.canonical != most_specific.canonical:
                return [
                    Action(
                        "remove_date_category_subsumed",
                        "date_label",
                        most_specific.source_label,
                        "safe",
                        "",
                        f"more specific date category {most_specific.source_label} exists on the same work (absolute equivalent {most_specific.label})",
                        "Promote only the most specific compatible date; remove the coarser category.",
                    )
                ]
            return [
                Action(
                    "promote_date_metadata",
                    "date_label",
                    most_specific.source_label,
                    "high",
                    "",
                    f"most specific compatible date category; absolute equivalent {most_specific.label}",
                    "Populate date_label with the historical expression, let the shared CalendarEngine/HistoricalDateResolver path derive the absolute year, then remove the date category.",
                )
            ]
        return [
            Action(
                "date_metadata_conflict",
                "date_label",
                most_specific.source_label,
                "review",
                existing_source,
                "category does not agree with existing date metadata",
                "Review the date evidence before changing either value.",
            )
        ]

    dated_composite = leading_date_in_suffix(canonical, context=calendar_context)
    if dated_composite is not None:
        composite_date, remainder = dated_composite
        if remainder:
            existing_source = work.date_label or work.date
            existing = parse_existing_date_label(existing_source, context=calendar_context) if existing_source else None
            path_bounds = calendar_period_bounds(corpus_hierarchy_labels(work))
            path_conflict = bool(
                path_bounds
                and not ranges_overlap((composite_date.year, composite_date.year), path_bounds[:2])
            )
            if path_conflict:
                confidence = "review"
                existing_value = existing_source or work.period
                evidence_text = (
                    f"absolute date {composite_date.year} falls outside canonical path period bounds "
                    f"{path_bounds[0]}..{path_bounds[1]} ({'/'.join(path_bounds[2])})"
                )
            elif existing and date_compatible(composite_date, existing):
                confidence = "high"
                existing_value = existing_source
                evidence_text = f"date prefix agrees with structured date metadata; absolute equivalent {composite_date.label}"
            elif not existing_source:
                confidence = "high"
                existing_value = ""
                evidence_text = f"date prefix can populate date metadata; absolute equivalent {composite_date.label}"
            else:
                confidence = "review"
                existing_value = existing_source
                evidence_text = "date prefix conflicts with structured date metadata"
            return [Action(
                "split_date_from_category",
                "date_label + categories",
                f"date_label={composite_date.source_label}; category={remainder}",
                confidence,
                existing_value,
                evidence_text,
                "The leading date is metadata; retain the non-date remainder as a category candidate and remove the composite source label.",
            )]

    if looks_like_unmapped_era_year(canonical):
        is_mention = bool(re.search(r"\s*[（(]提及[)）]\s*$", canonical))
        return [
            Action(
                "era_year_mention_review" if is_mention else "era_year_metadata_review",
                "mentions.dates" if is_mention else "date_label",
                canonical,
                "review",
                work.date_label,
                "year-like category uses an era/regnal name without a configured Gregorian base",
                "This belongs in structured date metadata, but convert the era year only after the era has been identified unambiguously.",
            )
        ]

    if canonical in material_map:
        proposed_medium = clean_text(material_map[canonical])
        animal_row = animal_materials.get(canonical) if isinstance(animal_materials.get(canonical), dict) else None
        target_field = "medium"
        proposed_display = proposed_medium
        animal_note = ""
        if animal_row:
            target_field = "medium + animal identification"
            animal_name = clean_text(animal_row.get("animal_name"))
            animal_name_en = clean_text(animal_row.get("animal_common_name_en"))
            taxon = clean_text(animal_row.get("taxon_candidate"))
            species_field = clean_text(animal_row.get("species_field"))
            proposed_display = f"medium={proposed_medium}"
            if animal_name:
                proposed_display += f"; animal={animal_name}"
            if animal_name_en:
                proposed_display += f"; animal_en={animal_name_en}"
            if taxon:
                proposed_display += f"; taxon={taxon}"
            if species_field:
                proposed_display += f"; species_field={species_field}"
            animal_note = " " + clean_text(animal_row.get("note"))
        if work.medium and normalize_name(normalizer, work.medium) == normalize_name(normalizer, proposed_medium):
            return [
                Action(
                    "remove_material_category_redundant",
                    target_field,
                    proposed_display,
                    "safe",
                    work.medium,
                    "category agrees with existing medium",
                    "Material belongs in structured metadata.",
                )
            ]
        if not work.medium:
            return [
                Action(
                    "promote_material_metadata",
                    target_field,
                    proposed_display,
                    "high",
                    "",
                    "explicit material category",
                    "The value names the support/material directly; 金 remains broad and does not imply alloy composition." + animal_note,
                )
            ]
        return [
            Action(
                "material_metadata_conflict",
                target_field,
                proposed_display,
                "review",
                work.medium,
                "explicit material category conflicts with current medium",
                "Review the object description before changing material metadata.",
            )
        ]

    if canonical in material_review_map and canonical != "甲骨文":
        return [
            Action(
                "material_identification_review",
                "medium",
                clean_text(material_review_map[canonical]),
                "review",
                work.medium,
                "material category is broader than the desired structured material values",
                "Resolve the physical support before migration; do not collapse distinct supports into one value.",
            )
        ]

    # 甲骨文 is a meaningful epigraphic/script category. Physical-support
    # inference is handled once per work by material_profile_actions so the
    # category itself is not consumed as material metadata.


    shijing_action = shijing_structure_action(work, canonical, rules)
    if shijing_action is not None:
        return [shijing_action]

    parts = compilation_parts(canonical)
    if parts is not None:
        base, edition, volume = parts
        base_norm = normalize_name(normalizer, base)
        matches = indexes["titles"].get(base_norm, [])
        compilations = [candidate for candidate in matches if candidate.is_compilation]
        if len(compilations) == 1:
            parent = compilations[0]
            proposal = f"work_id={parent.work_id}; title={parent.title}; volume=卷{volume}"
            if edition:
                proposal += f"; edition={edition}"
            if parent.work_id in existing_containment_ids(work):
                return [
                    Action(
                        "remove_compilation_path_redundant",
                        "contained_in",
                        proposal,
                        "safe",
                        "contained_in already links this compilation",
                        "category path resolves to existing compilation membership",
                        "The path-like category duplicates structured compilation membership.",
                    )
                ]
            return [
                Action(
                    "promote_compilation_membership",
                    "contained_in",
                    proposal,
                    "high",
                    "",
                    "category path resolves to one compilation work",
                    "Preserve the volume and edition information in structured compilation membership.",
                )
            ]
        return [
            Action(
                "promote_compilation_membership_unresolved_parent",
                "contained_in / compilation system",
                f"title={base}; volume=卷{volume}" + (f"; edition={edition}" if edition else ""),
                "high",
                "",
                f"explicit compilation/volume path; title matches: {len(matches)}; marked compilations: {len(compilations)}",
                "The membership and volume/edition evidence are explicit in the source category. Resolve or create the parent compilation once at the compilation level; individual member rows do not need separate semantic review.",
            )
        ]

    if canonical in known_compilation_titles:
        # A generic compilation label is redundant when this same work also has
        # a more specific source path such as 全唐文/卷0649.  The path preserves
        # the membership plus volume, so keeping a second plain 全唐文 decision
        # only creates duplicate review work.
        specific_memberships: list[str] = []
        for other_raw, _other_origin in unique_memberships(work):
            other_canonical, _ = canonical_label(normalizer, other_raw)
            if other_canonical == canonical:
                continue
            parts = compilation_parts(other_canonical)
            if parts is not None and parts[0] == canonical:
                specific_memberships.append(other_canonical)
        if specific_memberships:
            return [Action(
                "remove_compilation_category_subsumed",
                "contained_in / compilation system",
                canonical,
                "safe",
                "",
                "more specific compilation membership on same work: " + " | ".join(specific_memberships[:4]),
                "The specific compilation/volume path already preserves this membership. Remove the generic compilation category to avoid duplicate evidence.",
            )]

        known_matches = indexes["titles"].get(canonical, [])
        known_compilations = [candidate for candidate in known_matches if candidate.is_compilation and candidate.metadata_path != work.metadata_path]
        if len(known_compilations) == 1:
            parent = known_compilations[0]
            if parent.work_id in existing_containment_ids(work):
                return [
                    Action(
                        "remove_compilation_category_redundant",
                        "contained_in",
                        f"work_id={parent.work_id}; title={parent.title}",
                        "safe",
                        "contained_in already present",
                        "known compilation title and existing structured membership",
                        "The compilation category duplicates contained_in.",
                    )
                ]
            return [
                Action(
                    "promote_compilation_membership",
                    "contained_in",
                    f"work_id={parent.work_id}; title={parent.title}",
                    "high",
                    "",
                    "configured compilation title resolves to one corpus compilation",
                    "The configured compilation label is direct membership evidence; use contained_in instead of retaining it as subject taxonomy.",
                )
            ]
        if len(known_compilations) > 1:
            return [
                Action(
                    "known_compilation_parent_ambiguity_review",
                    "contained_in / compilation system",
                    canonical,
                    "review",
                    "",
                    f"configured compilation title resolves to {len(known_compilations)} marked corpus compilations",
                    "Resolve the duplicate/edition-specific parent records once at compilation level. Do not reinterpret this label as subject taxonomy.",
                )
            ]
        if known_matches and not known_compilations:
            return [
                Action(
                    "promote_compilation_membership_unresolved_parent",
                    "is_compilation / contained_in",
                    canonical,
                    "high",
                    "",
                    f"configured compilation label; corpus title matches: {len(known_matches)}; marked compilations: 0",
                    "Membership evidence is strong. Resolve which matching title is the parent and mark the parent as a compilation if appropriate; do this once per compilation, not once per member.",
                )
            ]
        if not known_matches:
            return [
                Action(
                    "promote_compilation_membership_missing_parent",
                    "compilation system / contained_in",
                    canonical,
                    "high",
                    "",
                    "configured compilation title has no corpus title match",
                    "The source membership is explicit. Add or resolve the parent compilation record once, then attach these members through contained_in.",
                )
            ]

    title_matches = indexes["titles"].get(canonical, [])
    compilation_matches = [candidate for candidate in title_matches if candidate.is_compilation and candidate.metadata_path != work.metadata_path]
    if compilation_matches:
        containment_ids = existing_containment_ids(work)
        existing = [candidate for candidate in compilation_matches if candidate.work_id in containment_ids]
        if existing:
            parent = existing[0]
            return [
                Action(
                    "remove_compilation_category_redundant",
                    "contained_in",
                    f"work_id={parent.work_id}; title={parent.title}",
                    "safe",
                    "contained_in already present",
                    "category exactly names an existing parent compilation",
                    "Compilation membership is already structured.",
                )
            ]
        if len(compilation_matches) == 1:
            parent = compilation_matches[0]
            return [
                Action(
                    "promote_compilation_membership",
                    "contained_in",
                    f"work_id={parent.work_id}; title={parent.title}",
                    "high",
                    "",
                    "category exactly matches one marked compilation title",
                    "The source category is direct membership evidence for the uniquely resolved parent compilation.",
                )
            ]

    if canonical in book_grouping_labels:
        return [Action(
            "promote_book_grouping_membership",
            "book grouping system",
            canonical,
            "high",
            "",
            "configured/validated collective book-grouping label",
            "Treat exact membership in a configured book grouping as structured grouping evidence. Do not retain the grouping name as ordinary subject taxonomy.",
        )]

    serial_parts = serial_publication_parts(canonical, rules)
    if serial_parts is not None:
        publication, issue = serial_parts
        proposal = f"publication={publication}" + (f"; issue={issue}" if issue else "")
        pub_norm = normalize_name(normalizer, publication)
        matches = [candidate for candidate in indexes["titles"].get(pub_norm, []) if candidate.metadata_path != work.metadata_path]
        compilations = [candidate for candidate in matches if candidate.is_compilation]
        if len(compilations) == 1:
            parent = compilations[0]
            proposal = f"work_id={parent.work_id}; title={parent.title}" + (f"; issue={issue}" if issue else "")
        return [Action(
            "promote_serial_publication_membership",
            "contained_in / publication system",
            proposal,
            "high",
            "",
            "source category names a serial/publication title" + (" and issue" if issue else ""),
            "Preserve source-publication membership structurally. A parent publication record may need to be created or marked as a compilation/serial once; the source category itself should not remain subject taxonomy.",
        )]

    if likely_compilation_title(canonical, rules):
        return [Action(
            "likely_compilation_title_review",
            "compilation system",
            canonical,
            "review",
            "",
            "category has a collection/compilation-style title but no unique structured compilation match was found",
            "Check whether the compilation exists under another title/edition. If it does, migrate this to contained_in; otherwise consider adding the compilation record.",
        )]

    role_category = split_contributor_role_suffix(canonical)
    if role_category is not None and canonical not in indexes["people"]:
        name, role = role_category
        target = "authors" if role == "author" else "contributors"
        return [Action(
            "promote_contributor_role_candidate",
            target,
            f"{name}; role={role}",
            "high",
            " | ".join(work.authors + work.editors + work.contributors),
            "category explicitly encodes a personal credit plus intellectual role",
            "Promote the named contributor and role, then remove the role-marked category. A genuine personal name ending in 著 is protected by the whole-name person check.",
        )]

    authors, other_people = work_people(work, normalizer)
    qualified_person = qualified_person_label(canonical, indexes)
    if qualified_person is not None:
        person_base, qualifier = qualified_person
        canonical = person_base

    if canonical in indexes["people"]:
        if canonical in authors:
            return [
                Action(
                    "remove_person_category_author_redundant",
                    "authors",
                    canonical,
                    "safe",
                    " | ".join(work.authors + work.document_authors),
                    "category name matches structured author",
                    "Personal names used as author groupings belong in the author field.",
                )
            ]
        if canonical in other_people:
            return [
                Action(
                    "remove_person_category_role_redundant",
                    "editors/contributors",
                    canonical,
                    "safe",
                    " | ".join(work.editors + work.contributors),
                    "category name matches structured editor/contributor",
                    "The person's role is already structured.",
                )
            ]
        cbdb_direct = (indexes.get("cbdb_role_evidence") or {}).get((work.metadata_path, canonical), ())
        if cbdb_direct:
            role_set = {item.role for item in cbdb_direct if item.role}
            evidence_bits = [
                f"CBDB person {item.person_id} ({item.primary_name}); text {item.text_title}; role {item.role_label or item.role}"
                for item in cbdb_direct[:4]
            ]
            if len(role_set) == 1:
                role = next(iter(role_set))
                target = "authors" if role == "author" else ("editors" if role == "editor" else "contributors")
                proposed = canonical if role in {"author", "editor"} else f"{canonical}; role={role}"
                if role == "author" and authors and canonical not in authors:
                    return [Action(
                        "cbdb_author_conflict_review",
                        "authors",
                        canonical,
                        "review",
                        " | ".join(work.authors + work.document_authors),
                        "; ".join(evidence_bits),
                        "CBDB directly links this person to the matching text as an author, but structured authorship already names someone else. Review the witness/title identity before changing metadata.",
                    )]
                return [Action(
                    "promote_author_candidate" if role == "author" else "promote_contributor_role_candidate",
                    target,
                    proposed,
                    "high",
                    " | ".join(work.authors + work.editors + work.contributors),
                    "; ".join(evidence_bits),
                    "CBDB directly links the exact person and text title with this intellectual role. Remove the personal-name category after structuring the credit.",
                )]
            return [Action(
                "cbdb_person_role_conflict_review",
                "authors / contributors",
                canonical,
                "review",
                " | ".join(work.authors + work.editors + work.contributors),
                "; ".join(evidence_bits),
                "CBDB links the person to the matching title with more than one role; preserve those intellectual roles explicitly instead of choosing one automatically.",
            )]
        if preamble_evidence and preamble_evidence.roles:
            roles = list(preamble_evidence.roles)
            if len(roles) == 1:
                role = roles[0]
                target = "authors" if role == "author" else "contributors"
                return [
                    Action(
                        "promote_author_candidate" if role == "author" else "promote_contributor_role_candidate",
                        target,
                        canonical if role == "author" else f"{canonical}; role={role}",
                        "high",
                        " | ".join(work.authors + work.editors + work.contributors),
                        f"source-added document preamble explicitly marks {canonical} as {role}: {preamble_evidence.first_snippet}",
                        "Move the personal credit into structured authorship/contributor metadata and remove the personal-name category.",
                    )
                ]
            return [
                Action(
                    "person_preamble_role_review",
                    "authors / contributors",
                    canonical,
                    "review",
                    " | ".join(work.authors + work.editors + work.contributors),
                    "source-added document preambles use multiple role markers: " + ", ".join(sorted(roles)),
                    "The category is certainly a personal credit, but its intellectual role varies and should be represented explicitly.",
                )
            ]
        authorial_source = (indexes.get("authorial_compilation_evidence") or {}).get((work.metadata_path, canonical))
        if authorial_source and not authors:
            return [
                Action(
                    "promote_author_candidate",
                    "authors",
                    canonical,
                    "high",
                    "",
                    f"source category is the sole plausible personal name alongside author-organized anthology volume {authorial_source}",
                    "Promote the source author category into structured authorship, then remove the personal-name category. The anthology rule requires exactly one plausible person candidate on the work.",
                )
            ]
        stats = semantics.get(canonical)
        if stats is not None:
            likely_author = (
                (
                    int(stats.get("author_matches", 0)) >= int(rules.get("person_author_min_matches", 3))
                    and float(stats.get("author_ratio", 0.0)) >= float(rules.get("person_author_ratio", 0.8))
                )
                or int(stats.get("title_parenthetical_matches", 0))
                >= int(rules.get("person_parenthetical_author_min_matches", 2))
                or int(stats.get("authorial_compilation_matches", 0)) > 0
                or int(stats.get("preamble_author_matches", 0)) > 0
                or (
                    int(stats.get("cbdb_author_matches", 0)) > 0
                    and not any(
                        token and not token.startswith("author=")
                        for token in clean_text(stats.get("cbdb_roles")).split(", ")
                    )
                )
            )
            if not authors and likely_author:
                return [
                    Action(
                        "promote_author_candidate",
                        "authors",
                        canonical,
                        "high",
                        "",
                        (
                            f"person category behaves like an author grouping; structured-author ratio "
                            f"{float(stats.get('author_ratio', 0.0)):.1%}, title-parenthesis signals "
                            f"{int(stats.get('title_parenthetical_matches', 0))}, preamble author signals "
                            f"{int(stats.get('preamble_author_matches', 0))}, CBDB direct author-title signals "
                            f"{int(stats.get('cbdb_author_matches', 0))}"
                        ),
                        "Use positive authorship evidence to fill missing authors, then remove the personal-name category.",
                    )
                ]

        body_count = evidence.occurrences if evidence else 0
        if body_count > 0:
            status = person_annotation_status(evidence)
            annotation_evidence = person_annotation_evidence_text(evidence)
            caution = ""
            if work.is_compilation and evidence and len(evidence.documents) < len(work.documents):
                caution = " Mention evidence is component-level within a compilation."
            if status == "high":
                return [
                    Action(
                        "promote_person_mention",
                        "mentions.people",
                        canonical,
                        "high" if not work.is_compilation else "review",
                        " | ".join(work.authors),
                        annotation_evidence,
                        "The source category is corroborated in the body and the shared historical annotator confirms a high-confidence person occurrence. This records a person mention only; it does not infer the person's associated tradition or genre." + caution,
                    )
                ]
            if status == "possible":
                return [
                    Action(
                        "person_mention_review",
                        "mentions.people",
                        canonical,
                        "review",
                        " | ".join(work.authors),
                        annotation_evidence,
                        "The source category is corroborated in the body and the shared annotator retains the person identity as possible, but its normal ambiguity/chronology threshold was not high enough for automatic promotion. Do not infer a tradition category from the name.",
                    )
                ]
            if status == "authority_unavailable":
                return [
                    Action(
                        "person_mention_authority_unavailable_review",
                        "mentions.people",
                        canonical,
                        "review",
                        " | ".join(work.authors),
                        annotation_evidence,
                        "The personal-name string occurs in the body, but the shared historical annotator had no usable authority index. Re-run after the authority data are available; do not turn the figure's audit grouping into taxonomy.",
                    )
                ]
            return [
                Action(
                    "person_mention_unconfirmed_review",
                    "mentions.people",
                    canonical,
                    "review",
                    " | ".join(work.authors),
                    annotation_evidence,
                    "The personal-name string occurs in the body, but the shared annotator did not confirm it under its temporal, ambiguity, and syntax rules. Keep this as a mention review instead of assuming authorship or subject taxonomy.",
                )
            ]

        if stats is not None:
            return [
                Action(
                    "author_role_review",
                    "authors",
                    canonical,
                    "review",
                    " | ".join(work.authors),
                    clean_text(stats.get("semantic")),
                    "This label has positive authorship evidence somewhere in the corpus, but this work has neither local authorship evidence nor a corroborated body mention.",
                )
            ]
        return [
            Action(
                "person_role_review",
                "authors / contributors / mentions.people",
                canonical,
                "review",
                " | ".join(work.authors + work.editors + work.contributors),
                "known personal identity; no positive authorship evidence and no body corroboration",
                "The source category names a person, but its role in this work is unresolved. Do not infer an intellectual/religious tradition solely from the identity.",
            )
        ]

    period_norm = normalize_name(normalizer, work.period) if work.period else ""
    polity_norm = normalize_name(normalizer, work.polity) if work.polity else ""
    macro_norm = normalize_name(normalizer, work.macro_region) if work.macro_region else ""
    region_norm = normalize_name(normalizer, work.region) if work.region else ""
    p_candidate = configured_period_candidate(canonical, indexes, normalizer, rules)
    polity_cand = polity_candidate(canonical, indexes["polities"])
    geo_field, geo_cand = geography_candidate(canonical, indexes)
    body_count = evidence.occurrences if evidence else 0
    hierarchy_norms = set(normalized_hierarchy_labels(work, normalizer))
    path_periods = set(hierarchy_period_candidates(work, indexes, normalizer, rules))
    work_range = work_absolute_year_range(work, work_date_categories, context=calendar_context) if p_candidate else None
    path_bounds = calendar_period_bounds(corpus_hierarchy_labels(work)) if p_candidate else None
    candidate_bounds = calendar_period_bounds(indexes["periods"].get(p_candidate, p_candidate)) if p_candidate else None
    candidate_date_conflict = bool(
        p_candidate and work_range and candidate_bounds and not ranges_overlap(work_range, candidate_bounds[:2])
    )
    path_date_conflict = bool(
        work_range and path_bounds and not ranges_overlap(work_range, path_bounds[:2])
    )

    period_phase_labels = set(rules.get("period_phase_labels") or [])
    source_periodisation = source_periodisation_for(work, rules)
    source_phases = set(source_periodisation.get("phase_labels") or []) if source_periodisation else set()
    source_unknowns = set(source_periodisation.get("unknown_phase_labels") or []) if source_periodisation else set()
    source_bases = set(source_periodisation.get("base_period_labels") or []) if source_periodisation else set()

    if source_periodisation and work.period and canonical in source_bases and canonical in period_norm:
        return [Action(
            "remove_source_period_base_category_redundant", "period", work.period, "safe", work.period,
            f"{clean_text(source_periodisation.get('name'))}: source base-period fragment is already represented in structured period",
            "Remove the source period component from taxonomy; keep the complete source periodisation in structured period metadata.",
        )]

    if source_periodisation and work.period:
        aliases = source_periodisation.get("base_period_aliases") or {}
        composed = re.fullmatch(r"(.+?)(早期|中期|晚期)", canonical)
        if composed:
            base, phase = composed.groups()
            base_norm = clean_text(aliases.get(base)) or base
            composed_norm = base_norm + phase
            period_segments = [segment for segment in re.split(r"或", period_norm) if segment]
            if composed_norm in period_segments or composed_norm == period_norm:
                return [Action(
                    "remove_source_period_composed_fragment_redundant", "period", work.period, "safe", work.period,
                    f"{clean_text(source_periodisation.get('name'))}: composed source-period fragment is one explicit segment of structured period",
                    "Keep the complete archaeological period assertion in structured metadata; the component label is not global taxonomy.",
                )]

        # ASDC-style cross-boundary labels can split a complete period across two
        # source categories. Example: 春秋 + 西周晚期或早期 represents the
        # structured value 西周晚期或春秋早期. Reconstruct only when it exactly
        # matches the existing structured period; otherwise leave it for review.
        cross = re.fullmatch(r"(.+?)(早期|中期|晚期)或(早期|中期|晚期)", canonical)
        if cross:
            first_base, first_phase, second_phase = cross.groups()
            companion_bases: list[str] = []
            for candidate_raw, _candidate_origin in unique_memberships(work):
                candidate, _ = canonical_label(normalizer, candidate_raw)
                if candidate in source_bases and candidate != first_base:
                    companion_bases.append(candidate)
            reconstructed = [
                first_base + first_phase + "或" + companion + second_phase
                for companion in dict.fromkeys(companion_bases)
            ]
            if period_norm in reconstructed:
                return [Action(
                    "remove_source_period_cross_boundary_fragment_redundant", "period", work.period, "safe", work.period,
                    f"{clean_text(source_periodisation.get('name'))}: source categories reconstruct {work.period}",
                    "This lossy source-category fragment is already preserved as the complete structured period; remove it from taxonomy.",
                )]
            if first_base in source_bases or companion_bases:
                return [Action(
                    "source_period_cross_boundary_review", "period", canonical, "review", work.period,
                    f"{clean_text(source_periodisation.get('name'))}: cross-boundary source-period fragment did not exactly reconstruct structured period",
                    "Treat this as source dating evidence, not subject taxonomy; review the complete source period before changing metadata.",
                )]

        reverse_cross = re.fullmatch(r"(早期|中期|晚期)或(.+?)(早期|中期|晚期)", canonical)
        if reverse_cross:
            first_phase, second_base, second_phase = reverse_cross.groups()
            aliases = source_periodisation.get("base_period_aliases") or {}
            companion_bases: list[str] = []
            for candidate_raw, _candidate_origin in unique_memberships(work):
                candidate, _ = canonical_label(normalizer, candidate_raw)
                if candidate in source_bases and candidate != second_base:
                    companion_bases.append(candidate)
            reconstructed = []
            for companion in dict.fromkeys(companion_bases):
                left = clean_text(aliases.get(companion)) or companion
                right = clean_text(aliases.get(second_base)) or second_base
                reconstructed.append(left + first_phase + "或" + right + second_phase)
            if period_norm in reconstructed:
                return [Action(
                    "remove_source_period_cross_boundary_fragment_redundant", "period", work.period, "safe", work.period,
                    f"{clean_text(source_periodisation.get('name'))}: source categories reconstruct {work.period}",
                    "This source-category fragment is already preserved as the complete structured period; remove it from taxonomy.",
                )]
            if second_base in source_bases or companion_bases:
                return [Action(
                    "source_period_cross_boundary_review", "period", canonical, "review", work.period,
                    f"{clean_text(source_periodisation.get('name'))}: reverse cross-boundary fragment did not exactly reconstruct structured period",
                    "Treat this as source dating evidence, not subject taxonomy; review the complete source period before changing metadata.",
                )]

    if canonical in period_phase_labels:
        if source_periodisation and (canonical in source_phases or canonical in source_unknowns):
            source_name = clean_text(source_periodisation.get("name")) or "source periodisation"
            if canonical in source_unknowns:
                if work.period:
                    return [Action(
                        "remove_source_period_unknown_phase", "period", work.period, "safe", work.period,
                        f"{source_name}: {canonical} means finer phase was not assigned",
                        "The broad period remains useful; this source-specific unknown-phase marker is not corpus taxonomy.",
                    )]
                return [Action(
                    "source_period_unknown_without_base_review", "period", canonical, "review", "",
                    f"{source_name}: unknown finer phase without structured base period",
                    "Recover the broad period first; do not keep 不詳 as a category.",
                )]
            if work.period:
                if canonical in period_norm:
                    return [Action(
                        "remove_source_period_phase_category_redundant", "period", work.period, "safe", work.period,
                        f"{source_name}: phase is already encoded in structured period",
                        "Preserve source-specific periodisation in the period field and remove the standalone phase category.",
                    )]
                other_phases = [phase for phase in source_phases if phase in period_norm]
                if not other_phases:
                    return [Action(
                        "promote_source_period_phase_metadata", "period", work.period + canonical, "high", work.period,
                        f"{source_name}: phase refines the existing base period",
                        "Preserve uncertain forms such as 早期或中期 exactly; they are meaningful source periodisation evidence.",
                    )]
                return [Action(
                    "source_period_phase_conflict_review", "period", canonical, "review", work.period,
                    f"{source_name}: phase conflicts with structured period",
                    "Review the source dating evidence before changing the period.",
                )]
            candidate_bases: list[str] = []
            for candidate_raw, _candidate_origin in unique_memberships(work):
                candidate, _ = canonical_label(normalizer, candidate_raw)
                if candidate == canonical or candidate in source_phases or candidate in source_unknowns:
                    continue
                if candidate in indexes["periods"]:
                    candidate_bases.append(candidate)
            candidate_bases = list(dict.fromkeys(candidate_bases))
            if len(candidate_bases) == 1:
                return [Action(
                    "promote_source_period_metadata", "period", candidate_bases[0] + canonical, "high", "",
                    f"{source_name}: one base-period category plus one phase category",
                    "Combine the source's base period and phase in structured period metadata.",
                )]
            return [Action(
                "source_period_phase_without_base_review", "period", canonical, "review", "",
                f"{source_name}: phase found but base period could not be resolved uniquely",
                "Keep the phase evidence for review; it cannot stand alone as a global category.",
            )]

        if canonical == "不詳":
            return [Action(
                "period_precision_review", "period / date precision", canonical, "review", work.period,
                "unresolved period precision outside a configured source periodisation",
                "Do not keep 不詳 as content taxonomy; determine which dating field/source it qualifies before removing it.",
            )]
        if work.period and canonical in period_norm:
            return [Action(
                "remove_period_phase_category_redundant", "period", work.period, "safe", work.period,
                "period phase is already encoded in structured period metadata",
                "Remove the standalone phase category; it is a fragment of the structured period value.",
            )]
        return [Action(
            "period_phase_review", "period", canonical, "review", work.period,
            "generic phase vocabulary outside a configured source periodisation",
            "Do not concatenate a generic 早期/中期/晚期 mechanically unless its base period and source dating scheme are known.",
        )]

    if canonical.endswith("作品") and len(canonical) > 2:
        prefix = canonical[:-2]
        prefix_period = configured_period_candidate(prefix, indexes, normalizer, rules)
        prefix_polity = polity_candidate(prefix, indexes["polities"])
        prefix_geo_field, prefix_geo = geography_candidate(prefix, indexes)
        if prefix_period or prefix_polity or prefix_geo_field:
            prefix_matches = (
                (prefix_period and (prefix_period == period_norm or prefix_period in path_periods))
                or (prefix_polity and (prefix_polity == polity_norm or prefix_polity in hierarchy_norms))
                or (prefix_geo_field == "macro_region" and prefix_geo == macro_norm)
                or (prefix_geo_field == "region" and prefix_geo == region_norm)
            )
            if prefix_matches:
                return [Action(
                    "remove_origin_work_category_redundant", "period / polity / macro_region / region", prefix, "safe",
                    " | ".join(value for value in (work.period, work.polity, work.macro_region, work.region) if value),
                    f"{prefix} + 作品 composite agrees with structured origin metadata",
                    "作品 adds no subject taxonomy; retain the origin in structured metadata.",
                )]
            if prefix_polity and not work.polity:
                return [Action(
                    "promote_polity_metadata", "polity", indexes["polities"].get(prefix_polity, prefix), "high", "",
                    f"{prefix} + 作品 composite",
                    "Move the polity out of the composite source category and remove 作品.",
                )]
            return [Action(
                "origin_work_category_review", "period / polity / macro_region / region / mentions", prefix, "review",
                " | ".join(value for value in (work.period, work.polity, work.macro_region, work.region) if value),
                f"{prefix} + 作品 composite does not agree with structured origin metadata",
                "Review whether the prefix identifies origin or a mentioned polity/region; 作品 itself is not a useful category.",
            )]


    redundant_fields: list[str] = []
    path_redundancy = False
    if p_candidate and (p_candidate == period_norm or p_candidate in path_periods):
        redundant_fields.append("period")
        path_redundancy = path_redundancy or p_candidate in path_periods
    if polity_cand and (polity_cand == polity_norm or polity_cand in hierarchy_norms):
        redundant_fields.append("polity")
        path_redundancy = path_redundancy or polity_cand in hierarchy_norms
    if geo_field == "macro_region" and geo_cand and (geo_cand == macro_norm or geo_cand in hierarchy_norms):
        redundant_fields.append("macro_region")
        path_redundancy = path_redundancy or geo_cand in hierarchy_norms
    if geo_field == "region" and geo_cand and (geo_cand == region_norm or geo_cand in hierarchy_norms):
        redundant_fields.append("region")
        path_redundancy = path_redundancy or geo_cand in hierarchy_norms
    if redundant_fields:
        evidence_text = "category agrees with structured metadata"
        note = "Remove the redundant category after confirming the structured field is authoritative."
        if path_redundancy:
            evidence_text += "; canonical corpus hierarchy also contains this classification"
            note = "The curated corpus hierarchy already carries this broader/same classification; remove the duplicated Wikisource category without changing the work's placement."
        return [
            Action(
                "remove_geography_period_category_redundant",
                "; ".join(redundant_fields),
                " | ".join(
                    value for value in (work.period, work.polity, work.macro_region, work.region) if value
                ),
                "safe",
                " | ".join(redundant_fields),
                evidence_text,
                note,
            )
        ]

    if p_candidate and candidate_date_conflict:
        return [Action(
            "period_category_date_conflict_review",
            "period / date",
            indexes["periods"].get(p_candidate, canonical),
            "review",
            work.period,
            f"firm work chronology {work_range[0]}..{work_range[1]} does not overlap candidate period bounds {candidate_bounds[0]}..{candidate_bounds[1]}",
            "The normalized date contradicts this source period category. Do not populate period metadata or move the work from this category automatically.",
        )]

    if p_candidate and path_date_conflict and candidate_bounds and work_range and ranges_overlap(work_range, candidate_bounds[:2]):
        return [Action(
            "period_path_date_conflict_review",
            "period / corpus path / date",
            indexes["periods"].get(p_candidate, canonical),
            "review",
            work.period,
            f"firm work chronology {work_range[0]}..{work_range[1]} fits candidate {candidate_bounds[0]}..{candidate_bounds[1]} but conflicts with canonical path bounds {path_bounds[0]}..{path_bounds[1]}",
            "This is a strong candidate for one of the genuinely misfiled works. Keep it in review; the planner must never move a directory from source-category evidence alone.",
        )]

    if p_candidate and not work.period:
        if path_periods:
            return [Action(
                "period_category_path_conflict_review",
                "period / corpus path",
                indexes["periods"][p_candidate],
                "review",
                " / ".join(corpus_hierarchy_labels(work)),
                f"source category proposes {indexes['periods'][p_candidate]}, but canonical path already encodes period(s) {', '.join(path_periods)}",
                "Do not fill missing period metadata from a conflicting Wikisource category. The folder hierarchy remains authoritative unless independent chronology supports a correction.",
            )]
        return [
            Action(
                "promote_period_metadata",
                "period",
                indexes["periods"][p_candidate],
                "high",
                "",
                "category matches a period value already used elsewhere in the corpus",
                "Populate period metadata and remove the period category.",
            )
        ]
    if polity_cand and not work.polity:
        return [
            Action(
                "promote_polity_metadata",
                "polity",
                indexes["polities"][polity_cand],
                "high",
                "",
                "category matches a polity value already used elsewhere in the corpus",
                "Populate polity metadata and remove the polity category.",
            )
        ]
    if geo_field and geo_cand:
        existing_geo = {"macro_region": work.macro_region, "polity": work.polity, "region": work.region}.get(geo_field, "")
        if not existing_geo:
            index_name = {"macro_region": "macro_regions", "polity": "polities", "region": "regions"}.get(geo_field, "")
            source_dict = indexes.get(index_name, {})
            proposed = source_dict.get(geo_cand, geo_cand) if isinstance(source_dict, dict) else geo_cand
            return [
                Action(
                    "promote_geographic_metadata",
                    geo_field,
                    proposed,
                    "high",
                    "",
                    "category matches a geographic value already used elsewhere in the corpus",
                    "Populate geographic metadata and remove the geographic category.",
                )
            ]

    if (p_candidate or polity_cand or geo_field) and body_count > 0:
        mention_value = polity_cand or p_candidate or geo_cand or canonical
        target = "mentions.polities" if polity_cand or geo_field else "mentions.periods"
        caution = ""
        if work.is_compilation and evidence and len(evidence.documents) < len(work.documents):
            caution = " Evidence occurs in only part of this compilation."
        return [
            Action(
                "promote_polity_period_mention",
                target,
                mention_value,
                "high" if not work.is_compilation else "review",
                " | ".join(value for value in (work.period, work.polity, work.macro_region, work.region) if value),
                f"exact body occurrences: {body_count}",
                "The category conflicts with the work's own origin metadata but is explicitly present in the body." + caution,
            )
        ]
    if p_candidate or polity_cand or geo_field:
        return [
            Action(
                "geography_period_conflict_review",
                "period / polity / macro_region / region / mentions",
                canonical,
                "review",
                " | ".join(value for value in (work.period, work.polity, work.macro_region, work.region) if value),
                "known structured-metadata vocabulary but no exact body corroboration",
                "Review whether the category describes origin, historical subject matter, or stale source taxonomy.",
            )
        ]

    if canonical == "典籍":
        return [
            Action(
                "delete_generic_text_category",
                "categories/source_categories",
                "",
                "safe",
                canonical,
                "generic 典籍 category",
                "Every corpus item is already a text/work; bare 典籍 carries no useful distinction here.",
            )
        ]
    if canonical.endswith("典籍"):
        base = canonical[:-2]
        if base in tradition_labels:
            return [
                Action(
                    "normalize_religion_text_category",
                    "categories",
                    base,
                    "high",
                    canonical,
                    "宗教 + 典籍 composite",
                    "The 典籍 suffix is redundant; retain the meaningful tradition category.",
                )
            ]
        base_geo_field, base_geo = geography_candidate(base, indexes)
        base_polity = polity_candidate(base, indexes["polities"])
        if base_geo_field or base_polity:
            candidate = base_polity or base_geo
            existing_geo = {"macro_region": work.macro_region, "polity": work.polity, "region": work.region}.get(base_geo_field or "polity", "")
            existing_norm = normalize_name(normalizer, existing_geo) if existing_geo else ""
            if candidate and candidate == existing_norm:
                return [Action(
                    "remove_geographic_text_category_redundant",
                    base_geo_field or "polity",
                    existing_geo,
                    "safe",
                    canonical,
                    f"{base} + 典籍 agrees with structured origin metadata",
                    "The geographic component is already structured and 典籍 adds no useful distinction.",
                )]
            if candidate and not existing_geo:
                return [Action(
                    "promote_geographic_metadata_from_text_category",
                    base_geo_field or "polity",
                    candidate,
                    "high",
                    "",
                    f"{base} + 典籍 composite",
                    "Move the geographic component into structured metadata and discard the redundant 典籍 wrapper.",
                )]
            return [Action(
                "geographic_text_category_review",
                "period / polity / macro_region / region",
                base,
                "review",
                existing_geo,
                f"{base} + 典籍 composite does not cleanly agree with structured origin metadata",
                "Review the origin field; bare 典籍 should not survive as taxonomy.",
            )]

    if canonical in semantic_map:
        target = semantic_map[canonical]
        values = target if isinstance(target, list) else [target]
        values = [clean_text(value) for value in values if clean_text(value)]
        return [
            Action(
                "split_category" if len(values) > 1 else "normalize_category",
                "categories",
                " | ".join(values),
                "high",
                canonical,
                "configured semantic normalization",
                "Normalize synonymous/generic category wording while preserving meaningful subtypes.",
            )
        ]

    prefixed_taxonomy = period_prefixed_taxonomy(canonical, indexes, normalizer, rules)
    if prefixed_taxonomy is not None:
        prefix, target_period, taxonomy_leaf = prefixed_taxonomy
        existing_period = normalize_name(normalizer, work.period) if work.period else ""
        display_period = indexes["periods"].get(target_period, target_period)
        if existing_period == target_period:
            return [Action(
                "split_period_from_taxonomy",
                "categories",
                taxonomy_leaf,
                "high",
                canonical,
                f"period prefix {prefix} agrees with structured period {work.period}",
                "Keep the semantic category leaf and remove the period prefix because chronology is already structured.",
            )]
        if not work.period:
            return [Action(
                "promote_period_and_split_taxonomy",
                "period + categories",
                f"period={display_period}; category={taxonomy_leaf}",
                "high",
                canonical,
                f"configured period prefix {prefix} + controlled taxonomy leaf {taxonomy_leaf}",
                "Populate period metadata and retain only the semantic taxonomy leaf.",
            )]
        return [Action(
            "period_prefixed_taxonomy_conflict_review",
            "period + categories",
            f"period={display_period}; category={taxonomy_leaf}",
            "review",
            f"period={work.period}; category={canonical}",
            f"category period prefix {prefix} conflicts with structured period",
            "Review chronology before splitting the composite source category.",
        )]

    han_form_targets = {"漢詩": "漢詩", "漢詞": "詞"}
    for surface_form, target_form in han_form_targets.items():
        if canonical.endswith(surface_form) and canonical != surface_form:
            prefix = canonical[: -len(surface_form)]
            geo_field2, geo_cand2 = geography_candidate(prefix, indexes)
            if geo_field2:
                return [
                    Action(
                        "split_geography_from_han_literary_form",
                        "categories + " + geo_field2,
                        target_form,
                        "high" if prefix in {macro_norm, polity_norm, region_norm} else "review",
                        " | ".join(value for value in (work.macro_region, work.polity, work.region) if value),
                        f"geographic prefix {prefix} + {surface_form}",
                        f"Keep {target_form} as the cross-regional literary category and leave geography to structured metadata.",
                    )
                ]

    if canonical.endswith("詩") and canonical not in {"詩", "漢詩"}:
        prefix = canonical[:-1]
        prefix_polity = polity_candidate(prefix, indexes["polities"])
        prefix_period = configured_period_candidate(prefix + "朝", indexes, normalizer, rules) if prefix + "朝" in indexes["periods"] else configured_period_candidate(prefix, indexes, normalizer, rules)
        if prefix_polity or prefix_period:
            origin_match = (prefix_polity and prefix_polity == polity_norm) or (prefix_period and prefix_period == period_norm)
            return [
                Action(
                    "split_period_from_poetry",
                    "categories + period/polity",
                    "漢詩",
                    "high" if origin_match else "review",
                    " | ".join(value for value in (work.period, work.polity) if value),
                    f"period/polity prefix {prefix} + 詩",
                    "The literary leaf is 漢詩; period/polity belongs in structured metadata. More specific poem-form categories should be retained separately when present.",
                )
            ]

    if canonical.endswith("詞") and canonical not in {"詞", "青詞", "頌詞", "題詞", "賀詞"}:
        prefix = canonical[:-1]
        prefix_polity = polity_candidate(prefix, indexes["polities"])
        prefix_period = configured_period_candidate(prefix + "朝", indexes, normalizer, rules) if prefix + "朝" in indexes["periods"] else configured_period_candidate(prefix, indexes, normalizer, rules)
        if prefix_polity or prefix_period:
            origin_match = (prefix_polity and prefix_polity == polity_norm) or (prefix_period and prefix_period == period_norm)
            return [
                Action(
                    "split_period_from_ci",
                    "categories + period/polity",
                    "詞",
                    "high" if origin_match else "review",
                    " | ".join(value for value in (work.period, work.polity) if value),
                    f"period/polity prefix {prefix} + 詞",
                    "Keep 詞 as the literary category and place period/polity in structured metadata. More specific 詞牌/form metadata remains separate.",
                )
            ]

    taxonomy_pattern = taxonomy_pattern_match(canonical, rules)
    if taxonomy_pattern is not None and canonical == strip_namespace(raw):
        return [Action(
            "keep_pattern_taxonomy",
            "categories",
            canonical,
            "safe",
            canonical,
            clean_text(taxonomy_pattern.get("name")) or "configured taxonomy pattern",
            clean_text(taxonomy_pattern.get("note")) or "This is a meaningful patterned browse/search category.",
        )]

    if canonical in controlled_taxonomy and canonical == strip_namespace(raw):
        return [Action(
            "keep_controlled_taxonomy",
            "categories",
            canonical,
            "safe",
            canonical,
            "configured controlled taxonomy / ontology node",
            "This is a meaningful browse/search category. Keep the leaf category; parent relationships are inherited through the taxonomy graph.",
        )]

    path_text = work.metadata_path.as_posix()
    scope_parts = [path_text, semantic_path_text(work.metadata_path), work.title, work.work_base_title, *work.sources]
    for identifier in work.identifiers:
        scope_parts.extend((clean_text(identifier.get("scheme")), clean_text(identifier.get("value"))))
    work_scope_text = "\n".join(value for value in scope_parts if value)
    for scoped in scoped_rules:
        if not isinstance(scoped, dict):
            continue
        pattern = clean_text(scoped.get("pattern"))
        if not pattern or not re.search(pattern, canonical):
            continue
        scope_pattern = clean_text(scoped.get("work_scope_pattern"))
        in_scope = bool(re.search(scope_pattern, work_scope_text)) if scope_pattern else True
        if in_scope:
            return [Action(
                "keep_scoped_category",
                "categories",
                canonical,
                "safe",
                canonical,
                clean_text(scoped.get("name")),
                clean_text(scoped.get("note")),
            )]
        if bool(scoped.get("review_outside_scope", True)):
            return [Action(
                "scoped_category_review",
                "categories",
                canonical,
                "review",
                canonical,
                clean_text(scoped.get("name")),
                clean_text(scoped.get("note")),
            )]

    if unresolved_chars:
        return [
            Action(
                "traditionalization_review",
                "categories/source_categories",
                canonical,
                "review",
                strip_namespace(raw),
                "ambiguous Simplified/Traditional character mapping: " + "、".join(unresolved_chars),
                "Resolve the ambiguous graph in context before the category is accepted into the Traditional-Chinese taxonomy.",
            )
        ]

    if canonical != strip_namespace(raw):
        note = "Normalize category text to Traditional Chinese."
        confidence = "high"
        if unresolved_chars:
            confidence = "review"
            note += " Ambiguous conversion character(s) left unchanged: " + "、".join(unresolved_chars)
        return [
            Action(
                "normalize_category_traditional",
                "categories/source_categories",
                canonical,
                confidence,
                strip_namespace(raw),
                "conservative Traditional-Chinese normalization",
                note,
            )
        ]

    if raw != strip_namespace(raw):
        return [
            Action(
                "remove_category_namespace",
                "categories/source_categories",
                canonical,
                "high",
                raw,
                "MediaWiki namespace leaked into category text",
                "Keep the useful label but remove the 分類:/Category: namespace prefix.",
            )
        ]

    return [
        Action(
            "keep_or_review_taxonomy",
            "categories",
            canonical,
            "review",
            canonical,
            "no metadata migration rule matched",
            "This is part of the residual category taxonomy that deserves human review.",
        )
    ]


def plan_title_cleanup(
    works: Sequence[Work], normalizer: Traditionalizer, indexes: dict, rules: dict
) -> list[TitleAction]:
    rows: list[TitleAction] = []
    for work in works:
        calendar_context = calendar_context_for_work(work)
        proposed_title, suffixes = split_trailing_parentheticals(work.title)
        if not suffixes or not proposed_title:
            continue
        authors, other_people = work_people(work, normalizer)
        edition_labels = existing_edition_labels(work, normalizer)
        category_labels = {canonical_label(normalizer, raw)[0] for raw, _origin in unique_memberships(work)}

        for suffix in suffixes:
            canonical, unresolved = canonical_label(normalizer, suffix)
            date_cat = parse_date_category(canonical, context=calendar_context)
            if date_cat is not None and not date_cat.is_mention:
                existing_source = work.date_label or work.date
                existing = parse_existing_date_label(existing_source, context=calendar_context) if existing_source else None
                path_bounds = calendar_period_bounds(corpus_hierarchy_labels(work))
                if path_bounds and not ranges_overlap((date_cat.year, date_cat.year), path_bounds[:2]):
                    action = Action(
                        "title_date_path_period_conflict_review", "title + date_label + period / corpus path", date_cat.source_label, "review", existing_source or work.period,
                        f"trailing date resolves to {date_cat.year}, outside canonical path period bounds {path_bounds[0]}..{path_bounds[1]} ({'/'.join(path_bounds[2])})",
                        "Do not let a source-added title date silently change chronology or placement. Review whether the date is wrong or the work is genuinely misfiled.",
                    )
                elif existing and date_compatible(date_cat, existing):
                    action = Action(
                        "strip_title_date_suffix_redundant", "title + date_label", date_cat.source_label, "safe", existing_source,
                        f"trailing parenthetical date agrees with structured date metadata; absolute equivalent {date_cat.label}",
                        "Strip the source-added date suffix from the title; the date is already structured.",
                    )
                elif not existing_source:
                    action = Action(
                        "strip_title_date_suffix_promote", "title + date_label", date_cat.source_label, "high", "",
                        f"trailing parenthetical is a deterministic calendar date; absolute equivalent {date_cat.label}",
                        "Strip the suffix from the title, preserve the historical date expression in date_label, and let the shared CalendarEngine/HistoricalDateResolver path derive the absolute year.",
                    )
                else:
                    action = Action(
                        "title_date_suffix_conflict_review", "title + date_label", date_cat.source_label, "review", existing_source,
                        "trailing parenthetical date conflicts with structured date metadata",
                        "Review the dating evidence before stripping the suffix or changing the date field.",
                    )
                rows.append(TitleAction(work, work.title, proposed_title, suffix, action))
                continue

            dated_qualifier = leading_date_in_suffix(canonical, context=calendar_context)
            if dated_qualifier is not None:
                prefix_date, qualifier = dated_qualifier
                if qualifier:
                    rows.append(TitleAction(work, work.title, proposed_title, suffix, Action(
                        "title_date_qualifier_suffix_review", "title + date_label + source/contributor metadata",
                        f"date_label={prefix_date.source_label}; qualifier={qualifier}", "review", work.date_label,
                        f"trailing parenthetical begins with a resolvable date ({prefix_date.label}) and then adds a qualifier",
                        "Strip the whole source-added suffix from the clean title, promote the date through the shared CalendarEngine/HistoricalDateResolver path, and classify the remaining institution/document qualifier separately.",
                    )))
                    continue

            if looks_like_unmapped_era_year(canonical):
                rows.append(TitleAction(work, work.title, proposed_title, suffix, Action(
                    "title_era_year_suffix_review", "title + date_label", canonical, "review", work.date_label,
                    "trailing parenthetical is an era/regnal-year expression",
                    "Resolve it with HistoricalDateResolver, then strip it from the source-added title suffix.",
                )))
                continue

            if looks_like_edition_suffix(canonical):
                if canonical in edition_labels:
                    action = Action(
                        "strip_title_edition_suffix_redundant", "title + editions.edition_label", canonical, "safe", canonical,
                        "trailing parenthetical already matches a structured edition label",
                        "Strip the edition label from the title; edition identity is already structured.",
                    )
                else:
                    action = Action(
                        "strip_title_edition_suffix_promote", "title + editions.edition_label", canonical, "high", "",
                        "trailing parenthetical has an edition/witness form ending in 本 or 版",
                        "Strip it from the work title and preserve it as edition metadata.",
                    )
                rows.append(TitleAction(work, work.title, proposed_title, suffix, action))
                continue

            # Prefer a known full personal name before interpreting the last graph as a
            # contributor-role marker: 馮著 is a personal name, while 白延譯 is a
            # role-marked credit.
            if canonical in indexes["people"]:
                if canonical in authors:
                    action = Action(
                        "strip_title_author_suffix_redundant", "title + authors", canonical, "safe", " | ".join(work.authors + work.document_authors),
                        "trailing parenthetical personal name matches structured author",
                        "Strip the source-added author disambiguator from the title.",
                    )
                elif canonical in other_people:
                    action = Action(
                        "strip_title_person_role_suffix_redundant", "title + editors/contributors", canonical, "safe", " | ".join(work.editors + work.contributors),
                        "trailing parenthetical personal name already has a structured non-author role",
                        "Strip the source-added person disambiguator from the title.",
                    )
                elif not authors:
                    action = Action(
                        "strip_title_author_suffix_promote", "title + authors", canonical, "high", "",
                        "trailing parenthetical is a known/inferred personal name and no author is structured",
                        "Treat the bracketed name as source-added authorship metadata; strip it from the title and populate authors.",
                    )
                else:
                    action = Action(
                        "title_person_suffix_conflict_review", "title + authors/contributors", canonical, "review", " | ".join(work.authors),
                        "trailing parenthetical personal name differs from existing authorship",
                        "Determine the person's role before stripping the suffix; it may be an editor, translator, commentator, or mentioned person.",
                    )
                rows.append(TitleAction(work, work.title, proposed_title, suffix, action))
                continue

            role_match = split_contributor_role_suffix(canonical)
            if role_match is not None:
                name, role = role_match
                target = "authors" if role == "author" else "contributors"
                rows.append(TitleAction(work, work.title, proposed_title, suffix, Action(
                    "strip_title_contributor_suffix_promote", f"title + {target}", f"{name}; role={role}", "high", "",
                    "trailing parenthetical explicitly includes a contributor-role marker",
                    "Strip the source-added credit from the title and preserve both the contributor and intellectual role in metadata.",
                )))
                continue

            if canonical in category_labels and looks_like_person_label(canonical):
                rows.append(TitleAction(work, work.title, proposed_title, suffix, Action(
                    "title_person_suffix_review", "title + authors/contributors", canonical, "review", " | ".join(work.authors),
                    "trailing parenthetical matches a category and looks name-like, but has insufficient person evidence",
                    "Strip the source-added disambiguator only after confirming whether it is a person, role label, edition, or topical qualifier.",
                )))
                continue

            if re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{5,}", suffix):
                rows.append(TitleAction(work, work.title, proposed_title, suffix, Action(
                    "strip_title_identifier_suffix_promote", "title + identifiers", suffix, "high", "",
                    "trailing parenthetical has identifier-like syntax",
                    "Strip the identifier from the title and preserve it as structured source identifier metadata after scheme review.",
                )))
                continue

            note = "The brackets appear to be source-added disambiguation, but the suffix type is not yet resolved. Preserve its value while deciding the proper metadata field."
            if unresolved:
                note += " Traditionalisation also needs review for: " + "、".join(unresolved)
            rows.append(TitleAction(work, work.title, proposed_title, suffix, Action(
                "title_parenthetical_metadata_review", "title + appropriate metadata field", canonical, "review", "",
                "trailing parenthetical suffix is outside the proposed clean title", note,
            )))
    return rows


def title_action_row(item: TitleAction) -> tuple[object, ...]:
    work = item.work
    return (
        item.action.confidence, item.action.action, item.current_title, item.proposed_title, item.suffix,
        item.action.target_field, item.action.proposed_value, item.action.existing_value, item.action.evidence, item.action.note,
        int(work.work_id) if work.work_id.isdigit() else work.work_id, work.date_label or work.date, work.period, work.polity,
        work.macro_region, work.region, work.metadata_path.as_posix(),
    )


def action_row(item: MembershipAction) -> tuple[object, ...]:
    work = item.work
    return (
        item.action.confidence,
        item.action.action,
        item.action.target_field,
        item.action.proposed_value,
        item.raw_category,
        item.canonical_category,
        item.origin,
        int(work.work_id) if work.work_id.isdigit() else work.work_id,
        work.title,
        work.date_label or work.date,
        work.period,
        work.polity,
        work.macro_region,
        work.region,
        work.medium,
        work.object_type,
        compact_json(work.material),
        work.is_compilation,
        len(work.documents),
        item.body_occurrences,
        item.body_documents,
        item.body_coverage,
        item.action.existing_value,
        item.action.evidence,
        item.action.note,
        work.metadata_path.as_posix(),
    )


def make_sheet(name: str, rows: list[tuple[object, ...]]) -> SheetSpec:
    headers = (
        "Confidence",
        "Action",
        "Target metadata field",
        "Proposed value",
        "Raw category",
        "Traditional/canonical label",
        "Origin",
        "Work ID",
        "Title",
        "Date",
        "Period",
        "Polity",
        "Macro region",
        "Region",
        "Medium",
        "Object type",
        "Material detail",
        "Is compilation",
        "Listed documents",
        "Body occurrences",
        "Matching documents",
        "Document coverage",
        "Existing value",
        "Evidence",
        "Notes",
        "Metadata path",
    )
    return SheetSpec(
        name=name,
        headers=headers,
        rows=rows,
        row_count=len(rows),
        widths=(12, 34, 30, 48, 36, 36, 16, 12, 40, 18, 20, 18, 18, 18, 20, 18, 48, 14, 16, 18, 18, 18, 46, 58, 78, 78),
        wrap_columns=frozenset({1, 2, 3, 4, 5, 8, 16, 22, 23, 24, 25}),
    )


def build_sheets(
    works: Sequence[Work],
    normalizer: Traditionalizer,
    indexes: dict,
    rules: dict,
    semantics: dict[str, dict[str, float | int | str]],
    evidence: dict[tuple[Path, str], Evidence],
    preamble_evidence: dict[tuple[Path, str], PreamblePersonEvidence],
    issues: Sequence[tuple[str, str]],
    scanned_documents: int,
    preamble_documents_scanned: int,
    generated_at: str,
    include_master_actions: bool,
) -> tuple[list[SheetSpec], list[MembershipAction], list[TitleAction]]:
    all_actions: list[MembershipAction] = []
    title_actions = plan_title_cleanup(works, normalizer, indexes, rules)
    category_counts: collections.Counter[str] = collections.Counter()
    category_origin_counts: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)

    for work in works:
        calendar_context = calendar_context_for_work(work)
        for material_action in material_profile_actions(work, normalizer, rules):
            all_actions.append(
                MembershipAction(
                    raw_category="",
                    canonical_category="",
                    origin="derived:material metadata",
                    work=work,
                    action=material_action,
                )
            )
        memberships = unique_memberships(work)
        existing_categories = {canonical_label(normalizer, raw)[0] for raw, _origin in memberships}
        shijing_genre, shijing_evidence = shijing_genre_for_work(work, rules)
        if shijing_genre and shijing_genre not in existing_categories:
            all_actions.append(
                MembershipAction(
                    raw_category="",
                    canonical_category=shijing_genre,
                    origin="derived:詩經 structure",
                    work=work,
                    action=Action(
                        "promote_shijing_genre_category",
                        "categories",
                        shijing_genre,
                        "high",
                        "",
                        f"existing 詩經 structure: {shijing_evidence}",
                        "Add only the broad ancient literary genre category 風、雅、 or 頌. The received 詩經 hierarchy itself stays in the existing corpus organisation.",
                    ),
                )
            )
        date_categories: list[DateCategory] = []
        for raw, _origin in memberships:
            canonical, _unresolved = canonical_label(normalizer, raw)
            parsed = parse_date_category(canonical, context=calendar_context)
            if parsed is not None:
                date_categories.append(parsed)
        for raw, origin in memberships:
            canonical, unresolved = canonical_label(normalizer, raw)
            category_counts[canonical] += 1
            category_origin_counts[canonical][origin] += 1
            ev = evidence.get((work.metadata_path, canonical))
            preamble_ev = preamble_evidence.get((work.metadata_path, canonical))
            actions = classify_membership(
                work,
                raw,
                origin,
                canonical,
                unresolved,
                normalizer,
                indexes,
                rules,
                semantics,
                ev,
                preamble_ev,
                date_categories,
            )
            for action in actions:
                body_docs = len(ev.documents) if ev else 0
                coverage = body_docs / len(work.documents) if ev and work.documents else 0.0
                all_actions.append(
                    MembershipAction(
                        raw_category=raw,
                        canonical_category=canonical,
                        origin=origin,
                        work=work,
                        action=action,
                        body_occurrences=ev.occurrences if ev else 0,
                        body_documents=body_docs,
                        body_coverage=coverage,
                    )
                )

    confidence_order = {"safe": 0, "high": 1, "review": 2}
    all_actions.sort(
        key=lambda item: (
            confidence_order.get(item.action.confidence, 9),
            item.action.action,
            item.canonical_category,
            item.work.date_label,
            item.work.title,
        )
    )

    action_counts = collections.Counter(item.action.action for item in all_actions)
    confidence_counts = collections.Counter(item.action.confidence for item in all_actions)
    residual = sum(1 for item in all_actions if item.action.action == "keep_or_review_taxonomy")
    overview = [
        ("Generated UTC", generated_at),
        ("Works scanned", len(works)),
        ("Category-work memberships planned", len(all_actions)),
        ("Trailing title suffixes planned", len(title_actions)),
        ("Titles with source-added trailing parentheses", len({item.work.metadata_path for item in title_actions})),
        ("Safe actions", confidence_counts.get("safe", 0)),
        ("High-confidence actions", confidence_counts.get("high", 0)),
        ("Human-review actions", confidence_counts.get("review", 0)),
        ("Residual taxonomy memberships", residual),
        ("Known/inferred people from metadata, figure lexicon, and title signals", len(indexes["people"])),
        ("Known periods", len(indexes["periods"])),
        ("Known polities", len(indexes["polities"])),
        ("Compilation titles/aliases indexed", len(indexes["titles"])),
        ("Body documents scanned for migration evidence", scanned_documents),
        ("Document preambles scanned for contributor-role evidence", preamble_documents_scanned),
        ("Traditional map loaded", normalizer.loaded),
        ("Traditional map", str(normalizer.mapping_path) if normalizer.mapping_path else ""),
        ("Audit issues", len(issues)),
        ("Safety", "PLAN ONLY: this script never writes metadata.json"),
    ]
    sheets: list[SheetSpec] = [
        SheetSpec("Overview", ("Metric", "Value"), overview, len(overview), widths=(48, 90), wrap_columns=frozenset({1}))
    ]

    summary_rows = [
        (action, count, sum(1 for item in all_actions if item.action.action == action and item.action.confidence == "safe"),
         sum(1 for item in all_actions if item.action.action == action and item.action.confidence == "high"),
         sum(1 for item in all_actions if item.action.action == action and item.action.confidence == "review"))
        for action, count in action_counts.most_common()
    ]
    sheets.append(
        SheetSpec(
            "Action Summary",
            ("Action", "Rows", "Safe", "High", "Review"),
            summary_rows,
            len(summary_rows),
            widths=(42, 14, 14, 14, 14),
            wrap_columns=frozenset({0}),
        )
    )

    title_rows = [title_action_row(item) for item in title_actions]
    sheets.append(
        SheetSpec(
            "Title Cleanup",
            ("Confidence", "Action", "Current title", "Proposed clean title", "Extracted suffix", "Target metadata field",
             "Proposed metadata value", "Existing value", "Evidence", "Notes", "Work ID", "Date", "Period", "Polity",
             "Macro region", "Region", "Metadata path"),
            title_rows,
            len(title_rows),
            widths=(12, 38, 56, 48, 44, 34, 52, 38, 62, 86, 12, 20, 24, 20, 20, 20, 90),
            wrap_columns=frozenset({1,2,3,4,5,6,7,8,9,16}),
        )
    )

    if include_master_actions:
        rows_all = [action_row(item) for item in all_actions]
        sheets.append(make_sheet("Migration Actions", rows_all))

    def subset(name: str, predicate) -> None:
        rows = [action_row(item) for item in all_actions if predicate(item)]
        sheets.append(make_sheet(name, rows))

    subset("Safe Removals", lambda item: item.action.confidence == "safe" and (item.action.action.startswith("remove_") or item.action.action.startswith("delete_")))
    subset("Taxonomy Keeps", lambda item: item.action.confidence == "safe" and item.action.action.startswith("keep_"))
    subset(
        "Metadata Promotions",
        lambda item: item.action.action.startswith("promote_")
        and "mention" not in item.action.action
        and not any(token in item.action.action for token in ("compilation", "collection", "book_grouping", "serial_publication")),
    )
    subset("Mention Promotions", lambda item: "mention" in item.action.action and item.action.confidence != "review")
    subset("Person Mention Review", is_person_mention_review_action)
    subset("Conflicts Review", lambda item: "conflict" in item.action.action or item.action.action.endswith("_review"))
    subset("People Review", is_people_review_action)
    subset("Date Review", is_date_review_action)
    subset("Period Polity Review", is_period_polity_review_action)
    subset("Source Periodisation", lambda item: "source_period" in item.action.action)
    subset("Compilation Review", lambda item: "compilation" in item.action.action and item.action.confidence == "review")
    subset("Collection Structure", lambda item: "collection_" in item.action.action or "collection hierarchy" in item.action.target_field)
    subset("Book Grouping Promotions", lambda item: "book_grouping" in item.action.action)
    subset("Publication Membership", lambda item: "serial_publication" in item.action.action or "publication system" in item.action.target_field)

    compilation_groups: dict[tuple[str, str, str], dict[str, object]] = {}
    for item in all_actions:
        if not item.action.action.startswith("promote_compilation_membership"):
            continue
        parts = compilation_parts(item.canonical_category)
        if parts is not None:
            base, edition, volume = parts
        else:
            base, edition, volume = item.canonical_category, "", ""
        key = (base, edition, item.action.action)
        row = compilation_groups.setdefault(
            key, {"count": 0, "volumes": set(), "examples": [], "evidence": set()}
        )
        row["count"] = int(row["count"]) + 1
        if volume:
            row["volumes"].add(volume)
        if len(row["examples"]) < 4:
            row["examples"].append(item.work.title)
        if item.action.evidence:
            row["evidence"].add(item.action.evidence)
    compilation_summary_rows = []
    for (base, edition, action), row in sorted(
        compilation_groups.items(), key=lambda pair: (-int(pair[1]["count"]), pair[0][0], pair[0][1])
    ):
        volumes = sorted(row["volumes"])
        volume_display = " | ".join(volumes[:24])
        if len(volumes) > 24:
            volume_display += f" | … (+{len(volumes) - 24})"
        compilation_summary_rows.append((
            base, edition, action, int(row["count"]), len(volumes), volume_display,
            " | ".join(sorted(row["evidence"])[:4]), " | ".join(row["examples"]),
        ))
    sheets.append(
        SheetSpec(
            "Compilation Promotions",
            ("Compilation", "Edition", "Action", "Memberships", "Distinct volumes", "Volumes", "Parent-resolution evidence", "Example members"),
            compilation_summary_rows,
            len(compilation_summary_rows),
            widths=(42, 34, 46, 14, 16, 72, 80, 90),
            wrap_columns=frozenset({0, 1, 2, 5, 6, 7}),
        )
    )
    subset("Material Review", lambda item: any(token in item.action.action for token in ("material", "oracle_bone", "epigraphic_medium", "slip_material", "digital_medium", "species_")))
    subset("Species Normalisation", lambda item: "species_" in item.action.action)
    subset("Oracle Bone Review", lambda item: item.action.action == "oracle_bone_material_review")
    subset(
        "Category Normalisation",
        lambda item: item.action.action != "normalize_category_traditional"
        and any(token in item.action.action for token in ("normalize_category", "split_category", "split_geography", "split_period", "normalize_religion")),
    )

    traditional_groups: dict[tuple[str, str, str, str, str], dict[str, object]] = {}
    for item in all_actions:
        if "traditionalization" not in item.action.action and item.action.action != "normalize_category_traditional":
            continue
        key = (
            item.raw_category,
            item.canonical_category,
            item.action.action,
            item.action.confidence,
            item.action.proposed_value,
        )
        row = traditional_groups.setdefault(
            key, {"count": 0, "origins": set(), "examples": []}
        )
        row["count"] = int(row["count"]) + 1
        row["origins"].add(item.origin)
        if len(row["examples"]) < 3:
            row["examples"].append(item.work.title)
    traditional_rows = []
    for key, row in sorted(traditional_groups.items(), key=lambda pair: (-int(pair[1]["count"]), pair[0][0])):
        raw, canonical, action, confidence, proposed = key
        traditional_rows.append((raw, canonical, action, confidence, proposed, int(row["count"]), " | ".join(sorted(row["origins"])), " | ".join(row["examples"])))
    sheets.append(
        SheetSpec(
            "Traditionalization Review",
            ("Raw category", "Traditional/canonical", "Action", "Confidence", "Proposed value", "Memberships", "Origins", "Example titles"),
            traditional_rows,
            len(traditional_rows),
            widths=(38, 38, 34, 14, 38, 14, 20, 90),
            wrap_columns=frozenset({0, 1, 2, 4, 6, 7}),
        )
    )

    residual_groups: dict[str, dict[str, object]] = {}
    for item in all_actions:
        if item.action.action != "keep_or_review_taxonomy":
            continue
        row = residual_groups.setdefault(
            item.canonical_category,
            {"count": 0, "origins": collections.Counter(), "examples": [], "periods": set(), "regions": set()},
        )
        row["count"] = int(row["count"]) + 1
        row["origins"][item.origin] += 1
        if len(row["examples"]) < 4:
            row["examples"].append(item.work.title)
        if item.work.period:
            row["periods"].add(item.work.period)
        if item.work.macro_region:
            row["regions"].add(item.work.macro_region)
    residual_rows = []
    for category, row in sorted(residual_groups.items(), key=lambda pair: (-int(pair[1]["count"]), pair[0])):
        origins = row["origins"]
        residual_rows.append((
            category, int(row["count"]), origins.get("curated", 0), origins.get("source", 0), origins.get("curated+source", 0),
            " | ".join(sorted(row["periods"])[:12]), " | ".join(sorted(row["regions"])[:12]), " | ".join(row["examples"]),
        ))
    sheets.append(
        SheetSpec(
            "Residual Taxonomy",
            ("Category", "Memberships", "Curated only", "Source only", "Both", "Periods", "Macro regions", "Example titles"),
            residual_rows,
            len(residual_rows),
            widths=(40, 14, 14, 14, 12, 54, 36, 90),
            wrap_columns=frozenset({0, 5, 6, 7}),
        )
    )

    people_rows: list[tuple[object, ...]] = []
    for person, row in sorted(semantics.items(), key=lambda pair: (-int(pair[1].get("works", 0)), pair[0])):
        people_rows.append(
            (
                person,
                int(row.get("works", 0)),
                int(row.get("works_with_authors", 0)),
                int(row.get("author_matches", 0)),
                float(row.get("author_ratio", 0.0)),
                int(row.get("other_role_matches", 0)),
                int(row.get("title_parenthetical_matches", 0)),
                int(row.get("authorial_compilation_matches", 0)),
                int(row.get("preamble_role_matches", 0)),
                int(row.get("preamble_author_matches", 0)),
                clean_text(row.get("preamble_roles")),
                int(row.get("cbdb_candidates", 0)),
                int(row.get("cbdb_text_role_matches", 0)),
                int(row.get("cbdb_author_matches", 0)),
                clean_text(row.get("cbdb_roles")),
                clean_text(row.get("semantic")),
            )
        )
    sheets.append(
        SheetSpec(
            "People Semantics",
            ("Person category", "Works", "Works with authors", "Author matches", "Author ratio", "Other role matches", "Title-parenthesis signals", "Authorial-anthology signals", "Preamble role signals", "Preamble author signals", "Preamble roles", "CBDB candidates", "CBDB text-role matches", "CBDB author matches", "CBDB roles", "Inferred author behaviour"),
            people_rows,
            len(people_rows),
            widths=(28, 12, 20, 16, 14, 20, 22, 24, 20, 22, 30, 16, 22, 20, 30, 52),
            wrap_columns=frozenset({0, 10, 14, 15}),
        )
    )

    taxonomy = rules.get("taxonomy_edges") or []
    taxonomy_rows = []
    for row in taxonomy:
        if isinstance(row, dict):
            taxonomy_rows.append((clean_text(row.get("domain")), clean_text(row.get("child")), clean_text(row.get("parent")), clean_text(row.get("note"))))
    sheets.append(
        SheetSpec(
            "Taxonomy Edges",
            ("Domain", "Child", "Parent", "Note"),
            taxonomy_rows,
            len(taxonomy_rows),
            widths=(20, 28, 28, 72),
            wrap_columns=frozenset({1, 2, 3}),
        )
    )

    taxonomy_parent = {
        clean_text(row.get("child")): clean_text(row.get("parent"))
        for row in taxonomy
        if isinstance(row, dict) and clean_text(row.get("domain")) == "漢詩"
    }
    poetry_markers = tuple(rules.get("poetry_markers") or [])
    poetry_rows = []
    for category, count in category_counts.most_common():
        if category in taxonomy_parent or any(marker and marker in category for marker in poetry_markers):
            poetry_rows.append(
                (
                    category,
                    count,
                    taxonomy_parent.get(category, ""),
                    category_origin_counts[category].get("curated", 0),
                    category_origin_counts[category].get("source", 0),
                    category_origin_counts[category].get("curated+source", 0),
                )
            )
    sheets.append(
        SheetSpec(
            "Poetry Categories",
            ("Category", "Memberships", "Taxonomy parent", "Curated only", "Source only", "Both"),
            poetry_rows,
            len(poetry_rows),
            widths=(38, 16, 30, 16, 16, 14),
            wrap_columns=frozenset({0, 2}),
        )
    )

    special_rows: list[tuple[object, ...]] = []
    for group in rules.get("special_category_sets") or []:
        if not isinstance(group, dict):
            continue
        name = clean_text(group.get("name"))
        for term in group.get("terms") or []:
            canonical, _ = canonical_label(normalizer, clean_text(term))
            special_rows.append((name, canonical, category_counts.get(canonical, 0)))
    sheets.append(
        SheetSpec(
            "Special Category Sets",
            ("Set", "Category", "Memberships"),
            special_rows,
            len(special_rows),
            widths=(24, 30, 16),
            wrap_columns=frozenset({0, 1}),
        )
    )

    issue_rows = [(path, detail) for path, detail in issues]
    sheets.append(
        SheetSpec("Audit Issues", ("Metadata path", "Detail"), issue_rows, len(issue_rows), widths=(86, 100), wrap_columns=frozenset({0, 1}))
    )
    return sheets, all_actions, title_actions


def action_plan_payload(action: Action) -> dict[str, str]:
    return {
        "action": action.action,
        "target_field": action.target_field,
        "proposed_value": action.proposed_value,
        "confidence": action.confidence,
        "existing_value": action.existing_value,
        "evidence": action.evidence,
        "note": action.note,
    }


def write_application_plan(
    path: Path,
    corpus_root: Path,
    membership_actions: Sequence[MembershipAction],
    title_actions: Sequence[TitleAction],
    generated_at: str,
) -> None:
    """Write the exact planner decisions as a machine-readable, stale-safe JSONL plan.

    The application stage must consume planner output, not re-infer category meaning.
    Each work record therefore carries the SHA-256 of the metadata.json bytes that
    were inspected. category_migration_apply.py refuses a changed file instead of
    applying a decision to newer metadata.
    """
    grouped_memberships: dict[Path, list[MembershipAction]] = collections.defaultdict(list)
    grouped_titles: dict[Path, list[TitleAction]] = collections.defaultdict(list)
    work_by_path: dict[Path, Work] = {}
    for item in membership_actions:
        grouped_memberships[item.work.metadata_path].append(item)
        work_by_path[item.work.metadata_path] = item.work
    for item in title_actions:
        grouped_titles[item.work.metadata_path].append(item)
        work_by_path[item.work.metadata_path] = item.work

    header = {
        "record": "header",
        "schema": "fanyahanwen.category_migration.application_plan",
        "version": 1,
        "generated_at": generated_at,
        "corpus_root": str(corpus_root),
        "works": len(work_by_path),
        "membership_actions": len(membership_actions),
        "title_actions": len(title_actions),
        "safety": "PLAN ONLY; category_migration_apply.py verifies metadata SHA-256 before staging changes",
    }

    with path.open("w", encoding="utf-8-sig", newline="\n") as handle:
        handle.write(json.dumps(header, ensure_ascii=False, separators=(",", ":")) + "\n")
        for metadata_path in sorted(work_by_path, key=lambda value: value.as_posix()):
            work = work_by_path[metadata_path]
            absolute = corpus_root / metadata_path
            digest = work.metadata_sha256 or hashlib.sha256(absolute.read_bytes()).hexdigest()
            record = {
                "record": "work",
                "metadata_path": metadata_path.as_posix(),
                "metadata_sha256": digest,
                "work_id": work.work_id,
                "title": work.title,
                "membership_actions": [
                    {
                        "raw_category": item.raw_category,
                        "canonical_category": item.canonical_category,
                        "origin": item.origin,
                        "body_occurrences": item.body_occurrences,
                        "body_documents": item.body_documents,
                        "action": action_plan_payload(item.action),
                    }
                    for item in grouped_memberships.get(metadata_path, ())
                ],
                "title_actions": [
                    {
                        "current_title": item.current_title,
                        "proposed_title": item.proposed_title,
                        "suffix": item.suffix,
                        "action": action_plan_payload(item.action),
                    }
                    for item in grouped_titles.get(metadata_path, ())
                ],
            }
            handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def main() -> int:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent
    corpus_root = args.corpus_root.expanduser().resolve()
    rules_path = args.rules.expanduser().resolve()
    output = args.output.expanduser().resolve()
    application_plan = args.application_plan.expanduser().resolve() if args.application_plan else None
    traditional_map = args.traditional_map.expanduser().resolve() if args.traditional_map else None

    if not corpus_root.is_dir():
        print(f"ERROR: corpus root does not exist: {corpus_root}", file=sys.stderr)
        return 2
    if not rules_path.is_file():
        print(f"ERROR: rules file does not exist: {rules_path}", file=sys.stderr)
        return 2
    if not output.parent.is_dir():
        print(f"ERROR: output directory does not exist: {output.parent}", file=sys.stderr)
        return 2
    if output.suffix.lower() != ".xlsx":
        print("ERROR: --output must end in .xlsx", file=sys.stderr)
        return 2
    if application_plan is not None and not application_plan.parent.is_dir():
        print(f"ERROR: application-plan directory does not exist: {application_plan.parent}", file=sys.stderr)
        return 2

    # Fail before an expensive corpus scan if the one shared calendar service
    # cannot boot. The migration script never falls back to local date rules.
    try:
        calendar_status = calendar_engine().systems()
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"ERROR: shared CalendarEngine unavailable: {exc}", file=sys.stderr)
        return 2
    if not calendar_status.get("resolved"):
        print(
            f"ERROR: shared CalendarEngine failed its startup check: {calendar_status.get('error', 'unknown error')}",
            file=sys.stderr,
        )
        return 2

    rules = load_rules(rules_path)
    ambiguous = set(rules.get("traditionalization_ambiguous_chars") or [])
    forced_value = rules.get("traditionalization_forced_chars") or {}
    forced = {str(key): str(value) for key, value in forced_value.items()} if isinstance(forced_value, dict) else {}
    phrase_value = rules.get("traditionalization_phrase_overrides") or {}
    phrases = {str(key): str(value) for key, value in phrase_value.items()} if isinstance(phrase_value, dict) else {}
    try:
        normalizer = Traditionalizer(
            traditional_map,
            ambiguous,
            forced,
            phrases,
            backend=args.traditional_backend,
            opencc_config=args.opencc_config,
        )
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    rules["_controlled_taxonomy_nodes"] = controlled_taxonomy_nodes(rules)

    print(f"Corpus root: {corpus_root}", file=sys.stderr)
    print(f"Traditionalization: {normalizer.backend_name}", file=sys.stderr)
    works, issues, hierarchy_labels = discover_works(corpus_root, args.limit)
    print(f"Works: {len(works):,}", file=sys.stderr)
    # OpenCC CLI installations are much faster when the corpus strings are
    # converted in one batch. The Python binding ignores this call.
    normalizer.preload(traditionalization_prewarm_values(works))

    terms_path = script_dir / "category_audit_terms.json"
    figure_aliases = figure_alias_groups_from_terms(terms_path, normalizer)
    figure_names = set(figure_aliases) or figure_names_from_terms(terms_path, normalizer)
    blocked_person_labels = person_inference_blocked_labels(
        works, normalizer, rules, hierarchy_labels=hierarchy_labels
    )

    cbdb_authority: CbdbAuthority | None = None
    cbdb_people: dict[str, tuple[CbdbPersonCandidate, ...]] = {}
    cbdb_role_evidence: dict[tuple[Path, str], tuple[CbdbRoleEvidence, ...]] = {}
    if not args.no_cbdb:
        cbdb_path = discover_cbdb_path(repo_root, args.cbdb)
        if args.cbdb is not None and cbdb_path is None:
            print(f"ERROR: --cbdb does not point to a readable SQLite file: {args.cbdb}", file=sys.stderr)
            return 2
        if cbdb_path is not None:
            try:
                cbdb_authority = CbdbAuthority(cbdb_path)
                cbdb_labels = cbdb_candidate_category_labels(works, normalizer, blocked_person_labels, rules)
                cbdb_people = cbdb_authority.resolve_labels(cbdb_labels)
                figure_names.update(cbdb_people)
                cbdb_authority.preload_text_roles(
                    candidate.person_id
                    for candidates in cbdb_people.values()
                    for candidate in candidates
                )
                cbdb_role_evidence = infer_cbdb_role_evidence(works, normalizer, cbdb_authority, cbdb_people)
                print(
                    f"CBDB: {cbdb_path.name}; exact personal-name categories {len(cbdb_people):,}; "
                    f"direct text-role matches {len(cbdb_role_evidence):,}",
                    file=sys.stderr,
                )
            except Exception as exc:
                print(f"ERROR: CBDB verification failed: {exc}", file=sys.stderr)
                cbdb_authority.close() if cbdb_authority is not None else None
                return 2
        else:
            print(
                "WARNING: no local viewer/data/cbdb*.sqlite3 found; CBDB person/text-role verification is disabled. "
                "From viewer/, run `bin/rails cbdb:refresh_and_build` to prepare it.",
                file=sys.stderr,
            )

    authorial_compilation_evidence = infer_authorial_compilation_people(
        works, normalizer, rules, blocked_person_labels
    )
    figure_names.update(canonical for (_path, canonical) in authorial_compilation_evidence)
    inferred_people = infer_people_from_title_parentheses(
        works,
        normalizer,
        int(rules.get("person_parenthetical_min_matches", 2)),
        int(rules.get("person_parenthetical_single_match_memberships", 20)),
        blocked_person_labels,
    )
    figure_names.update(inferred_people)

    # Source-added preambles are metadata-like evidence, not body mentions. Scan
    # them separately so strings such as 闍那崛多譯 can identify contributor
    # roles without making the translator a topical mention of the sutra.
    preamble_evidence, preamble_issues, preamble_documents_scanned = scan_preamble_person_evidence(
        corpus_root,
        works,
        normalizer,
        rules["_controlled_taxonomy_nodes"],
        args.progress_every,
        seed_people=figure_names,
        blocked_labels=blocked_person_labels,
    )
    issues.extend(preamble_issues)
    figure_names.update(canonical for (_path, canonical), ev in preamble_evidence.items() if ev.roles)

    indexes = build_indexes(works, normalizer, figure_names)
    indexes["authorial_compilation_evidence"] = authorial_compilation_evidence
    indexes["cbdb_people"] = cbdb_people
    indexes["cbdb_role_evidence"] = cbdb_role_evidence
    for alias, target in (rules.get("period_aliases") or {}).items():
        alias_norm = normalize_name(normalizer, alias)
        target_norm = normalize_name(normalizer, target)
        if target_norm in indexes["periods"]:
            indexes["periods"][alias_norm] = indexes["periods"][target_norm]

    if args.skip_body_evidence:
        evidence: dict[tuple[Path, str], Evidence] = {}
        scanned_documents = 0
    else:
        evidence, body_issues, scanned_documents = scan_body_evidence(
            corpus_root, works, normalizer, indexes, args.progress_every, figure_aliases
        )
        issues.extend(body_issues)

    semantics = person_semantics(
        works,
        normalizer,
        indexes["people"],
        preamble_evidence,
        authorial_compilation_evidence,
        cbdb_people,
        cbdb_role_evidence,
    )

    print(f"Body documents scanned: {scanned_documents:,}", file=sys.stderr)
    print(f"Document preambles scanned: {preamble_documents_scanned:,}", file=sys.stderr)

    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    sheets, membership_actions, title_actions = build_sheets(
        works,
        normalizer,
        indexes,
        rules,
        semantics,
        evidence,
        preamble_evidence,
        issues,
        scanned_documents,
        preamble_documents_scanned,
        generated_at,
        args.include_master_actions,
    )
    write_xlsx(output, sheets, generated_at)
    print(f"Wrote: {output}", file=sys.stderr)
    print(f"Sheets: {len(sheets):,}", file=sys.stderr)
    if application_plan is not None:
        write_application_plan(application_plan, corpus_root, membership_actions, title_actions, generated_at)
        print(f"Application plan: {application_plan}", file=sys.stderr)
    if cbdb_authority is not None:
        cbdb_authority.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
