#!/usr/bin/env python3
"""Harvest external Literary Chinese source datasets into an untracked staging area.

This script deliberately does *not* import anything into the Fanya Hanwen Corpus.
Its job is to preserve upstream data, provenance, checksums, and edition identities
so that matching/filtering/import can be performed later and reproducibly.

Designed to be safe to leave running unattended:
- sequential downloads (no download worker pool)
- resumable HTTP downloads via .part files
- atomic JSON manifests
- source failures are recorded without discarding completed sources
- SIGINT/SIGTERM stop the whole run instead of skipping to the next item
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

USER_AGENT = (
    "FanyaHanwenCorpusSourceHarvester/0.1 "
    "(+https://github.com/ShiraTheMogul/fanyahanwen-corpus)"
)
CHUNK_SIZE = 1024 * 1024
KANRIPO_ID_RE = re.compile(r"\bKR[1-6][a-z][0-9]{4}\b")
KANRIPO_SUBCATEGORY_RE = re.compile(r"\bKR[1-6][a-z]\b")
KANRIPO_TOP_CATEGORY_RE = re.compile(r"^KR[1-6]$")


class StopRequested(Exception):
    """Raised when the user requests termination."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(message: str) -> None:
    print(f"[{utc_now()}] {message}", flush=True)


def handle_stop(signum: int, _frame: Any) -> None:
    name = signal.Signals(signum).name
    log(f"Received {name}; stopping the harvest run.")
    raise StopRequested(name)


def install_signal_handlers() -> None:
    signal.signal(signal.SIGINT, handle_stop)
    signal.signal(signal.SIGTERM, handle_stop)


def atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(CHUNK_SIZE)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def file_record(path: Path, root: Path, url: str | None = None) -> dict[str, Any]:
    record: dict[str, Any] = {
        "path": path.relative_to(root).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }
    if url:
        record["url"] = url
    return record


def request_bytes(
    url: str,
    *,
    timeout: int = 60,
    accept: str | None = None,
    retries: int = 6,
) -> tuple[bytes, str | None]:
    """Fetch a small HTTP resource with polite retry/backoff.

    Catalogue/metadata requests should be sparse, but scholarly services can still
    return 429/5xx responses. Honour Retry-After when present and otherwise back
    off exponentially instead of immediately hammering the endpoint again.
    """
    headers = {"User-Agent": USER_AGENT}
    if accept:
        headers["Accept"] = accept

    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read(), response.headers.get("Content-Type")
        except StopRequested:
            raise
        except urllib.error.HTTPError as exc:
            last_error = exc
            retryable = exc.code == 429 or 500 <= exc.code <= 599
            if not retryable or attempt >= retries:
                raise

            retry_after = exc.headers.get("Retry-After") if exc.headers else None
            try:
                server_wait = float(retry_after) if retry_after else 0.0
            except (TypeError, ValueError):
                server_wait = 0.0
            wait = min(300.0, max(server_wait, float(2 ** (attempt + 1))))
            log(
                f"HTTP {exc.code} from {url}; waiting {wait:.0f}s before "
                f"retry {attempt + 1}/{retries}."
            )
            time.sleep(wait)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last_error = exc
            if attempt >= retries:
                raise
            wait = min(60.0, float(2 ** attempt))
            log(
                f"HTTP request failed for {url}: {exc}; waiting {wait:.0f}s "
                f"before retry {attempt + 1}/{retries}."
            )
            time.sleep(wait)

    assert last_error is not None
    raise RuntimeError(f"Failed to fetch {url}: {last_error}")


