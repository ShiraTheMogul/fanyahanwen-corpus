#!/usr/bin/env python3
"""Move legacy Kanripo/Kanseki # metadata headers into sibling metadata.json.

This script is intentionally narrow:
- it scans .txt files first;
- it only touches files whose leading header says SOURCE: Kanseki Repository
  and has a Kanripo SOURCE_ID;
- unrelated metadata.json files are never opened;
- if a Kanripo text has no matching document record, one is created;
- existing populated metadata wins; header values fill missing provenance;
- the leading # metadata block is then removed from the text.

Default mode is a dry run. Pass --apply to write changes.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

UTF8_BOM = b"\xef\xbb\xbf"
HEADER_RE = re.compile(r"^#\s*([A-Z0-9_]+):\s*(.*?)\s*$")
KANRIPO_ID_RE = re.compile(r"^KR([1-6])([A-Za-z])(\d{4})$")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo-root", type=Path, default=Path.cwd())
    p.add_argument("--corpus-root", type=Path)
    p.add_argument("--source-id", action="append", default=[],
                   help="Optional KR ID filter; repeatable.")
    p.add_argument("--apply", action="store_true",
                   help="Write the metadata/text changes. Without this, only report.")
    return p.parse_args()


def canonical_sid(value: str) -> str:
    m = KANRIPO_ID_RE.fullmatch(value.strip())
    if not m:
        raise ValueError(f"invalid Kanripo ID {value!r}")
    return f"KR{m.group(1)}{m.group(2).lower()}{m.group(3)}"


def parse_header(path: Path) -> tuple[dict[str, str], str] | None:
    raw = path.read_bytes().decode("utf-8-sig")
    lines = raw.splitlines(keepends=True)
    if not lines:
        return None

    headers: dict[str, str] = {}
    i = 0
    while i < len(lines):
        logical = lines[i].rstrip("\r\n")
        m = HEADER_RE.fullmatch(logical)
        if not m:
            break
        headers[m.group(1).upper()] = m.group(2).strip()
        i += 1

    if not headers:
        return None
    if headers.get("SOURCE", "").casefold() != "kanseki repository":
        return None
    sid = headers.get("SOURCE_ID", "")
    if not KANRIPO_ID_RE.fullmatch(sid):
        return None

    while i < len(lines) and not lines[i].strip():
        i += 1
    body = "".join(lines[i:])
    if not body.strip():
        raise ValueError("Kanripo header is followed by an empty body")
    return headers, body


def read_meta(path: Path) -> dict[str, Any]:
    obj = json.loads(path.read_bytes().decode("utf-8-sig"))
    if not isinstance(obj, dict):
        raise ValueError("metadata root is not a JSON object")
    return obj


def dump_meta(meta: dict[str, Any]) -> bytes:
    return UTF8_BOM + (json.dumps(meta, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def clean_text_bytes(body: str) -> bytes:
    body = body.replace("\r\n", "\n").replace("\r", "\n")
    return UTF8_BOM + body.encode("utf-8")


def corpus_rel(path: Path, corpus_root: Path) -> str:
    return path.resolve().relative_to(corpus_root.resolve()).as_posix()


def document_lists(meta: dict[str, Any]) -> list[list[dict[str, Any]]]:
    result: list[list[dict[str, Any]]] = []
    docs = meta.get("documents")
    if isinstance(docs, list):
        result.append(docs)
    editions = meta.get("editions")
    if isinstance(editions, list):
        for ed in editions:
            if isinstance(ed, dict) and isinstance(ed.get("documents"), list):
                result.append(ed["documents"])
    return result


def all_docs(meta: dict[str, Any]) -> list[dict[str, Any]]:
    return [d for docs in document_lists(meta) for d in docs if isinstance(d, dict)]


def find_doc(meta: dict[str, Any], text_path: Path, corpus_root: Path) -> dict[str, Any] | None:
    rel = corpus_rel(text_path, corpus_root)
    for d in all_docs(meta):
        if str(d.get("path") or "").lstrip("/") == rel:
            return d
        if str(d.get("file") or "") == text_path.name:
            return d
    return None


def choose_container(meta: dict[str, Any], text_path: Path, corpus_root: Path) -> list[dict[str, Any]]:
    # Prefer top-level documents when they already exist.
    if isinstance(meta.get("documents"), list):
        return meta["documents"]

    editions = meta.get("editions")
    if isinstance(editions, list):
        candidates = [
            ed["documents"] for ed in editions
            if isinstance(ed, dict) and isinstance(ed.get("documents"), list)
        ]
        if len(candidates) == 1:
            return candidates[0]

        # If there are several editions, use the one whose existing documents
        # live in the same work directory as this text.
        work_prefix = corpus_rel(text_path.parent, corpus_root).rstrip("/") + "/"
        matching = []
        for docs in candidates:
            if any(
                isinstance(d, dict)
                and str(d.get("path") or "").lstrip("/").startswith(work_prefix)
                for d in docs
            ):
                matching.append(docs)
        if len(matching) == 1:
            return matching[0]

    # No usable document container exists yet. Make the ordinary one.
    meta["documents"] = []
    return meta["documents"]


def add_unique_list_value(meta: dict[str, Any], key: str, value: str) -> None:
    value = value.strip()
    if not value:
        return
    current = meta.get(key)
    if current is None:
        meta[key] = [value]
    elif isinstance(current, list) and value not in current:
        current.append(value)


def promote_work_fields(meta: dict[str, Any], h: dict[str, str]) -> None:
    title = (h.get("WORK_TITLE") or h.get("WORK_BASE_TITLE") or "").strip()
    if title:
        if not str(meta.get("title") or "").strip():
            meta["title"] = title
        elif str(meta.get("title")) != title:
            add_unique_list_value(meta, "aliases", title)

    base = h.get("WORK_BASE_TITLE", "").strip()
    if base and not str(meta.get("work_base_title") or "").strip():
        meta["work_base_title"] = base

    display = h.get("DISPLAY_TITLE", "").strip()
    if display and display != str(meta.get("title") or ""):
        add_unique_list_value(meta, "aliases", display)

    # Older corpus metadata often stores author/source labels in source_categories.
    author = h.get("AUTHOR", "").strip()
    if author:
        add_unique_list_value(meta, "source_categories", author)

    times = h.get("TIMES", "").strip()
    if times:
        if not str(meta.get("period") or "").strip():
            meta["period"] = times
        elif str(meta.get("period")) != times:
            add_unique_list_value(meta, "source_categories", times)


def ensure_document(meta: dict[str, Any], text_path: Path,
                    corpus_root: Path, h: dict[str, str]) -> dict[str, Any]:
    d = find_doc(meta, text_path, corpus_root)
    if d is None:
        d = {
            "file": text_path.name,
            "path": corpus_rel(text_path, corpus_root),
        }
        choose_container(meta, text_path, corpus_root).append(d)

    d["file"] = text_path.name
    d["path"] = corpus_rel(text_path, corpus_root)

    page_title = h.get("PAGE_TITLE", "").strip()
    if page_title and not str(d.get("page_title") or "").strip():
        d["page_title"] = page_title
    if not str(d.get("chapter") or "").strip() and "/" in page_title:
        d["chapter"] = page_title.split("/", 1)[1]

    sid = canonical_sid(h["SOURCE_ID"])
    repo = f"https://github.com/kanripo/{sid}"
    sources = d.get("sources")
    if not isinstance(sources, list):
        sources = []
        d["sources"] = sources
    if repo not in sources:
        sources.append(repo)

    branch = h.get("DIGITAL_EDITION", "").strip()
    revision = h.get("DIGITAL_REVISION", "").strip()
    if branch and revision and not str(d.get("digital_transcription_id") or "").strip():
        d["digital_transcription_id"] = f"kanripo:{sid}:{branch}@{revision}"

    # With the # block gone, body text begins at line 1.
    d.pop("body_start_line", None)
    return d


def witness_key(witness: dict[str, Any]) -> str:
    return str(witness.get("witness_id") or "")


def ensure_witness(meta: dict[str, Any], h: dict[str, str]) -> None:
    sid = canonical_sid(h["SOURCE_ID"])
    repo = f"https://github.com/kanripo/{sid}"
    branch = h.get("DIGITAL_EDITION", "").strip()
    revision = h.get("DIGITAL_REVISION", "").strip()
    transcription_id = (
        f"kanripo:{sid}:{branch}@{revision}"
        if branch and revision else f"kanripo:{sid}"
    )
    label = h.get("SOURCE_WITNESS", "").strip() or "unspecified"
    licence = h.get("LICENSE", "").strip()

    witnesses = meta.get("source_witnesses")
    if not isinstance(witnesses, list):
        witnesses = []
        meta["source_witnesses"] = witnesses

    # Prefer an existing witness whose transcription already points at this KR ID.
    witness = None
    for candidate in witnesses:
        if not isinstance(candidate, dict):
            continue
        trans = candidate.get("digital_transcriptions")
        if not isinstance(trans, list):
            continue
        if any(
            isinstance(t, dict)
            and (
                str(t.get("transcription_id") or "").startswith(f"kanripo:{sid}:")
                or str(t.get("repository") or "") == repo
            )
            for t in trans
        ):
            witness = candidate
            break

    if witness is None:
        witness = {
            "witness_id": f"kanripo:{sid}:witness:legacy-inline",
            "label": label,
            "upstream_code": "UNSPECIFIED",
            "evidence": "legacy Kanripo inline header",
            "digital_transcriptions": [],
        }
        witnesses.append(witness)
    elif not str(witness.get("label") or "").strip():
        witness["label"] = label

    trans = witness.get("digital_transcriptions")
    if not isinstance(trans, list):
        trans = []
        witness["digital_transcriptions"] = trans

    t = next(
        (x for x in trans if isinstance(x, dict)
         and str(x.get("transcription_id") or "") == transcription_id),
        None
    )
    if t is None:
        t = {"transcription_id": transcription_id}
        trans.append(t)

    t.setdefault("provider", "Kanseki Repository")
    t.setdefault("repository", repo)
    if branch:
        t.setdefault("branch", branch)
    if revision:
        t.setdefault("revision", revision)
    if licence:
        t.setdefault("license", licence)
    t.setdefault("preferred", True)

    meta.setdefault("provenance_schema_version", 1)


def atomic_write(path: Path, data: bytes) -> None:
    fd, temp = tempfile.mkstemp(prefix=f".{path.name}.kanripo-meta-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main() -> int:
    args = parse_args()
    repo = args.repo_root.expanduser().resolve()
    corpus = (args.corpus_root or repo / "corpus").expanduser().resolve()
    wanted = {canonical_sid(x) for x in args.source_id}

    # Key simplification: find Kanripo text headers BEFORE opening metadata.json.
    affected: dict[Path, list[tuple[Path, dict[str, str], str]]] = {}
    scanned_txt = 0

    for text_path in corpus.rglob("*.txt"):
        scanned_txt += 1
        try:
            parsed = parse_header(text_path)
        except (OSError, UnicodeError, ValueError) as exc:
            print(f"ERROR {text_path}: {exc}")
            return 2
        if parsed is None:
            continue
        headers, body = parsed
        sid = canonical_sid(headers["SOURCE_ID"])
        if wanted and sid not in wanted:
            continue
        meta_path = text_path.parent / "metadata.json"
        if not meta_path.is_file():
            print(f"ERROR {text_path}: sibling metadata.json is missing")
            return 2
        affected.setdefault(meta_path, []).append((text_path, headers, body))

    if not affected:
        print("No legacy Kanripo/Kanseki # headers found.")
        return 0

    planned_meta: dict[Path, bytes] = {}
    planned_text: dict[Path, bytes] = {}
    source_ids: set[str] = set()

    for meta_path, entries in sorted(affected.items(), key=lambda x: x[0].as_posix()):
        try:
            meta = read_meta(meta_path)
        except Exception as exc:
            print(f"ERROR {meta_path}: {exc}")
            return 2

        for text_path, h, body in entries:
            sid = canonical_sid(h["SOURCE_ID"])
            source_ids.add(sid)
            promote_work_fields(meta, h)
            ensure_document(meta, text_path, corpus, h)
            ensure_witness(meta, h)
            planned_text[text_path] = clean_text_bytes(body)

        planned_meta[meta_path] = dump_meta(meta)

    print("KANRIPO INLINE HEADER MIGRATION")
    print("===============================")
    print(f"Text files scanned:        {scanned_txt:,}")
    print(f"Kanripo works affected:    {len(planned_meta):,}")
    print(f"Kanripo texts affected:    {len(planned_text):,}")
    print(f"Source IDs:                {', '.join(sorted(source_ids))}")

    if not args.apply:
        print("Dry run only. Add --apply to write these changes.")
        return 0

    # Metadata first, then the text header is removed.
    for path, data in planned_meta.items():
        atomic_write(path, data)
    for path, data in planned_text.items():
        atomic_write(path, data)

    print(f"Applied: {len(planned_meta):,} metadata.json files and {len(planned_text):,} text files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
