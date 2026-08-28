#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime as dt
import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Iterable, Sequence

from category_audit import SheetSpec, read_json, write_xlsx


@dataclasses.dataclass(frozen=True)
class Work:
    metadata_path: Path
    work_id: str
    title: str
    work_base_title: str
    aliases: tuple[str, ...]
    date_label: str
    period: str
    polity: str
    macro_region: str
    region: str
    medium: str
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


@dataclasses.dataclass
class Evidence:
    occurrences: int = 0
    documents: set[str] = dataclasses.field(default_factory=set)
    first_document: str = ""
    first_snippet: str = ""


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
    def __init__(
        self,
        mapping_path: Path | None,
        ambiguous: set[str],
        forced: dict[str, str],
        phrase_overrides: dict[str, str] | None = None,
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
        self.loaded = False
        if mapping_path is not None and mapping_path.is_file():
            self._load(mapping_path)

    def _load(self, path: Path) -> None:
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
            # kTraditionalVariant is broader than a Simplified->Traditional table.
            # If the source itself is a valid target (for example 家, 表, 志, 千),
            # keep it: converting to 傢/錶/誌/韆 would be a semantic corruption.
            if source in targets:
                continue
            if len(targets) == 1:
                self.mapping[source] = next(iter(targets))
            elif len(targets) > 1:
                self.auto_ambiguous.add(source)
        self.loaded = True

    def normalize(self, text: str) -> tuple[str, tuple[str, ...]]:
        value = unicodedata.normalize("NFC", text.strip())
        # Some Simplified graphs are also legitimate Traditional graphs (for example
        # 云, 后, 面). Character-only conversion cannot resolve those safely. Apply
        # small, explicit metadata-phrase conversions first, then use Unihan for the
        # straightforward one-to-one graph changes.
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
        "--traditional-map",
        type=Path,
        default=repo_root / "viewer" / "resources" / "unihan" / "kTraditionalVariant.txt",
        help="Unihan kTraditionalVariant mapping used for conservative category-label normalization.",
    )
    parser.add_argument("--output", type=Path, default=Path.cwd() / "category_migration.xlsx")
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


def discover_works(corpus_root: Path, limit: int | None) -> tuple[list[Work], list[tuple[str, str]]]:
    works: list[Work] = []
    issues: list[tuple[str, str]] = []
    paths = sorted(corpus_root.rglob("metadata.json"), key=lambda path: path.as_posix())
    if limit is not None:
        paths = paths[: max(0, limit)]
    for path in paths:
        rel = path.relative_to(corpus_root)
        try:
            metadata = read_json(path)
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
                period=clean_text(metadata.get("period")),
                polity=clean_text(metadata.get("polity")),
                macro_region=clean_text(metadata.get("macro_region")),
                region=clean_text(metadata.get("region")),
                medium=clean_text(metadata.get("medium")),
                is_compilation=bool(metadata.get("is_compilation")),
                categories=string_list(metadata.get("categories")),
                source_categories=string_list(metadata.get("source_categories")),
                authors=string_list(metadata.get("authors")),
                editors=string_list(metadata.get("editors")),
                contributors=contributor_names(metadata.get("contributors")),
                document_authors=nested_document_authors(metadata),
                contained_in=contained,
                editions=editions,
                sources=string_list(metadata.get("sources")),
                identifiers=identifiers,
                documents=documents,
            )
        )
    return works, issues


def load_rules(path: Path) -> dict:
    data = read_json(path)
    if not isinstance(data, dict):
        raise ValueError("migration rules must be a JSON object")
    return data


def strip_namespace(label: str) -> str:
    return re.sub(r"^(?:分類|分类|Category):\s*", "", label).strip()


def normalize_name(normalizer: Traditionalizer, value: str) -> str:
    return normalizer.normalize(strip_namespace(value))[0]


