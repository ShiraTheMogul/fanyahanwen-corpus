#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
import_heji_rubbings.py

Import image witnesses from 《甲骨文合集》 into the existing Fanya Hanwen
oracle-bone object folders.

The script is deliberately conservative:

- It reads the 合集 catalogue number from each IMAGE FILENAME.
- It looks only in the existing target:
  corpus/中國漢文/clean/商殷朝/商/甲骨文/殷墟/出土位置不詳
- It never creates a missing 合集 work directory.
- It never overwrites an existing image with different bytes.
- It keeps image witnesses beside metadata.json and transcription files.
- It records 《甲骨文合集》 as an image source under work-level "sources".
- It does not add images to "documents"; 合集37986 on current main is the model.
- It is dry-run by default. Pass --apply to write changes.
- metadata.json is read and written as UTF-8 with BOM (utf-8-sig).

Accepted filename examples:
    39424.jpg
    合集39424.jpg
    39424 (1).jpg
    39424（2）.png
    39424正.jpg
    39424_反.tif
    39424-2.jpeg

Destination examples:
    合集39424_甲骨文合集.jpg
    合集39424_甲骨文合集_1.jpg
    合集39424_甲骨文合集_正.jpg

No image bytes are altered or recompressed.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Optional


TARGET_RELATIVE = Path(
    "corpus/中國漢文/clean/商殷朝/商/甲骨文/殷墟/出土位置不詳"
)

IMAGE_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".png",
    ".tif",
    ".tiff",
    ".webp",
    ".bmp",
}

# Strict enough to avoid treating arbitrary numbers elsewhere in a filename
# as 合集 catalogue numbers.
#
# Examples:
#   39424
#   合集39424
#   39424 (2)
#   39424（2）
#   39424正
#   39424_反
#   39424-2
FILENAME_RE = re.compile(
    r"""
    ^\s*
    (?:合集\s*)?
    (?P<number>\d{1,5})
    (?:
        \s*[\(（\[]\s*(?P<bracket_view>\d+)\s*[\)）\]]
      |
        \s*[_-]?\s*(?P<named_view>正|反|背)
      |
        \s*[_-]\s*(?P<numbered_view>\d+)
    )?
    \s*$
    """,
    re.VERBOSE,
)

IMAGE_SOURCE = {
    "kind": "image_source",
    "citation": "甲骨文合集",
    "source_note": (
        "Rubbing image matched to this object by the 甲骨文合集 catalogue "
        "number encoded in the source filename."
    ),
}


@dataclass(frozen=True)
class ParsedImage:
    source: Path
    catalogue: str
    view: Optional[str]

    @property
    def work_name(self) -> str:
        return f"合集{self.catalogue}"

    @property
    def destination_name(self) -> str:
        suffix = self.source.suffix.lower()
        view_suffix = f"_{self.view}" if self.view else ""
        return f"合集{self.catalogue}_甲骨文合集{view_suffix}{suffix}"


@dataclass
class ReportRow:
    source_file: str
    catalogue: str
    view: str
    status: str
    destination: str
    message: str


