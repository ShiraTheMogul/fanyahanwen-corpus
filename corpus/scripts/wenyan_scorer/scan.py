"""
Full-corpus scan: enumerate every document, score it, stream the results out.

Scale (2026-09-11)
------------------
    corpus size      ~270,000 .txt documents, ~1.16 x 10^9 Han characters
    read throughput  1.26 M chars/sec on the OneDrive/WSL mount
    score throughput 0.29 M chars/sec/core (whole), 0.51 (paragraph)

CAVEAT ON THE TIMING ESTIMATE: read and score figures above were measured in the
sandboxed VM that Claude's `device_bash` reaches, which reports 2 CPUs. Llinos's
own WSL shell reports 24. They are not the same environment, so the wall-clock
estimate derived from them was wrong and is not repeated here. Run it and look
at the `docs/s` line; the run reports its own throughput every 500 documents.

Whatever the wall clock turns out to be, it is long enough that the run has to
survive itself. Three things follow, and they are why this module exists rather
than a for-loop over `iter_works`:

1. **Resumable.** Two hours of work must not be lost to a OneDrive sync stall, a
   laptop sleep, or a Ctrl-C. Results are appended to JSONL as they are produced
   and a re-run skips every path already in the output file.

2. **Streaming.** 270,000 result records cannot sit in memory, and neither can
   the file list. Enumeration uses `os.walk` and yields as it goes;
   `corpus.iter_works` used `sorted(rglob(...))`, which materialises the entire
   listing before yielding anything — on 四庫全書 that is minutes of apparent
   hang followed by a large allocation.

3. **Parallel.** Reading and scoring are within a factor of two of each other,
   so neither dominates and both are worth overlapping. `--workers` defaults to
   one per CPU.

Why enumerate .txt rather than metadata.json
--------------------------------------------
`metadata.json` does not reliably enumerate documents:

    四庫全書   2,740 metadata.json   94,626 .txt      (many juan per work)
    維基大典   5,621 metadata.json    4,092 .txt      (more metadata than text)
    礦藝大典   4,403 metadata.json    4,116 .txt
    中國漢文   4,339 metadata.json  162,175 indexed docs

維基大典 and 礦藝大典 have MORE metadata files than text files, so roughly 1,800
works there have metadata and no body. Walking metadata would therefore both miss
documents and invent them. This walks the text and attaches the nearest ancestor
metadata.json where one exists.

Why not drive it from index_corpus.csv
---------------------------------------
It is tempting — 172,613 rows with paths and metadata, one 54MB read, no
filesystem traversal. But the index is stale:

    root        .txt on disk   rows in index_corpus.csv
    四庫全書           94,626                          0
    維基大典            4,092                          0
    礦藝大典            4,116                          0
    琉球漢文              143                          0
    日本漢文              949                         46

It covers 中國漢文 and 朝鮮漢文 and is missing something like 104,000 documents,
including the whole of 四庫全書. `--index` is offered anyway, because when you
only want those two roots it is much faster than walking; it just cannot be the
default.
"""
from __future__ import annotations

import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Sequence, Tuple

from .rules import DEFAULT_RULESETS, load_rulesets
from .score import (DEFAULT_LC_THRESHOLD, DEFAULT_MIN_HAN, DEFAULT_VN_THRESHOLD,
                    score_segment)

SKIP_DIR_NAMES = {"raw", "archives", "scripts", ".git", "__pycache__",
                  ".metadata", "node_modules"}


@dataclass
class Doc:
    path: str
    rel: str
    corpus_root: str
    category: str
    work: str
    period: str
    title: str
    size: int


def _meta_for(folder: Path, cache: Dict[Path, dict]) -> dict:
    """Nearest-ancestor metadata.json, cached per directory.

    Walks up at most four levels: a juan file sits beside its work's metadata,
    and nothing in this corpus puts it further away than that.
    """
    cur = folder
    for _ in range(4):
        if cur in cache:
            return cache[cur]
        mp = cur / "metadata.json"
        if mp.exists():
            try:
                meta = json.loads(mp.read_text(encoding="utf-8-sig"))
                if isinstance(meta, dict):
                    cache[folder] = meta
                    cache[cur] = meta
                    return meta
            except (OSError, json.JSONDecodeError):
                pass
        if cur.parent == cur:
            break
        cur = cur.parent
    cache[folder] = {}
    return {}