def canonical_label(normalizer: Traditionalizer, raw: str) -> tuple[str, tuple[str, ...]]:
    return normalizer.normalize(strip_namespace(raw))


def chinese_integer(value: str) -> int | None:
    text = value.strip()
    if text == "元":
        return 1
    if text.isdigit():
        return int(text)
    text = text.replace("两", "兩")
    text = re.sub(r"^廿", "二十", text)
    text = re.sub(r"^卅", "三十", text)
    text = re.sub(r"^卌", "四十", text)
    digits = {"〇": 0, "零": 0, "○": 0, "一": 1, "二": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
    units = {"十": 10, "百": 100, "千": 1000}
    if text and all(char in digits for char in text):
        value = 0
        for char in text:
            value = value * 10 + digits[char]
        return value
    if not text or any(char not in digits and char not in units for char in text):
        return None
    total = 0
    current = 0
    for char in text:
        if char in digits:
            current = digits[char]
        else:
            total += (current or 1) * units[char]
            current = 0
    return total + current


def parse_date_category(canonical: str, calendar_year_bases: dict[str, object] | None = None) -> DateCategory | None:
    mention = False
    value = canonical.strip()
    mention_match = re.search(r"\s*[（(]提及[)）]\s*$", value)
    if mention_match:
        mention = True
        value = value[: mention_match.start()].strip()

    number = r"(?:元|[〇零○一二三四五六七八九十百千兩两廿卅卌0-9]+)"
    match = re.fullmatch(r"(\d{3,4})年(?:(\d{1,2})月)?(?:(\d{1,2})日)?", value)
    if match:
        year = int(match.group(1))
        month = int(match.group(2)) if match.group(2) else None
        day = int(match.group(3)) if match.group(3) else None
        if month is not None and not (1 <= month <= 12):
            return None
        if day is not None and not (1 <= day <= 31):
            return None
        return DateCategory(raw=canonical, canonical=canonical, year=year, month=month, day=day, is_mention=mention)

    if isinstance(calendar_year_bases, dict):
        era_match = re.fullmatch(rf"(.+?)({number})年(?:({number})月)?(?:({number})日)?", value)
        if era_match:
            ordinal = chinese_integer(era_match.group(2))
            month = chinese_integer(era_match.group(3)) if era_match.group(3) else None
            day = chinese_integer(era_match.group(4)) if era_match.group(4) else None
            base = calendar_year_bases.get(era_match.group(1).strip())
            try:
                base_year = int(base) if base is not None else None
            except (TypeError, ValueError):
                base_year = None
            if ordinal is not None and ordinal >= 1 and base_year is not None:
                if month is not None and not (1 <= month <= 12):
                    return None
                if day is not None and not (1 <= day <= 31):
                    return None
                return DateCategory(
                    raw=canonical,
                    canonical=canonical,
                    year=base_year + ordinal,
                    month=month,
                    day=day,
                    is_mention=mention,
                )
    return None


def looks_like_unmapped_era_year(canonical: str) -> bool:
    value = re.sub(r"\s*[（(]提及[)）]\s*$", "", canonical.strip())
    return bool(re.fullmatch(r"[\u3400-\u9fff\uf900-\ufaff]{1,10}(?:元|[〇零一二三四五六七八九十百千0-9]+)年", value))


def parse_date_label(value: str) -> tuple[int, int | None, int | None] | None:
    text = value.strip()
    match = re.search(r"(?<!\d)(\d{3,4})(?:年|$)(?:(\d{1,2})月)?(?:(\d{1,2})日)?", text)
    if not match:
        match = re.fullmatch(r"(\d{3,4})", text)
        if not match:
            return None
        return int(match.group(1)), None, None
    return (
        int(match.group(1)),
        int(match.group(2)) if match.group(2) else None,
        int(match.group(3)) if match.group(3) else None,
    )


def parse_existing_date_label(value: str, calendar_bases: dict[str, object]) -> tuple[int, int | None, int | None] | None:
    parsed = parse_date_category(value, calendar_bases)
    if parsed is not None and not parsed.is_mention:
        return parsed.year, parsed.month, parsed.day
    return parse_date_label(value)


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


def leading_date_in_suffix(value: str, bases: dict[str, object]) -> tuple[DateCategory, str] | None:
    number = r"(?:元|[〇零○一二三四五六七八九十百千兩两廿卅卌0-9]+)"
    patterns = [
        rf"^(?:中華民國|中华民国|民國|民国){number}年(?:{number}月)?(?:{number}日)?",
        r"^\d{3,4}年(?:\d{1,2}月)?(?:\d{1,2}日)?",
    ]
    for pattern in patterns:
        match = re.match(pattern, value)
        if not match:
            continue
        parsed = parse_date_category(match.group(0), bases)
        if parsed is not None:
            return parsed, value[match.end():].strip()
    return None


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


def calendar_year_bases(rules: dict) -> dict[str, object]:
    value = rules.get("calendar_year_bases")
    if isinstance(value, dict):
        return value
    legacy = rules.get("era_year_bases")
    return legacy if isinstance(legacy, dict) else {}


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
    works: Sequence[Work], normalizer: Traditionalizer, rules: dict
) -> set[str]:
    """Labels that must never become people merely from title/category coincidence.

    Periods, polities, regions and controlled/scoped semantic labels can occur in
    source-added parentheses too.  Treating one such coincidence as evidence of a
    person contaminated the person authority set (for example 西晉 and 礦藝).
    """
    blocked = {normalize_name(normalizer, value) for value in controlled_taxonomy_nodes(rules)}
    blocked.update(normalize_name(normalizer, value) for value in rules.get("tradition_labels") or [] if clean_text(value))
    blocked.update(normalize_name(normalizer, value) for value in rules.get("person_inference_exclusions") or [] if clean_text(value))
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


