#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Harvest the Hán-văn PDFs of 《南風雜誌》 into the existing Fanya Hanwen
Corpus layout.

Repository target (no extra witness/source directory is created):

    corpus/越南漢文/clean/大越/阮朝/南風雜誌/
        卷01/
            第001期/
                metadata.json
                Q01_HV_001-006_T001.pdf
            ...
        ...

Non-issue Hán-văn PDFs such as LTHCLC/TLTHC files are retained directly in
their source volume folder because the source filename identifies a volume but
not a numbered issue.  The script does not invent a lower-level classification
for them.

The expected OCR transcription name for an issue is:

    南風雜誌__第001期.txt

No empty OCR files are created.  If that exact file already exists, the script
adds it to the issue's metadata and allocates a document_id.

The source PDF filename and the actual href found in the source catalogue are
preserved.  The harvester does not consult Wikisource or any substitute text
edition: issue metadata is limited to facts supported by the source catalogue
and established publication-level metadata.  Existing valid PDFs are skipped,
so an interrupted run can simply be started again.
"""

from __future__ import annotations

import argparse
import codecs
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urljoin, urlparse
from urllib.request import Request, urlopen

TITLE = "南風雜誌"
CORPUS_ROOT = "越南漢文"
MACRO_REGION = "越南"
PERIOD = "阮朝"
POLITY = "阮"
EDITION = "漢文部"
TARGET_PARTS = ("corpus", CORPUS_ROOT, "clean", "大越", PERIOD, TITLE)

DEFAULT_CATALOGUES = (
    "http://ndclnh-mytho-usa.org/Nam%20Phong%20Tap%20Chi.htm",
    "https://ndclnh-mytho-usa.org/Nam%20Phong%20Tap%20Chi.htm",
    "http://ndclnh-mytho-usa.org/khochuasachcu.htm",
    "https://ndclnh-mytho-usa.org/khochuasachcu.htm",
)


USER_AGENT = (
    "FanyaHanwenCorpus-NamPhongHanVanHarvester/1.0 "
    "(+https://github.com/ShiraTheMogul/fanyahanwen-corpus)"
)

PDF_NAME_RE = re.compile(
    r"^Q(?P<volume>\d{2})_HV_(?P<range_start>\d{3})-(?P<range_end>\d{3})_"
    r"(?P<tail>[^/]+)\.pdf$",
    re.IGNORECASE,
)
ISSUE_TAIL_RE = re.compile(r"^T(?P<issue>\d{3})$", re.IGNORECASE)



@dataclass(frozen=True)
class CataloguePdf:
    filename: str
    url: str
    catalogue_url: str
    volume: int
    range_start: int
    range_end: int
    tail: str
    issue: Optional[int]


class AnchorCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.anchors: list[tuple[str, str]] = []
        self._href: Optional[str] = None
        self._text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, Optional[str]]]) -> None:
        if tag.lower() != "a":
            return
        self._href = None
        self._text = []
        for key, value in attrs:
            if key.lower() == "href" and value:
                self._href = value.strip()
                break

    def handle_data(self, data: str) -> None:
        if self._href is not None:
            self._text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "a" and self._href is not None:
            self.anchors.append((self._href, "".join(self._text).strip()))
            self._href = None
            self._text = []


class TextCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        s = data.strip()
        if s:
            self.parts.append(s)

    def text(self) -> str:
        return " ".join(self.parts)


def request_bytes(url: str, *, timeout: int, retries: int) -> tuple[bytes, str, str]:
    last: Optional[BaseException] = None
    for attempt in range(1, retries + 1):
        req = Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urlopen(req, timeout=timeout) as resp:
                data = resp.read()
                ctype = resp.headers.get("Content-Type", "")
                return data, resp.geturl(), ctype
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            last = exc
            if attempt < retries:
                time.sleep(min(8.0, 1.5 * attempt))
    raise RuntimeError(f"failed to fetch {url}: {last}")


def decode_html(data: bytes, content_type: str) -> str:
    # The catalogue filenames needed here are ASCII, but decode the surrounding
    # page as faithfully as possible.
    m = re.search(r"charset\s*=\s*([^;\s]+)", content_type, re.IGNORECASE)
    candidates = [m.group(1).strip('"\'') if m else "", "utf-8", "windows-1252"]
    for enc in candidates:
        if not enc:
            continue
        try:
            return data.decode(enc)
        except (LookupError, UnicodeDecodeError):
            pass
    return data.decode("utf-8", errors="replace")


def catalogue_pdf_from_anchor(href: str, text: str, base_url: str) -> Optional[CataloguePdf]:
    absolute = urljoin(base_url, html.unescape(href))
    path_name = Path(unquote(urlparse(absolute).path)).name

    candidates = [path_name]
    candidates.extend(re.findall(r"Q\d{2}_HV_[^\s<>\"']+?\.pdf", text, re.IGNORECASE))

    filename = ""
    match: Optional[re.Match[str]] = None
    for candidate in candidates:
        candidate = unquote(candidate)
        m = PDF_NAME_RE.match(candidate)
        if m:
            filename = candidate
            match = m
            break

    if not match:
        return None

    # Preserve the actual anchor href.  If the anchor text carries the filename
    # while the href's basename does not, we still keep the href and never invent
    # a download URL from the filename.
    tail = match.group("tail")
    issue_match = ISSUE_TAIL_RE.match(tail)
    issue = int(issue_match.group("issue")) if issue_match else None

    return CataloguePdf(
        filename=filename,
        url=absolute,
        catalogue_url=base_url,
        volume=int(match.group("volume")),
        range_start=int(match.group("range_start")),
        range_end=int(match.group("range_end")),
        tail=tail,
        issue=issue,
    )


def scrape_catalogue(urls: Iterable[str], *, timeout: int, retries: int) -> tuple[list[CataloguePdf], str]:
    errors: list[str] = []
    for url in urls:
        try:
            data, final_url, content_type = request_bytes(url, timeout=timeout, retries=retries)
            parser = AnchorCollector()
            parser.feed(decode_html(data, content_type))
            found: dict[tuple[str, str], CataloguePdf] = {}
            for href, text in parser.anchors:
                item = catalogue_pdf_from_anchor(href, text, final_url)
                if item:
                    found[(item.filename.casefold(), item.url)] = item
            if found:
                items = sorted(
                    found.values(),
                    key=lambda x: (x.volume, x.issue is None, x.issue or 9999, x.filename.casefold()),
                )
                return items, final_url
            errors.append(f"{final_url}: no Q##_HV_*.pdf anchors found")
        except Exception as exc:
            errors.append(f"{url}: {exc}")
    raise RuntimeError("no usable Nam Phong Hán-văn catalogue found:\n  " + "\n  ".join(errors))


def target_root(repo_root: Path) -> Path:
    return repo_root.joinpath(*TARGET_PARTS)


def volume_dir(root: Path, volume: int) -> Path:
    return root / f"卷{volume:02d}"


def issue_dir(root: Path, volume: int, issue: int) -> Path:
    return volume_dir(root, volume) / f"第{issue:03d}期"


def ocr_filename(issue: int) -> str:
    return f"{TITLE}__第{issue:03d}期.txt"


def ensure_repo_root(path: Path) -> Path:
    path = path.resolve()
    if not (path / "corpus").is_dir():
        raise SystemExit(f"repository root does not contain corpus/: {path}")
    return path


def tracked_metadata_ids(repo_root: Path) -> tuple[set[int], set[int]]:
    work_ids: set[int] = set()
    document_ids: set[int] = set()

    # Fast path: ask the local git index to read tracked metadata.  This is a
    # read-only local Git operation; it does not contact or modify GitHub.
    try:
        cp = subprocess.run(
            [
                "git", "-C", str(repo_root), "grep", "-h", "-E",
                '"(work_id|document_id)"[[:space:]]*:',
                "--", ":(glob)corpus/**/metadata.json",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        for line in cp.stdout.splitlines():
            wm = re.search(r'"work_id"\s*:\s*(\d+)', line)
            dm = re.search(r'"document_id"\s*:\s*(\d+)', line)
            if wm:
                work_ids.add(int(wm.group(1)))
            if dm:
                document_ids.add(int(dm.group(1)))
    except (FileNotFoundError, subprocess.CalledProcessError):
        # Fallback for a copy of the repository with no Git executable/index.
        for meta_path in (repo_root / "corpus").rglob("metadata.json"):
            try:
                obj = json.loads(meta_path.read_text(encoding="utf-8-sig"))
            except Exception:
                continue
            wid = obj.get("work_id")
            if isinstance(wid, int):
                work_ids.add(wid)
            for doc in obj.get("documents") or []:
                did = doc.get("document_id") if isinstance(doc, dict) else None
                if isinstance(did, int):
                    document_ids.add(did)

    # Include uncommitted/new target metadata too, so reruns preserve uniqueness.
    root = target_root(repo_root)
    if root.exists():
        for meta_path in root.rglob("metadata.json"):
            try:
                obj = json.loads(meta_path.read_text(encoding="utf-8-sig"))
            except Exception:
                continue
            wid = obj.get("work_id")
            if isinstance(wid, int):
                work_ids.add(wid)
            for doc in obj.get("documents") or []:
                did = doc.get("document_id") if isinstance(doc, dict) else None
                if isinstance(did, int):
                    document_ids.add(did)

    return work_ids, document_ids


class IdAllocator:
    def __init__(self, used: set[int]) -> None:
        self.used = set(used)
        self.next_id = max(self.used, default=0) + 1

    def take(self) -> int:
        while self.next_id in self.used:
            self.next_id += 1
        value = self.next_id
        self.used.add(value)
        self.next_id += 1
        return value


def load_metadata(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8-sig") as f:
        obj = json.load(f)
    if not isinstance(obj, dict):
        raise ValueError(f"metadata root is not an object: {path}")
    return obj


def write_json_bom(path: Path, obj: dict) -> None:
    payload = json.dumps(obj, ensure_ascii=False, indent=2) + "\n"
    path.write_bytes(codecs.BOM_UTF8 + payload.encode("utf-8"))


def text_body_start_line(path: Path) -> int:
    # Corpus files normally carry a leading metadata/header block.  For future
    # OCR files we avoid guessing: if the file exists, count leading '# KEY:'
    # lines plus one blank separator.  Otherwise this function is never called.
    text = path.read_text(encoding="utf-8-sig", errors="strict")
    lines = text.splitlines()
    n = 0
    for line in lines:
        if re.match(r"^#\s*[A-Z0-9_]+\s*:", line):
            n += 1
            continue
        if n and line.strip() == "":
            n += 1
        break
    return n + 1 if n else 1


def issue_metadata(
    *,
    existing: dict,
    item: CataloguePdf,
    work_ids: IdAllocator,
    document_ids: IdAllocator,
    repo_root: Path,
) -> dict:
    assert item.issue is not None
    issue = item.issue
    leaf = issue_dir(target_root(repo_root), item.volume, issue)

    work_id = existing.get("work_id")
    if not isinstance(work_id, int):
        work_id = work_ids.take()

    sources: list[str] = []
    for source in [item.url, item.catalogue_url]:
        if source and source not in sources:
            sources.append(source)

    meta: dict = {
        "schema_version": 1,
        "work_id": work_id,
        "corpus_root": CORPUS_ROOT,
        "macro_region": MACRO_REGION,
        "period": PERIOD,
        "polity": POLITY,
        "title": f"{TITLE}第{issue}期",
        "work_base_title": TITLE,
    }

    # Nguyễn Bá Trác 阮伯卓 is explicitly identified as Hán-section editor in
    # the early run; issue 26 (1919-08) announces his resignation.  We stop at
    # 26 and do not guess a successor for later issues from secondary summaries.
    if issue <= 26:
        meta["editors"] = ["阮伯卓"]

    meta.update(
        {
            "edition": EDITION,
            "categories": ["越南典籍", "期刊"],
            "sources": sources,
            "is_compilation": True,
        }
    )

    expected_txt = leaf / ocr_filename(issue)
    docs: list[dict] = []
    if expected_txt.exists():
        prior_doc_id: Optional[int] = None
        for doc in existing.get("documents") or []:
            if isinstance(doc, dict) and doc.get("file") == expected_txt.name:
                candidate = doc.get("document_id")
                if isinstance(candidate, int):
                    prior_doc_id = candidate
                    break
        if prior_doc_id is None:
            prior_doc_id = document_ids.take()
        rel = expected_txt.relative_to(repo_root / "corpus").as_posix()
        docs.append(
            {
                "document_id": prior_doc_id,
                "file": expected_txt.name,
                "path": rel,
                "body_start_line": text_body_start_line(expected_txt),
            }
        )

    meta["documents"] = docs
    meta["known_commentaries"] = existing.get("known_commentaries") or []
    return meta


def valid_existing_pdf(path: Path) -> bool:
    if not path.is_file() or path.stat().st_size < 5:
        return False
    try:
        with path.open("rb") as f:
            return f.read(5) == b"%PDF-"
    except OSError:
        return False


def download_pdf(item: CataloguePdf, destination: Path, *, timeout: int, retries: int, delay: float) -> str:
    if valid_existing_pdf(destination):
        return "existing"

    destination.parent.mkdir(parents=True, exist_ok=True)
    last: Optional[BaseException] = None

    for attempt in range(1, retries + 1):
        temp_path: Optional[Path] = None
        try:
            req = Request(item.url, headers={"User-Agent": USER_AGENT})
            with urlopen(req, timeout=timeout) as resp:
                fd, temp_name = tempfile.mkstemp(prefix=destination.name + ".", suffix=".part", dir=destination.parent)
                os.close(fd)
                temp_path = Path(temp_name)
                with temp_path.open("wb") as out:
                    while True:
                        chunk = resp.read(1024 * 1024)
                        if not chunk:
                            break
                        out.write(chunk)

            if not valid_existing_pdf(temp_path):
                raise RuntimeError("download did not begin with a PDF signature")
            temp_path.replace(destination)
            if delay:
                time.sleep(delay)
            return "downloaded"
        except (HTTPError, URLError, TimeoutError, OSError, RuntimeError) as exc:
            last = exc
            if temp_path and temp_path.exists():
                temp_path.unlink(missing_ok=True)
            if attempt < retries:
                time.sleep(min(12.0, 2.0 * attempt))

    raise RuntimeError(f"failed after {retries} attempts: {last}")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def print_plan(items: list[CataloguePdf]) -> None:
    issues = sorted(x.issue for x in items if x.issue is not None)
    missing = [n for n in range(1, 211) if n not in set(issues)]
    supplements = [x for x in items if x.issue is None]
    print(f"Hán-văn PDFs found: {len(items)}")
    print(f"numbered issues found: {len(issues)} / 210")
    print(f"volume-level/non-issue PDFs: {len(supplements)}")
    print("missing numbered issues in this source:", ", ".join(map(str, missing)) if missing else "none")


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Harvest 《南風雜誌》 Hán-văn PDFs into the corpus.")
    p.add_argument("--repo-root", type=Path, default=Path.cwd(), help="Fanya Hanwen Corpus repository root (default: current directory)")
    p.add_argument("--catalog-url", action="append", default=[], help="catalogue page to try; may be supplied more than once")
    p.add_argument("--no-download", action="store_true", help="create/update folders and metadata but do not download PDFs")
    p.add_argument("--plan", action="store_true", help="scrape and report source holdings without writing anything")
    p.add_argument("--timeout", type=int, default=90, help="network timeout in seconds (default: 90)")
    p.add_argument("--retries", type=int, default=4, help="network attempts per request (default: 4)")
    p.add_argument("--delay", type=float, default=0.20, help="delay after each successful PDF download (default: 0.20s)")
    p.add_argument("--hash", action="store_true", help="print SHA-256 for downloaded/existing PDFs (slower)")
    return p.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)
    repo_root = ensure_repo_root(args.repo_root)
    catalogues = tuple(args.catalog_url) if args.catalog_url else DEFAULT_CATALOGUES

    print("Scraping Hán-văn catalogue…")
    items, catalogue_url = scrape_catalogue(catalogues, timeout=args.timeout, retries=args.retries)
    # Keep the final successful page as provenance for all items gathered from it.
    items = [
        CataloguePdf(
            filename=x.filename,
            url=x.url,
            catalogue_url=catalogue_url,
            volume=x.volume,
            range_start=x.range_start,
            range_end=x.range_end,
            tail=x.tail,
            issue=x.issue,
        )
        for x in items
    ]
    print_plan(items)

    if args.plan:
        return 0


    print("Reading existing corpus IDs…")
    used_work_ids, used_document_ids = tracked_metadata_ids(repo_root)
    work_ids = IdAllocator(used_work_ids)
    document_ids = IdAllocator(used_document_ids)

    root = target_root(repo_root)
    root.mkdir(parents=True, exist_ok=True)

    failures: list[str] = []
    downloaded = 0
    existing = 0
    metadata_written = 0
    supplements = 0

    for index, item in enumerate(items, start=1):
        vol_dir = volume_dir(root, item.volume)
        vol_dir.mkdir(parents=True, exist_ok=True)

        if item.issue is None:
            # The catalogue gives no numbered issue for these files.  Keep them
            # at the volume level instead of inventing an issue/supplement work.
            supplements += 1
            pdf_path = vol_dir / item.filename
        else:
            leaf = issue_dir(root, item.volume, item.issue)
            leaf.mkdir(parents=True, exist_ok=True)
            meta_path = leaf / "metadata.json"
            try:
                existing_meta = load_metadata(meta_path)
                meta = issue_metadata(
                    existing=existing_meta,
                    item=item,
                    work_ids=work_ids,
                    document_ids=document_ids,
                    repo_root=repo_root,
                )
                write_json_bom(meta_path, meta)
                metadata_written += 1
            except Exception as exc:
                failures.append(f"{item.filename}: metadata: {exc}")
                print(f"[{index}/{len(items)}] metadata FAILED {item.filename}: {exc}", file=sys.stderr)
                continue
            pdf_path = leaf / item.filename

        if args.no_download:
            print(f"[{index}/{len(items)}] prepared {pdf_path.relative_to(repo_root)}")
            continue

        try:
            state = download_pdf(
                item, pdf_path, timeout=args.timeout, retries=args.retries, delay=args.delay
            )
            if state == "downloaded":
                downloaded += 1
            else:
                existing += 1
            suffix = f" sha256={sha256_file(pdf_path)}" if args.hash else ""
            print(f"[{index}/{len(items)}] {state} {pdf_path.relative_to(repo_root)}{suffix}")
        except Exception as exc:
            failures.append(f"{item.filename}: download: {exc}")
            print(f"[{index}/{len(items)}] FAILED {item.filename}: {exc}", file=sys.stderr)

    print("\nDone.")
    print(f"metadata issue folders written: {metadata_written}")
    print(f"volume-level/non-issue PDFs seen: {supplements}")
    if not args.no_download:
        print(f"PDFs downloaded: {downloaded}")
        print(f"PDFs already present: {existing}")
    if failures:
        print(f"failures: {len(failures)}", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print("Re-run the same command to resume; valid existing PDFs are skipped.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
