#!/usr/bin/env python3
"""Download selected Kanripo edition snapshots and compare them with PALCC works.

This is deliberately a staging/reporting tool. It never writes inside corpus work
folders. The input is the refined exact-title queue produced by refine_inventory.py.

Design goals:
- queue-aware: only download records already selected for witness comparison;
- branch-aware: compare every textual edition branch, not just master;
- reproducible: snapshot branch commit SHAs and use commit-pinned codeload ZIPs;
- resumable: downloaded archives and branch manifests persist in staging;
- conservative: comparison labels describe overlap, never authorize overwriting PALCC;
- stoppable: SIGINT/SIGTERM terminate the run rather than skipping to the next work.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import signal
import sys
import time
import unicodedata
import zipfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

# Sibling helper module from the source harvester. It already provides commit-pinned
# GitHub codeload URLs, resumable downloads, git ls-remote, and atomic JSON writes.
from harvest_sources import (  # type: ignore
    StopRequested,
    atomic_json,
    download,
    github_codeload,
    remote_branches,
)

QUEUE_NAME = "kanripo_existing_title_witnesses.csv"
ADMIN_BRANCH_PREFIX = "_"
EXCLUDED_PALCC_DIRS = {
    "variants", "kanbun", "hanvan", "hanmun", "annotations", "annotation",
    "translations", "translation", "images", "image", "raw", "sources", "source",
}
KANRIPO_ID_RE = re.compile(r"^KR([1-6])([A-Za-z])(\d{4})$")
TAG_RE = re.compile(r"<[^>]*>")
BASE_EDITION_RE = re.compile(r"^#\+PROPERTY:\s*BASEEDITION\s+(.+?)\s*$", re.I | re.M)
TITLE_RE = re.compile(r"^#\+TITLE:\s*(.+?)\s*$", re.I | re.M)

# Keep CJK unified/compatibility ideographs. Punctuation, whitespace, page markers,
# Latin metadata, and editorial spacing are intentionally ignored for the *comparison*
# stream only. Original source ZIPs remain untouched in staging.
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
    "ERROR": -1,
}

STOP_REQUESTED = False


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def stamp_now() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def log(message: str) -> None:
    print(f"[{utc_now()}] {message}", flush=True)


def install_signal_handlers() -> None:
    def handler(signum: int, _frame: Any) -> None:
        global STOP_REQUESTED
        STOP_REQUESTED = True
        name = signal.Signals(signum).name
        log(f"Received {name}; stopping Kanripo witness comparison.")
        raise StopRequested(name)
    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)


def canonical_kanripo_id(value: str) -> str:
    value = (value or "").strip()
    m = KANRIPO_ID_RE.match(value)
    if not m:
        raise ValueError(f"Invalid Kanripo ID: {value!r}")
    return f"KR{m.group(1)}{m.group(2).lower()}{m.group(3)}"


def split_pipe(value: str) -> list[str]:
    return [part.strip() for part in (value or "").split(" | ") if part.strip()]


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def resolve_queue(staging_root: Path, explicit: Path | None) -> Path:
    if explicit:
        path = explicit.expanduser().resolve()
        if not path.is_file():
            raise FileNotFoundError(path)
        return path

    state = staging_root / "_state" / "last_inventory.json"
    if state.is_file():
        try:
            payload = json.loads(state.read_text(encoding="utf-8"))
            output = Path(payload.get("output_dir", ""))
            candidate = output / "refined" / QUEUE_NAME
            if candidate.is_file():
                return candidate
        except Exception:
            pass

    # Robust fallback: a missing/stale convenience pointer must not force another
    # 256k-file corpus scan. Reuse the newest completed refined queue on disk.
    candidates = sorted(
        (staging_root / "_inventory").glob(f"*/refined/{QUEUE_NAME}"),
        key=lambda p: p.parent.parent.name,
        reverse=True,
    )
    if candidates:
        return candidates[0]
    raise FileNotFoundError(
        f"Could not find {QUEUE_NAME} under {staging_root / '_inventory'}"
    )


def is_han(ch: str) -> bool:
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in HAN_RANGES)


def han_stream(text: str) -> str:
    text = unicodedata.normalize("NFC", TAG_RE.sub("", text))
    return "".join(ch for ch in text if is_han(ch))


def strip_palcc_header(text: str) -> str:
    lines = text.splitlines()
    i = 0
    while i < len(lines) and (not lines[i].strip() or lines[i].startswith("#")):
        i += 1
    return "\n".join(lines[i:])


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


def load_palcc_text(work_path: Path) -> tuple[str, list[str]]:
    files = primary_palcc_files(work_path)
    pieces: list[str] = []
    for path in files:
        try:
            raw = path.read_text(encoding="utf-8-sig", errors="replace")
        except OSError:
            continue
        pieces.append(strip_palcc_header(raw))
    return han_stream("\n".join(pieces)), [p.relative_to(work_path).as_posix() for p in files]


def textual_zip_members(zf: zipfile.ZipFile) -> list[str]:
    names = []
    for name in zf.namelist():
        if name.endswith("/") or not name.lower().endswith(".txt"):
            continue
        base = Path(name).name.lower()
        if base in {"readme.txt", "license.txt", "licence.txt"}:
            continue
        names.append(name)
    return sorted(names)


def load_kanripo_archive(archive: Path) -> tuple[str, dict[str, Any]]:
    pieces: list[str] = []
    first_text = ""
    members: list[str] = []
    with zipfile.ZipFile(archive) as zf:
        members = textual_zip_members(zf)
        for name in members:
            raw = zf.read(name)
            text = raw.decode("utf-8-sig", errors="replace")
            if not first_text:
                first_text = text
            # Remove org-mode metadata lines while preserving the historical text.
            body_lines = [line for line in text.splitlines() if not line.startswith("#+")]
            pieces.append("\n".join(body_lines))
    base = BASE_EDITION_RE.search(first_text)
    title = TITLE_RE.search(first_text)
    meta = {
        "base_edition": base.group(1).strip() if base else "",
        "archive_title": title.group(1).strip() if title else "",
        "text_files": len(members),
    }
    return han_stream("\n".join(pieces)), meta


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def shingles(text: str, *, n: int = 8, maximum: int = 30000) -> set[str]:
    if not text:
        return set()
    if len(text) <= n:
        return {text}
    total = len(text) - n + 1
    stride = max(1, total // maximum)
    return {text[i:i+n] for i in range(0, total, stride)}


def compare_streams(source: str, palcc: str) -> dict[str, Any]:
    slen, plen = len(source), len(palcc)
    minimum = min(slen, plen)
    maximum = max(slen, plen)
    length_ratio = (minimum / maximum) if maximum else 0.0
    if minimum == 0:
        return {
            "classification": "COULD_NOT_ALIGN", "length_ratio": length_ratio,
            "jaccard": 0.0, "containment": 0.0,
        }
    if source == palcc:
        return {
            "classification": "IDENTICAL", "length_ratio": 1.0,
            "jaccard": 1.0, "containment": 1.0,
        }
    if minimum < 80:
        return {
            "classification": "TOO_SHORT_TO_JUDGE", "length_ratio": length_ratio,
            "jaccard": 0.0, "containment": 0.0,
        }

    a = shingles(source)
    b = shingles(palcc)
    inter = len(a & b)
    union = len(a | b)
    jaccard = inter / union if union else 0.0
    containment = inter / min(len(a), len(b)) if a and b else 0.0

    if length_ratio >= 0.90 and jaccard >= 0.85:
        cls = "NEAR_IDENTICAL"
    elif containment >= 0.85:
        cls = "SUBSTANTIAL_OVERLAP"
    elif jaccard >= 0.45 or containment >= 0.60:
        cls = "TEXTUAL_DIFFERENCE"
    elif containment >= 0.25:
        cls = "PARTIAL_OVERLAP"
    else:
        cls = "COULD_NOT_ALIGN"
    return {
        "classification": cls,
        "length_ratio": round(length_ratio, 6),
        "jaccard": round(jaccard, 6),
        "containment": round(containment, 6),
    }


def branch_manifest_path(work_root: Path) -> Path:
    return work_root / "witness_compare_source.json"


def load_or_fetch_branches(
    work_root: Path,
    identifier: str,
    *,
    refresh: bool,
    offline: bool,
) -> list[dict[str, str]]:
    manifest_path = branch_manifest_path(work_root)
    if manifest_path.is_file() and not refresh:
        try:
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            branches = payload.get("branches") or []
            if branches:
                return branches
        except Exception:
            pass
    if offline:
        raise RuntimeError("no cached branch manifest available in --offline mode")

    repo_url = f"https://github.com/kanripo/{identifier}.git"
    last_error: Exception | None = None
    raw_branches: list[dict[str, str]] = []
    for attempt in range(1, 6):
        try:
            raw_branches = remote_branches(repo_url)
            last_error = None
            break
        except StopRequested:
            raise
        except Exception as exc:
            last_error = exc
            if attempt >= 5:
                break
            wait = min(60.0, float(2 ** attempt))
            log(f"Branch discovery failed for {identifier}: {exc}; waiting {wait:.0f}s before retry {attempt + 1}/5.")
            time.sleep(wait)
    if last_error is not None:
        raise RuntimeError(f"branch discovery failed after retries: {last_error}")
    branches = [
        b for b in raw_branches
        if b.get("name") and not b["name"].startswith(ADMIN_BRANCH_PREFIX)
    ]
    if not branches:
        raise RuntimeError("no textual branch heads returned")
    atomic_json(
        manifest_path,
        {
            "source": "Kanseki Repository",
            "work_id": identifier,
            "repository": repo_url,
            "retrieved_at": utc_now(),
            "branches": branches,
            "note": "underscore-prefixed administrative branches excluded from witness comparison",
        },
    )
    return branches


def ensure_archive(
    work_root: Path,
    identifier: str,
    sha: str,
    *,
    offline: bool,
) -> Path:
    archive = work_root / "raw" / f"{identifier}-{sha}.zip"
    if archive.is_file():
        return archive
    if offline:
        raise RuntimeError(f"archive not cached in --offline mode: {archive.name}")
    url = github_codeload("kanripo", identifier, sha)
    download(url, archive, retries=7, timeout=120)
    return archive


def comparison_sort_key(row: dict[str, Any]) -> tuple[int, float, float, float]:
    return (
        CLASS_RANK.get(str(row.get("classification")), -2),
        float(row.get("containment") or 0),
        float(row.get("jaccard") or 0),
        float(row.get("length_ratio") or 0),
    )


def state_payload(
    *, status: str, output_dir: Path, queue: Path, selected: int,
    processed: int, failures: int, started_at: str, error: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "status": status,
        "started_at": started_at,
        "updated_at": utc_now(),
        "queue": str(queue),
        "output_dir": str(output_dir),
        "selected_works": selected,
        "processed_works": processed,
        "failed_works": failures,
        "corpus_files_changed": 0,
    }
    if status in {"complete", "complete_with_errors", "stopped", "failed"}:
        payload["finished_at"] = utc_now()
    if error:
        payload["error"] = error
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--staging-root", type=Path, required=True)
    parser.add_argument("--queue", type=Path, default=None)
    parser.add_argument("--limit", type=int, default=100,
                        help="Number of refined exact-title works to process (default: 100; 0 = all after offset).")
    parser.add_argument("--offset", type=int, default=0,
                        help="Zero-based work offset in the refined queue (default: 0).")
    parser.add_argument("--delay", type=float, default=0.5,
                        help="Polite delay between Kanripo repositories (default: 0.5s).")
    parser.add_argument("--refresh-upstream", action="store_true",
                        help="Refresh branch heads even when a cached branch manifest exists.")
    parser.add_argument("--offline", action="store_true",
                        help="Use only already-cached branch manifests and ZIPs; never access network.")
    args = parser.parse_args()

    install_signal_handlers()
    repo_root = args.repo_root.expanduser().resolve()
    staging_root = args.staging_root.expanduser().resolve()
    queue = resolve_queue(staging_root, args.queue)
    rows = read_csv(queue)
    rows = [r for r in rows if r.get("refined_queue") == "DOWNLOAD_FOR_WITNESS_COMPARE"]
    if args.offset < 0:
        raise SystemExit("--offset must be >= 0")
    selected = rows[args.offset:]
    if args.limit > 0:
        selected = selected[:args.limit]
    if not selected:
        raise SystemExit("No Kanripo witness-compare rows selected.")

    run_dir = staging_root / "_kanripo_compare" / stamp_now()
    run_dir.mkdir(parents=True, exist_ok=False)
    state_path = staging_root / "_state" / "last_kanripo_compare.json"
    started_at = utc_now()
    processed = 0
    failures = 0
    comparison_rows: list[dict[str, Any]] = []
    work_rows: list[dict[str, Any]] = []
    error_rows: list[dict[str, Any]] = []

    atomic_json(state_path, state_payload(
        status="running", output_dir=run_dir, queue=queue,
        selected=len(selected), processed=0, failures=0, started_at=started_at,
    ))

    log(f"Repository: {repo_root}")
    log(f"Staging:    {staging_root}")
    log(f"Queue:      {queue}")
    log(f"Output:     {run_dir}")
    log(f"Selected:   {len(selected):,} Kanripo exact-title works (offset {args.offset:,})")
    log("Corpus is read-only: no PALCC files will be changed.")

    try:
        for index, source_row in enumerate(selected, start=1):
            if STOP_REQUESTED:
                raise StopRequested("stop requested")
            raw_id = source_row.get("source_id", "")
            try:
                identifier = canonical_kanripo_id(raw_id)
                source_title = source_row.get("source_title", "")
                candidate_paths = split_pipe(source_row.get("candidate_paths", ""))
                if not candidate_paths and source_row.get("palcc_path"):
                    candidate_paths = [source_row["palcc_path"].strip()]
                if not candidate_paths:
                    raise RuntimeError("queue row has no PALCC candidate path")

                palcc_candidates: list[dict[str, Any]] = []
                for rel in candidate_paths:
                    path = (repo_root / rel).resolve()
                    try:
                        path.relative_to(repo_root)
                    except ValueError:
                        raise RuntimeError(f"PALCC candidate escapes repository: {rel}")
                    stream, files = load_palcc_text(path)
                    if not stream:
                        continue
                    palcc_candidates.append({
                        "rel": rel, "path": path, "stream": stream, "files": files,
                        "sha256": sha256_text(stream),
                    })
                if not palcc_candidates:
                    raise RuntimeError("no readable primary PALCC text found for candidate path(s)")

                work_root = staging_root / "kanripo" / "works" / identifier
                branches = load_or_fetch_branches(
                    work_root, identifier,
                    refresh=args.refresh_upstream, offline=args.offline,
                )
                # Multiple branch names can point to the same commit. Download once, but
                # retain every branch label because edition identity remains meaningful.
                archive_cache: dict[str, Path] = {}
                branch_stream_cache: dict[str, tuple[str, dict[str, Any]]] = {}
                work_comparisons: list[dict[str, Any]] = []

                for branch in branches:
                    branch_name = branch["name"]
                    sha = branch["sha"]
                    if sha not in archive_cache:
                        archive_cache[sha] = ensure_archive(
                            work_root, identifier, sha, offline=args.offline,
                        )
                    if sha not in branch_stream_cache:
                        branch_stream_cache[sha] = load_kanripo_archive(archive_cache[sha])
                    source_stream, archive_meta = branch_stream_cache[sha]
                    source_sha = sha256_text(source_stream) if source_stream else ""

                    for candidate in palcc_candidates:
                        metrics = compare_streams(source_stream, candidate["stream"])
                        row: dict[str, Any] = {
                            "source_id": identifier,
                            "source_title": source_title,
                            "branch": branch_name,
                            "branch_commit": sha,
                            "base_edition": archive_meta.get("base_edition", ""),
                            "archive_title": archive_meta.get("archive_title", ""),
                            "kanripo_text_files": archive_meta.get("text_files", 0),
                            "kanripo_han_chars": len(source_stream),
                            "kanripo_han_sha256": source_sha,
                            "palcc_title": source_row.get("palcc_title", ""),
                            "palcc_path": candidate["rel"],
                            "palcc_primary_files": len(candidate["files"]),
                            "palcc_han_chars": len(candidate["stream"]),
                            "palcc_han_sha256": candidate["sha256"],
                            **metrics,
                            "decision": "COMPARE_ONLY_NEVER_OVERWRITE_AUTOMATICALLY",
                        }
                        comparison_rows.append(row)
                        work_comparisons.append(row)

                if not work_comparisons:
                    raise RuntimeError("no textual edition branches were compared")
                best = max(work_comparisons, key=comparison_sort_key)
                work_rows.append({
                    "source_id": identifier,
                    "source_title": source_title,
                    "branches_compared": len(branches),
                    "unique_commits": len({b["sha"] for b in branches}),
                    "palcc_candidates_compared": len(palcc_candidates),
                    "best_classification": best["classification"],
                    "best_branch": best["branch"],
                    "best_base_edition": best["base_edition"],
                    "best_palcc_path": best["palcc_path"],
                    "best_length_ratio": best["length_ratio"],
                    "best_jaccard": best["jaccard"],
                    "best_containment": best["containment"],
                    "needs_human_witness_review": "yes" if best["classification"] != "IDENTICAL" else "yes",
                    "note": "Even IDENTICAL means identical normalized Han stream, not permission to replace metadata/provenance.",
                })
                processed += 1
                log(
                    f"Kanripo compare {index:,}/{len(selected):,}: {identifier} {source_title} -> "
                    f"{best['classification']} via {best['branch']} vs {best['palcc_path']}"
                )
            except StopRequested:
                raise
            except Exception as exc:
                failures += 1
                error_rows.append({
                    "source_id": raw_id,
                    "source_title": source_row.get("source_title", ""),
                    "error": str(exc),
                })
                log(f"Kanripo compare {raw_id} FAILED: {exc}")

            atomic_json(state_path, state_payload(
                status="running", output_dir=run_dir, queue=queue,
                selected=len(selected), processed=processed, failures=failures,
                started_at=started_at,
            ))
            if args.delay > 0:
                time.sleep(max(0.0, args.delay))

    except StopRequested as exc:
        write_outputs(run_dir, comparison_rows, work_rows, error_rows, selected_count=len(selected))
        atomic_json(state_path, state_payload(
            status="stopped", output_dir=run_dir, queue=queue,
            selected=len(selected), processed=processed, failures=failures,
            started_at=started_at, error=str(exc),
        ))
        log("Kanripo witness comparison stopped; completed snapshots/reports were preserved.")
        return 130
    except Exception as exc:
        write_outputs(run_dir, comparison_rows, work_rows, error_rows, selected_count=len(selected))
        atomic_json(state_path, state_payload(
            status="failed", output_dir=run_dir, queue=queue,
            selected=len(selected), processed=processed, failures=failures,
            started_at=started_at, error=str(exc),
        ))
        log(f"Kanripo witness comparison failed: {exc}")
        return 1

    write_outputs(run_dir, comparison_rows, work_rows, error_rows, selected_count=len(selected))
    status = "complete_with_errors" if failures else "complete"
    atomic_json(state_path, state_payload(
        status=status, output_dir=run_dir, queue=queue,
        selected=len(selected), processed=processed, failures=failures,
        started_at=started_at,
    ))
    if failures:
        log(f"Kanripo witness comparison complete with errors: {failures:,} work(s) failed.")
        return 2
    log("Kanripo witness comparison complete.")
    return 0


def write_outputs(
    run_dir: Path,
    comparisons: list[dict[str, Any]],
    works: list[dict[str, Any]],
    errors: list[dict[str, Any]],
    *, selected_count: int,
) -> None:
    comparison_fields = [
        "source_id", "source_title", "branch", "branch_commit", "base_edition",
        "archive_title", "kanripo_text_files", "kanripo_han_chars", "kanripo_han_sha256",
        "palcc_title", "palcc_path", "palcc_primary_files", "palcc_han_chars",
        "palcc_han_sha256", "classification", "length_ratio", "jaccard", "containment",
        "decision",
    ]
    work_fields = [
        "source_id", "source_title", "branches_compared", "unique_commits",
        "palcc_candidates_compared", "best_classification", "best_branch",
        "best_base_edition", "best_palcc_path", "best_length_ratio", "best_jaccard",
        "best_containment", "needs_human_witness_review", "note",
    ]
    write_csv(run_dir / "kanripo_witness_comparisons.csv", comparisons, comparison_fields)
    write_csv(run_dir / "kanripo_work_summary.csv", works, work_fields)
    write_csv(run_dir / "errors.csv", errors, ["source_id", "source_title", "error"])

    buckets = {
        "identical.csv": {"IDENTICAL"},
        "near_identical.csv": {"NEAR_IDENTICAL"},
        "overlap_or_textual_difference.csv": {"SUBSTANTIAL_OVERLAP", "TEXTUAL_DIFFERENCE", "PARTIAL_OVERLAP"},
        "could_not_align.csv": {"COULD_NOT_ALIGN", "TOO_SHORT_TO_JUDGE"},
    }
    for filename, classes in buckets.items():
        bucket = [r for r in comparisons if r.get("classification") in classes]
        write_csv(run_dir / filename, bucket, comparison_fields)

    counts = Counter(r.get("best_classification", "") for r in works)
    summary = {
        "selected_works": selected_count,
        "completed_works": len(works),
        "failed_works": len(errors),
        "edition_candidate_comparisons": len(comparisons),
        "best_work_classifications": dict(sorted(counts.items())),
        "corpus_files_changed": 0,
    }
    atomic_json(run_dir / "summary.json", summary)
    lines = [
        "KANRIPO WITNESS COMPARISON PILOT",
        "================================",
        "",
        f"Selected works:                 {selected_count:,}",
        f"Completed works:                {len(works):,}",
        f"Failed works:                   {len(errors):,}",
        f"Edition/PALCC comparisons:      {len(comparisons):,}",
        "Corpus files changed:           0",
        "",
        "Best classification per Kanripo work",
    ]
    for cls in ["IDENTICAL", "NEAR_IDENTICAL", "SUBSTANTIAL_OVERLAP", "TEXTUAL_DIFFERENCE", "PARTIAL_OVERLAP", "COULD_NOT_ALIGN", "TOO_SHORT_TO_JUDGE"]:
        lines.append(f"  {cls:<22} {counts.get(cls, 0):,}")
    lines += [
        "",
        "Interpretation",
        "- IDENTICAL means the normalized Han-character stream is identical.",
        "- NEAR_IDENTICAL ignores punctuation/spacing but allows small textual variation.",
        "- SUBSTANTIAL_OVERLAP often means one witness contains extra/omitted material.",
        "- TEXTUAL_DIFFERENCE / PARTIAL_OVERLAP require witness-level review.",
        "- COULD_NOT_ALIGN can mean a wrong title relationship, radically different edition, or extraction problem.",
        "- No classification is permission to overwrite PALCC. Provenance and edition identity remain separate.",
    ]
    (run_dir / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