def candidate_aliases_for_work(work: Work, normalizer: Traditionalizer, indexes: dict) -> dict[str, set[str]]:
    result: dict[str, set[str]] = collections.defaultdict(set)
    people = indexes["people"]
    periods = indexes["periods"]
    polities = indexes["polities"]
    macro_regions = indexes["macro_regions"]
    regions = indexes["regions"]
    for raw, _origin in unique_memberships(work):
        canonical, _ = canonical_label(normalizer, raw)
        date_cat = parse_date_category(canonical)
        if date_cat is not None and date_cat.is_mention:
            result[canonical].add(date_cat.source_label)
            continue
        if canonical in people:
            result[canonical].add(canonical)
            continue
        if canonical in periods:
            result[canonical].add(canonical)
        p_candidate = polity_candidate(canonical, polities)
        if p_candidate:
            result[canonical].add(p_candidate)
            result[canonical].add(p_candidate + "朝")
        if canonical in macro_regions or canonical in regions:
            result[canonical].add(canonical)
    return result


def scan_body_evidence(
    corpus_root: Path,
    works: Sequence[Work],
    normalizer: Traditionalizer,
    indexes: dict,
    progress_every: int,
) -> tuple[dict[tuple[Path, str], Evidence], list[tuple[str, str]], int]:
    evidence: dict[tuple[Path, str], Evidence] = {}
    issues: list[tuple[str, str]] = []
    scanned_documents = 0
    for work_index, work in enumerate(works, start=1):
        candidates = candidate_aliases_for_work(work, normalizer, indexes)
        if not candidates:
            continue
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
                    if not item.first_snippet:
                        pos = body.find(alias)
                        item.first_document = rel_document
                        item.first_snippet = body_snippet(body, pos, len(alias))
        if progress_every > 0 and work_index % progress_every == 0:
            print(f"Body evidence: {work_index:,}/{len(works):,} works", file=sys.stderr)
    return evidence, issues, scanned_documents


