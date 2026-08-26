from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime as dt
import json
import re
import sys
import zipfile
from pathlib import Path
from typing import Iterable, Iterator, Sequence
from xml.sax.saxutils import escape as xml_escape

EXCEL_MAX_ROWS = 1_048_576
INVALID_SHEET_CHARS = re.compile(r"[\\/*?:\[\]]")
INVALID_XML_CHARS = re.compile(
    "[\x00-\x08\x0B\x0C\x0E-\x1F\uD800-\uDFFF\uFFFE\uFFFF]"
)


@dataclasses.dataclass(frozen=True)
class Work:
    metadata_path: Path
    work_id: str
    title: str
    date_label: str
    period: str
    polity: str
    macro_region: str
    region: str
    categories: tuple[str, ...]
    source_categories: tuple[str, ...]
    documents: tuple[dict, ...]


@dataclasses.dataclass(frozen=True)
class Term:
    tradition: str
    kind: str
    label: str
    aliases: tuple[str, ...]
    scope: str
    note: str


@dataclasses.dataclass(frozen=True)
class SourceCategoryRule:
    name: str
    classification: str
    action: str
    pattern: str
    note: str
    regex: re.Pattern[str]


@dataclasses.dataclass
class MentionHit:
    work: Work
    term: Term
    occurrences: int = 0
    documents: set[str] = dataclasses.field(default_factory=set)
    aliases: collections.Counter[str] = dataclasses.field(default_factory=collections.Counter)
    first_document: str = ""
    first_snippet: str = ""


@dataclasses.dataclass
class AuditIssue:
    kind: str
    metadata_path: str
    document_path: str
    detail: str


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    corpus_root = script_dir.parent
    parser = argparse.ArgumentParser(
        description=(
            "Audit curated and inherited source corpus categories, identify source-category "
            "promotion/maintenance candidates, count configured religious/cultural terms in "
            "work bodies, then write an Excel workbook."
        )
    )
    parser.add_argument(
        "--corpus-root",
        type=Path,
        default=corpus_root,
        help="Corpus directory containing metadata.json files (default: corpus/).",
    )
    parser.add_argument(
        "--terms",
        type=Path,
        default=script_dir / "category_audit_terms.json",
        help=(
            "UTF-8 JSON audit configuration containing mention terms and source-category "
            "review rules (default: category_audit_terms.json beside this script)."
        ),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path.cwd() / "category_audit.xlsx",
        help="Output .xlsx path (default: ./category_audit.xlsx).",
    )
    parser.add_argument(
        "--no-category-sheets",
        action="store_true",
        help=(
            "Do not create one worksheet per discovered category (curated or source); "
            "keep the index/membership/review sheets only."
        ),
    )
    parser.add_argument(
        "--skip-mentions",
        action="store_true",
        help="Skip body-text term scanning and produce the category audit only.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Process at most N metadata files. Intended for test runs.",
    )
    parser.add_argument(
        "--progress-every",
        type=int,
        default=1000,
        help="Print progress every N works (default: 1000; 0 disables).",
    )
    return parser.parse_args()


def read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8-sig", errors="strict") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("top-level JSON value is not an object")
    return value


def clean_text(value: object) -> str:
    if value is None:
        return ""
    return str(value).strip()


def string_list(value: object) -> tuple[str, ...]:
    if not isinstance(value, list):
        return ()
    seen: set[str] = set()
    result: list[str] = []
    for item in value:
        text = clean_text(item)
        if text and text not in seen:
            seen.add(text)
            result.append(text)
    return tuple(result)


def discover_works(corpus_root: Path, limit: int | None) -> tuple[list[Work], list[AuditIssue]]:
    issues: list[AuditIssue] = []
    works: list[Work] = []
    metadata_paths = sorted(corpus_root.rglob("metadata.json"), key=lambda p: p.as_posix())
    if limit is not None:
        metadata_paths = metadata_paths[: max(limit, 0)]

    for metadata_path in metadata_paths:
        rel = metadata_path.relative_to(corpus_root)
        try:
            metadata = read_json(metadata_path)
        except Exception as exc:  # report malformed metadata without aborting the entire audit
            issues.append(AuditIssue("metadata_read_error", rel.as_posix(), "", str(exc)))
            continue

        documents = metadata.get("documents")
        if isinstance(documents, list):
            document_rows = tuple(d for d in documents if isinstance(d, dict))
        else:
            document_rows = ()
            issues.append(
                AuditIssue(
                    "documents_not_array",
                    rel.as_posix(),
                    "",
                    "metadata['documents'] is missing or is not an array",
                )
            )

        categories_value = metadata.get("categories")
        if categories_value is not None and not isinstance(categories_value, list):
            issues.append(
                AuditIssue(
                    "categories_not_array",
                    rel.as_posix(),
                    "",
                    "metadata['categories'] exists but is not an array",
                )
            )

        source_categories_value = metadata.get("source_categories")
        if source_categories_value is not None and not isinstance(source_categories_value, list):
            issues.append(
                AuditIssue(
                    "source_categories_not_array",
                    rel.as_posix(),
                    "",
                    "metadata['source_categories'] exists but is not an array",
                )
            )

        works.append(
            Work(
                metadata_path=rel,
                work_id=clean_text(metadata.get("work_id")),
                title=clean_text(metadata.get("title") or metadata.get("work_base_title") or metadata_path.parent.name),
                date_label=clean_text(metadata.get("date_label")),
                period=clean_text(metadata.get("period")),
                polity=clean_text(metadata.get("polity")),
                macro_region=clean_text(metadata.get("macro_region")),
                region=clean_text(metadata.get("region")),
                categories=string_list(categories_value),
                source_categories=string_list(source_categories_value),
                documents=document_rows,
            )
        )

    return works, issues


