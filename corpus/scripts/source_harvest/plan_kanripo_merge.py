#!/usr/bin/env python3
"""Build a read-only Kanripo incorporation plan from completed harvest/comparison data.

This script never edits corpus files. It combines all completed Kanripo comparison
runs, detects PALCC metadata-only work stubs, separates the physical/documentary
source witness from later digital transcription editions, detects clearly partial
digital transcriptions so they cannot block a more complete maintained text, estimates
the cost of preserving historical transcriptions, and writes action queues into staging.

The intended provenance chain is:

    work / textual tradition
        -> source witness or source edition
           e.g. 郭店楚簡, 馬王堆帛書, 宋刊本, 四庫全書・文淵閣本
        -> digital transcription edition
           e.g. Kanripo master, historical Kanripo WYG branch, Wikisource
        -> digital revision / snapshot
           e.g. a Kanripo commit SHA or dated Wikisource capture

Kanripo's upstream field is literally named BASEEDITION. In PALCC planning output we
treat its value as evidence for the *source witness*, because a branch named WYG and
BASEEDITION=WYG are different facts. Branch + commit identify the digital publication
state of a transcription; BASEEDITION identifies what that transcription was based on.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import unicodedata
import zipfile
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

EXCLUDED_PALCC_DIRS = {
    "variants", "kanbun", "hanvan", "hanmun", "annotations", "annotation",
    "translations", "translation", "images", "image", "raw", "sources", "source",
}
KANRIPO_ID_RE = re.compile(r"^KR([1-6])([A-Za-z])(\d{4})$")
BASE_EDITION_RE = re.compile(r"^#\+PROPERTY:\s*BASEEDITION\s+(.+?)\s*$", re.I | re.M)
TITLE_RE = re.compile(r"^#\+TITLE:\s*(.+?)\s*$", re.I | re.M)

HAN_RANGES = (
    (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF),
    (0x20000, 0x2A6DF), (0x2A700, 0x2B73F), (0x2B740, 0x2B81F),
    (0x2B820, 0x2CEAF), (0x2CEB0, 0x2EBEF), (0x30000, 0x3134F),
    (0x31350, 0x323AF),
)

CLASS_RANK = {
    "IDENTICAL": 6,
    "NEAR_IDENTICAL": 5,
    "SUBSTANTIAL_OVERLAP": 4,
    "TEXTUAL_DIFFERENCE": 3,
    "PARTIAL_OVERLAP": 2,
    "COULD_NOT_ALIGN": 1,
    "TOO_SHORT_TO_JUDGE": 0,
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def stamp_now() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def clean(value: Any) -> str:
    return "" if value is None else str(value).strip()


def intish(value: Any) -> int:
    try:
        return int(float(clean(value) or "0"))
    except ValueError:
        return 0


def floatish(value: Any) -> float:
    try:
        return float(clean(value) or "0")
    except ValueError:
        return 0.0


def canonical_kanripo_id(value: str) -> str:
    value = clean(value)
    m = KANRIPO_ID_RE.match(value)
    if not m:
        return value
    return f"KR{m.group(1)}{m.group(2).lower()}{m.group(3)}"


def split_pipe(value: str) -> list[str]:
    return [part.strip() for part in clean(value).split(" | ") if part.strip()]


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: Iterable[dict[str, Any]], fields: list[str] | None = None) -> None:
    rows = list(rows)
    if fields is None:
        fields = []
        seen: set[str] = set()
        for row in rows:
            for key in row:
                if key not in seen:
                    seen.add(key)
                    fields.append(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def resolve_inventory(staging_root: Path, explicit: Path | None) -> Path:
    if explicit:
        path = explicit.expanduser().resolve()
        if not (path / "refined" / "kanripo_existing_title_witnesses.csv").is_file():
            raise FileNotFoundError(f"No refined Kanripo queue under {path}")
        return path

    state = staging_root / "_state" / "last_inventory.json"
    if state.is_file():
        try:
            payload = json.loads(state.read_text(encoding="utf-8"))
            output = Path(payload.get("output_dir", ""))
            if not output.is_absolute():
                output = (staging_root / output).resolve()
            if (output / "refined" / "kanripo_existing_title_witnesses.csv").is_file():
                return output
        except Exception:
            pass

    candidates = sorted(
        (staging_root / "_inventory").glob("*/refined/kanripo_existing_title_witnesses.csv"),
        key=lambda p: p.parent.parent.name,
        reverse=True,
    )
    if not candidates:
        raise FileNotFoundError("No completed refined inventory found")
    return candidates[0].parent.parent


def comparison_dirs(staging_root: Path, explicit: list[Path]) -> list[Path]:
    if explicit:
        result = []
        for path in explicit:
            resolved = path.expanduser().resolve()
            if not resolved.is_dir():
                raise FileNotFoundError(resolved)
            result.append(resolved)
        return result
    return sorted(
        [p for p in (staging_root / "_kanripo_compare").glob("*") if p.is_dir()],
        key=lambda p: p.name,
    )


def primary_palcc_files(work_path: Path) -> list[Path]:
    if not work_path.is_dir():
        return []
    files: list[Path] = []
    for path in work_path.rglob("*.txt"):
        rel_parts = {part.lower() for part in path.relative_to(work_path).parts[:-1]}
        if rel_parts & EXCLUDED_PALCC_DIRS:
            continue
        files.append(path)
    return sorted(files, key=lambda p: p.relative_to(work_path).as_posix())


def is_han(ch: str) -> bool:
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in HAN_RANGES)


def primary_han_chars(files: list[Path]) -> int:
    total = 0
    for path in files:
        try:
            text = path.read_text(encoding="utf-8-sig", errors="replace")
        except OSError:
            continue
        text = unicodedata.normalize("NFC", text)
        total += sum(1 for ch in text if is_han(ch))
    return total


def json_load(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def collect_urls(value: Any) -> list[str]:
    result: list[str] = []
    if isinstance(value, dict):
        for child in value.values():
            result.extend(collect_urls(child))
    elif isinstance(value, list):
        for child in value:
            result.extend(collect_urls(child))
    elif isinstance(value, str) and ("http://" in value or "https://" in value):
        result.append(value.strip())
    return result


def existing_source_witness_labels(metadata: dict[str, Any]) -> list[str]:
    labels: list[str] = []
    for edition in metadata.get("editions") or []:
        if isinstance(edition, dict):
            label = clean(edition.get("edition_label"))
            if label:
                labels.append(label)
    for item in metadata.get("contained_in") or []:
        if isinstance(item, dict):
            label = clean(item.get("edition_label"))
            if label and label not in labels:
                labels.append(label)
    return labels


def archive_text_info(archive: Path) -> dict[str, Any]:
    if not archive.is_file():
        return {
            "archive_present": "no", "archive_zip_bytes": 0, "text_uncompressed_bytes": 0,
            "text_files": 0, "base_edition": "", "archive_title": "",
        }
    base_edition = ""
    archive_title = ""
    text_bytes = 0
    text_files = 0
    first_text = ""
    try:
        with zipfile.ZipFile(archive) as zf:
            names = [
                name for name in zf.namelist()
                if not name.endswith("/") and name.lower().endswith(".txt")
                and Path(name).name.lower() not in {"readme.txt", "license.txt", "licence.txt"}
            ]
            for name in names:
                info = zf.getinfo(name)
                text_bytes += int(info.file_size)
                text_files += 1
                if not first_text:
                    first_text = zf.read(name).decode("utf-8-sig", errors="replace")
        match = BASE_EDITION_RE.search(first_text)
        if match:
            base_edition = match.group(1).strip()
        match = TITLE_RE.search(first_text)
        if match:
            archive_title = match.group(1).strip()
    except Exception:
        pass
    return {
        "archive_present": "yes",
        "archive_zip_bytes": archive.stat().st_size,
        "text_uncompressed_bytes": text_bytes,
        "text_files": text_files,
        "base_edition": base_edition,
        "archive_title": archive_title,
    }


def witness_label_from_code(code: str) -> str:
    code = clean(code)
    known = {
        "WYG": "四庫全書・文淵閣本",
    }
    return known.get(code.upper(), code)


def cached_branch_rows(staging_root: Path, source_id: str) -> list[dict[str, Any]]:
    identifier = canonical_kanripo_id(source_id)
    work_root = staging_root / "kanripo" / "works" / identifier
    manifest = json_load(work_root / "witness_compare_source.json")
    retrieved_at = clean(manifest.get("retrieved_at"))
    rows: list[dict[str, Any]] = []
    for branch in manifest.get("branches") or []:
        if not isinstance(branch, dict):
            continue
        name = clean(branch.get("name"))
        sha = clean(branch.get("sha"))
        if not name or not sha:
            continue
        info = archive_text_info(work_root / "raw" / f"{identifier}-{sha}.zip")
        raw_base = clean(info.get("base_edition"))
        witness_code = raw_base
        witness_evidence = "BASEEDITION" if raw_base else "unknown"
        # Branch names are digital publication labels. We only fall back from a
        # non-master branch when upstream omitted BASEEDITION, and mark that as
        # inference rather than pretending the branch *is* the witness.
        if not witness_code and name.lower() != "master":
            witness_code = name
            witness_evidence = "branch_fallback_inference"
        rows.append({
            "source_id": identifier,
            "digital_branch": name,
            "digital_revision": sha,
            "upstream_baseedition": raw_base,
            "source_witness_code": witness_code,
            "source_witness_label": witness_label_from_code(witness_code),
            "source_witness_evidence": witness_evidence,
            "archive_title": clean(info.get("archive_title")),
            "archive_present": info.get("archive_present", "no"),
            "archive_zip_bytes": info.get("archive_zip_bytes", 0),
            "text_uncompressed_bytes": info.get("text_uncompressed_bytes", 0),
            "kanripo_text_files": info.get("text_files", 0),
            "retrieved_at": retrieved_at,
        })
    return rows


def source_witness_for_comparison(row: dict[str, Any]) -> tuple[str, str, str]:
    raw_base = clean(row.get("base_edition"))
    branch = clean(row.get("branch"))
    if raw_base:
        return raw_base, witness_label_from_code(raw_base), "BASEEDITION"
    if branch and branch.lower() != "master":
        return branch, witness_label_from_code(branch), "branch_fallback_inference"
    return "", "", "unknown"


def classification_key(row: dict[str, Any]) -> tuple[int, float, float, float]:
    return (
        CLASS_RANK.get(clean(row.get("classification")), -1),
        floatish(row.get("containment")),
        floatish(row.get("jaccard")),
        floatish(row.get("length_ratio")),
    )


def preferred_wyg(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    candidates: list[tuple[int, tuple[int, float, float, float], dict[str, Any]]] = []
    for row in rows:
        base = clean(row.get("base_edition"))
        branch = clean(row.get("branch"))
        witness_code, _witness_label, _evidence = source_witness_for_comparison(row)
        if witness_code.upper() != "WYG":
            continue
        # Prefer the current master publication when it explicitly says its base
        # witness is WYG; then any other branch with explicit BASEEDITION=WYG;
        # only then a historical WYG branch inferred from its branch name.
        if branch.lower() == "master" and base.upper() == "WYG":
            priority = 30
        elif base.upper() == "WYG":
            priority = 20
        elif branch.upper() == "WYG":
            priority = 10
        else:
            priority = 0
        candidates.append((priority, classification_key(row), row))
    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return candidates[0][2]


def preferred_cached_wyg(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    candidates: list[tuple[int, dict[str, Any]]] = []
    for row in rows:
        witness_code = clean(row.get("source_witness_code"))
        branch = clean(row.get("digital_branch"))
        base = clean(row.get("upstream_baseedition"))
        if witness_code.upper() != "WYG":
            continue
        if branch.lower() == "master" and base.upper() == "WYG":
            priority = 30
        elif base.upper() == "WYG":
            priority = 20
        elif branch.upper() == "WYG":
            priority = 10
        else:
            priority = 0
        candidates.append((priority, row))
    if not candidates:
        return None
    candidates.sort(key=lambda item: item[0], reverse=True)
    return candidates[0][1]


def preferred_current_transcription(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Choose Kanripo's current digital publication, without confusing it with the source witness.

    `master` is preferred because it is Kanripo's maintained current publication state.
    When no master comparison exists, fall back to the best-supported available branch.
    Duplicate comparison rows for multiple PALCC targets are harmless.
    """
    if not rows:
        return None
    candidates: list[tuple[int, int, tuple[int, float, float, float], dict[str, Any]]] = []
    for row in rows:
        branch = clean(row.get("branch"))
        branch_priority = 20 if branch.lower() == "master" else 10
        han = intish(row.get("kanripo_han_chars"))
        candidates.append((branch_priority, han, classification_key(row), row))
    candidates.sort(key=lambda item: (item[0], item[1], item[2]), reverse=True)
    return candidates[0][3]