def person_semantics(
    works: Sequence[Work],
    normalizer: Traditionalizer,
    people: set[str],
    preamble_evidence: dict[tuple[Path, str], PreamblePersonEvidence] | None = None,
    authorial_compilation_evidence: dict[tuple[Path, str], str] | None = None,
) -> dict[str, dict[str, float | int | str]]:
    stats: dict[str, dict[str, int]] = collections.defaultdict(lambda: collections.Counter())
    preamble_roles: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
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
    output: dict[str, dict[str, float | int | str]] = {}
    for person, row in stats.items():
        denominator = row["works_with_authors"]
        ratio = row["author_matches"] / denominator if denominator else 0.0
        role_summary = ", ".join(
            f"{role}={count}" for role, count in preamble_roles.get(person, collections.Counter()).most_common()
        )
        if int(row.get("preamble_role_matches", 0)) > 0:
            semantic = "explicit contributor role in source-added document preamble"
        elif int(row.get("authorial_compilation_matches", 0)) > 0:
            semantic = "author grouping in an author-organized source anthology"
        elif (row["author_matches"] >= 3 and ratio >= 0.8) or row["title_parenthetical_matches"] >= 2:
            semantic = "likely author grouping"
        elif row["author_matches"] == 0 and row["title_parenthetical_matches"] == 0:
            semantic = "likely mention/topic or unresolved person role"
        else:
            semantic = "mixed person role"
        output[person] = {
            **row,
            "author_ratio": ratio,
            "preamble_roles": role_summary,
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

    deterministic_bases = calendar_year_bases(rules)

    range_period = configured_period_range(canonical, rules)
    if range_period:
        target_norm = normalize_name(normalizer, range_period)
        work_period_norm = normalize_name(normalizer, work.period) if work.period else ""
        if work_period_norm == target_norm:
            return [Action(
                "remove_period_range_category_redundant", "period", work.period, "safe", work.period,
                f"source date-range label maps to period {range_period}",
                "This range is dynasty/period classification, not the date of every individual work. Keep the structured period and remove the source range category.",
            )]
        if not work.period:
            return [Action(
                "promote_period_from_range_category", "period", range_period, "high", "",
                f"configured source range maps to period {range_period}",
                "Populate period metadata; do not copy the dynasty-wide date range into the work's date_label.",
            )]
        return [Action(
            "period_range_category_conflict_review", "period", range_period, "review", work.period,
            f"configured source range maps to {range_period} but structured period differs",
            "Review the source chronology. A dynasty-wide range category must not overwrite a specific work date.",
        )]

    date_cat = parse_date_category(canonical, deterministic_bases)
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
        existing = parse_existing_date_label(work.date_label, deterministic_bases) if work.date_label else None
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
        most_specific = max(plain_dates, key=lambda item: item.specificity) if plain_dates else date_cat
        if existing and date_compatible(date_cat, existing):
            return [
                Action(
                    "remove_date_category_redundant",
                    "date_label",
                    work.date_label,
                    "safe",
                    work.date_label,
                    "category agrees with existing date metadata",
                    "The date belongs in date metadata and the category can be removed.",
                )
            ]
        if not work.date_label:
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
                    "Populate date_label with the historical expression, let HistoricalDateResolver derive the absolute year, then remove the date category.",
                )
            ]
        return [
            Action(
                "date_metadata_conflict",
                "date_label",
                most_specific.source_label,
                "review",
                work.date_label,
                "category does not agree with existing date metadata",
                "Review the date evidence before changing either value.",
            )
        ]

    dated_composite = leading_date_in_suffix(canonical, deterministic_bases)
    if dated_composite is not None:
        composite_date, remainder = dated_composite
        if remainder:
            existing = parse_existing_date_label(work.date_label, deterministic_bases) if work.date_label else None
            if existing and date_compatible(composite_date, existing):
                confidence = "high"
                existing_value = work.date_label
                evidence_text = f"date prefix agrees with structured date metadata; absolute equivalent {composite_date.label}"
            elif not work.date_label:
                confidence = "high"
                existing_value = ""
                evidence_text = f"date prefix can populate date metadata; absolute equivalent {composite_date.label}"
            else:
                confidence = "review"
                existing_value = work.date_label
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
            taxon = clean_text(animal_row.get("taxon_candidate"))
            proposed_display = f"medium={proposed_medium}"
            if animal_name:
                proposed_display += f"; animal={animal_name}"
            if taxon:
                proposed_display += f"; taxon={taxon}"
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

    if canonical == "甲骨文":
        combined = " | ".join((work.title, work.work_base_title, *work.categories, *work.source_categories, work.metadata_path.as_posix(), semantic_path_text(work.metadata_path)))
        if "龜甲" in combined or "龟甲" in combined:
            proposal = "medium=龜甲; animal=龜; taxon=待辨"
            confidence = "high"
            note = "Explicit turtle-shell evidence is present in title/category/path metadata. Record species only when a catalogue or zooarchaeological source supports it."
        elif "兕骨" in combined:
            proposal = "medium=兕骨; animal=兕; taxon=Bubalus sp.（需來源核定）"
            confidence = "high"
            note = "Explicit 兕骨 evidence is present; retain the historical animal label and record a scientific identification only with supporting evidence."
        elif "牛肩胛骨" in combined or "牛骨" in combined:
            proposal = "骨（具體動物待核）"
            confidence = "review"
            note = "Bovine bone evidence is present, but it must not be silently relabelled 兕骨. Record taxonomic identification separately when supported."
        else:
            proposal = "龜甲 / 骨（待辨）"
            confidence = "review"
            note = "甲骨文 alone does not identify the support. Distinguish turtle shell from bone before migration; preserve animal-species evidence where available."
        return [
            Action(
                "oracle_bone_material_review",
                "medium + animal identification",
                proposal,
                confidence,
                work.medium,
                "甲骨文 category",
                note,
            )
        ]


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
        body_count = evidence.occurrences if evidence else 0
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
        stats = semantics.get(canonical, {})
        likely_author = (
            (
                int(stats.get("author_matches", 0)) >= int(rules.get("person_author_min_matches", 3))
                and float(stats.get("author_ratio", 0.0)) >= float(rules.get("person_author_ratio", 0.8))
            )
            or int(stats.get("title_parenthetical_matches", 0))
            >= int(rules.get("person_parenthetical_author_min_matches", 2))
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
                        f"{int(stats.get('title_parenthetical_matches', 0))}"
                    ),
                    "Use category behaviour to fill missing authors, then remove the person category.",
                )
            ]
        if body_count > 0:
            caution = ""
            if work.is_compilation and evidence and len(evidence.documents) < len(work.documents):
                caution = " Mention evidence is component-level within a compilation."
            return [
                Action(
                    "promote_person_mention",
                    "mentions.people",
                    canonical,
                    "high" if not work.is_compilation else "review",
                    " | ".join(work.authors),
                    f"exact body occurrences: {body_count}",
                    "The person is present in the work body and is not a structured author/contributor." + caution,
                )
            ]
        return [
            Action(
                "person_role_review",
                "authors / contributors / mentions.people",
                canonical,
                "review",
                " | ".join(work.authors + work.editors + work.contributors),
                clean_text(stats.get("semantic")),
                "The category is a known personal name but its role in this work is unresolved.",
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
                (prefix_period and prefix_period == period_norm)
                or (prefix_polity and prefix_polity == polity_norm)
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
    if p_candidate and p_candidate == period_norm:
        redundant_fields.append("period")
    if polity_cand and polity_cand == polity_norm:
        redundant_fields.append("polity")
    if canonical and canonical == macro_norm:
        redundant_fields.append("macro_region")
    if canonical and canonical == region_norm:
        redundant_fields.append("region")
    if redundant_fields:
        return [
            Action(
                "remove_geography_period_category_redundant",
                "; ".join(redundant_fields),
                " | ".join(
                    value for value in (work.period, work.polity, work.macro_region, work.region) if value
                ),
                "safe",
                " | ".join(redundant_fields),
                "category exactly agrees with structured metadata",
                "Remove the redundant category after confirming the structured field is authoritative.",
            )
        ]

    if p_candidate and not work.period:
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
    bases = calendar_year_bases(rules)
    for work in works:
        proposed_title, suffixes = split_trailing_parentheticals(work.title)
        if not suffixes or not proposed_title:
            continue
        authors, other_people = work_people(work, normalizer)
        edition_labels = existing_edition_labels(work, normalizer)
        category_labels = {canonical_label(normalizer, raw)[0] for raw, _origin in unique_memberships(work)}

        for suffix in suffixes:
            canonical, unresolved = canonical_label(normalizer, suffix)
            date_cat = parse_date_category(canonical, bases)
            if date_cat is not None and not date_cat.is_mention:
                existing = parse_existing_date_label(work.date_label, bases) if work.date_label else None
                if existing and date_compatible(date_cat, existing):
                    action = Action(
                        "strip_title_date_suffix_redundant", "title + date_label", date_cat.source_label, "safe", work.date_label,
                        f"trailing parenthetical date agrees with structured date metadata; absolute equivalent {date_cat.label}",
                        "Strip the source-added date suffix from the title; the date is already structured.",
                    )
                elif not work.date_label:
                    action = Action(
                        "strip_title_date_suffix_promote", "title + date_label", date_cat.source_label, "high", "",
                        f"trailing parenthetical is a deterministic calendar date; absolute equivalent {date_cat.label}",
                        "Strip the suffix from the title, preserve the historical date expression in date_label, and let HistoricalDateResolver derive the absolute year.",
                    )
                else:
                    action = Action(
                        "title_date_suffix_conflict_review", "title + date_label", date_cat.source_label, "review", work.date_label,
                        "trailing parenthetical date conflicts with structured date metadata",
                        "Review the dating evidence before stripping the suffix or changing the date field.",
                    )
                rows.append(TitleAction(work, work.title, proposed_title, suffix, action))
                continue

            dated_qualifier = leading_date_in_suffix(canonical, bases)
            if dated_qualifier is not None:
                prefix_date, qualifier = dated_qualifier
                if qualifier:
                    rows.append(TitleAction(work, work.title, proposed_title, suffix, Action(
                        "title_date_qualifier_suffix_review", "title + date_label + source/contributor metadata",
                        f"date_label={prefix_date.source_label}; qualifier={qualifier}", "review", work.date_label,
                        f"trailing parenthetical begins with a resolvable date ({prefix_date.label}) and then adds a qualifier",
                        "Strip the whole source-added suffix from the clean title, promote the date through HistoricalDateResolver, and classify the remaining institution/document qualifier separately.",
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
        int(work.work_id) if work.work_id.isdigit() else work.work_id, work.date_label, work.period, work.polity,
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
        work.date_label,
        work.period,
        work.polity,
        work.macro_region,
        work.region,
        work.medium,
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
        widths=(12, 34, 30, 48, 36, 36, 16, 12, 40, 18, 20, 18, 18, 18, 20, 14, 16, 18, 18, 18, 46, 58, 78, 78),
        wrap_columns=frozenset({1, 2, 3, 4, 5, 8, 20, 21, 22, 23}),
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
) -> list[SheetSpec]:
    all_actions: list[MembershipAction] = []
    title_actions = plan_title_cleanup(works, normalizer, indexes, rules)
    category_counts: collections.Counter[str] = collections.Counter()
    category_origin_counts: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)

    for work in works:
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
            parsed = parse_date_category(canonical, calendar_year_bases(rules))
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
    subset("Mention Promotions", lambda item: "mention" in item.action.action)
    subset("Conflicts Review", lambda item: "conflict" in item.action.action or item.action.action.endswith("_review"))
    subset("People Review", lambda item: "person" in item.action.action or item.action.target_field.startswith("authors"))
    subset("Date Review", lambda item: "date" in item.action.action)
    subset("Period Polity Review", lambda item: any(token in item.action.action for token in ("period", "polity", "geograph")))
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
    subset("Material Review", lambda item: any(token in item.action.action for token in ("material", "oracle_bone")))
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
                clean_text(row.get("preamble_roles")),
                clean_text(row.get("semantic")),
            )
        )
    sheets.append(
        SheetSpec(
            "People Semantics",
            ("Person category", "Works", "Works with authors", "Author matches", "Author ratio", "Other role matches", "Title-parenthesis signals", "Authorial-anthology signals", "Preamble role signals", "Preamble roles", "Inferred category behaviour"),
            people_rows,
            len(people_rows),
            widths=(28, 12, 20, 16, 14, 20, 22, 24, 20, 30, 48),
            wrap_columns=frozenset({0, 9, 10}),
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
    return sheets


def main() -> int:
    args = parse_args()
    corpus_root = args.corpus_root.expanduser().resolve()
    rules_path = args.rules.expanduser().resolve()
    output = args.output.expanduser().resolve()
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

    rules = load_rules(rules_path)
    ambiguous = set(rules.get("traditionalization_ambiguous_chars") or [])
    forced_value = rules.get("traditionalization_forced_chars") or {}
    forced = {str(key): str(value) for key, value in forced_value.items()} if isinstance(forced_value, dict) else {}
    phrase_value = rules.get("traditionalization_phrase_overrides") or {}
    phrases = {str(key): str(value) for key, value in phrase_value.items()} if isinstance(phrase_value, dict) else {}
    normalizer = Traditionalizer(traditional_map, ambiguous, forced, phrases)
    rules["_controlled_taxonomy_nodes"] = controlled_taxonomy_nodes(rules)
    if not normalizer.loaded:
        print(f"WARNING: Traditional mapping not loaded: {traditional_map}", file=sys.stderr)

    print(f"Corpus root: {corpus_root}", file=sys.stderr)
    works, issues = discover_works(corpus_root, args.limit)
    print(f"Works: {len(works):,}", file=sys.stderr)

    terms_path = Path(__file__).resolve().parent / "category_audit_terms.json"
    figure_names = figure_names_from_terms(terms_path, normalizer)
    blocked_person_labels = person_inference_blocked_labels(works, normalizer, rules)
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
    # Do not infer a person merely because the same bare parenthetical suffix is
    # repeated. Form labels such as 七言絕句 can repeat in titles too. Category +
    # title agreement (including role-marked names such as 竺法護譯) is the safer
    # inference signal.
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
    for alias, target in (rules.get("period_aliases") or {}).items():
        alias_norm = normalize_name(normalizer, alias)
        target_norm = normalize_name(normalizer, target)
        if target_norm in indexes["periods"]:
            indexes["periods"][alias_norm] = indexes["periods"][target_norm]
    semantics = person_semantics(
        works, normalizer, indexes["people"], preamble_evidence, authorial_compilation_evidence
    )

    if args.skip_body_evidence:
        evidence: dict[tuple[Path, str], Evidence] = {}
        scanned_documents = 0
    else:
        evidence, body_issues, scanned_documents = scan_body_evidence(
            corpus_root, works, normalizer, indexes, args.progress_every
        )
        issues.extend(body_issues)
    print(f"Body documents scanned: {scanned_documents:,}", file=sys.stderr)
    print(f"Document preambles scanned: {preamble_documents_scanned:,}", file=sys.stderr)

    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    sheets = build_sheets(
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