def enumerate_docs(root: str | Path, *, skip_raw: bool = True) -> Iterator[Doc]:
    """Stream every .txt under `root`, with metadata attached where available.

    `skip_raw=True` (the default) skips `raw/` directories. Every corpus root
    holds `clean/` and `raw/` side by side and they are the same works twice;
    scanning both doubles the runtime and the output for no information.
    """
    root = Path(root)

    # os.walk() on a path that does not exist yields NOTHING and raises nothing.
    # Without this check a typo'd or relative path reports "0 documents", which
    # reads as "your corpus is empty" rather than "that path is not there" —
    # and that is exactly how it failed the first time it was run for real.
    if not root.exists():
        raise FileNotFoundError(
            f"no such path: {root}\n"
            f"  (resolved from the current directory: {Path.cwd()})\n"
            f"  If you are running from inside the repo, pass an absolute path "
            f"or the right number of '..' — e.g. from corpus/scripts/wenyan_scorer "
            f"the corpus root is '../..'."
        )
    if not root.is_dir():
        raise NotADirectoryError(f"not a directory: {root}")

    cache: Dict[Path, dict] = {}

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        d = Path(dirpath)
        dirnames[:] = [
            n for n in dirnames
            if n not in SKIP_DIR_NAMES or (n == "raw" and not skip_raw)
        ]
        txts = [f for f in filenames if f.endswith(".txt")]
        if not txts:
            continue
        meta = _meta_for(d, cache)
        try:
            rel_parts = d.relative_to(root).parts
        except ValueError:
            rel_parts = d.parts

        for fn in sorted(txts):
            p = d / fn
            try:
                size = p.stat().st_size
            except OSError:
                continue
            yield Doc(
                path=str(p),
                rel=str(p.relative_to(root)) if p.is_relative_to(root) else str(p),
                corpus_root=str(meta.get("corpus_root") or (rel_parts[0] if rel_parts else root.name)),
                category=str(meta.get("macro_region") or (rel_parts[1] if len(rel_parts) > 1 else "")),
                work=str(meta.get("title") or d.name),
                period=str(meta.get("period") or ""),
                title=Path(fn).stem,
                size=size,
            )


