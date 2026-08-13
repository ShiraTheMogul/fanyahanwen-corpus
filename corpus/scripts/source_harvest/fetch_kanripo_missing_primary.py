#!/usr/bin/env python3
"""Fetch Kanripo snapshots for exact-title PALCC records that have metadata but no text.

Input is the most recent read-only merge plan. This script downloads source snapshots
only into the untracked staging area. It does not create or edit corpus works.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import signal
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harvest_sources import StopRequested  # type: ignore
from kanripo_witness_compare import (  # type: ignore
    canonical_kanripo_id,
    ensure_archive,
    load_kanripo_archive,
    load_or_fetch_branches,
)

STOP_REQUESTED = False

# GitHub returns an authentication-looking failure for some non-existent public
# repositories. This fetch is unattended corpus tooling, so Git must never stop
# and ask the terminal for credentials.
os.environ.setdefault("GIT_TERMINAL_PROMPT", "0")
os.environ.setdefault("GCM_INTERACTIVE", "Never")


def github_repo_exists(identifier: str) -> bool | None:
    """Return False for a definite GitHub 404, True when present, None if unsure.

    A transient API/rate-limit failure must not be mistaken for a missing source;
    in that case the existing git branch discovery still gets a chance to run.
    """
    url = f"https://api.github.com/repos/kanripo/{identifier}"
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "FanyaHanwenCorpusSourceHarvester/0.1",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return 200 <= getattr(response, "status", response.getcode()) < 300
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return False
        return None
    except Exception:
        return None


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(message: str) -> None:
    print(f"[{utc_now()}] {message}", flush=True)


def install_signal_handlers() -> None:
    def handler(signum: int, _frame: Any) -> None:
        global STOP_REQUESTED
        STOP_REQUESTED = True
        raise StopRequested(signal.Signals(signum).name)
    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def resolve_plan(staging_root: Path, explicit: Path | None) -> Path:
    if explicit:
        path = explicit.expanduser().resolve()
        if not (path / "metadata_only_fill_candidates.csv").is_file():
            raise FileNotFoundError(path)
        return path
    state = staging_root / "_state" / "last_kanripo_merge_plan.json"
    if state.is_file():
        try:
            payload = json.loads(state.read_text(encoding="utf-8"))
            path = Path(payload.get("output_dir", ""))
            if (path / "metadata_only_fill_candidates.csv").is_file():
                return path
        except Exception:
            pass
    candidates = sorted(
        (staging_root / "_merge_plan").glob("*/metadata_only_fill_candidates.csv"),
        key=lambda p: p.parent.name,
        reverse=True,
    )
    if not candidates:
        raise FileNotFoundError("No Kanripo merge plan found")
    return candidates[0].parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging-root", type=Path, required=True)
    parser.add_argument("--plan-dir", type=Path, default=None)
    parser.add_argument("--delay", type=float, default=0.5)
    parser.add_argument("--refresh-upstream", action="store_true")
    parser.add_argument("--limit", type=int, default=0, help="0 = all metadata-only candidates")
    args = parser.parse_args()

    install_signal_handlers()
    staging_root = args.staging_root.expanduser().resolve()
    plan = resolve_plan(staging_root, args.plan_dir)
    rows = read_csv(plan / "metadata_only_fill_candidates.csv")
    # One source may have multiple metadata-only PALCC candidate paths. Fetch the
    # source once; source-witness placement is decided later by the merge planner.
    source_rows: dict[str, dict[str, str]] = {}
    for row in rows:
        # The corrected planner writes only genuinely no-readable-target rows to
        # this file.  Still honour source_fetch_needed so reruns do not waste
        # branch-discovery requests for snapshots already present in staging.
        if row.get("source_fetch_needed", "").strip().lower() != "yes":
            continue
        sid = canonical_kanripo_id(row.get("source_id", ""))
        if sid:
            source_rows.setdefault(sid, row)
    selected = list(source_rows.items())
    if args.limit > 0:
        selected = selected[:args.limit]

    if not selected:
        print("No metadata-only Kanripo source IDs to fetch.")
        return 0

    report_rows: list[dict[str, Any]] = []
    failures = 0
    log(f"Fetching {len(selected):,} Kanripo source(s) for metadata-only PALCC records.")
    log("Corpus is read-only; downloads go only to staging.")

    try:
        for index, (sid, row) in enumerate(selected, start=1):
            if STOP_REQUESTED:
                raise StopRequested("stop requested")
            try:
                work_root = staging_root / "kanripo" / "works" / sid
                exists = github_repo_exists(sid)
                if exists is False:
                    raise RuntimeError("upstream Kanripo GitHub repository unavailable (HTTP 404)")
                branches = load_or_fetch_branches(
                    work_root,
                    sid,
                    refresh=args.refresh_upstream,
                    offline=False,
                )
                for branch in branches:
                    name = branch["name"]
                    sha = branch["sha"]
                    archive = ensure_archive(work_root, sid, sha, offline=False)
                    stream, meta = load_kanripo_archive(archive)
                    report_rows.append({
                        "source_id": sid,
                        "source_title": row.get("source_title", ""),
                        "branch": name,
                        "branch_commit": sha,
                        "upstream_baseedition": meta.get("base_edition", ""),
                        "archive_title": meta.get("archive_title", ""),
                        "text_files": meta.get("text_files", 0),
                        "han_chars": len(stream),
                        "archive": str(archive),
                        "status": "fetched",
                        "error": "",
                    })
                log(f"{index:,}/{len(selected):,} {sid} {row.get('source_title','')}: {len(branches)} textual branch(es)")
            except StopRequested:
                raise
            except Exception as exc:
                failures += 1
                report_rows.append({
                    "source_id": sid,
                    "source_title": row.get("source_title", ""),
                    "branch": "",
                    "branch_commit": "",
                    "upstream_baseedition": "",
                    "archive_title": "",
                    "text_files": 0,
                    "han_chars": 0,
                    "archive": "",
                    "status": "failed",
                    "error": str(exc),
                })
                log(f"{sid} FAILED: {exc}")
            if args.delay > 0:
                time.sleep(max(0.0, args.delay))
    except StopRequested as exc:
        log(f"Stopped: {exc}")
        return 130

    report = plan / "metadata_only_source_fetch.csv"
    fields = [
        "source_id", "source_title", "branch", "branch_commit", "upstream_baseedition",
        "archive_title", "text_files", "han_chars", "archive", "status", "error",
    ]
    with report.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(report_rows)

    log(f"Fetch complete: {len(selected) - failures:,} source(s) succeeded; {failures:,} failed.")
    log("Rerun run_kanripo_merge_plan.sh so the plan can read source-witness BASEEDITION and digital branch/revision metadata from the newly cached snapshots.")
    return 2 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