def download(
    url: str,
    destination: Path,
    *,
    retries: int = 5,
    timeout: int = 90,
) -> dict[str, Any]:
    """Download URL atomically, resuming a .part file where the server supports Range."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file():
        log(f"Already present: {destination}")
        return file_record(destination, destination.parent, url)

    part = destination.with_name(destination.name + ".part")
    last_error: Exception | None = None

    for attempt in range(1, retries + 1):
        try:
            existing = part.stat().st_size if part.exists() else 0
            headers = {"User-Agent": USER_AGENT}
            if existing:
                headers["Range"] = f"bytes={existing}-"

            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status = getattr(response, "status", response.getcode())
                resumed = existing > 0 and status == 206
                mode = "ab" if resumed else "wb"
                if existing and not resumed:
                    log(f"Server did not resume {destination.name}; restarting it.")
                with part.open(mode) as handle:
                    while True:
                        block = response.read(CHUNK_SIZE)
                        if not block:
                            break
                        handle.write(block)

            os.replace(part, destination)
            log(f"Downloaded: {destination} ({destination.stat().st_size:,} bytes)")
            return file_record(destination, destination.parent, url)
        except StopRequested:
            raise
        except Exception as exc:  # network errors differ across Python/platform versions
            last_error = exc
            log(f"Download attempt {attempt}/{retries} failed for {url}: {exc}")
            if attempt < retries:
                time.sleep(min(30, 2 ** (attempt - 1)))

    assert last_error is not None
    raise RuntimeError(f"Failed to download {url}: {last_error}")


def run_git(args: list[str], *, timeout: int = 120) -> str:
    if not shutil.which("git"):
        raise RuntimeError("git is required for upstream branch/commit discovery")
    completed = subprocess.run(
        ["git", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or f"git {' '.join(args)} failed")
    return completed.stdout


def remote_head(repo_url: str) -> tuple[str | None, str]:
    output = run_git(["ls-remote", "--symref", repo_url, "HEAD"])
    branch: str | None = None
    sha: str | None = None
    for line in output.splitlines():
        if line.startswith("ref: ") and line.endswith("\tHEAD"):
            ref = line.split("\t", 1)[0].removeprefix("ref: ")
            branch = ref.removeprefix("refs/heads/")
        elif line.endswith("\tHEAD"):
            sha = line.split("\t", 1)[0]
    if not sha:
        raise RuntimeError(f"Could not resolve HEAD for {repo_url}")
    return branch, sha


def remote_branches(repo_url: str) -> list[dict[str, str]]:
    output = run_git(["ls-remote", "--heads", repo_url])
    branches: list[dict[str, str]] = []
    for line in output.splitlines():
        if "\trefs/heads/" not in line:
            continue
        sha, ref = line.split("\t", 1)
        branches.append({"name": ref.removeprefix("refs/heads/"), "sha": sha})
    return branches


def github_codeload(owner: str, repo: str, sha: str) -> str:
    return f"https://codeload.github.com/{owner}/{repo}/zip/{urllib.parse.quote(sha, safe='')}"


@dataclass(frozen=True)
class UdTreebank:
    repo: str
    webpage: str
    license_label: str
    license_status: str


UD_TREEBANKS = (
    UdTreebank(
        repo="UD_Classical_Chinese-Kyoto",
        webpage="https://universaldependencies.org/treebanks/lzh_kyoto/index.html",
        license_label="Public Domain",
        license_status="explicit_open_license",
    ),
    UdTreebank(
        repo="UD_Classical_Chinese-TueCL",
        webpage="https://universaldependencies.org/treebanks/lzh_tuecl/index.html",
        license_label="CC BY-SA 4.0",
        license_status="explicit_open_license",
    ),
)


def harvest_ud(root: Path, refresh: bool) -> dict[str, Any]:
    source_root = root / "ud_classical_chinese"
    source_root.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []

    for treebank in UD_TREEBANKS:
        repo_root = source_root / treebank.repo
        manifest_path = repo_root / "source.json"
        if manifest_path.exists() and not refresh:
            log(f"UD already harvested: {treebank.repo}")
            results.append({"repo": treebank.repo, "status": "already_present"})
            continue

        repo_url = f"https://github.com/UniversalDependencies/{treebank.repo}.git"
        branch, sha = remote_head(repo_url)
        archive = repo_root / "raw" / f"{treebank.repo}-{sha}.zip"
        archive.parent.mkdir(parents=True, exist_ok=True)
        url = github_codeload("UniversalDependencies", treebank.repo, sha)
        download(url, archive)

        manifest = {
            "source": "Universal Dependencies",
            "treebank": treebank.repo,
            "retrieved_at": utc_now(),
            "upstream": {
                "repository": repo_url,
                "default_branch": branch,
                "commit": sha,
                "documentation": treebank.webpage,
            },
            "rights": {
                "status": treebank.license_status,
                "license": treebank.license_label,
                "evidence_url": treebank.webpage,
                "note": "Preserve the upstream LICENSE contained in the repository snapshot.",
            },
            "files": [file_record(archive, repo_root, url)],
            "palcc_imported": False,
        }
        atomic_json(manifest_path, manifest)
        results.append({"repo": treebank.repo, "status": "downloaded", "commit": sha})

    return {"source": "ud", "treebanks": results}


CODH_PACKAGES = {
    "metadata.zip": "https://codh.rois.ac.jp/pmjt/package/metadata.zip",
    "text.zip": "https://codh.rois.ac.jp/pmjt/package/text.zip",
    "tag.zip": "https://codh.rois.ac.jp/pmjt/package/tag.zip",
}


def harvest_codh(root: Path, refresh: bool) -> dict[str, Any]:
    source_root = root / "codh_japanese_classical_books"
    manifest_path = source_root / "source.json"
    if manifest_path.exists() and not refresh:
        log("CODH packages already harvested.")
        return {"source": "codh", "status": "already_present"}

    records: list[dict[str, Any]] = []
    for filename, url in CODH_PACKAGES.items():
        target = source_root / "raw" / filename
        if refresh and target.exists():
            target.unlink()
        download(url, target)
        records.append(file_record(target, source_root, url))

    manifest = {
        "source": "CODH Japanese Classical Books Dataset",
        "retrieved_at": utc_now(),
        "upstream": {
            "dataset_page": "https://codh.rois.ac.jp/pmjt/",
            "packages": CODH_PACKAGES,
        },
        "rights": {
            "status": "explicit_open_license",
            "license": "CC BY-SA 4.0",
            "evidence_url": "https://codh.rois.ac.jp/pmjt/",
            "attribution_note": "日本古典籍データセット（国文研等所蔵）; source: CODH/NIJL as applicable.",
        },
        "files": records,
        "palcc_imported": False,
    }
    atomic_json(manifest_path, manifest)
    return {"source": "codh", "status": "downloaded", "files": len(records)}


def kanripo_catalog_html(category: str) -> tuple[str, str, str | None]:
    """Fetch one Kanripo catalogue page.

    Kanripo's HTML catalogue expands a department prefix such as KR1 to all of
    the work records beneath it. That makes six department requests sufficient
    for a full inventory, instead of querying every subcategory through the
    titles API and risking unnecessary load/rate limiting.
    """
    query = urllib.parse.urlencode({"coll": category})
    url = f"https://www.kanripo.org/catalog?{query}"
    payload, content_type = request_bytes(
        url,
        accept="text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
    )
    return payload.decode("utf-8", errors="replace"), url, content_type


def validate_kanripo_category(category: str) -> None:
    if KANRIPO_TOP_CATEGORY_RE.fullmatch(category):
        return
    if KANRIPO_SUBCATEGORY_RE.fullmatch(category):
        return
    raise RuntimeError(
        f"Unsupported Kanripo category {category!r}; use KR1 ... KR6 "
        "or a subcategory such as KR1a."
    )


def harvest_kanripo_catalog(
    source_root: Path,
    *,
    categories: Iterable[str],
    page_size: int,
    refresh: bool,
) -> list[str]:
    # page_size is retained in the CLI for compatibility with the first
    # harvester overlay, but the HTML catalogue is not paginated.
    del page_size

    catalog_dir = source_root / "catalog_pages"
    catalog_dir.mkdir(parents=True, exist_ok=True)
    requested_categories = list(dict.fromkeys(categories))
    for category in requested_categories:
        validate_kanripo_category(category)

    all_ids: set[str] = set()
    category_records: list[dict[str, Any]] = []

    for index, category in enumerate(requested_categories, start=1):
        cache = catalog_dir / f"{category}.html"
        if cache.exists() and not refresh:
            text = cache.read_text(encoding="utf-8", errors="replace")
            url = f"https://www.kanripo.org/catalog?{urllib.parse.urlencode({'coll': category})}"
            content_type = "cached"
        else:
            text, url, content_type = kanripo_catalog_html(category)
            cache.write_text(text, encoding="utf-8", newline="\n")
            # The catalogue is tiny compared with the payload. A small pause is
            # intentional courtesy even though this is only ~6 requests by default.
            if index < len(requested_categories):
                time.sleep(1.0)

        ids = sorted(set(KANRIPO_ID_RE.findall(text)))
        if not ids:
            raise RuntimeError(
                f"Kanripo catalogue {category} returned no work IDs; refusing "
                "to record an empty/suspicious catalogue page."
            )

        # Department pages should represent far more than one work. This catches
        # the exact class of bug that previously made KR1..KR6 look like six works.
        if KANRIPO_TOP_CATEGORY_RE.fullmatch(category) and len(ids) < 10:
            raise RuntimeError(
                f"Kanripo department {category} returned only {len(ids)} work IDs; "
                "refusing a suspiciously incomplete result."
            )

        before = len(all_ids)
        all_ids.update(ids)
        category_records.append(
            {
                "category": category,
                "work_count": len(ids),
                "new_work_count": len(all_ids) - before,
                "url": url,
                "content_type": content_type,
                "cache": cache.relative_to(source_root).as_posix(),
            }
        )
        log(
            f"Kanripo catalogue {category}: {len(ids):,} work IDs "
            f"({len(all_ids) - before:,} new); {index}/{len(requested_categories)} pages."
        )

    ids_sorted = sorted(all_ids)
    (source_root / "catalog_ids.txt").write_text(
        "".join(f"{identifier}\n" for identifier in ids_sorted),
        encoding="utf-8",
        newline="\n",
    )
    atomic_json(
        source_root / "catalog.json",
        {
            "source": "Kanseki Repository",
            "retrieved_at": utc_now(),
            "requested_categories": requested_categories,
            "work_count": len(ids_sorted),
            "work_ids_file": "catalog_ids.txt",
            "catalogue_pages": category_records,
            "catalogue_method": "HTML department/subcategory catalogue pages",
            "catalogue_base": "https://www.kanripo.org/catalog",
            "note": (
                "The HTML catalogue expands KR1..KR6 department prefixes to work "
                "records, avoiding dozens of titles-API requests."
            ),
        },
    )
    if set(requested_categories) == {f"KR{i}" for i in range(1, 7)} and len(ids_sorted) < 1000:
        raise RuntimeError(
            "Full Kanripo catalogue returned fewer than 1,000 work IDs; "
            "refusing to record a suspiciously incomplete catalogue as successful."
        )
    return ids_sorted

def harvest_kanripo(
    root: Path,
    *,
    refresh: bool,
    catalog_only: bool,
    editions: str,
    categories: list[str],
    page_size: int,
    limit: int | None,
    delay: float,
) -> dict[str, Any]:
    source_root = root / "kanripo"
    source_root.mkdir(parents=True, exist_ok=True)
    ids = harvest_kanripo_catalog(
        source_root,
        categories=categories,
        page_size=page_size,
        refresh=refresh,
    )
    if limit is not None:
        ids = ids[:limit]
    if catalog_only:
        log(f"Kanripo catalogue complete: {len(ids):,} selected works; payload disabled.")
        return {"source": "kanripo", "status": "catalogued", "works": len(ids)}

    completed = 0
    failures = 0
    for index, identifier in enumerate(ids, start=1):
        work_root = source_root / "works" / identifier
        manifest_path = work_root / "source.json"
        if manifest_path.exists() and not refresh:
            completed += 1
            if index % 100 == 0:
                log(f"Kanripo progress: {index:,}/{len(ids):,} inspected")
            continue

        repo_url = f"https://github.com/kanripo/{identifier}.git"
        try:
            branches = remote_branches(repo_url)
            if editions == "master":
                master = [branch for branch in branches if branch["name"] == "master"]
                if master:
                    branches = master
                else:
                    default_branch, default_sha = remote_head(repo_url)
                    branches = [{"name": default_branch or "HEAD", "sha": default_sha}]

            if not branches:
                raise RuntimeError("no branch heads returned")

            archives_by_sha: dict[str, str] = {}
            branch_records: list[dict[str, str]] = []
            for branch in branches:
                sha = branch["sha"]
                archive_rel = archives_by_sha.get(sha)
                if archive_rel is None:
                    archive = work_root / "raw" / f"{identifier}-{sha}.zip"
                    url = github_codeload("kanripo", identifier, sha)
                    download(url, archive)
                    archive_rel = archive.relative_to(work_root).as_posix()
                    archives_by_sha[sha] = archive_rel
                branch_records.append(
                    {"name": branch["name"], "commit": sha, "archive": archive_rel}
                )

            atomic_json(
                manifest_path,
                {
                    "source": "Kanseki Repository",
                    "work_id": identifier,
                    "retrieved_at": utc_now(),
                    "upstream": {"repository": repo_url, "branches": branch_records},
                    "rights": {
                        "status": "explicit_open_license_needs_version_check",
                        "license": "CC BY-SA (version not stated on the Kanripo site page inspected)",
                        "evidence_url": "https://www.kanripo.org/",
                        "automatic_palcc_import": False,
                    },
                    "palcc_imported": False,
                },
            )
            completed += 1
        except StopRequested:
            raise
        except Exception as exc:
            failures += 1
            work_root.mkdir(parents=True, exist_ok=True)
            atomic_json(
                work_root / "harvest_error.json",
                {
                    "work_id": identifier,
                    "failed_at": utc_now(),
                    "error": str(exc),
                    "repository": repo_url,
                },
            )
            log(f"Kanripo {identifier} failed: {exc}")

        log(
            f"Kanripo progress: {index:,}/{len(ids):,} inspected; "
            f"{completed:,} complete; {failures:,} failed"
        )
        if delay > 0:
            time.sleep(delay)

    return {
        "source": "kanripo",
        "status": "downloaded",
        "selected_works": len(ids),
        "completed": completed,
        "failures": failures,
    }


def gitlab_group_projects(group: str, page: int, per_page: int = 100) -> list[dict[str, Any]]:
    encoded = urllib.parse.quote(group, safe="")
    query = urllib.parse.urlencode(
        {
            "per_page": per_page,
            "page": page,
            "simple": "true",
            "order_by": "id",
            "sort": "asc",
            "include_subgroups": "false",
        }
    )
    url = f"https://gitlab.nijl.ac.jp/api/v4/groups/{encoded}/projects?{query}"
    payload, _ = request_bytes(url, accept="application/json")
    parsed = json.loads(payload.decode("utf-8"))
    if not isinstance(parsed, list):
        raise RuntimeError(f"Unexpected NIJL GitLab API response for {group}")
    return parsed


def harvest_nijl(
    root: Path,
    *,
    refresh: bool,
    catalog_only: bool,
    limit: int | None,
    delay: float,
) -> dict[str, Any]:
    source_root = root / "nijl_kokusho_ocr"
    source_root.mkdir(parents=True, exist_ok=True)
    groups = ("Kokusho", "Kokusho-Works")
    projects: list[dict[str, Any]] = []

    discovery_errors: list[dict[str, str]] = []
    for group in groups:
        cache = source_root / f"catalog-{group}.json"
        try:
            if cache.exists() and not refresh:
                cached = json.loads(cache.read_text(encoding="utf-8"))
                group_projects = cached.get("projects", [])
            else:
                group_projects: list[dict[str, Any]] = []
                for page in range(1, 1001):
                    batch = gitlab_group_projects(group, page)
                    if not batch:
                        break
                    group_projects.extend(batch)
                    log(f"NIJL {group}: catalogue page {page}, total {len(group_projects):,}")
                    if len(batch) < 100:
                        break
                atomic_json(
                    cache,
                    {"group": group, "retrieved_at": utc_now(), "projects": group_projects},
                )
            projects.extend(group_projects)
        except StopRequested:
            raise
        except Exception as exc:
            discovery_errors.append({"group": group, "error": str(exc)})
            atomic_json(
                cache,
                {
                    "group": group,
                    "retrieved_at": utc_now(),
                    "projects": [],
                    "discovery_error": str(exc),
                },
            )
            log(f"NIJL {group}: public GitLab project enumeration unavailable: {exc}")

    # Some GitLab deployments hide group project enumeration even when individual
    # public projects are reachable. Treat zero as a recorded discovery result,
    # not as permission to fabricate an index by scraping HTML.
    atomic_json(
        source_root / "source.json",
        {
            "source": "NIJL Kokusho OCR open dataset (work in progress)",
            "retrieved_at": utc_now(),
            "groups": list(groups),
            "project_count": len(projects),
            "discovery_errors": discovery_errors,
            "rights": {
                "status": "staging_only_pending_per_item_verification",
                "note": (
                    "The project describes OCR derived from images published under open-data "
                    "conditions, but this harvester does not infer one corpus-wide licence for "
                    "all OCR repositories. Verify the individual source/item conditions before PALCC import."
                ),
                "dataset_description": "https://gitlab.nijl.ac.jp/Kokusho",
                "kokusho_terms": "https://kokusho.nijl.ac.jp/page/terms.html",
            },
            "palcc_imported": False,
        },
    )

    if catalog_only or not projects:
        status = "catalogued" if projects else "catalogue_unavailable_or_empty"
        log(f"NIJL result: {status}; {len(projects):,} projects enumerated.")
        return {"source": "nijl", "status": status, "projects": len(projects)}

    selected = projects[:limit] if limit is not None else projects
    completed = 0
    failures = 0
    for index, project in enumerate(selected, start=1):
        path_with_namespace = project.get("path_with_namespace")
        if not path_with_namespace:
            continue
        project_path = source_root / "projects" / path_with_namespace.replace("/", "__")
        manifest_path = project_path / "source.json"
        if manifest_path.exists() and not refresh:
            completed += 1
            continue
        repo_url = project.get("http_url_to_repo") or f"https://gitlab.nijl.ac.jp/{path_with_namespace}.git"
        try:
            branch, sha = remote_head(repo_url)
            archive_url = (
                f"https://gitlab.nijl.ac.jp/{path_with_namespace}/-/archive/{sha}/"
                f"{urllib.parse.quote(str(project.get('path') or 'source'), safe='')}-{sha}.zip"
            )
            archive = project_path / "raw" / f"{project.get('path', 'source')}-{sha}.zip"
            download(archive_url, archive)
            atomic_json(
                manifest_path,
                {
                    "source": "NIJL Kokusho OCR",
                    "retrieved_at": utc_now(),
                    "project": project,
                    "default_branch": branch,
                    "commit": sha,
                    "archive": file_record(archive, project_path, archive_url),
                    "rights_status": "staging_only_pending_per_item_verification",
                    "palcc_imported": False,
                },
            )
            completed += 1
        except StopRequested:
            raise
        except Exception as exc:
            failures += 1
            atomic_json(
                project_path / "harvest_error.json",
                {"failed_at": utc_now(), "error": str(exc), "project": project},
            )
            log(f"NIJL {path_with_namespace} failed: {exc}")
        log(
            f"NIJL progress: {index:,}/{len(selected):,}; "
            f"{completed:,} complete; {failures:,} failed"
        )
        if delay > 0:
            time.sleep(delay)

    return {
        "source": "nijl",
        "status": "downloaded_to_staging",
        "selected_projects": len(selected),
        "completed": completed,
        "failures": failures,
    }


def harvest_cobo_reference(root: Path, refresh: bool) -> dict[str, Any]:
    """Record the Cobo Shilu witness now; OCR/image extraction is intentionally separate."""
    source_root = root / "cobo_shilu_bne"
    source_root.mkdir(parents=True, exist_ok=True)
    manifest_path = source_root / "source.json"
    if manifest_path.exists() and not refresh:
        return {"source": "cobo", "status": "already_present"}

    manifest = {
        "source": "Biblioteca Nacional de España / BNE Digital",
        "retrieved_at": utc_now(),
        "work": {
            "author": "Juan Cobo (高母羨)",
            "short_title": "Shilu",
            "title_as_commonly_cited": "辨正教真傳實錄",
            "date": "1593",
            "place": "Manila",
            "shelfmark": "R/33396",
            "legacy_bdh_record": "https://bdh.bne.es/bnesearch/detalle/2532052",
        },
        "rights": {
            "original_work": "public_domain",
            "image_policy_status": "verify_item_conditions_before_repository_import",
            "bne_reuse_policy": "https://www.bne.es/es/servicios/reproduccion-documentos/uso-reproducciones",
            "note": (
                "BNE states that open-access images of public-domain works may be reused with "
                "source credit, but the item-level conditions should still be captured before "
                "the scan or derived OCR is committed to PALCC."
            ),
        },
        "harvest_status": (
            "bibliographic_witness_recorded_only; page-image acquisition/OCR intentionally "
            "deferred so it does not compete with viewer performance measurements"
        ),
        "palcc_imported": False,
    }
    atomic_json(manifest_path, manifest)
    return {"source": "cobo", "status": "witness_recorded"}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--staging-root",
        type=Path,
        required=True,
        help="Untracked directory in which upstream snapshots and manifests are stored.",
    )
    parser.add_argument(
        "--sources",
        default="cobo,ud,codh,kanripo,nijl",
        help="Comma-separated: cobo,ud,codh,kanripo,nijl (default: all).",
    )
    parser.add_argument("--refresh", action="store_true", help="Re-query/re-download existing source entries.")
    parser.add_argument(
        "--kanripo-catalog-only",
        action="store_true",
        help="Only enumerate Kanripo work IDs; do not download work archives.",
    )
    parser.add_argument(
        "--kanripo-editions",
        choices=("all", "master"),
        default="all",
        help="Download every edition branch or only master/default (default: all).",
    )
    parser.add_argument(
        "--kanripo-category",
        action="append",
        dest="kanripo_categories",
        help="Catalogue prefix to harvest; repeatable. KR1 ... KR6 use one HTML department catalogue page each.",
    )
    parser.add_argument("--kanripo-page-size", type=int, default=500, help="Compatibility option; ignored by the HTML catalogue harvester.")
    parser.add_argument("--kanripo-limit", type=int, default=None, help="Testing/partial-run work limit.")
    parser.add_argument("--kanripo-delay", type=float, default=0.20, help="Seconds between Kanripo works.")
    parser.add_argument(
        "--nijl-payload",
        action="store_true",
        help="Download enumerated NIJL OCR repositories. Default is catalogue/rights staging only.",
    )
    parser.add_argument("--nijl-limit", type=int, default=None, help="Testing/partial NIJL project limit.")
    parser.add_argument("--nijl-delay", type=float, default=0.20)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    install_signal_handlers()
    root = args.staging_root.expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    state = root / "_state"
    state.mkdir(parents=True, exist_ok=True)

    valid_sources = {"cobo", "ud", "codh", "kanripo", "nijl"}
    requested = [part.strip().lower() for part in args.sources.split(",") if part.strip()]
    unknown = sorted(set(requested) - valid_sources)
    if unknown:
        raise SystemExit(f"Unknown sources: {', '.join(unknown)}")

    run_manifest: dict[str, Any] = {
        "started_at": utc_now(),
        "staging_root": str(root),
        "sources_requested": requested,
        "results": [],
        "status": "running",
    }
    atomic_json(state / "last_run.json", run_manifest)

    log(f"Staging root: {root}")
    log(f"Sources: {', '.join(requested)}")
    log("No PALCC corpus files will be changed by this process.")

    try:
        for source in requested:
            log(f"=== Starting source: {source} ===")
            try:
                if source == "cobo":
                    result = harvest_cobo_reference(root, args.refresh)
                elif source == "ud":
                    result = harvest_ud(root, args.refresh)
                elif source == "codh":
                    result = harvest_codh(root, args.refresh)
                elif source == "kanripo":
                    result = harvest_kanripo(
                        root,
                        refresh=args.refresh,
                        catalog_only=args.kanripo_catalog_only,
                        editions=args.kanripo_editions,
                        categories=args.kanripo_categories or [f"KR{i}" for i in range(1, 7)],
                        page_size=args.kanripo_page_size,
                        limit=args.kanripo_limit,
                        delay=max(0.0, args.kanripo_delay),
                    )
                elif source == "nijl":
                    result = harvest_nijl(
                        root,
                        refresh=args.refresh,
                        catalog_only=not args.nijl_payload,
                        limit=args.nijl_limit,
                        delay=max(0.0, args.nijl_delay),
                    )
                else:  # guarded by validation above
                    raise AssertionError(source)
                run_manifest["results"].append(result)
                log(f"=== Completed source: {source} ===")
            except StopRequested:
                raise
            except Exception as exc:
                log(f"SOURCE FAILED ({source}): {exc}")
                run_manifest["results"].append(
                    {"source": source, "status": "failed", "error": str(exc), "failed_at": utc_now()}
                )
            atomic_json(state / "last_run.json", run_manifest)

        failed_sources = [
            result.get("source", "unknown")
            for result in run_manifest["results"]
            if result.get("status") == "failed"
        ]
        run_manifest["status"] = "complete_with_errors" if failed_sources else "complete"
        run_manifest["finished_at"] = utc_now()
        atomic_json(state / "last_run.json", run_manifest)
        if failed_sources:
            log(
                "Harvest run complete with errors. Failed sources: "
                + ", ".join(failed_sources)
            )
            return 1
        log("Harvest run complete.")
        return 0
    except StopRequested:
        run_manifest["status"] = "stopped"
        run_manifest["finished_at"] = utc_now()
        atomic_json(state / "last_run.json", run_manifest)
        log("Harvest run stopped by user request. Existing completed downloads are preserved for resume.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