def load_terms(path: Path) -> list[Term]:
    data = read_json(path)
    groups = data.get("groups")
    if not isinstance(groups, list):
        raise ValueError("terms JSON must contain a 'groups' array")

    terms: list[Term] = []
    alias_owner: dict[str, str] = {}
    for group in groups:
        if not isinstance(group, dict):
            continue
        tradition = clean_text(group.get("tradition"))
        entries = group.get("entries")
        if not tradition or not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            label = clean_text(entry.get("label"))
            aliases = string_list(entry.get("aliases"))
            if not label or not aliases:
                continue
            term = Term(
                tradition=tradition,
                kind=clean_text(entry.get("kind")) or "term",
                label=label,
                aliases=aliases,
                scope=clean_text(entry.get("scope")),
                note=clean_text(entry.get("note")),
            )
            for alias in aliases:
                prior = alias_owner.get(alias)
                if prior is not None and prior != label:
                    raise ValueError(
                        f"alias {alias!r} is assigned to both {prior!r} and {label!r}; "
                        "aliases must have one owner so counts are deterministic"
                    )
                alias_owner[alias] = label
            terms.append(term)
    return terms


def load_source_category_rules(path: Path) -> list[SourceCategoryRule]:
    data = read_json(path)
    rows = data.get("source_category_review_rules", [])
    if rows is None:
        return []
    if not isinstance(rows, list):
        raise ValueError("terms JSON 'source_category_review_rules' must be an array")

    rules: list[SourceCategoryRule] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = clean_text(row.get("name"))
        classification = clean_text(row.get("classification")) or "review"
        action = clean_text(row.get("action")) or "review"
        pattern = clean_text(row.get("pattern"))
        note = clean_text(row.get("note"))
        if not name or not pattern:
            continue
        try:
            regex = re.compile(pattern)
        except re.error as exc:
            raise ValueError(f"invalid source-category review regex {name!r}: {exc}") from exc
        rules.append(
            SourceCategoryRule(
                name=name,
                classification=classification,
                action=action,
                pattern=pattern,
                note=note,
                regex=regex,
            )
        )
    return rules


def normalize_source_category(category: str) -> str:
    # A leaked MediaWiki namespace is provenance noise; the suffix may still be useful.
    return re.sub(r"^(?:\u5206\u985e|\u5206\u7c7b|Category):\s*", "", category).strip() or category


def source_category_rule_hits(category: str, rules: Sequence[SourceCategoryRule]) -> list[SourceCategoryRule]:
    return [rule for rule in rules if rule.regex.search(category)]


def compile_term_matcher(terms: Sequence[Term]) -> tuple[re.Pattern[str] | None, dict[str, Term]]:
    alias_to_term: dict[str, Term] = {}
    for term in terms:
        for alias in term.aliases:
            alias_to_term[alias] = term
    if not alias_to_term:
        return None, alias_to_term
    aliases = sorted(alias_to_term, key=lambda value: (-len(value), value))
    return re.compile("|".join(re.escape(alias) for alias in aliases)), alias_to_term


def resolve_document_path(corpus_root: Path, work: Work, document: dict) -> Path | None:
    candidates: list[Path] = []
    declared_path = clean_text(document.get("path"))
    file_name = clean_text(document.get("file"))

    if declared_path:
        p = Path(declared_path)
        candidates.append(p if p.is_absolute() else corpus_root / p)
    if file_name:
        metadata_dir = corpus_root / work.metadata_path.parent
        candidates.append(metadata_dir / file_name)

    seen: set[Path] = set()
    for candidate in candidates:
        candidate = candidate.resolve()
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.is_file():
            return candidate
    return None


def read_document_body(path: Path, body_start_line: object) -> str:
    with path.open("r", encoding="utf-8-sig", errors="strict", newline=None) as handle:
        text = handle.read()
    try:
        start = int(body_start_line)
    except (TypeError, ValueError):
        start = 1
    if start <= 1:
        return text
    lines = text.splitlines(keepends=True)
    return "".join(lines[start - 1 :])


def snippet(text: str, start: int, end: int, radius: int = 36) -> str:
    left = max(0, start - radius)
    right = min(len(text), end + radius)
    result = re.sub(r"\s+", " ", text[left:right]).strip()
    if left > 0:
        result = "..." + result
    if right < len(text):
        result += "..."
    return result