def sha256_file(path: Path) -> str:
    """Return the SHA-256 digest of one file."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_image_filename(path: Path) -> Optional[ParsedImage]:
    """
    Read the catalogue number from the filename only.

    For X in filenames:
        if X matches a known 合集 filename shape:
            return its catalogue number
        else:
            return None
    """
    m = FILENAME_RE.fullmatch(path.stem)
    if not m:
        return None

    catalogue = m.group("number").zfill(5)
    view = (
        m.group("bracket_view")
        or m.group("named_view")
        or m.group("numbered_view")
    )

    return ParsedImage(source=path, catalogue=catalogue, view=view)


def iter_images(source_root: Path, recursive: bool) -> Iterable[Path]:
    """Yield supported image files in a stable order."""
    iterator = source_root.rglob("*") if recursive else source_root.glob("*")
    files = [
        p
        for p in iterator
        if p.is_file() and p.suffix.lower() in IMAGE_EXTENSIONS
    ]
    yield from sorted(files, key=lambda p: str(p).casefold())


def read_metadata(path: Path) -> dict[str, Any]:
    """
    Read JSON while accepting either BOM or non-BOM UTF-8.

    utf-8-sig removes a BOM if present and also reads ordinary UTF-8.
    """
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_metadata_bom(path: Path, data: dict[str, Any]) -> None:
    """
    Write metadata.json as UTF-8 WITH BOM.

    ensure_ascii=False keeps Han characters as Han characters.
    """
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    path.write_text(text, encoding="utf-8-sig")


def canonical_heji_value(metadata: dict[str, Any]) -> Optional[str]:
    """
    Return the work's canonical 甲骨文合集 number, if the metadata declares one.
    """
    canonical = metadata.get("canonical_identifier")
    if not isinstance(canonical, dict):
        return None
    if canonical.get("scheme") != "甲骨文合集":
        return None

    value = str(canonical.get("value", "")).strip()
    if not value.isdigit():
        return None
    return value.zfill(5)


def has_heji_image_source(sources: list[Any]) -> bool:
    """
    True only when an explicit image_source for 甲骨文合集 is already present.

    A legacy plain string "甲骨文合集" is left untouched. It may identify the
    inscription record generally, while this script adds explicit image provenance.
    """
    for source in sources:
        if not isinstance(source, dict):
            continue
        if (
            source.get("kind") == "image_source"
            and source.get("citation") == "甲骨文合集"
        ):
            return True
    return False


def ensure_heji_image_source(metadata: dict[str, Any]) -> bool:
    """
    Add the explicit image-source record once.

    Returns True when metadata changed.
    """
    sources = metadata.get("sources")

    if sources is None:
        metadata["sources"] = [dict(IMAGE_SOURCE)]
        return True

    if not isinstance(sources, list):
        raise ValueError('"sources" exists but is not a list')

    if has_heji_image_source(sources):
        return False

    sources.append(dict(IMAGE_SOURCE))
    return True


def validate_work_metadata(
    metadata_path: Path,
    expected_catalogue: str,
) -> tuple[dict[str, Any], Optional[str]]:
    """
    Check that a work directory really describes the catalogue number we matched.

    Returns:
        (metadata, None) on success
        (metadata, error_message) on failure
    """
    try:
        metadata = read_metadata(metadata_path)
    except Exception as exc:
        return {}, f"cannot read metadata.json: {exc}"

    canonical = canonical_heji_value(metadata)
    if canonical is None:
        return metadata, (
            "metadata.json has no canonical_identifier "
            'with scheme "甲骨文合集"'
        )

    if canonical != expected_catalogue:
        return metadata, (
            f"canonical identifier says {canonical}, "
            f"but filename matched {expected_catalogue}"
        )

    return metadata, None


def write_report(path: Path, rows: list[ReportRow]) -> None:
    """
    Write an optional CSV report as UTF-8 WITH BOM.

    The parent directory must already exist. The script will not invent one.
    """
    if not path.parent.exists():
        raise FileNotFoundError(
            f"report parent directory does not exist: {path.parent}"
        )

    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "source_file",
                "catalogue",
                "view",
                "status",
                "destination",
                "message",
            ]
        )
        for row in rows:
            writer.writerow(
                [
                    row.source_file,
                    row.catalogue,
                    row.view,
                    row.status,
                    row.destination,
                    row.message,
                ]
            )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Import 《甲骨文合集》 rubbing images into existing 合集 work folders. "
            "Dry-run is the default."
        )
    )
    parser.add_argument(
        "source",
        help="Folder containing the rubbing images.",
    )
    parser.add_argument(
        "--repo-root",
        help=(
            "Fanya Hanwen repository root. "
            "Default: inferred from this script's corpus/scripts location."
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually copy images and update metadata.json.",
    )
    parser.add_argument(
        "--top-level-only",
        action="store_true",
        help="Do not scan subfolders of the source folder.",
    )
    parser.add_argument(
        "--report",
        help=(
            "Optional CSV report path. Its parent directory must already exist. "
            "Written as UTF-8 with BOM."
        ),
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help=(
            "Return exit code 1 if any image is unmatched, its work is missing, "
            "metadata is invalid, or a destination collision occurs."
        ),
    )
    args = parser.parse_args()

    source_root = Path(args.source).expanduser().resolve()
    if not source_root.is_dir():
        print(f"[error] source folder not found: {source_root}", file=sys.stderr)
        return 2

    if args.repo_root:
        repo_root = Path(args.repo_root).expanduser().resolve()
    else:
        # corpus/scripts/import_heji_rubbings.py -> repository root
        repo_root = Path(__file__).resolve().parents[2]

    target_root = repo_root / TARGET_RELATIVE
    if not target_root.is_dir():
        print(
            "[error] expected target folder not found:\n"
            f"        {target_root}\n"
            "Nothing was created.",
            file=sys.stderr,
        )
        return 2

    images = list(
        iter_images(
            source_root,
            recursive=not args.top_level_only,
        )
    )

    report_rows: list[ReportRow] = []
    grouped: dict[str, list[ParsedImage]] = defaultdict(list)

    unmatched = 0
    for image in images:
        parsed = parse_image_filename(image)
        if parsed is None:
            unmatched += 1
            report_rows.append(
                ReportRow(
                    source_file=str(image),
                    catalogue="",
                    view="",
                    status="unmatched_filename",
                    destination="",
                    message=(
                        "Filename does not match a supported 合集 catalogue-number shape."
                    ),
                )
            )
            print(f"[unmatched] {image.name}")
            continue
        grouped[parsed.catalogue].append(parsed)

    copied = 0
    already_present = 0
    planned = 0
    missing_work = 0
    bad_metadata = 0
    collisions = 0
    metadata_updated = 0
    metadata_planned = 0

    for catalogue in sorted(grouped):
        work_dir = target_root / f"合集{catalogue}"
        items = grouped[catalogue]

        if not work_dir.is_dir():
            missing_work += len(items)
            for item in items:
                report_rows.append(
                    ReportRow(
                        source_file=str(item.source),
                        catalogue=catalogue,
                        view=item.view or "",
                        status="missing_work",
                        destination=str(work_dir),
                        message=(
                            "Matching 合集 work directory does not exist; "
                            "the script does not create work records."
                        ),
                    )
                )
                print(f"[missing work] {item.source.name} -> {work_dir.name}")
            continue

        metadata_path = work_dir / "metadata.json"
        if not metadata_path.is_file():
            bad_metadata += len(items)
            for item in items:
                report_rows.append(
                    ReportRow(
                        source_file=str(item.source),
                        catalogue=catalogue,
                        view=item.view or "",
                        status="missing_metadata",
                        destination=str(work_dir),
                        message="Existing work directory has no metadata.json.",
                    )
                )
                print(f"[bad metadata] {work_dir}: metadata.json missing")
            continue

        metadata, metadata_error = validate_work_metadata(
            metadata_path,
            catalogue,
        )
        if metadata_error:
            bad_metadata += len(items)
            for item in items:
                report_rows.append(
                    ReportRow(
                        source_file=str(item.source),
                        catalogue=catalogue,
                        view=item.view or "",
                        status="invalid_metadata",
                        destination=str(work_dir),
                        message=metadata_error,
                    )
                )
            print(f"[bad metadata] {work_dir}: {metadata_error}")
            continue

        valid_witness_for_work = False

        for item in items:
            destination = work_dir / item.destination_name

            if destination.exists():
                try:
                    same = sha256_file(item.source) == sha256_file(destination)
                except OSError as exc:
                    collisions += 1
                    report_rows.append(
                        ReportRow(
                            source_file=str(item.source),
                            catalogue=catalogue,
                            view=item.view or "",
                            status="io_error",
                            destination=str(destination),
                            message=str(exc),
                        )
                    )
                    print(f"[error] {item.source.name}: {exc}")
                    continue

                if same:
                    already_present += 1
                    valid_witness_for_work = True
                    report_rows.append(
                        ReportRow(
                            source_file=str(item.source),
                            catalogue=catalogue,
                            view=item.view or "",
                            status="already_present",
                            destination=str(destination),
                            message="Destination already has identical bytes.",
                        )
                    )
                    print(
                        f"[already] {item.source.name} -> "
                        f"{work_dir.name}/{destination.name}"
                    )
                    continue

                collisions += 1
                report_rows.append(
                    ReportRow(
                        source_file=str(item.source),
                        catalogue=catalogue,
                        view=item.view or "",
                        status="collision",
                        destination=str(destination),
                        message=(
                            "Destination exists with different bytes. "
                            "Nothing was overwritten. Rename the source with an "
                            "explicit view marker such as (2) if it is a distinct witness."
                        ),
                    )
                )
                print(
                    f"[collision] {item.source.name} -> "
                    f"{work_dir.name}/{destination.name}"
                )
                continue

            valid_witness_for_work = True

            if args.apply:
                shutil.copy2(item.source, destination)
                copied += 1
                status = "copied"
                prefix = "[copied]"
            else:
                planned += 1
                status = "would_copy"
                prefix = "[dry-run]"

            report_rows.append(
                ReportRow(
                    source_file=str(item.source),
                    catalogue=catalogue,
                    view=item.view or "",
                    status=status,
                    destination=str(destination),
                    message="",
                )
            )
            print(
                f"{prefix} {item.source.name} -> "
                f"{work_dir.name}/{destination.name}"
            )

        # Only attach image provenance when there is an image that is present
        # already or can be copied safely.
        if valid_witness_for_work:
            try:
                changed = ensure_heji_image_source(metadata)
            except ValueError as exc:
                bad_metadata += 1
                report_rows.append(
                    ReportRow(
                        source_file="",
                        catalogue=catalogue,
                        view="",
                        status="invalid_sources",
                        destination=str(metadata_path),
                        message=str(exc),
                    )
                )
                print(f"[bad metadata] {metadata_path}: {exc}")
                continue

            if changed:
                if args.apply:
                    write_metadata_bom(metadata_path, metadata)
                    metadata_updated += 1
                    print(f"[metadata] updated {work_dir.name}/metadata.json")
                else:
                    metadata_planned += 1
                    print(
                        f"[metadata dry-run] would add 甲骨文合集 image source "
                        f"to {work_dir.name}/metadata.json"
                    )

    if args.report:
        report_path = Path(args.report).expanduser().resolve()
        write_report(report_path, report_rows)
        print(f"[report] {report_path}")

    problems = unmatched + missing_work + bad_metadata + collisions

    print("\n[done]")
    print(f"  image_files_scanned       = {len(images)}")
    print(f"  matched_catalogue_files   = {len(images) - unmatched}")
    print(f"  unmatched_filenames       = {unmatched}")
    print(f"  missing_work_files        = {missing_work}")
    print(f"  metadata_problems         = {bad_metadata}")
    print(f"  collisions                = {collisions}")
    print(f"  already_present           = {already_present}")
    print(f"  would_copy                = {planned}")
    print(f"  copied                    = {copied}")
    print(f"  metadata_would_update     = {metadata_planned}")
    print(f"  metadata_updated          = {metadata_updated}")
    print(f"  apply                     = {args.apply}")

    if args.strict and problems:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