def preferred_cached_current(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not rows:
        return None
    candidates: list[tuple[int, int, dict[str, Any]]] = []
    for row in rows:
        branch = clean(row.get("digital_branch"))
        branch_priority = 20 if branch.lower() == "master" else 10
        size = intish(row.get("text_uncompressed_bytes"))
        candidates.append((branch_priority, size, row))
    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return candidates[0][2]


def digital_quality_advantage(
    selected: dict[str, Any] | None,
    readable_infos: list[dict[str, Any]],
) -> dict[str, Any]:
    """Return a strong, conservative completeness signal for canonical transcription choice.

    Length alone is not textual authority. It is used here only when the gap is so large
    that the existing PALCC material is very likely partial/truncated. Close calls remain
    ordinary witness/transcription decisions.
    """
    existing_counts = [intish(info.get("primary_han_chars")) for info in readable_infos]
    existing_counts = [count for count in existing_counts if count > 0]
    best_existing = max(existing_counts, default=0)
    kanripo_han = intish((selected or {}).get("kanripo_han_chars"))
    if not kanripo_han or not best_existing:
        return {
            "decision": "INSUFFICIENT_QUALITY_EVIDENCE",
            "basis": "missing comparable Han-character counts",
            "kanripo_han_chars": kanripo_han,
            "best_existing_han_chars": best_existing,
            "ratio": 0.0,
        }

    ratio = kanripo_han / best_existing
    wikimedia_like = any(
        info.get("palcc_path", "").startswith("corpus/維基大典/")
        or bool(split_pipe(info.get("existing_wikisource_urls", "")))
        for info in readable_infos
    )

    # A fourfold gap is strong enough to treat an existing text as clearly partial
    # regardless of provider. For Wikisource/Wikimedia-derived material, a threefold
    # gap is sufficient because incomplete page transcriptions are a known corpus state.
    # Tiny fragments get an additional conservative rule.
    clearly_more_complete = (
        kanripo_han >= 1000
        and (
            ratio >= 4.0
            or (wikimedia_like and ratio >= 3.0)
            or (best_existing < 2000 and ratio >= 3.0)
        )
    )
    if clearly_more_complete:
        return {
            "decision": "KANRIPO_CLEARLY_MORE_COMPLETE",
            "basis": (
                "current Kanripo transcription is dramatically more complete than the best readable PALCC exact-title candidate; "
                "preserve the shorter digital text as an alternate/partial transcription rather than letting it block the canonical text"
            ),
            "kanripo_han_chars": kanripo_han,
            "best_existing_han_chars": best_existing,
            "ratio": ratio,
        }
    return {
        "decision": "NO_CLEAR_QUALITY_WINNER",
        "basis": "length/completeness evidence is not strong enough to choose a canonical transcription automatically",
        "kanripo_han_chars": kanripo_han,
        "best_existing_han_chars": best_existing,
        "ratio": ratio,
    }


def candidate_status(repo_root: Path, rel: str, *, measure_han: bool = False) -> dict[str, Any]:
    work_path = (repo_root / rel).resolve()
    try:
        work_path.relative_to(repo_root)
    except ValueError:
        raise RuntimeError(f"Candidate path escapes repository: {rel}")
    files = primary_palcc_files(work_path)
    metadata = json_load(work_path / "metadata.json")
    urls = sorted(set(collect_urls(metadata)))
    wik = [url for url in urls if "wikisource.org" in url.lower()]
    primary_bytes = 0
    for path in files:
        try:
            primary_bytes += path.stat().st_size
        except OSError:
            pass
    han_chars = primary_han_chars(files) if measure_han else 0
    return {
        "palcc_path": rel,
        "work_exists": "yes" if work_path.is_dir() else "no",
        "metadata_exists": "yes" if (work_path / "metadata.json").is_file() else "no",
        "primary_text_file_count": len(files),
        "primary_text_bytes": primary_bytes,
        "primary_han_chars": han_chars,
        "metadata_only_stub": "yes" if work_path.is_dir() and (work_path / "metadata.json").is_file() and not files else "no",
        "work_id": clean(metadata.get("work_id")),
        "corpus_root": clean(metadata.get("corpus_root")),
        "existing_source_witness_labels": " | ".join(existing_source_witness_labels(metadata)),
        "existing_source_urls": " | ".join(urls),
        "existing_wikisource_urls": " | ".join(wik),
        "existing_wikisource_capture_date": clean(
            metadata.get("retrieved_at") or metadata.get("scraped_at") or metadata.get("snapshot_date")
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--staging-root", type=Path, required=True)
    parser.add_argument("--inventory-dir", type=Path, default=None)
    parser.add_argument("--comparison-dir", type=Path, action="append", default=[],
                        help="Optional comparison directory; repeat to limit aggregation. Default: all completed runs.")
    args = parser.parse_args()

    repo_root = args.repo_root.expanduser().resolve()
    staging_root = args.staging_root.expanduser().resolve()
    inventory = resolve_inventory(staging_root, args.inventory_dir)
    refined = inventory / "refined"
    queue = read_csv(refined / "kanripo_existing_title_witnesses.csv")
    if not queue:
        raise SystemExit("Refined Kanripo exact-title queue is empty or missing")

    runs = comparison_dirs(staging_root, args.comparison_dir)
    comparisons_by_source: dict[str, list[dict[str, Any]]] = defaultdict(list)
    errors_by_source: dict[str, list[dict[str, Any]]] = defaultdict(list)
    comparison_seen: set[tuple[str, str, str, str]] = set()
    error_seen: set[tuple[str, str]] = set()

    for run in runs:
        for row in read_csv(run / "kanripo_witness_comparisons.csv"):
            sid = canonical_kanripo_id(row.get("source_id", ""))
            row["source_id"] = sid
            key = (sid, clean(row.get("branch")), clean(row.get("branch_commit")), clean(row.get("palcc_path")))
            if key in comparison_seen:
                continue
            comparison_seen.add(key)
            comparisons_by_source[sid].append(row)
        for row in read_csv(run / "errors.csv"):
            sid = canonical_kanripo_id(row.get("source_id", ""))
            row["source_id"] = sid
            key = (sid, clean(row.get("error")))
            if key in error_seen:
                continue
            error_seen.add(key)
            errors_by_source[sid].append(row)

    run_dir = staging_root / "_merge_plan" / stamp_now()
    run_dir.mkdir(parents=True, exist_ok=False)

    plan_rows: list[dict[str, Any]] = []
    digital_rows: list[dict[str, Any]] = []
    unresolved_rows: list[dict[str, Any]] = []

    queue_by_source = {canonical_kanripo_id(row.get("source_id", "")): row for row in queue}

    # Every comparison row becomes an explicit physical-to-digital provenance row.
    # The source witness and the digital publication state are deliberately separate.
    for sid, rows in sorted(comparisons_by_source.items()):
        cached_by_key = {
            (clean(r.get("digital_branch")), clean(r.get("digital_revision"))): r
            for r in cached_branch_rows(staging_root, sid)
        }
        for row in rows:
            witness_code, witness_label, witness_evidence = source_witness_for_comparison(row)
            branch = clean(row.get("branch"))
            sha = clean(row.get("branch_commit"))
            cache = cached_by_key.get((branch, sha), {})
            digital_rows.append({
                "source_id": sid,
                "source_title": clean(row.get("source_title")),
                "palcc_path": clean(row.get("palcc_path")),
                "source_witness_code": witness_code,
                "source_witness_label": witness_label,
                "source_witness_evidence": witness_evidence,
                "upstream_baseedition": clean(row.get("base_edition")),
                "digital_transcription_provider": "Kanseki Repository",
                "digital_edition_label": branch,
                "digital_revision": sha,
                "digital_transcription_id": f"kanripo:{sid}:{branch}@{sha}" if sha else "",
                "retrieved_at": clean(cache.get("retrieved_at")),
                "classification": clean(row.get("classification")),
                "length_ratio": clean(row.get("length_ratio")),
                "jaccard": clean(row.get("jaccard")),
                "containment": clean(row.get("containment")),
                "kanripo_text_files": clean(row.get("kanripo_text_files")),
                "kanripo_han_chars": clean(row.get("kanripo_han_chars")),
                "archive_present": clean(cache.get("archive_present")),
                "archive_zip_bytes": clean(cache.get("archive_zip_bytes")),
                "text_uncompressed_bytes": clean(cache.get("text_uncompressed_bytes")),
                "role": "candidate_digital_transcription",
            })

    for sid, source in sorted(queue_by_source.items()):
        title = clean(source.get("source_title"))
        candidate_paths = split_pipe(source.get("candidate_paths", ""))
        if not candidate_paths and clean(source.get("palcc_path")):
            candidate_paths = [clean(source.get("palcc_path"))]
        comp_rows = comparisons_by_source.get(sid, [])
        cached_rows = cached_branch_rows(staging_root, sid)
        wyg = preferred_wyg(comp_rows)
        cached_wyg = preferred_cached_wyg(cached_rows)
        chosen_wyg = wyg or cached_wyg
        current = preferred_current_transcription(comp_rows) or preferred_cached_current(cached_rows)

        # Counting Han characters across the entire corpus would make this cheap planner
        # unnecessarily expensive. First use the already-computed comparison ratio as a
        # tripwire: only inspect PALCC text content when the current Kanripo transcription
        # and a readable candidate differ by roughly 3x or more. Then determine which side
        # is actually longer.
        current_branch = clean((current or {}).get("branch") or (current or {}).get("digital_branch"))
        current_revision = clean((current or {}).get("branch_commit") or (current or {}).get("digital_revision"))
        current_comparisons = [
            row for row in comp_rows
            if clean(row.get("branch")) == current_branch
            and (not current_revision or clean(row.get("branch_commit")) == current_revision)
        ]
        measure_han = any(0 < floatish(row.get("length_ratio")) <= 0.34 for row in current_comparisons)
        candidate_infos = [candidate_status(repo_root, rel, measure_han=measure_han) for rel in candidate_paths]
        error_texts = [clean(r.get("error")) for r in errors_by_source.get(sid, [])]
        error_text = " | ".join(error_texts)
        no_read_error = any("no readable primary PALCC text" in err for err in error_texts)
        missing_repo = any("could not read Username for 'https://github.com'" in err for err in error_texts)

        stub_infos = [c for c in candidate_infos if c["metadata_only_stub"] == "yes"]
        readable_infos = [c for c in candidate_infos if intish(c["primary_text_file_count"]) > 0]
        siku_readable = [c for c in readable_infos if c["palcc_path"].startswith("corpus/四庫全書/")]
        non_siku_readable = [c for c in readable_infos if not c["palcc_path"].startswith("corpus/四庫全書/")]
        quality = digital_quality_advantage(current, readable_infos)
        clear_quality_win = quality["decision"] == "KANRIPO_CLEARLY_MORE_COMPLETE"

        # A metadata-only exact-title record is not automatically the target for a
        # Kanripo transcription.  The same work may also have a readable Siku
        # witness, and BASEEDITION=WYG belongs to that Siku witness rather than to
        # the empty general-China record.  This distinction prevents a digital
        # transcription of one physical/textual witness being poured into a
        # different witness merely because both share a title.
        all_candidates_are_stubs = bool(candidate_infos) and len(stub_infos) == len(candidate_infos)
        mixed_stub_and_readable = bool(stub_infos and readable_infos)

        if all_candidates_are_stubs:
            if len(stub_infos) > 1:
                action = "REVIEW_MULTI_STUB_WITNESS_PLACEMENT"
                note = (
                    "Exact-title PALCC records exist, but every candidate is metadata-only. "
                    "Fill text without creating a duplicate work; choose which source-witness/corpus "
                    "record the digital transcription belongs under first."
                )
            else:
                action = "FILL_METADATA_ONLY_WORK"
                note = (
                    "PALCC has metadata/provenance but no primary text. Reuse the existing work_id; "
                    "attach the Kanripo digital transcription to its source witness rather than creating a duplicate work."
                )
        elif mixed_stub_and_readable and siku_readable and chosen_wyg:
            action = "PROMOTE_KANRIPO_WYG_DIGITAL_TRANSCRIPTION"
            note = (
                "A metadata-only title twin also exists, but Kanripo identifies this transcription with the "
                "四庫全書・文淵閣本 witness. Attach/promote it under the readable Siku witness; do not fill the "
                "metadata-only non-Siku record with a WYG transcription merely because the titles match. "
                "Preserve that empty record for separate witness/work resolution."
            )
        elif mixed_stub_and_readable and clear_quality_win:
            action = "PREFER_KANRIPO_COMPLETE_DIGITAL_TRANSCRIPTION"
            note = (
                "A readable exact-title digital text exists, but it is dramatically shorter than Kanripo's current transcription. "
                "Use Kanripo as the canonical PALCC transcription and preserve the shorter readable candidate as a partial/alternate "
                "digital transcription with its own source-witness provenance. Do not let a fragment block a complete text."
            )
        elif mixed_stub_and_readable:
            action = "REVIEW_MIXED_STUB_AND_READABLE_TARGETS"
            note = (
                "Some exact-title PALCC candidates have text and some are metadata-only. There is no strong completeness/maintenance "
                "signal establishing a canonical digital transcription, so keep the witness-placement decision explicit."
            )
        elif siku_readable and chosen_wyg:
            action = "PROMOTE_KANRIPO_WYG_DIGITAL_TRANSCRIPTION"
            note = (
                "The source witness is 四庫全書・文淵閣本 (upstream BASEEDITION=WYG or explicit WYG fallback). "
                "Use the preferred current Kanripo digital transcription as PALCC's maintained representation of that witness; "
                "preserve the older Wikisource digital transcription with its snapshot provenance."
            )
        elif readable_infos and clear_quality_win:
            action = "PREFER_KANRIPO_COMPLETE_DIGITAL_TRANSCRIPTION"
            note = (
                "Kanripo's current digital transcription is clearly more complete than the readable PALCC exact-title material. "
                "Prefer it as the canonical work transcription while retaining existing shorter texts as alternate/partial digital "
                "transcriptions tied to their own source witnesses."
            )
        elif non_siku_readable and chosen_wyg:
            action = "ADD_WYG_SOURCE_WITNESS"
            note = (
                "Kanripo supplies a digital transcription derived from the 四庫全書・文淵閣本 witness, but the matched PALCC "
                "record is outside the Siku corpus root. Add/associate that source witness rather than silently replacing another witness."
            )
        elif readable_infos and comp_rows:
            action = "ADD_KANRIPO_DIGITAL_TRANSCRIPTION_OR_SOURCE_WITNESS"
            note = (
                "Readable PALCC text exists. If BASEEDITION points to the same source witness, add Kanripo as another digital "
                "transcription edition/revision; if it points to a different witness, add that witness separately."
            )
        elif missing_repo:
            action = "UPSTREAM_REPOSITORY_UNAVAILABLE"
            note = "Kanripo catalogue entry has no public GitHub mirror at harvest time. Keep as unresolved source metadata; no corpus action."
        elif no_read_error:
            action = "FILL_METADATA_ONLY_WORK"
            note = "Comparator could not read PALCC text; local path inspection should determine whether this is a metadata-only work stub."
        else:
            action = "UNRESOLVED"
            note = "No safe automated incorporation action determined."

        preferred_path = ""
        if action == "PROMOTE_KANRIPO_WYG_DIGITAL_TRANSCRIPTION" and len(siku_readable) == 1:
            preferred_path = siku_readable[0]["palcc_path"]
        elif action == "PREFER_KANRIPO_COMPLETE_DIGITAL_TRANSCRIPTION":
            # Prefer an existing general-China work record for the canonical work.
            # Source-specific roots such as 維基大典 remain alternate digital witnesses.
            china_stubs = [c for c in stub_infos if c.get("corpus_root") == "中國漢文"]
            china_readable = [c for c in readable_infos if c.get("corpus_root") == "中國漢文"]
            if len(china_stubs) == 1:
                preferred_path = china_stubs[0]["palcc_path"]
            elif len(china_readable) == 1:
                preferred_path = china_readable[0]["palcc_path"]
            elif len(candidate_infos) == 1:
                preferred_path = candidate_infos[0]["palcc_path"]
        elif len(candidate_infos) == 1:
            preferred_path = candidate_infos[0]["palcc_path"]
        elif stub_infos:
            # Prefer an existing China-root work record over a Korea-root bibliographic
            # duplicate, but never auto-pick between China and Siku witness records.
            china = [c for c in stub_infos if c.get("corpus_root") == "中國漢文"]
            siku = [c for c in stub_infos if c.get("corpus_root") == "四庫全書"]
            if len(china) == 1 and not siku:
                preferred_path = china[0]["palcc_path"]

        selected_branch = ""
        selected_commit = ""
        selected_witness_code = ""
        selected_witness_label = ""
        selected_witness_evidence = ""
        selected_digital = chosen_wyg if action == "PROMOTE_KANRIPO_WYG_DIGITAL_TRANSCRIPTION" else current
        if selected_digital:
            if "branch" in selected_digital:
                selected_branch = clean(selected_digital.get("branch"))
                selected_commit = clean(selected_digital.get("branch_commit"))
                selected_witness_code, selected_witness_label, selected_witness_evidence = source_witness_for_comparison(selected_digital)
            else:
                selected_branch = clean(selected_digital.get("digital_branch"))
                selected_commit = clean(selected_digital.get("digital_revision"))
                selected_witness_code = clean(selected_digital.get("source_witness_code"))
                selected_witness_label = clean(selected_digital.get("source_witness_label"))
                selected_witness_evidence = clean(selected_digital.get("source_witness_evidence"))

        selected_text_bytes = 0
        selected_zip_bytes = 0
        selected_retrieved_at = ""
        if selected_branch and selected_commit:
            for cached in cached_rows:
                if clean(cached.get("digital_branch")) == selected_branch and clean(cached.get("digital_revision")) == selected_commit:
                    selected_text_bytes = intish(cached.get("text_uncompressed_bytes"))
                    selected_zip_bytes = intish(cached.get("archive_zip_bytes"))
                    selected_retrieved_at = clean(cached.get("retrieved_at"))
                    break

        existing_primary_bytes = sum(intish(c.get("primary_text_bytes")) for c in candidate_infos)
        existing_wikisource = sorted({url for c in candidate_infos for url in split_pipe(c.get("existing_wikisource_urls", ""))})
        capture_dates = sorted({clean(c.get("existing_wikisource_capture_date")) for c in candidate_infos if clean(c.get("existing_wikisource_capture_date"))})

        plan_row = {
            "source_id": sid,
            "source_title": title,
            "action": action,
            "preferred_palcc_path": preferred_path,
            "candidate_count": len(candidate_infos),
            "candidate_paths": " | ".join(c["palcc_path"] for c in candidate_infos),
            "metadata_only_candidate_count": len(stub_infos),
            "readable_candidate_count": len(readable_infos),
            "existing_primary_text_files": sum(intish(c["primary_text_file_count"]) for c in candidate_infos),
            "existing_primary_bytes": existing_primary_bytes,
            "existing_max_primary_han_chars": quality["best_existing_han_chars"],
            "preferred_kanripo_han_chars": quality["kanripo_han_chars"],
            "completeness_ratio_vs_best_existing": round(floatish(quality["ratio"]), 3),
            "digital_quality_decision": quality["decision"],
            "digital_quality_basis": quality["basis"],
            "existing_source_witness_labels": " | ".join(sorted({clean(c.get("existing_source_witness_labels")) for c in candidate_infos if clean(c.get("existing_source_witness_labels"))})),
            "existing_wikisource_sources": " | ".join(existing_wikisource),
            "existing_wikisource_capture_date": " | ".join(capture_dates),
            "capture_date_status": "recorded" if capture_dates else ("not_recorded_in_current_metadata" if existing_wikisource else "not_applicable"),
            "preferred_source_witness_code": selected_witness_code,
            "preferred_source_witness_label": selected_witness_label,
            "preferred_source_witness_evidence": selected_witness_evidence,
            "preferred_digital_transcription_provider": "Kanseki Repository" if selected_digital else "",
            "preferred_digital_edition_label": selected_branch,
            "preferred_digital_revision": selected_commit,
            "preferred_digital_transcription_id": f"kanripo:{sid}:{selected_branch}@{selected_commit}" if selected_commit else "",
            "preferred_digital_transcription_retrieved_at": selected_retrieved_at,
            "preferred_digital_transcription_text_bytes": selected_text_bytes,
            "preferred_digital_transcription_zip_bytes": selected_zip_bytes,
            "estimated_working_tree_added_bytes_if_preserved": selected_text_bytes,
            "comparison_rows": len(comp_rows),
            "best_comparison": max((clean(r.get("classification")) for r in comp_rows), key=lambda x: CLASS_RANK.get(x, -1), default=""),
            "source_fetch_needed": "yes" if not cached_rows and not missing_repo else "no",
            "error": error_text,
            "note": note,
        }
        plan_rows.append(plan_row)
        if action in {"UPSTREAM_REPOSITORY_UNAVAILABLE", "UNRESOLVED", "REVIEW_MULTI_STUB_WITNESS_PLACEMENT", "REVIEW_MIXED_STUB_AND_READABLE_TARGETS"}:
            unresolved_rows.append(plan_row)

    action_counts = Counter(row["action"] for row in plan_rows)
    # "metadata_only_fill_candidates" means the source has no readable PALCC
    # exact-title target at all.  Mixed cases are reported separately so the
    # fetcher does not mistake an empty title twin for the source-witness target.
    metadata_only_rows = [
        row for row in plan_rows
        if intish(row["metadata_only_candidate_count"]) > 0
        and intish(row["readable_candidate_count"]) == 0
    ]
    mixed_stub_rows = [
        row for row in plan_rows
        if intish(row["metadata_only_candidate_count"]) > 0
        and intish(row["readable_candidate_count"]) > 0
    ]
    siku_rows = [row for row in plan_rows if row["action"] == "PROMOTE_KANRIPO_WYG_DIGITAL_TRANSCRIPTION"]
    quality_rows = [row for row in plan_rows if row["action"] == "PREFER_KANRIPO_COMPLETE_DIGITAL_TRANSCRIPTION"]
    alternate_rows = [row for row in plan_rows if row["action"] in {"ADD_WYG_SOURCE_WITNESS", "ADD_KANRIPO_DIGITAL_TRANSCRIPTION_OR_SOURCE_WITNESS"}]

    write_csv(run_dir / "kanripo_merge_plan.csv", plan_rows)
    write_csv(run_dir / "metadata_only_fill_candidates.csv", metadata_only_rows)
    write_csv(run_dir / "mixed_stub_and_readable_candidates.csv", mixed_stub_rows)
    write_csv(run_dir / "siku_preferred_digital_transcription_candidates.csv", siku_rows)
    write_csv(run_dir / "quality_preferred_digital_transcription_candidates.csv", quality_rows)
    write_csv(run_dir / "alternate_source_witness_candidates.csv", alternate_rows)
    write_csv(run_dir / "witness_digital_transcription_candidates.csv", digital_rows)
    write_csv(run_dir / "unresolved_or_unavailable.csv", unresolved_rows)

    # This is a model example only, written to staging. It is deliberately not a
    # corpus mutation or a schema migration. Existing editions[] can remain for
    # backward compatibility, but semantically this example treats them as source
    # witness/source-edition records and keeps digital transcriptions underneath.
    metadata_model = {
        "schema_note": "Illustrative future metadata shape; not applied by this planner.",
        "provenance_chain": "work -> source witness/source edition -> digital transcription edition -> revision/snapshot",
        "legacy_mapping_note": (
            "Existing PALCC editions[] may continue to store source-witness/source-edition records. "
            "Do not use a digital provider or branch name as if it were a physical/textual witness."
        ),
        "source_witness_example": {
            "witness_id": "existing or future PALCC witness/edition id",
            "witness_label": "四庫全書・文淵閣本",
            "witness_type": "documentary/textual witness",
            "collection": "四庫全書",
            "upstream_siglum": "WYG",
            "documents": ["canonical PALCC document records remain here for backward compatibility"],
            "digital_transcriptions": [
                {
                    "digital_transcription_id": "kanripo:KRxxxxxx:master@COMMIT",
                    "provider": "Kanseki Repository",
                    "digital_edition_label": "master",
                    "revision": "COMMIT",
                    "retrieved_at": "UTC timestamp",
                    "role": "preferred",
                    "derived_from_witness": "四庫全書・文淵閣本",
                    "upstream_baseedition": "WYG",
                    "paths": ["canonical primary .txt paths"],
                },
                {
                    "digital_transcription_id": "kanripo:KRxxxxxx:WYG@OLDER_COMMIT",
                    "provider": "Kanseki Repository",
                    "digital_edition_label": "WYG",
                    "revision": "OLDER_COMMIT",
                    "role": "historical_digital_edition",
                    "derived_from_witness": "四庫全書・文淵閣本",
                },
                {
                    "digital_transcription_id": "wikisource:historical-capture",
                    "provider": "Chinese Wikisource",
                    "digital_edition_label": "Wikisource",
                    "role": "historical_digital_edition",
                    "retrieved_at": None,
                    "retrieved_at_status": "not_recorded_in_current_metadata",
                    "derived_from_witness": "same source witness when established",
                    "source_urls": ["existing metadata source URLs"],
                    "paths": ["variants/transcriptions/wikisource-<date-or-undated>/..."],
                },
            ],
        },
    }
    (run_dir / "metadata_model_example.json").write_text(
        json.dumps(metadata_model, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    summary = {
        "created_at": utc_now(),
        "repo_root": str(repo_root),
        "staging_root": str(staging_root),
        "inventory": str(inventory),
        "comparison_runs": [str(p) for p in runs],
        "exact_title_queue_rows": len(queue),
        "planned_rows": len(plan_rows),
        "comparison_source_ids": len(comparisons_by_source),
        "error_source_ids": len(errors_by_source),
        "actions": dict(action_counts),
        "metadata_only_source_ids": len({row["source_id"] for row in metadata_only_rows}),
        "mixed_stub_and_readable_source_ids": len({row["source_id"] for row in mixed_stub_rows}),
        "siku_preferred_digital_transcription_candidates": len(siku_rows),
        "quality_preferred_digital_transcription_candidates": len(quality_rows),
        "alternate_source_witness_candidates": len(alternate_rows),
        "witness_digital_transcription_records": len(digital_rows),
        "estimated_siku_working_tree_added_bytes": sum(intish(row["estimated_working_tree_added_bytes_if_preserved"]) for row in siku_rows),
        "existing_siku_primary_bytes_for_candidates": sum(intish(row["existing_primary_bytes"]) for row in siku_rows),
        "corpus_files_changed": 0,
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    lines = [
        "KANRIPO INCORPORATION PLAN",
        "===========================",
        "",
        f"Exact-title queue rows:                    {len(queue):,}",
        f"Comparison source IDs aggregated:          {len(comparisons_by_source):,}",
        f"Error source IDs aggregated:               {len(errors_by_source):,}",
        f"Metadata-only PALCC source IDs:            {summary['metadata_only_source_ids']:,}",
        f"Mixed stub + readable source IDs:          {summary['mixed_stub_and_readable_source_ids']:,}",
        f"Siku preferred digital transcriptions:     {len(siku_rows):,}",
        f"Quality-preferred digital transcriptions:  {len(quality_rows):,}",
        f"Alternate source-witness candidates:       {len(alternate_rows):,}",
        f"Witness/digital-transcription records:      {len(digital_rows):,}",
        f"Preferred Siku Kanripo text bytes:          {summary['estimated_siku_working_tree_added_bytes']:,}",
        f"Existing PALCC bytes for those candidates:  {summary['existing_siku_primary_bytes_for_candidates']:,}",
        "Corpus files changed:                      0",
        "",
        "Actions",
    ]
    for action, count in sorted(action_counts.items()):
        lines.append(f"  {action:<52} {count:,}")
    lines.extend([
        "",
        "Provenance model",
        "  work -> source witness/source edition -> digital transcription edition -> revision/snapshot",
        "  Examples of source witnesses: bamboo-slip manuscript, silk manuscript, Song print, Yongle Dadian witness, 四庫全書・文淵閣本.",
        "  Examples of digital transcription editions: Kanripo master/WYG branches, Wikisource.",
        "  Kanripo BASEEDITION is preserved verbatim as upstream evidence for the source witness.",
        "  A branch named WYG and BASEEDITION=WYG are stored in different fields because they are different facts.",
        "  Existing Wikisource text is preserved as a historical digital transcription when a Kanripo transcription becomes preferred.",
        "  Missing scrape dates are reported as unknown; the planner never invents them.",
        "  A clearly partial/truncated digital text never blocks a demonstrably more complete maintained transcription.",
        "  Completeness only auto-decides extreme gaps; close textual-edition differences remain explicit witness decisions.",
        "",
        f"Reports: {run_dir}",
        "",
    ])
    (run_dir / "summary.txt").write_text("\n".join(lines), encoding="utf-8")

    state_dir = staging_root / "_state"
    state_dir.mkdir(parents=True, exist_ok=True)
    state = {
        "status": "complete",
        "created_at": summary["created_at"],
        "output_dir": str(run_dir),
        "inventory": str(inventory),
        "corpus_files_changed": 0,
    }
    tmp = state_dir / "last_kanripo_merge_plan.json.tmp"
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, state_dir / "last_kanripo_merge_plan.json")

    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