def scan_mentions(
    corpus_root: Path,
    works: Sequence[Work],
    terms: Sequence[Term],
    issues: list[AuditIssue],
    progress_every: int,
) -> tuple[dict[tuple[Path, str, str], MentionHit], int]:
    matcher, alias_to_term = compile_term_matcher(terms)
    hits: dict[tuple[Path, str, str], MentionHit] = {}
    scanned_documents = 0
    if matcher is None:
        return hits, scanned_documents

    for work_index, work in enumerate(works, start=1):
        for document in work.documents:
            resolved = resolve_document_path(corpus_root, work, document)
            declared = clean_text(document.get("path") or document.get("file"))
            if resolved is None:
                issues.append(
                    AuditIssue(
                        "missing_document",
                        work.metadata_path.as_posix(),
                        declared,
                        "document listed in metadata could not be resolved",
                    )
                )
                continue
            try:
                body = read_document_body(resolved, document.get("body_start_line"))
            except UnicodeDecodeError as exc:
                issues.append(
                    AuditIssue(
                        "document_utf8_error",
                        work.metadata_path.as_posix(),
                        resolved.relative_to(corpus_root).as_posix(),
                        str(exc),
                    )
                )
                continue
            except OSError as exc:
                issues.append(
                    AuditIssue(
                        "document_read_error",
                        work.metadata_path.as_posix(),
                        resolved.relative_to(corpus_root).as_posix(),
                        str(exc),
                    )
                )
                continue

            scanned_documents += 1
            rel_document = resolved.relative_to(corpus_root).as_posix()
            for match in matcher.finditer(body):
                alias = match.group(0)
                term = alias_to_term[alias]
                key = (work.metadata_path, term.tradition, term.label)
                hit = hits.get(key)
                if hit is None:
                    hit = MentionHit(work=work, term=term)
                    hits[key] = hit
                hit.occurrences += 1
                hit.documents.add(rel_document)
                hit.aliases[alias] += 1
                if not hit.first_snippet:
                    hit.first_document = rel_document
                    hit.first_snippet = snippet(body, match.start(), match.end())

        if progress_every > 0 and work_index % progress_every == 0:
            print(f"Scanned mentions in {work_index:,}/{len(works):,} works...", file=sys.stderr)

    return hits, scanned_documents


def safe_xml_text(value: object) -> str:
    text = clean_text(value)
    text = INVALID_XML_CHARS.sub("", text)
    return xml_escape(text, {"\"": "&quot;"})


def col_name(index: int) -> str:
    result = ""
    value = index + 1
    while value:
        value, remainder = divmod(value - 1, 26)
        result = chr(65 + remainder) + result
    return result


def cell_xml(row_num: int, col_num: int, value: object, style: int = 0) -> str:
    ref = f"{col_name(col_num)}{row_num}"
    style_attr = f' s="{style}"' if style else ""
    if value is None:
        return f'<c r="{ref}"{style_attr}/>'
    if isinstance(value, bool):
        return f'<c r="{ref}" t="b"{style_attr}><v>{1 if value else 0}</v></c>'
    if isinstance(value, int):
        return f'<c r="{ref}"{style_attr}><v>{value}</v></c>'
    if isinstance(value, float):
        return f'<c r="{ref}"{style_attr}><v>{value}</v></c>'
    return f'<c r="{ref}" t="inlineStr"{style_attr}><is><t xml:space="preserve">{safe_xml_text(value)}</t></is></c>'


@dataclasses.dataclass
class SheetSpec:
    name: str
    headers: tuple[str, ...]
    rows: Iterable[Sequence[object]]
    row_count: int
    widths: tuple[float, ...] = ()
    wrap_columns: frozenset[int] = frozenset()


class SheetNameAllocator:
    def __init__(self) -> None:
        self.used: set[str] = set()

    def allocate(self, desired: str) -> str:
        cleaned = INVALID_SHEET_CHARS.sub("_", desired).strip("'") or "Sheet"
        cleaned = cleaned[:31]
        candidate = cleaned
        counter = 2
        while candidate.casefold() in self.used:
            suffix = f"~{counter}"
            candidate = cleaned[: 31 - len(suffix)] + suffix
            counter += 1
        self.used.add(candidate.casefold())
        return candidate


def rows_to_chunks(rows: Sequence[Sequence[object]], capacity: int = EXCEL_MAX_ROWS - 1) -> list[Sequence[Sequence[object]]]:
    if not rows:
        return [rows]
    return [rows[i : i + capacity] for i in range(0, len(rows), capacity)]


def workbook_content_types(sheet_count: int) -> str:
    sheets = "".join(
        f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        for i in range(1, sheet_count + 1)
    )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
        f"{sheets}</Types>"
    )


def workbook_xml(sheets: Sequence[SheetSpec]) -> str:
    body = "".join(
        f'<sheet name="{safe_xml_text(sheet.name)}" sheetId="{i}" r:id="rId{i}"/>'
        for i, sheet in enumerate(sheets, start=1)
    )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        f"<sheets>{body}</sheets></workbook>"
    )


def workbook_rels_xml(sheet_count: int) -> str:
    body = "".join(
        f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>'
        for i in range(1, sheet_count + 1)
    )
    styles_id = sheet_count + 1
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        f"{body}"
        f'<Relationship Id="rId{styles_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        "</Relationships>"
    )


def root_rels_xml() -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>'
        "</Relationships>"
    )


def styles_xml() -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
        '<font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>'
        '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFD9E2F3"/><bgColor indexed="64"/></patternFill></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="3">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center"/></xf>'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>'
        '</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        "</styleSheet>"
    )


def core_xml(generated_at: str) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>Fanya Hanwen Category Audit</dc:title><dc:creator>Fanya Hanwen Corpus category_audit.py</dc:creator>'
        f'<dcterms:created xsi:type="dcterms:W3CDTF">{safe_xml_text(generated_at)}</dcterms:created>'
        "</cp:coreProperties>"
    )


def app_xml(sheet_count: int) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" '
        'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">'
        '<Application>category_audit.py</Application>'
        f"<Sheets>{sheet_count}</Sheets>"
        "</Properties>"
    )


