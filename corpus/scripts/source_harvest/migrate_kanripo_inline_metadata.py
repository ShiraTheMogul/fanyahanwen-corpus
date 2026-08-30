#!/usr/bin/env python3
"""Migrate legacy Kanripo inline text headers into external metadata.json.

Older Kanripo incorporation overlays wrote a block like::

    # WORK_TITLE: ...
    # PAGE_TITLE: ...
    # SOURCE: Kanseki Repository
    # SOURCE_ID: KR...
    ...

at the start of every corpus text file. Current corpus files should contain only
textual content; work/document/provenance metadata belongs in the sibling
metadata.json. This script finds only Kanseki/Kanripo legacy headers, validates or
promotes their information into metadata.json, removes the header, and preserves
the historical body byte-for-byte apart from normalising output to UTF-8 with BOM
and LF newlines.

The default mode is a dry run. Use --overlay to create a repository-ready ZIP or
--apply to change the local working tree. It never touches Rails routes.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

UTF8_BOM = b"\xef\xbb\xbf"
HEADER_RE = re.compile(r"^#\s*([A-Z0-9_]+):\s*(.*?)\s*$")
KANRIPO_ID_RE = re.compile(r"^KR([1-6])([A-Za-z])(\d{4})$")
TRANSCRIPTION_RE = re.compile(r"^kanripo:(KR[1-6][A-Za-z]\d{4}):([^@]+)@(.+)$")


class MigrationError(RuntimeError):
    pass


@dataclass
class PlannedWork:
    metadata_path: Path
    metadata: dict[str, Any]
    changed_texts: dict[Path, bytes] = field(default_factory=dict)
    source_ids: set[str] = field(default_factory=set)
    notes: list[str] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--corpus-root",
        type=Path,
        default=None,
        help="Corpus directory; defaults to <repo-root>/corpus.",
    )
    parser.add_argument(
        "--path",
        action="append",
        default=[],
        help=(
            "Limit scanning to a repository-relative work directory, metadata.json, "
            "or parent directory. Repeat as needed."
        ),
    )
    parser.add_argument(
        "--source-id",
        action="append",
        default=[],
        help="Only migrate one or more Kanripo IDs such as KR1e0001. Repeatable.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--overlay", type=Path, help="Write changed repository files to this ZIP.")
    mode.add_argument("--apply", action="store_true", help="Apply validated changes to the local working tree.")
    parser.add_argument("--report", type=Path, help="Optional UTF-8-BOM JSON report written outside the overlay.")
    parser.add_argument("--limit", type=int, default=0, help="Maximum metadata records to inspect; 0 means all.")
    return parser.parse_args()


def canonical_kanripo_id(value: str) -> str:
    value = value.strip()
    match = KANRIPO_ID_RE.fullmatch(value)
    if not match:
        raise MigrationError(f"invalid Kanripo ID: {value!r}")
    return f"KR{match.group(1)}{match.group(2).lower()}{match.group(3)}"


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_bytes().decode("utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MigrationError(f"{path}: cannot read metadata JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise MigrationError(f"{path}: metadata root is not an object")
    return value


def metadata_bytes(value: dict[str, Any]) -> bytes:
    return UTF8_BOM + (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def all_document_records(meta: dict[str, Any]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    docs = meta.get("documents")
    if isinstance(docs, list):
        records.extend(item for item in docs if isinstance(item, dict))
    editions = meta.get("editions")
    if isinstance(editions, list):
        for edition in editions:
            if not isinstance(edition, dict):
                continue
            docs = edition.get("documents")
            if isinstance(docs, list):
                records.extend(item for item in docs if isinstance(item, dict))
    return records


def parse_inline_header(raw: bytes) -> tuple[dict[str, str], str] | None:
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise MigrationError(f"text is not valid UTF-8: {exc}") from exc

    lines = text.splitlines(keepends=True)
    if not lines:
        return None

    headers: dict[str, str] = {}
    index = 0
    saw_header = False
    while index < len(lines):
        logical = lines[index].rstrip("\r\n")
        match = HEADER_RE.fullmatch(logical)
        if match:
            saw_header = True
            headers.setdefault(match.group(1).upper(), match.group(2).strip())
            index += 1
            continue
        if saw_header and not logical.strip():
            index += 1
            while index < len(lines) and not lines[index].strip():
                index += 1
            break
        break

    if not saw_header:
        return None
    if headers.get("SOURCE", "").casefold() != "kanseki repository".casefold():
        return None
    source_id = headers.get("SOURCE_ID", "")
    if not KANRIPO_ID_RE.fullmatch(source_id):
        return None

    body = "".join(lines[index:])
    if not body.strip():
        raise MigrationError("legacy inline metadata header is followed by an empty text body")
    return headers, body


def split_people(value: str) -> list[str]:
    return [part.strip() for part in re.split(r"[;；]", value) if part.strip()]


def add_unique_string(meta: dict[str, Any], field: str, value: str) -> bool:
    value = value.strip()
    if not value:
        return False
    current = meta.get(field)
    if current is None:
        meta[field] = [value]
        return True
    if not isinstance(current, list):
        raise MigrationError(f"metadata field {field!r} is not an array")
    if value in current:
        return False
    current.append(value)
    return True


def set_if_empty_or_equal(container: dict[str, Any], field: str, value: str, context: str) -> bool:
    value = value.strip()
    if not value:
        return False
    current = str(container.get(field) or "").strip()
    if not current:
        container[field] = value
        return True
    if current == value:
        return False
    raise MigrationError(f"{context}: {field} conflict: metadata={current!r}, inline={value!r}")


def document_for_file(meta: dict[str, Any], path: Path, work_dir: Path, corpus_root: Path) -> dict[str, Any]:
    records = all_document_records(meta)
    rel_from_work = path.relative_to(work_dir).as_posix()
    try:
        rel_from_corpus = path.relative_to(corpus_root).as_posix()
    except ValueError:
        rel_from_corpus = ""

    matches: list[dict[str, Any]] = []
    for record in records:
        file_value = str(record.get("file") or "")
        path_value = str(record.get("path") or "").lstrip("/")
        if file_value in {path.name, rel_from_work}:
            matches.append(record)
            continue
        if rel_from_corpus and path_value == rel_from_corpus:
            matches.append(record)

    # Deduplicate identical dictionary objects reached by multiple match rules.
    unique: list[dict[str, Any]] = []
    seen: set[int] = set()
    for record in matches:
        marker = id(record)
        if marker not in seen:
            seen.add(marker)
            unique.append(record)
    if len(unique) != 1:
        raise MigrationError(
            f"{path}: expected exactly one metadata document record, found {len(unique)}"
        )
    return unique[0]


def expected_repo_url(source_id: str) -> str:
    return f"https://github.com/kanripo/{canonical_kanripo_id(source_id)}"


def ensure_document_provenance(record: dict[str, Any], headers: dict[str, str], path: Path) -> bool:
    changed = False
    source_id = canonical_kanripo_id(headers["SOURCE_ID"])
    branch = headers.get("DIGITAL_EDITION", "").strip()
    revision = headers.get("DIGITAL_REVISION", "").strip()
    if not branch or not revision:
        raise MigrationError(f"{path}: inline Kanripo header lacks branch/revision")

    page_title = headers.get("PAGE_TITLE", "").strip()
    if page_title:
        changed = set_if_empty_or_equal(record, "page_title", page_title, str(path)) or changed
        if not str(record.get("chapter") or "").strip() and "/" in page_title:
            record["chapter"] = page_title.split("/", 1)[1]
            changed = True

    repo_url = expected_repo_url(source_id)
    sources = record.get("sources")
    if sources is None:
        record["sources"] = [repo_url]
        changed = True
    elif not isinstance(sources, list):
        raise MigrationError(f"{path}: document sources is not an array")
    elif repo_url not in sources:
        sources.append(repo_url)
        changed = True

    transcription_id = f"kanripo:{source_id}:{branch}@{revision}"
    current_id = str(record.get("digital_transcription_id") or "").strip()
    if not current_id:
        record["digital_transcription_id"] = transcription_id
        changed = True
    elif current_id != transcription_id:
        raise MigrationError(
            f"{path}: digital_transcription_id conflict: metadata={current_id!r}, inline={transcription_id!r}"
        )

    # Once the inline block is removed the historical body begins on line 1.
    if "body_start_line" in record:
        del record["body_start_line"]
        changed = True
    return changed


def ensure_source_witness(meta: dict[str, Any], headers: dict[str, str], path: Path) -> bool:
    source_id = canonical_kanripo_id(headers["SOURCE_ID"])
    branch = headers.get("DIGITAL_EDITION", "").strip()
    revision = headers.get("DIGITAL_REVISION", "").strip()
    transcription_id = f"kanripo:{source_id}:{branch}@{revision}"
    witness_label = headers.get("SOURCE_WITNESS", "").strip()
    license_text = headers.get("LICENSE", "").strip()

    witnesses = meta.get("source_witnesses")
    if not isinstance(witnesses, list):
        raise MigrationError(
            f"{path}: metadata has no source_witnesses array; refusing to invent witness identity from an old inline header"
        )

    matches: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for witness in witnesses:
        if not isinstance(witness, dict):
            continue
        transcriptions = witness.get("digital_transcriptions")
        if not isinstance(transcriptions, list):
            continue
        for transcription in transcriptions:
            if not isinstance(transcription, dict):
                continue
            tid = str(transcription.get("transcription_id") or "")
            repo = str(transcription.get("repository") or "")
            same_source = tid == transcription_id or canonical_kanripo_id(source_id) in repo
            if same_source and str(transcription.get("branch") or "") == branch and str(transcription.get("revision") or "") == revision:
                matches.append((witness, transcription))

    if len(matches) != 1:
        raise MigrationError(
            f"{path}: expected one external source-witness transcription for {transcription_id}, found {len(matches)}"
        )

    witness, transcription = matches[0]
    changed = False
    if witness_label:
        current_label = str(witness.get("label") or "").strip()
        if not current_label:
            witness["label"] = witness_label
            changed = True
        elif current_label != witness_label:
            raise MigrationError(
                f"{path}: source witness label conflict: metadata={current_label!r}, inline={witness_label!r}"
            )

    if not str(transcription.get("provider") or "").strip():
        transcription["provider"] = "Kanseki Repository"
        changed = True
    if not str(transcription.get("repository") or "").strip():
        transcription["repository"] = expected_repo_url(source_id)
        changed = True
    if license_text and not str(transcription.get("license") or "").strip():
        transcription["license"] = license_text
        changed = True
    return changed


def promote_work_header(meta: dict[str, Any], headers: dict[str, str], path: Path) -> bool:
    changed = False
    inline_title = (headers.get("WORK_TITLE") or headers.get("WORK_BASE_TITLE") or "").strip()
    title = str(meta.get("title") or "").strip()
    if inline_title:
        if not title:
            meta["title"] = inline_title
            title = inline_title
            changed = True
        elif title != inline_title:
            raise MigrationError(f"{path}: work title conflict: metadata={title!r}, inline={inline_title!r}")

    base = headers.get("WORK_BASE_TITLE", "").strip()
    if base:
        current = str(meta.get("work_base_title") or "").strip()
        if not current:
            meta["work_base_title"] = base
            changed = True
        elif current != base:
            raise MigrationError(
                f"{path}: work_base_title conflict: metadata={current!r}, inline={base!r}"
            )

    display = headers.get("DISPLAY_TITLE", "").strip()
    if display and title and display != title:
        # Current metadata has no separate display_title field. Preserve a genuine
        # distinct source title as an alias before deleting the old header.
        changed = add_unique_string(meta, "aliases", display) or changed

    author = headers.get("AUTHOR", "").strip()
    for person in split_people(author):
        changed = add_unique_string(meta, "authors", person) or changed

    times = headers.get("TIMES", "").strip()
    if times:
        current_period = str(meta.get("period") or "").strip()
        if not current_period:
            meta["period"] = times
            changed = True
        elif current_period != times:
            raise MigrationError(
                f"{path}: period conflict: metadata={current_period!r}, inline TIMES={times!r}"
            )
    return changed


def candidate_text_paths(meta: dict[str, Any], work_dir: Path, corpus_root: Path) -> list[Path]:
    paths: set[Path] = set(work_dir.glob("*.txt"))
    for record in all_document_records(meta):
        path_value = str(record.get("path") or "").strip().lstrip("/")
        if path_value:
            candidate = corpus_root / path_value
            if candidate.is_file() and candidate.suffix.lower() == ".txt":
                paths.add(candidate)
        file_value = str(record.get("file") or "").strip()
        if file_value:
            candidate = work_dir / file_value
            if candidate.is_file() and candidate.suffix.lower() == ".txt":
                paths.add(candidate)
    return sorted(paths, key=lambda item: item.as_posix())


def resolve_metadata_paths(repo_root: Path, corpus_root: Path, requested: list[str]) -> list[Path]:
    if not requested:
        return sorted(corpus_root.rglob("metadata.json"), key=lambda item: item.as_posix())

    found: set[Path] = set()
    for raw in requested:
        candidate = (repo_root / raw).resolve() if not Path(raw).is_absolute() else Path(raw).resolve()
        try:
            candidate.relative_to(repo_root)
        except ValueError as exc:
            raise MigrationError(f"requested path escapes repository: {raw}") from exc
        if candidate.is_file():
            if candidate.name != "metadata.json":
                raise MigrationError(f"requested file is not metadata.json: {candidate}")
            found.add(candidate)
        elif candidate.is_dir():
            direct = candidate / "metadata.json"
            if direct.is_file():
                found.add(direct)
            else:
                found.update(candidate.rglob("metadata.json"))
        else:
            raise MigrationError(f"requested path does not exist: {candidate}")
    return sorted(found, key=lambda item: item.as_posix())


def write_repo_file(root: Path, repo_root: Path, source_path: Path, data: bytes) -> Path:
    rel = source_path.resolve().relative_to(repo_root)
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    return target


def verify_unicode_zip_flags(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            if any(ord(ch) > 0x7F for ch in info.filename) and not (info.flag_bits & 0x800):
                raise MigrationError(f"ZIP Unicode entry lacks UTF-8 flag: {info.filename}")


def make_zip(staged_root: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as archive:
        for path in sorted(staged_root.rglob("*"), key=lambda item: item.as_posix()):
            if path.is_file():
                archive.write(path, path.relative_to(staged_root).as_posix())
    verify_unicode_zip_flags(output)


def atomic_replace(target: Path, data: bytes) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=str(target.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, target)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.expanduser().resolve()
    corpus_root = (args.corpus_root or repo_root / "corpus").expanduser().resolve()
    try:
        corpus_root.relative_to(repo_root)
    except ValueError as exc:
        raise SystemExit(f"corpus root must be inside repository: {corpus_root}") from exc

    wanted_ids = {canonical_kanripo_id(value) for value in args.source_id}
    metadata_paths = resolve_metadata_paths(repo_root, corpus_root, args.path)
    if args.limit > 0:
        metadata_paths = metadata_paths[: args.limit]

    scanned_metadata = 0
    scanned_texts = 0
    changed_works = 0
    changed_text_count = 0
    detected_source_ids: set[str] = set()
    errors: list[str] = []
    report_works: list[dict[str, Any]] = []

    with tempfile.TemporaryDirectory(prefix="fanya-kanripo-inline-metadata-") as temp_dir:
        staged_root = Path(temp_dir) / "overlay"
        staged_root.mkdir(parents=True)

        for metadata_path in metadata_paths:
            scanned_metadata += 1
            try:
                meta = read_json(metadata_path)
                work_dir = metadata_path.parent
                changed_texts: dict[Path, bytes] = {}
                work_source_ids: set[str] = set()
                metadata_changed = False

                for text_path in candidate_text_paths(meta, work_dir, corpus_root):
                    scanned_texts += 1
                    parsed = parse_inline_header(text_path.read_bytes())
                    if parsed is None:
                        continue
                    headers, body = parsed
                    source_id = canonical_kanripo_id(headers["SOURCE_ID"])
                    if wanted_ids and source_id not in wanted_ids:
                        continue

                    record = document_for_file(meta, text_path, work_dir, corpus_root)
                    metadata_changed = promote_work_header(meta, headers, text_path) or metadata_changed
                    metadata_changed = ensure_document_provenance(record, headers, text_path) or metadata_changed
                    metadata_changed = ensure_source_witness(meta, headers, text_path) or metadata_changed

                    changed_texts[text_path] = UTF8_BOM + body.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
                    work_source_ids.add(source_id)
                    detected_source_ids.add(source_id)

                if not changed_texts:
                    continue

                changed_works += 1
                changed_text_count += len(changed_texts)
                for path, data in changed_texts.items():
                    write_repo_file(staged_root, repo_root, path, data)
                write_repo_file(staged_root, repo_root, metadata_path, metadata_bytes(meta))
                report_works.append({
                    "metadata": metadata_path.relative_to(repo_root).as_posix(),
                    "source_ids": sorted(work_source_ids),
                    "text_files": [path.relative_to(repo_root).as_posix() for path in sorted(changed_texts)],
                })
            except Exception as exc:
                errors.append(f"{metadata_path.relative_to(repo_root).as_posix()}: {exc}")

        if errors:
            print("Refusing output because validation errors were found:")
            for error in errors[:100]:
                print(f"  ERROR {error}")
            if len(errors) > 100:
                print(f"  ... {len(errors) - 100} additional errors")
            return 2

        summary = {
            "mode": "apply" if args.apply else "overlay" if args.overlay else "dry-run",
            "repo_root": str(repo_root),
            "corpus_root": str(corpus_root),
            "metadata_records_scanned": scanned_metadata,
            "text_files_scanned": scanned_texts,
            "works_with_legacy_kanripo_headers": changed_works,
            "legacy_header_text_files": changed_text_count,
            "source_ids": sorted(detected_source_ids),
            "changes": report_works,
            "routes_changed": 0,
        }

        if args.overlay:
            output = args.overlay.expanduser().resolve()
            if changed_text_count:
                make_zip(staged_root, output)
                summary["overlay"] = str(output)
            else:
                summary["overlay"] = None
        elif args.apply and changed_text_count:
            for staged in sorted(staged_root.rglob("*"), key=lambda item: item.as_posix()):
                if not staged.is_file():
                    continue
                target = repo_root / staged.relative_to(staged_root)
                atomic_replace(target, staged.read_bytes())

        if args.report:
            report_path = args.report.expanduser().resolve()
            report_path.parent.mkdir(parents=True, exist_ok=True)
            report_path.write_bytes(metadata_bytes(summary))

        print("KANRIPO INLINE METADATA MIGRATION")
        print("=================================")
        print(f"Mode:                         {summary['mode']}")
        print(f"Metadata records scanned:     {scanned_metadata:,}")
        print(f"Text files scanned:           {scanned_texts:,}")
        print(f"Affected works:               {changed_works:,}")
        print(f"Legacy-header text files:     {changed_text_count:,}")
        print(f"Source IDs:                   {', '.join(sorted(detected_source_ids)) or '(none)'}")
        print("Routes changed:               0")
        if args.overlay and changed_text_count:
            print(f"Overlay:                      {Path(args.overlay).expanduser().resolve()}")
        if not args.apply and not args.overlay:
            print("Dry run only: no repository files were changed.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
