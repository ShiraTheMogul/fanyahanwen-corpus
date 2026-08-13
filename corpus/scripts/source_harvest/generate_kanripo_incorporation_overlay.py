#!/usr/bin/env python3
"""Generate a repository-ready Kanripo incorporation overlay without touching PALCC.

This consumes the latest quality-aware merge plan and cached Kanripo commit ZIPs.
It materialises only deterministic canonical-text actions:

- PROMOTE_KANRIPO_WYG_DIGITAL_TRANSCRIPTION
- PREFER_KANRIPO_COMPLETE_DIGITAL_TRANSCRIPTION
- FILL_METADATA_ONLY_WORK

The generated ZIP contains only final repository files (metadata.json + replacement
primary text files). A companion apply script is written *outside* the ZIP because
replacement requires deleting stale root-level primary .txt files first.

The corpus itself is never modified by this generator.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import shlex
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_ACTIONS = {
    "PROMOTE_KANRIPO_WYG_DIGITAL_TRANSCRIPTION",
    "PREFER_KANRIPO_COMPLETE_DIGITAL_TRANSCRIPTION",
    "FILL_METADATA_ONLY_WORK",
}
EXCLUDED_ROOT_NAMES = {"metadata.json"}
ORG_META_RE = re.compile(r"^#\+([A-Z0-9_]+):\s*(.*?)\s*$", re.I)
ORG_PROP_RE = re.compile(r"^#\+PROPERTY:\s*([A-Z0-9_]+)\s+(.*?)\s*$", re.I)
PB_RE = re.compile(r"<pb:[^>]+>")
JUAN_FILE_RE = re.compile(r"_(\d+)\.txt$", re.I)
PALCC_JUAN_RE = re.compile(r"__juan_(\d+)\.txt$", re.I)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def stamp_now() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def canonical_kanripo_id(value: str) -> str:
    value = value.strip()
    m = re.fullmatch(r"KR([1-6])([A-Za-z])(\d{4})", value)
    if not m:
        raise ValueError(f"Invalid Kanripo ID: {value!r}")
    return f"KR{m.group(1)}{m.group(2).lower()}{m.group(3)}"


def run_git(repo_root: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    return proc.stdout.strip()


def resolve_plan(staging_root: Path, explicit: Path | None) -> Path:
    if explicit:
        p = explicit.expanduser().resolve()
        if p.is_file() and p.name == "kanripo_merge_plan.csv":
            return p.parent
        if p.is_dir() and (p / "kanripo_merge_plan.csv").is_file():
            return p
        raise FileNotFoundError(f"No kanripo_merge_plan.csv under {p}")
    candidates = sorted(
        (staging_root / "_merge_plan").glob("*/kanripo_merge_plan.csv"),
        key=lambda p: p.parent.name,
        reverse=True,
    )
    if not candidates:
        raise FileNotFoundError(f"No merge plan found under {staging_root / '_merge_plan'}")
    return candidates[0].parent


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as h:
        return list(csv.DictReader(h))


def metadata_document_lists(meta: dict[str, Any]) -> list[list[dict[str, Any]]]:
    out: list[list[dict[str, Any]]] = []
    docs = meta.get("documents")
    if isinstance(docs, list):
        out.append(docs)
    for edition in meta.get("editions") or []:
        if isinstance(edition, dict) and isinstance(edition.get("documents"), list):
            out.append(edition["documents"])
    return out


def all_document_records(meta: dict[str, Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for docs in metadata_document_lists(meta):
        result.extend(d for d in docs if isinstance(d, dict))
    return result


def target_document_container(meta: dict[str, Any], target_rel_no_corpus: str) -> list[dict[str, Any]]:
    """Find the existing document list belonging to this work.

    Ordinary records use top-level documents. Siku records normally use one editions[]
    item. If several edition document lists exist, choose the one whose existing path
    falls under the target work directory; otherwise refuse to guess.
    """
    candidates = metadata_document_lists(meta)
    if len(candidates) == 1:
        return candidates[0]
    matched: list[list[dict[str, Any]]] = []
    prefix = target_rel_no_corpus.rstrip("/") + "/"
    for docs in candidates:
        if any(str(d.get("path", "")).startswith(prefix) for d in docs if isinstance(d, dict)):
            matched.append(docs)
    if len(matched) == 1:
        return matched[0]
    if not candidates:
        meta["documents"] = []
        return meta["documents"]
    raise RuntimeError("metadata has multiple document containers and target edition is ambiguous")


def header_from_existing(target: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(target.glob("*.txt")):
        try:
            with path.open("r", encoding="utf-8-sig", errors="replace") as h:
                for line in h:
                    if not line.startswith("#"):
                        break
                    body = line[1:].strip()
                    if ":" in body:
                        k, v = body.split(":", 1)
                        result.setdefault(k.strip().upper(), v.strip())
        except OSError:
            continue
        if result:
            break
    return result


def parse_kanripo_text(raw: str) -> tuple[str, dict[str, str]]:
    meta: dict[str, str] = {}
    body: list[str] = []
    for line in raw.splitlines():
        if line.startswith("# -*-"):
            continue
        pm = ORG_PROP_RE.match(line)
        if pm:
            meta[pm.group(1).upper()] = pm.group(2).strip()
            continue
        mm = ORG_META_RE.match(line)
        if mm:
            meta[mm.group(1).upper()] = mm.group(2).strip()
            continue
        # Mandoku page-break markers are digital layout markup, not textual content.
        line = PB_RE.sub("", line)
        line = line.replace("¶", "")
        body.append(line.rstrip())
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    return "\n".join(body).rstrip() + "\n", meta


def textual_members(zf: zipfile.ZipFile) -> list[str]:
    names: list[str] = []
    for name in zf.namelist():
        if name.endswith("/") or not name.lower().endswith(".txt"):
            continue
        base = Path(name).name.lower()
        if base in {"readme.txt", "license.txt", "licence.txt"}:
            continue
        names.append(name)
    return sorted(names)


def existing_id_map(meta: dict[str, Any]) -> dict[int, int]:
    ids: dict[int, int] = {}
    for d in all_document_records(meta):
        filename = str(d.get("file", ""))
        m = PALCC_JUAN_RE.search(filename)
        doc_id = d.get("document_id")
        if m and isinstance(doc_id, int):
            ids.setdefault(int(m.group(1)), doc_id)
    return ids


def source_urls(meta: dict[str, Any]) -> list[str]:
    urls: list[str] = []
    for d in all_document_records(meta):
        for u in d.get("sources") or []:
            if isinstance(u, str) and u not in urls:
                urls.append(u)
    return urls


def old_primary_paths(meta: dict[str, Any], target_rel_no_corpus: str) -> list[str]:
    prefix = target_rel_no_corpus.rstrip("/") + "/"
    paths: list[str] = []
    for d in all_document_records(meta):
        p = str(d.get("path", ""))
        if p.startswith(prefix) and p not in paths:
            paths.append(p)
    return paths


def upsert_source_witness(meta: dict[str, Any], row: dict[str, str], base_commit: str,
                          old_paths: list[str], old_urls: list[str]) -> None:
    source_id = row["source_id"]
    witness_code = row.get("preferred_source_witness_code", "") or "UNSPECIFIED"
    witness_label = row.get("preferred_source_witness_label", "") or witness_code
    witness_id = f"kanripo:{source_id}:witness:{witness_code}"
    transcription_id = row.get("preferred_digital_transcription_id", "")
    current = {
        "transcription_id": transcription_id,
        "provider": "Kanseki Repository",
        "repository": f"https://github.com/kanripo/{canonical_kanripo_id(source_id)}",
        "branch": row.get("preferred_digital_edition_label", ""),
        "revision": row.get("preferred_digital_revision", ""),
        "retrieved_at": row.get("preferred_digital_transcription_retrieved_at", ""),
        "license": "CC BY-SA (upstream wording; version not specified in harvested record)",
        "preferred": True,
    }
    witnesses = meta.setdefault("source_witnesses", [])
    if not isinstance(witnesses, list):
        raise RuntimeError("metadata source_witnesses exists but is not a list")
    witness = next((w for w in witnesses if isinstance(w, dict) and w.get("witness_id") == witness_id), None)
    if witness is None:
        witness = {
            "witness_id": witness_id,
            "label": witness_label,
            "upstream_code": witness_code,
            "evidence": row.get("preferred_source_witness_evidence", ""),
            "digital_transcriptions": [],
        }
        witnesses.append(witness)
    trans = witness.setdefault("digital_transcriptions", [])
    if not isinstance(trans, list):
        raise RuntimeError("digital_transcriptions exists but is not a list")
    # Exactly one preferred transcription per witness in this generated state.
    for t in trans:
        if isinstance(t, dict):
            t["preferred"] = False
    if not any(isinstance(t, dict) and t.get("transcription_id") == transcription_id for t in trans):
        trans.append(current)
    else:
        for t in trans:
            if isinstance(t, dict) and t.get("transcription_id") == transcription_id:
                t.update(current)

    # Record the replaced PALCC digital state without copying another ~GiB of text.
    legacy = meta.setdefault("superseded_digital_transcriptions", [])
    if not isinstance(legacy, list):
        raise RuntimeError("superseded_digital_transcriptions exists but is not a list")
    legacy_id = f"palcc:{base_commit}:{source_id}:pre-kanripo"
    if not any(isinstance(x, dict) and x.get("transcription_id") == legacy_id for x in legacy):
        provider = "Wikisource" if any("wikisource.org" in u for u in old_urls) else "PALCC legacy transcription"
        legacy.append({
            "transcription_id": legacy_id,
            "provider": provider,
            "repository_revision": base_commit,
            "paths": old_paths,
            "source_urls": old_urls,
            "capture_date": row.get("existing_wikisource_capture_date", "") or None,
            "capture_date_status": row.get("capture_date_status", "") or "unknown",
            "preferred": False,
            "preservation": "recoverable from PALCC Git history; not duplicated in working tree",
        })


def make_documents(meta: dict[str, Any], target_rel_no_corpus: str, title: str,
                   source_id: str, branch: str, revision: str, witness_label: str,
                   archive: Path, target_overlay: Path, old_ids: dict[int, int],
                   old_header: dict[str, str]) -> list[dict[str, Any]]:
    docs: list[dict[str, Any]] = []
    seen_indexes: set[int] = set()
    with zipfile.ZipFile(archive) as zf:
        members = textual_members(zf)
        if not members:
            raise RuntimeError("preferred Kanripo archive contains no textual .txt members")
        for seq, name in enumerate(members, start=1):
            raw = zf.read(name).decode("utf-8-sig", errors="replace")
            body, km = parse_kanripo_text(raw)
            if not body.strip():
                continue
            m = JUAN_FILE_RE.search(Path(name).name)
            idx = int(m.group(1)) if m else seq
            while idx in seen_indexes:
                idx += 1
            seen_indexes.add(idx)
            filename = f"{title}__juan_{idx:03d}.txt"
            chapter = km.get("JUAN") or ("提要／序跋" if idx == 0 else f"卷{idx}")
            page_title = f"{title}/{chapter}"
            header_lines = [
                f"# WORK_TITLE: {title}",
                f"# DISPLAY_TITLE: {old_header.get('DISPLAY_TITLE') or title}",
                f"# PAGE_TITLE: {page_title}",
            ]
            for key in ("AUTHOR", "TIMES"):
                if old_header.get(key):
                    header_lines.append(f"# {key}: {old_header[key]}")
            header_lines.extend([
                "# SOURCE: Kanseki Repository",
                f"# SOURCE_ID: {source_id}",
                f"# SOURCE_WITNESS: {witness_label or 'unspecified'}",
                f"# DIGITAL_EDITION: {branch}",
                f"# DIGITAL_REVISION: {revision}",
                "# LICENSE: CC BY-SA (Kanseki Repository; upstream version unspecified)",
                "",
            ])
            target_overlay.mkdir(parents=True, exist_ok=True)
            (target_overlay / filename).write_text("\n".join(header_lines) + body, encoding="utf-8", newline="\n")
            d: dict[str, Any] = {
                "file": filename,
                "path": f"{target_rel_no_corpus}/{filename}",
                "page_title": page_title,
                "chapter": chapter,
                "sources": [f"https://github.com/kanripo/{canonical_kanripo_id(source_id)}"],
                "digital_transcription_id": f"kanripo:{source_id}:{branch}@{revision}",
            }
            if idx in old_ids:
                d["document_id"] = old_ids[idx]
            docs.append(d)
    if not docs:
        raise RuntimeError("all textual members became empty after markup cleaning")
    return docs


def write_apply_script(path: Path, overlay_zip: Path, base_commit: str, targets: list[str]) -> None:
    quoted_targets = "\n".join(f"  {shlex.quote(t)}" for t in targets)
    script = f'''#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="${{1:-$(pwd)}}"
EXPECTED={json.dumps(base_commit)}
ACTUAL="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "Refusing to apply: repository HEAD is $ACTUAL, expected $EXPECTED." >&2
  exit 1
fi
TARGETS=(
{quoted_targets}
)
for rel in "${{TARGETS[@]}}"; do
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- "$rel")" ]]; then
    echo "Refusing to apply: target has uncommitted changes: $rel" >&2
    exit 1
  fi
done
for rel in "${{TARGETS[@]}}"; do
  find "$REPO_ROOT/$rel" -maxdepth 1 -type f -name '*.txt' -delete
 done
unzip -o {shlex.quote(str(overlay_zip))} -d "$REPO_ROOT"
echo "Kanripo incorporation overlay applied."
echo "No routes were changed. Review git diff before committing."
'''
    path.write_text(script, encoding="utf-8", newline="\n")
    path.chmod(0o755)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo-root", type=Path, default=Path.cwd())
    ap.add_argument("--staging-root", type=Path, required=True)
    ap.add_argument("--plan-dir", type=Path)
    ap.add_argument("--output-root", type=Path)
    ap.add_argument("--limit", type=int, default=0, help="0 means all deterministic rows")
    ap.add_argument("--source-id", action="append", default=[], help="restrict to one or more KR IDs")
    args = ap.parse_args()

    repo = args.repo_root.expanduser().resolve()
    staging = args.staging_root.expanduser().resolve()
    plan_dir = resolve_plan(staging, args.plan_dir)
    rows = read_rows(plan_dir / "kanripo_merge_plan.csv")
    wanted_ids = {canonical_kanripo_id(x) for x in args.source_id}
    selected: list[dict[str, str]] = []
    for row in rows:
        if row.get("action") not in DEFAULT_ACTIONS:
            continue
        sid = canonical_kanripo_id(row.get("source_id", ""))
        if wanted_ids and sid not in wanted_ids:
            continue
        selected.append(row)
    if args.limit > 0:
        selected = selected[:args.limit]
    if not selected:
        raise SystemExit("No deterministic incorporation rows selected")

    base_commit = run_git(repo, "rev-parse", "HEAD")
    out_root = (args.output_root or (staging / "_incorporation_overlays")).expanduser().resolve()
    run_dir = out_root / stamp_now()
    overlay_root = run_dir / "overlay"
    overlay_root.mkdir(parents=True, exist_ok=True)

    applied: list[dict[str, Any]] = []
    skipped: list[dict[str, str]] = []
    targets: list[str] = []

    for n, row in enumerate(selected, start=1):
        sid = canonical_kanripo_id(row["source_id"])
        target_rel = row.get("preferred_palcc_path", "").strip().strip("/")
        try:
            if not target_rel.startswith("corpus/"):
                raise RuntimeError("preferred PALCC path is missing or outside corpus/")
            target = repo / target_rel
            if not target.is_dir():
                raise RuntimeError("target work directory does not exist")
            meta_path = target / "metadata.json"
            if not meta_path.is_file():
                raise RuntimeError("target has no metadata.json")
            dirty = run_git(repo, "status", "--porcelain", "--", target_rel)
            if dirty:
                raise RuntimeError("target has uncommitted changes; commit/stash before generation")
            nested_txt = [p for p in target.rglob("*.txt") if p.parent != target and not any(part in {"variants","kanbun","hanvan","hanmun","annotations","translations"} for part in p.relative_to(target).parts)]
            if nested_txt:
                raise RuntimeError("primary text appears nested below work root; automatic replacement is unsafe")

            branch = row.get("preferred_digital_edition_label", "").strip()
            revision = row.get("preferred_digital_revision", "").strip()
            if not branch or not revision:
                raise RuntimeError("merge plan lacks preferred Kanripo branch/revision; fetch missing-primary sources and rerun plan")
            archive = staging / "kanripo" / "works" / sid / "raw" / f"{sid}-{revision}.zip"
            if not archive.is_file():
                raise RuntimeError(f"preferred cached archive missing: {archive}")

            meta = json.loads(meta_path.read_text(encoding="utf-8-sig"))
            title = str(meta.get("title") or row.get("source_title") or target.name)
            target_no_corpus = target_rel[len("corpus/"):]
            old_paths = old_primary_paths(meta, target_no_corpus)
            old_urls = source_urls(meta)
            old_ids = existing_id_map(meta)
            old_header = header_from_existing(target)
            overlay_target = overlay_root / target_rel
            docs = make_documents(
                meta, target_no_corpus, title, sid, branch, revision,
                row.get("preferred_source_witness_label", ""), archive,
                overlay_target, old_ids, old_header,
            )
            container = target_document_container(meta, target_no_corpus)
            container[:] = docs
            upsert_source_witness(meta, row, base_commit, old_paths, old_urls)
            meta.setdefault("provenance_schema_version", 1)
            overlay_target.mkdir(parents=True, exist_ok=True)
            (overlay_target / "metadata.json").write_text(
                json.dumps(meta, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8", newline="\n",
            )
            targets.append(target_rel)
            applied.append({
                "source_id": sid,
                "title": title,
                "action": row.get("action", ""),
                "target": target_rel,
                "branch": branch,
                "revision": revision,
                "source_witness": row.get("preferred_source_witness_label", ""),
                "new_primary_files": len(docs),
            })
            print(f"[{n}/{len(selected)}] READY {sid} {title} -> {target_rel}", flush=True)
        except Exception as exc:
            skipped.append({
                "source_id": sid,
                "source_title": row.get("source_title", ""),
                "target": target_rel,
                "reason": str(exc),
            })
            print(f"[{n}/{len(selected)}] SKIP {sid}: {exc}", file=sys.stderr, flush=True)

    targets = sorted(set(targets))
    zip_path = run_dir / f"fanya-kanripo-incorporation-overlay-{base_commit[:8]}-{run_dir.name}.zip"
    if applied:
        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as zf:
            for p in sorted(overlay_root.rglob("*")):
                if p.is_file():
                    zf.write(p, p.relative_to(overlay_root).as_posix())
        write_apply_script(run_dir / "apply_overlay.sh", zip_path, base_commit, targets)

    with (run_dir / "generated.csv").open("w", encoding="utf-8-sig", newline="") as h:
        fields = ["source_id","title","action","target","branch","revision","source_witness","new_primary_files"]
        w = csv.DictWriter(h, fieldnames=fields); w.writeheader(); w.writerows(applied)
    with (run_dir / "skipped.csv").open("w", encoding="utf-8-sig", newline="") as h:
        fields = ["source_id","source_title","target","reason"]
        w = csv.DictWriter(h, fieldnames=fields); w.writeheader(); w.writerows(skipped)
    summary = {
        "created_at": utc_now(),
        "base_commit": base_commit,
        "plan_dir": str(plan_dir),
        "selected_rows": len(selected),
        "generated_rows": len(applied),
        "skipped_rows": len(skipped),
        "target_work_directories": len(targets),
        "overlay_zip": str(zip_path) if applied else None,
        "apply_script": str(run_dir / "apply_overlay.sh") if applied else None,
        "corpus_files_changed": 0,
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    (run_dir / "summary.txt").write_text(
        "KANRIPO INCORPORATION OVERLAY\n==============================\n\n"
        f"Base commit:              {base_commit}\n"
        f"Selected deterministic:   {len(selected):,}\n"
        f"Generated:                {len(applied):,}\n"
        f"Skipped:                  {len(skipped):,}\n"
        f"Target work directories:  {len(targets):,}\n"
        f"Corpus files changed:     0\n\n"
        + (f"Overlay: {zip_path}\nApply helper: {run_dir / 'apply_overlay.sh'}\n" if applied else "No overlay generated.\n"),
        encoding="utf-8",
    )
    state_dir = staging / "_state"; state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "last_kanripo_incorporation_overlay.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print((run_dir / "summary.txt").read_text(encoding="utf-8"), end="")
    return 0 if applied else 2


if __name__ == "__main__":
    raise SystemExit(main())