def write_sheet_xml(handle, sheet: SheetSpec) -> None:
    last_col = col_name(max(len(sheet.headers) - 1, 0))
    last_row = sheet.row_count + 1
    handle.write(
        (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
            '<sheetFormatPr defaultRowHeight="15"/>'
        ).encode("utf-8")
    )
    if sheet.widths:
        cols = []
        for idx, width in enumerate(sheet.widths, start=1):
            cols.append(f'<col min="{idx}" max="{idx}" width="{width}" customWidth="1"/>')
        handle.write(("<cols>" + "".join(cols) + "</cols>").encode("utf-8"))
    handle.write(b"<sheetData>")
    header_cells = "".join(cell_xml(1, col, value, style=1) for col, value in enumerate(sheet.headers))
    handle.write(f'<row r="1">{header_cells}</row>'.encode("utf-8"))
    for row_num, row in enumerate(sheet.rows, start=2):
        cells = []
        for col_num, value in enumerate(row):
            style = 2 if col_num in sheet.wrap_columns else 0
            cells.append(cell_xml(row_num, col_num, value, style=style))
        handle.write(f'<row r="{row_num}">{"".join(cells)}</row>'.encode("utf-8"))
    handle.write(b"</sheetData>")
    if sheet.headers:
        handle.write(f'<autoFilter ref="A1:{last_col}{max(last_row, 1)}"/>'.encode("utf-8"))
    handle.write(b"</worksheet>")


def write_xlsx(output: Path, sheets: Sequence[SheetSpec], generated_at: str) -> None:
    if not output.parent.is_dir():
        raise FileNotFoundError(
            f"output directory does not exist: {output.parent}. "
            "Create or choose it explicitly; this script will not invent directories."
        )
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        zf.writestr("[Content_Types].xml", workbook_content_types(len(sheets)).encode("utf-8"))
        zf.writestr("_rels/.rels", root_rels_xml().encode("utf-8"))
        zf.writestr("xl/workbook.xml", workbook_xml(sheets).encode("utf-8"))
        zf.writestr("xl/_rels/workbook.xml.rels", workbook_rels_xml(len(sheets)).encode("utf-8"))
        zf.writestr("xl/styles.xml", styles_xml().encode("utf-8"))
        zf.writestr("docProps/core.xml", core_xml(generated_at).encode("utf-8"))
        zf.writestr("docProps/app.xml", app_xml(len(sheets)).encode("utf-8"))
        for index, sheet in enumerate(sheets, start=1):
            with zf.open(f"xl/worksheets/sheet{index}.xml", "w") as handle:
                write_sheet_xml(handle, sheet)


def work_row(work: Work) -> tuple[object, ...]:
    return (
        int(work.work_id) if work.work_id.isdigit() else work.work_id,
        work.title,
        work.date_label,
        work.period,
        work.polity,
        work.macro_region,
        work.region,
        work.metadata_path.as_posix(),
        " | ".join(work.categories),
        " | ".join(work.source_categories),
    )