def enumerate_from_index(index_csv: str | Path, corpus_root_dir: str | Path) -> Iterator[Doc]:
    """Enumerate from index_corpus.csv instead of walking.

    Much faster where the index is current, which as of 2026-09-11 means
    中國漢文 and 朝鮮漢文 only. `clean_path` uses Windows separators; they are
    normalised here.
    """
    import csv

    base = Path(corpus_root_dir)
    with open(index_csv, encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            if r.get("is_empty_page") == "1":
                continue
            cp = (r.get("clean_path") or "").replace("\\", "/")
            if not cp:
                continue
            p = base / cp
            try:
                size = int(r.get("char_count_clean") or 0)
            except ValueError:
                size = 0
            yield Doc(
                path=str(p), rel=cp,
                corpus_root=r.get("corpus_root") or "",
                category=r.get("category") or "",
                work=r.get("work_title") or "",
                period=r.get("times") or "",
                title=r.get("page_title") or "",
                size=size,
            )


# --- worker ----------------------------------------------------------------
_RULES = None
_OPTS: dict = {}


def _init_worker(rulesets: Sequence[str], opts: dict) -> None:
    global _RULES, _OPTS
    _RULES = load_rulesets(list(rulesets))
    _OPTS = opts


def _score_one(doc: Doc) -> Optional[dict]:
    try:
        text = Path(doc.path).read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as exc:
        return {"p": doc.rel, "error": f"{type(exc).__name__}: {exc}"}

    r = score_segment(
        text, _RULES,
        keep_evidence=False,
        min_han=_OPTS["min_han"],
        lc_threshold=_OPTS["lc_threshold"],
        vn_threshold=_OPTS["vn_threshold"],
        apparatus_limit=_OPTS["apparatus_limit"],
    )
    lc, vn = r.get("lc_rate", 0.0), r.get("vn_rate", 0.0)
    total = lc + vn
    out = {
        "p": doc.rel,
        "root": doc.corpus_root,
        "cat": doc.category,
        "work": doc.work,
        "period": doc.period,
        "han": r["han_chars"],
        "label": r["label"],
        "lc": round(lc, 2),
        "vn": round(vn, 2),
        "vn_share": round(vn / total, 4) if total else 0.0,
        "prob": r.get("probability_literary"),
        "punct": r.get("punctuated"),
        "kana_r": r.get("apparatus", {}).get("kana_ratio", 0.0),
        "skipped": len(r.get("skipped_rules") or []),
    }
    # Only the vernacular hits are kept per-document. They are what you actually
    # go and look at — a document labelled not_literary, or a literary one with
    # a stray vernacular hit, is a rule to inspect. Keeping every literary hit
    # for 270,000 documents would make the output file larger than the corpus.
    vn_hits = {h["rule_id"]: h["count"] for h in r.get("hits", []) if h["polarity"] == "vn"}
    if vn_hits:
        out["vn_hits"] = vn_hits
    return out


def _load_done(out_path: Path) -> set:
    """Paths already scored, for resuming. Tolerates a truncated final line,
    which is what you get from a kill in the middle of a write."""
    done = set()
    if not out_path.exists():
        return done
    with open(out_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                done.add(json.loads(line)["p"])
            except (json.JSONDecodeError, KeyError):
                continue
    return done


def scan(
    root: str | Path,
    out_path: str | Path,
    *,
    rulesets: Sequence[str] = DEFAULT_RULESETS,
    workers: int = 0,
    limit: Optional[int] = None,
    min_han: int = DEFAULT_MIN_HAN,
    lc_threshold: float = DEFAULT_LC_THRESHOLD,
    vn_threshold: float = DEFAULT_VN_THRESHOLD,
    apparatus_limit: Optional[float] = None,
    index_csv: Optional[str] = None,
    skip_raw: bool = True,
    resume: bool = True,
    progress_every: int = 500,
    flush_every: int = 50,
    log=sys.stderr,
) -> Dict[str, object]:
    import multiprocessing as mp

    root_p = Path(root)
    if index_csv is None:
        # Validate here, before any worker starts: raising inside the pool buries
        # a one-line message under a multiprocessing traceback.
        if not root_p.exists():
            print(
                f"ERROR: no such path: {root}\n"
                f"  Relative paths resolve against the current directory,\n"
                f"  which is {Path.cwd()}\n"
                f"  From corpus/scripts/wenyan_scorer the corpus root is '../..',\n"
                f"  or give an absolute path.",
                file=log, flush=True,
            )
            raise SystemExit(2)
        if not root_p.is_dir():
            print(f"ERROR: not a directory: {root}", file=log, flush=True)
            raise SystemExit(2)

    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Writing the checkpoint onto a cloud-synced path makes every flush a sync
    # event. Over 270,000 records that is the slowest thing in the run, and it
    # thrashes the sync client for an hour. Say so rather than let it happen.
    op = str(out_path.resolve())
    if "/mnt/c/" in op.replace("\\", "/") or "OneDrive" in op:
        print(
            f"WARNING: output {out_path} is on a Windows/OneDrive-synced path.\n"
            f"         Every checkpoint flush becomes a sync event. Put it on the\n"
            f"         WSL filesystem instead, e.g. --out ~/scan.jsonl, and copy\n"
            f"         it across when the run finishes.",
            file=log, flush=True,
        )

    done = _load_done(out_path) if resume else set()
    if done:
        print(f"resuming: {len(done):,} documents already scored in {out_path}",
              file=log, flush=True)

    docs = (enumerate_from_index(index_csv, root) if index_csv
            else enumerate_docs(root, skip_raw=skip_raw))

    def pending() -> Iterator[Doc]:
        n = 0
        for d in docs:
            if d.rel in done:
                continue
            yield d
            n += 1
            if limit is not None and n >= limit:
                return

    opts = {"min_han": min_han, "lc_threshold": lc_threshold,
            "vn_threshold": vn_threshold, "apparatus_limit": apparatus_limit}

    if workers <= 0:
        workers = max(1, (os.cpu_count() or 2))

    counts: Dict[str, int] = {}
    by_root: Dict[str, Dict[str, int]] = {}
    errors = 0
    chars = 0
    n = 0
    t0 = time.time()

    # Append mode: the output file IS the checkpoint. Line-buffered and flushed
    # per record, because a buffered write that never reaches disk is exactly the
    # work a resume cannot recover.
    with open(out_path, "a", encoding="utf-8") as fh:
        def record(rec: Optional[dict]) -> None:
            nonlocal n, errors, chars
            if rec is None:
                return
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            n += 1
            # Flush in batches rather than per record. Per-record flushing bounds
            # loss to one document but costs a syscall (and, on a synced path, a
            # sync event) 270,000 times. flush_every=50 bounds loss to 50
            # documents, which is seconds of work, and is far cheaper.
            if flush_every <= 1 or n % flush_every == 0:
                fh.flush()
            if "error" in rec:
                errors += 1
                return
            chars += rec.get("han", 0)
            counts[rec["label"]] = counts.get(rec["label"], 0) + 1
            rb = by_root.setdefault(rec["root"], {})
            rb[rec["label"]] = rb.get(rec["label"], 0) + 1
            if n % progress_every == 0:
                dt = time.time() - t0
                print(f"  {n:>7,} docs  {chars/1e6:>8.1f}M han  "
                      f"{n/dt:>6.1f} docs/s  {chars/dt/1e6:>5.2f}M han/s  "
                      f"{counts}", file=log, flush=True)

        if workers == 1:
            _init_worker(rulesets, opts)
            for d in pending():
                record(_score_one(d))
        else:
            ctx = mp.get_context("spawn" if sys.platform == "win32" else "fork")
            with ctx.Pool(workers, initializer=_init_worker,
                          initargs=(list(rulesets), opts)) as pool:
                for rec in pool.imap_unordered(_score_one, pending(), chunksize=16):
                    record(rec)

    dt = time.time() - t0

    if n == 0 and not done:
        print(
            f"\nWARNING: walked {root} and found no .txt files to score.\n"
            f"  Checked for '*.txt', skipping {sorted(SKIP_DIR_NAMES)}.\n"
            f"  If the corpus stores text under raw/ only, pass --include-raw.\n"
            f"  If you meant a different directory, note that relative paths\n"
            f"  resolve against {Path.cwd()}.",
            file=log, flush=True,
        )

    summary = {
        "documents": n,
        "errors": errors,
        "han_chars": chars,
        "elapsed_seconds": round(dt, 1),
        "docs_per_second": round(n / dt, 1) if dt else None,
        "labels": counts,
        "labels_by_corpus_root": by_root,
        "output": str(out_path),
        "workers": workers,
    }
    print(f"\ndone: {n:,} documents, {chars/1e6:.1f}M Han, {dt/60:.1f} min "
          f"({workers} workers)", file=log, flush=True)
    return summary


def summarise_jsonl(path: str | Path, group: str = "root") -> Dict[str, object]:
    """Aggregate a completed (or partial) scan without loading it into memory."""
    counts: Dict[str, Dict[str, int]] = {}
    totals: Dict[str, int] = {}
    han: Dict[str, int] = {}
    flagged: List[Tuple[float, str, str]] = []

    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "error" in r:
                continue
            k = str(r.get(group, ""))
            counts.setdefault(k, {})
            counts[k][r["label"]] = counts[k].get(r["label"], 0) + 1
            totals[r["label"]] = totals.get(r["label"], 0) + 1
            han[k] = han.get(k, 0) + r.get("han", 0)
            # A literary document carrying any vernacular hit is a rule to look
            # at; keep the worst offenders for inspection.
            if r.get("vn_hits") and r["label"] == "literary":
                flagged.append((r.get("vn_share", 0.0), r["p"],
                                ",".join(r["vn_hits"])))

    flagged.sort(reverse=True)
    return {
        "labels": totals,
        f"by_{group}": counts,
        f"han_by_{group}": han,
        "literary_docs_with_vernacular_hits": len(flagged),
        "worst_offenders": [
            {"vn_share": s, "path": p, "rules": r} for s, p, r in flagged[:40]
        ],
    }