def build_sheets(
    corpus_root: Path,
    terms_path: Path,
    works: Sequence[Work],
    terms: Sequence[Term],
    source_category_rules: Sequence[SourceCategoryRule],
    mention_hits: dict[tuple[Path, str, str], MentionHit],
    scanned_documents: int,
    issues: Sequence[AuditIssue],
    include_category_sheets: bool,
    generated_at: str,
) -> list[SheetSpec]:
    allocator = SheetNameAllocator()
    curated_to_works: dict[str, list[Work]] = collections.defaultdict(list)
    source_to_works: dict[str, list[Work]] = collections.defaultdict(list)
    no_curated_categories: list[Work] = []

    for work in works:
        if work.categories:
            for category in work.categories:
                curated_to_works[category].append(work)
        else:
            no_curated_categories.append(work)
        for category in work.source_categories:
            source_to_works[category].append(work)

    for category_works in list(curated_to_works.values()) + list(source_to_works.values()):
        category_works.sort(key=lambda w: (w.date_label, w.period, w.title, w.metadata_path.as_posix()))

    all_category_labels = sorted(set(curated_to_works) | set(source_to_works))
    category_sheet_names: dict[str, str] = {}

    reserved = [
        "Overview",
        "Categories",
        "Curated Categories",
        "Source Categories",
        "Category Membership",
        "No Curated Categories",
        "Source Promotion Review",
        "Source Maintenance Review",
        "Mention Summary",
        "Assignment Candidates",
        "Audit Issues",
    ]
    reserved_allocated = {name: allocator.allocate(name) for name in reserved}

    traditions = sorted({term.tradition for term in terms})
    tradition_sheet_names = {tradition: allocator.allocate(f"Mentions {tradition}") for tradition in traditions}

    if include_category_sheets:
        for category in all_category_labels:
            category_sheet_names[category] = allocator.allocate(category)

    total_occurrences = sum(hit.occurrences for hit in mention_hits.values())
    curated_memberships = sum(len(work.categories) for work in works)
    source_memberships = sum(len(work.source_categories) for work in works)
    overview_rows = [
        ("Generated UTC", generated_at),
        ("Corpus root", str(corpus_root.resolve())),
        ("Audit configuration", str(terms_path.resolve())),
        ("Works scanned", len(works)),
        ("Works with curated categories", len(works) - len(no_curated_categories)),
        ("Works without curated categories", len(no_curated_categories)),
        ("Unique curated categories", len(curated_to_works)),
        ("Unique source categories", len(source_to_works)),
        ("Distinct category labels across both", len(all_category_labels)),
        ("Curated category-work memberships", curated_memberships),
        ("Source category-work memberships", source_memberships),
        ("Document bodies scanned for mentions", scanned_documents),
        ("Work-term mention hits", len(mention_hits)),
        ("Raw term occurrences", total_occurrences),
        ("Audit issues", len(issues)),
        ("Individual category sheets", "yes - curated and source" if include_category_sheets else "no"),
    ]

    sheets: list[SheetSpec] = [
        SheetSpec(
            name=reserved_allocated["Overview"],
            headers=("Metric", "Value"),
            rows=overview_rows,
            row_count=len(overview_rows),
            widths=(38, 78),
            wrap_columns=frozenset({1}),
        )
    ]

    source_review_cache: dict[str, dict[str, object]] = {}
    for category, source_works in source_to_works.items():
        candidate_label = normalize_source_category(category)
        rule_hits = source_category_rule_hits(category, source_category_rules)
        period_matches = sum(1 for work in source_works if category == work.period)
        polity_matches = sum(1 for work in source_works if category == work.polity)
        macro_region_matches = sum(1 for work in source_works if category == work.macro_region)
        region_matches = sum(1 for work in source_works if category == work.region)
        already_curated = sum(1 for work in source_works if candidate_label in work.categories)
        metadata_redundancy: list[str] = []
        if source_works and period_matches == len(source_works):
            metadata_redundancy.append("period")
        if source_works and polity_matches == len(source_works):
            metadata_redundancy.append("polity")
        if source_works and macro_region_matches == len(source_works):
            metadata_redundancy.append("macro_region")
        if source_works and region_matches == len(source_works):
            metadata_redundancy.append("region")

        classifications = list(dict.fromkeys(rule.classification for rule in rule_hits))
        actions = list(dict.fromkeys(rule.action for rule in rule_hits))
        rule_names = [rule.name for rule in rule_hits]
        notes = [rule.note for rule in rule_hits if rule.note]
        if metadata_redundancy:
            classifications.append("metadata_redundant")
            actions.append("review_remove_if_canonical_metadata_confirmed")
            notes.append(
                "Matches canonical metadata field(s) for every source-category membership: "
                + ", ".join(metadata_redundancy)
            )

        if rule_hits or metadata_redundancy:
            promotion_state = "maintenance/redundancy review first"
        elif candidate_label != category:
            promotion_state = "normalize label, then review promotion"
        elif already_curated == len(source_works):
            promotion_state = "already fully represented in curated categories"
        else:
            promotion_state = "review for curated-category promotion"

        source_review_cache[category] = {
            "candidate_label": candidate_label,
            "rule_names": " | ".join(rule_names),
            "classifications": " | ".join(dict.fromkeys(classifications)),
            "actions": " | ".join(dict.fromkeys(actions)),
            "notes": " | ".join(dict.fromkeys(notes)),
            "period_matches": period_matches,
            "polity_matches": polity_matches,
            "macro_region_matches": macro_region_matches,
            "region_matches": region_matches,
            "already_curated": already_curated,
            "promotion_gap": len(source_works) - already_curated,
            "promotion_state": promotion_state,
        }

    combined_summary_rows: list[tuple[object, ...]] = []
    for category in all_category_labels:
        curated_works = curated_to_works.get(category, [])
        source_works = source_to_works.get(category, [])
        unique_works = {work.metadata_path: work for work in curated_works + source_works}
        origins = []
        if curated_works:
            origins.append("curated")
        if source_works:
            origins.append("source")
        review = source_review_cache.get(category, {})
        combined_summary_rows.append(
            (
                category,
                "+".join(origins),
                len(curated_works),
                len(source_works),
                len(unique_works),
                review.get("candidate_label", ""),
                review.get("classifications", ""),
                review.get("promotion_state", ""),
                category_sheet_names.get(category, ""),
            )
        )
    combined_summary_rows.sort(key=lambda row: (-int(row[4]), str(row[0])))
    sheets.append(
        SheetSpec(
            name=reserved_allocated["Categories"],
            headers=(
                "Category",
                "Origin",
                "Curated works",
                "Source works",
                "Unique works",
                "Normalized source candidate",
                "Source review class",
                "Source review state",
                "Worksheet",
            ),
            rows=combined_summary_rows,
            row_count=len(combined_summary_rows),
            widths=(36, 18, 14, 14, 14, 36, 34, 46, 32),
            wrap_columns=frozenset({0, 5, 6, 7, 8}),
        )
    )

    curated_summary_rows: list[tuple[object, ...]] = []
    for category, category_works in sorted(curated_to_works.items(), key=lambda item: (-len(item[1]), item[0])):
        curated_summary_rows.append(
            (
                category,
                len(category_works),
                sum(len(work.documents) for work in category_works),
                " | ".join(sorted({work.macro_region for work in category_works if work.macro_region})),
                " | ".join(sorted({work.period for work in category_works if work.period})),
                category_sheet_names.get(category, ""),
            )
        )
    sheets.append(
        SheetSpec(
            name=reserved_allocated["Curated Categories"],
            headers=("Category", "Works", "Listed documents", "Macro regions", "Periods", "Worksheet"),
            rows=curated_summary_rows,
            row_count=len(curated_summary_rows),
            widths=(36, 12, 18, 30, 46, 32),
            wrap_columns=frozenset({0, 3, 4, 5}),
        )
    )

    source_summary_rows: list[tuple[object, ...]] = []
    for category, category_works in sorted(source_to_works.items(), key=lambda item: (-len(item[1]), item[0])):
        review = source_review_cache[category]
        examples = " | ".join(work.title for work in category_works[:5])
        source_summary_rows.append(
            (
                category,
                review["candidate_label"],
                len(category_works),
                review["already_curated"],
                review["promotion_gap"],
                review["promotion_state"],
                review["classifications"],
                review["rule_names"],
                review["actions"],
                review["period_matches"],
                review["polity_matches"],
                review["macro_region_matches"],
                review["region_matches"],
                examples,
                category_sheet_names.get(category, ""),
                review["notes"],
            )
        )
    sheets.append(
        SheetSpec(
            name=reserved_allocated["Source Categories"],
            headers=(
                "Source category",
                "Normalized candidate",
                "Source works",
                "Already curated as candidate",
                "Promotion gap",
                "Promotion state",
                "Review class",
                "Review rules",
                "Suggested action",
                "Matches period",
                "Matches polity",
                "Matches macro region",
                "Matches region",
                "Example works",
                "Worksheet",
                "Review notes",
            ),
            rows=source_summary_rows,
            row_count=len(source_summary_rows),
            widths=(38, 36, 13, 24, 15, 46, 30, 34, 46, 15, 15, 20, 15, 70, 32, 80),
            wrap_columns=frozenset({0, 1, 5, 6, 7, 8, 13, 14, 15}),
        )
    )

    membership_rows: list[tuple[object, ...]] = []
    for category in all_category_labels:
        works_for_category: dict[Path, Work] = {}
        for work in curated_to_works.get(category, []):
            works_for_category[work.metadata_path] = work
        for work in source_to_works.get(category, []):
            works_for_category[work.metadata_path] = work
        for work in sorted(
            works_for_category.values(),
            key=lambda w: (w.date_label, w.period, w.title, w.metadata_path.as_posix()),
        ):
            in_curated = category in work.categories
            in_source = category in work.source_categories
            origin = "curated+source" if in_curated and in_source else ("curated" if in_curated else "source")
            membership_rows.append((category, origin) + work_row(work))
    membership_headers = (
        "Category",
        "Membership origin",
        "Work ID",
        "Title",
        "Date",
        "Period",
        "Polity",
        "Macro region",
        "Region",
        "Metadata path",
        "Curated categories",
        "Source categories",
    )
    membership_chunks = rows_to_chunks(membership_rows)
    for chunk_index, chunk in enumerate(membership_chunks, start=1):
        base = (
            reserved_allocated["Category Membership"]
            if len(membership_chunks) == 1
            else allocator.allocate(f"Category Membership {chunk_index}")
        )
        sheets.append(
            SheetSpec(
                name=base,
                headers=membership_headers,
                rows=chunk,
                row_count=len(chunk),
                widths=(34, 18, 12, 36, 16, 20, 18, 18, 18, 72, 52, 64),
                wrap_columns=frozenset({0, 1, 3, 9, 10, 11}),
            )
        )

    no_curated_categories.sort(key=lambda w: (w.date_label, w.period, w.title, w.metadata_path.as_posix()))
    sheets.append(
        SheetSpec(
            name=reserved_allocated["No Curated Categories"],
            headers=(
                "Work ID",
                "Title",
                "Date",
                "Period",
                "Polity",
                "Macro region",
                "Region",
                "Metadata path",
                "Curated categories",
                "Source categories",
            ),
            rows=[work_row(work) for work in no_curated_categories],
            row_count=len(no_curated_categories),
            widths=(12, 36, 16, 20, 18, 18, 18, 72, 52, 64),
            wrap_columns=frozenset({1, 7, 8, 9}),
        )
    )

    promotion_rows: list[tuple[object, ...]] = []
    maintenance_rows: list[tuple[object, ...]] = []
    for category, category_works in source_to_works.items():
        review = source_review_cache[category]
        base_row = (
            category,
            review["candidate_label"],
            len(category_works),
            review["already_curated"],
            review["promotion_gap"],
            review["promotion_state"],
            review["classifications"],
            review["rule_names"],
            review["actions"],
            review["notes"],
            category_sheet_names.get(category, ""),
            " | ".join(work.title for work in category_works[:8]),
        )
        if int(review["promotion_gap"]) > 0:
            promotion_rows.append(base_row)
        if review["classifications"]:
            maintenance_rows.append(base_row)
    promotion_rows.sort(key=lambda row: (-int(row[4]), -int(row[2]), str(row[0])))
    maintenance_rows.sort(key=lambda row: (-int(row[2]), str(row[6]), str(row[0])))
    review_headers = (
        "Source category",
        "Normalized candidate",
        "Source works",
        "Already curated",
        "Promotion gap",
        "Review state",
        "Review class",
        "Review rules",
        "Suggested action",
        "Notes",
        "Worksheet",
        "Example works",
    )
    sheets.append(
        SheetSpec(
            name=reserved_allocated["Source Promotion Review"],
            headers=review_headers,
            rows=promotion_rows,
            row_count=len(promotion_rows),
            widths=(38, 36, 13, 16, 15, 46, 30, 34, 46, 78, 32, 80),
            wrap_columns=frozenset({0, 1, 5, 6, 7, 8, 9, 10, 11}),
        )
    )
    sheets.append(
        SheetSpec(
            name=reserved_allocated["Source Maintenance Review"],
            headers=review_headers,
            rows=maintenance_rows,
            row_count=len(maintenance_rows),
            widths=(38, 36, 13, 16, 15, 46, 30, 34, 46, 78, 32, 80),
            wrap_columns=frozenset({0, 1, 5, 6, 7, 8, 9, 10, 11}),
        )
    )

    hit_values = list(mention_hits.values())
    term_to_hits: dict[tuple[str, str, str], list[MentionHit]] = collections.defaultdict(list)
    for hit in hit_values:
        term_to_hits[(hit.term.tradition, hit.term.kind, hit.term.label)].append(hit)

    term_rows: list[tuple[object, ...]] = []
    term_objects: dict[tuple[str, str, str], Term] = {
        (term.tradition, term.kind, term.label): term for term in terms
    }
    for key, term in sorted(term_objects.items(), key=lambda item: (item[0][0], item[0][1], item[0][2])):
        hits_for_term = term_to_hits.get(key, [])
        term_rows.append(
            (
                term.tradition,
                term.kind,
                term.label,
                term.scope,
                " | ".join(term.aliases),
                len(hits_for_term),
                len({doc for hit in hits_for_term for doc in hit.documents}),
                sum(hit.occurrences for hit in hits_for_term),
                term.note,
            )
        )
    sheets.append(
        SheetSpec(
            name=reserved_allocated["Mention Summary"],
            headers=("Tradition", "Kind", "Label", "Scope", "Aliases", "Works", "Documents", "Occurrences", "Note"),
            rows=term_rows,
            row_count=len(term_rows),
            widths=(22, 14, 24, 26, 54, 10, 12, 14, 70),
            wrap_columns=frozenset({2, 3, 4, 8}),
        )
    )

    candidate_groups: dict[tuple[str, Path], list[MentionHit]] = collections.defaultdict(list)
    for hit in hit_values:
        candidate_groups[(hit.term.tradition, hit.work.metadata_path)].append(hit)
    candidate_rows: list[tuple[object, ...]] = []
    for (tradition, _metadata_path), grouped_hits in candidate_groups.items():
        work = grouped_hits[0].work
        matched_terms = sorted(
            ((hit.term.label, hit.occurrences) for hit in grouped_hits),
            key=lambda item: (-item[1], item[0]),
        )
        candidate_rows.append(
            (
                tradition,
                int(work.work_id) if work.work_id.isdigit() else work.work_id,
                work.title,
                work.date_label,
                work.period,
                work.polity,
                work.macro_region,
                work.region,
                len(grouped_hits),
                sum(hit.occurrences for hit in grouped_hits),
                " | ".join(f"{label} ({count})" for label, count in matched_terms),
                " | ".join(work.categories),
                " | ".join(work.source_categories),
                work.metadata_path.as_posix(),
            )
        )
    candidate_rows.sort(key=lambda row: (row[0], -int(row[8]), -int(row[9]), str(row[3]), str(row[2])))
    sheets.append(
        SheetSpec(
            name=reserved_allocated["Assignment Candidates"],
            headers=(
                "Tradition",
                "Work ID",
                "Title",
                "Date",
                "Period",
                "Polity",
                "Macro region",
                "Region",
                "Distinct matched terms",
                "Occurrences",
                "Matched terms",
                "Curated categories",
                "Source categories",
                "Metadata path",
            ),
            rows=candidate_rows,
            row_count=len(candidate_rows),
            widths=(24, 12, 36, 16, 18, 18, 18, 18, 22, 14, 68, 52, 64, 72),
            wrap_columns=frozenset({0, 2, 10, 11, 12, 13}),
        )
    )

    mention_headers = (
        "Tradition",
        "Kind",
        "Term",
        "Scope",
        "Work ID",
        "Title",
        "Date",
        "Period",
        "Polity",
        "Macro region",
        "Region",
        "Occurrences",
        "Matched aliases",
        "Documents",
        "First document",
        "First context",
        "Metadata path",
        "Curated categories",
        "Source categories",
        "Term note",
    )
    for tradition in traditions:
        tradition_hits = sorted(
            (hit for hit in hit_values if hit.term.tradition == tradition),
            key=lambda hit: (-hit.occurrences, hit.term.kind, hit.term.label, hit.work.date_label, hit.work.title),
        )
        rows = []
        for hit in tradition_hits:
            aliases = " | ".join(f"{alias} ({count})" for alias, count in hit.aliases.most_common())
            rows.append(
                (
                    hit.term.tradition,
                    hit.term.kind,
                    hit.term.label,
                    hit.term.scope,
                    int(hit.work.work_id) if hit.work.work_id.isdigit() else hit.work.work_id,
                    hit.work.title,
                    hit.work.date_label,
                    hit.work.period,
                    hit.work.polity,
                    hit.work.macro_region,
                    hit.work.region,
                    hit.occurrences,
                    aliases,
                    len(hit.documents),
                    hit.first_document,
                    hit.first_snippet,
                    hit.work.metadata_path.as_posix(),
                    " | ".join(hit.work.categories),
                    " | ".join(hit.work.source_categories),
                    hit.term.note,
                )
            )
        sheets.append(
            SheetSpec(
                name=tradition_sheet_names[tradition],
                headers=mention_headers,
                rows=rows,
                row_count=len(rows),
                widths=(20, 12, 22, 24, 12, 34, 16, 18, 18, 18, 18, 12, 40, 12, 64, 72, 68, 52, 64, 70),
                wrap_columns=frozenset({2, 3, 5, 12, 14, 15, 16, 17, 18, 19}),
            )
        )

    issue_rows = [(issue.kind, issue.metadata_path, issue.document_path, issue.detail) for issue in issues]
    sheets.append(
        SheetSpec(
            name=reserved_allocated["Audit Issues"],
            headers=("Kind", "Metadata path", "Document path", "Detail"),
            rows=issue_rows,
            row_count=len(issue_rows),
            widths=(28, 72, 72, 80),
            wrap_columns=frozenset({1, 2, 3}),
        )
    )

    if include_category_sheets:
        headers = (
            "Membership origin",
            "Work ID",
            "Title",
            "Date",
            "Period",
            "Polity",
            "Macro region",
            "Region",
            "Metadata path",
            "Curated categories",
            "Source categories",
        )
        for category in all_category_labels:
            works_for_category: dict[Path, Work] = {}
            for work in curated_to_works.get(category, []):
                works_for_category[work.metadata_path] = work
            for work in source_to_works.get(category, []):
                works_for_category[work.metadata_path] = work
            rows: list[tuple[object, ...]] = []
            for work in sorted(
                works_for_category.values(),
                key=lambda w: (w.date_label, w.period, w.title, w.metadata_path.as_posix()),
            ):
                in_curated = category in work.categories
                in_source = category in work.source_categories
                origin = "curated+source" if in_curated and in_source else ("curated" if in_curated else "source")
                rows.append((origin,) + work_row(work))
            sheets.append(
                SheetSpec(
                    name=category_sheet_names[category],
                    headers=headers,
                    rows=rows,
                    row_count=len(rows),
                    widths=(18, 12, 36, 16, 20, 18, 18, 18, 72, 52, 64),
                    wrap_columns=frozenset({0, 2, 8, 9, 10}),
                )
            )

    return sheets


def main() -> int:
    args = parse_args()
    corpus_root = args.corpus_root.expanduser().resolve()
    terms_path = args.terms.expanduser().resolve()
    output = args.output.expanduser().resolve()

    if not corpus_root.is_dir():
        print(f"ERROR: corpus root does not exist: {corpus_root}", file=sys.stderr)
        return 2
    if not terms_path.is_file():
        print(f"ERROR: audit configuration does not exist: {terms_path}", file=sys.stderr)
        return 2
    if output.suffix.lower() != ".xlsx":
        print("ERROR: --output must end in .xlsx", file=sys.stderr)
        return 2

    print(f"Corpus root: {corpus_root}", file=sys.stderr)
    works, issues = discover_works(corpus_root, args.limit)
    print(f"Works discovered: {len(works):,}", file=sys.stderr)

    curated_categories = {category for work in works for category in work.categories}
    source_categories = {category for work in works for category in work.source_categories}
    all_categories = curated_categories | source_categories
    print(f"Curated categories discovered: {len(curated_categories):,}", file=sys.stderr)
    print(f"Source categories discovered: {len(source_categories):,}", file=sys.stderr)
    print(f"Distinct category labels across both: {len(all_categories):,}", file=sys.stderr)
    if not args.no_category_sheets and len(all_categories) > 500:
        print(
            f"WARNING: this run will create {len(all_categories):,} individual category worksheets "
            "covering both curated and source categories. Use --no-category-sheets for a smaller "
            "workbook while keeping the complete category indexes and memberships.",
            file=sys.stderr,
        )

    try:
        source_category_rules = load_source_category_rules(terms_path)
    except Exception as exc:
        print(f"ERROR: could not load source-category review rules: {exc}", file=sys.stderr)
        return 2
    print(f"Configured source-category review rules: {len(source_category_rules):,}", file=sys.stderr)

    if args.skip_mentions:
        terms: list[Term] = []
        hits: dict[tuple[Path, str, str], MentionHit] = {}
        scanned_documents = 0
    else:
        try:
            terms = load_terms(terms_path)
        except Exception as exc:
            print(f"ERROR: could not load mention terms: {exc}", file=sys.stderr)
            return 2
        print(f"Configured audit terms: {len(terms):,}", file=sys.stderr)
        hits, scanned_documents = scan_mentions(
            corpus_root, works, terms, issues, max(args.progress_every, 0)
        )
        print(
            f"Mention scan complete: {scanned_documents:,} document bodies, "
            f"{len(hits):,} work-term hits.",
            file=sys.stderr,
        )

    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    sheets = build_sheets(
        corpus_root=corpus_root,
        terms_path=terms_path,
        works=works,
        terms=terms,
        source_category_rules=source_category_rules,
        mention_hits=hits,
        scanned_documents=scanned_documents,
        issues=issues,
        include_category_sheets=not args.no_category_sheets,
        generated_at=generated_at,
    )
    print(f"Writing {len(sheets):,} worksheets to {output}...", file=sys.stderr)
    try:
        write_xlsx(output, sheets, generated_at)
    except OSError as exc:
        print(f"ERROR: could not write workbook: {exc}", file=sys.stderr)
        return 2
    print(f"Done: {output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
