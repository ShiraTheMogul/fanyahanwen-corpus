#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Singapore simplified-character extractor from Taiwan MOE 《異體字字典》.

Version 9 uses ONLY the MOE's documented exact 字號 lookup.

Why this version exists
-----------------------
Earlier approaches tried to infer MOE's internal numeric `dictView.jsp?ID=...`
identifier. That is unsafe: the numeric IDs are not sequential.

The CSV already gives us the stable identifier we actually need:

    A00694-005

The MOE 字號查詢 documentation explicitly permits a complete variant 字號 such
as A00001-001. Therefore this script asks the official search form for each
exact CSV moe_id, follows the returned detail link, confirms that the page's
record label is the exact same moe_id, and only then inspects 〔關鍵文獻〕.

No glyph search.
No numeric-ID arithmetic.
No normalization.
No guessing.

The original CSV is never modified.

Outputs, all UTF-8 with BOM:
    singapore_simplified_verified.csv
    singapore_simplified_review.csv
    singapore_simplified_errors.csv

Checkpoint:
    singapore_simplified_scan_v9.sqlite3

The checkpoint makes Ctrl+C / restart safe.
"""

from __future__ import annotations

import argparse
import csv
import html
import random
import re
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from http.cookiejar import CookieJar
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit
from urllib.request import HTTPCookieProcessor, Request, build_opener


SCRIPT_VERSION = "9.0-exact-moe-id"

BASE_URL = "https://dict.variants.moe.edu.tw/"
HOME_URL = urljoin(BASE_URL, "index.jsp")
ID_SEARCH_FORM_URL = urljoin(BASE_URL, "search.jsp?ID=7")
DETAIL_URL = urljoin(BASE_URL, "dictView.jsp")

DEFAULT_SOURCE = "學生簡體字字典"

# This is our known positive control.
SELF_TEST_ID = "A00694-005"
SELF_TEST_LOCATOR = "口部"

# This is an 附錄字 control. It proves that the record-ID parser is not limited
# to pages labelled 異體字.
APPENDIX_SELF_TEST_ID = "A00004-007"

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/152.0 Safari/537.36"
)

MOE_ID_PATTERN = r"[ABCN]\d{5}(?:-\d{3}(?:-\d+)?)?"
MOE_ID_RE = re.compile(
    r"(?<![A-Z0-9-])(" + MOE_ID_PATTERN + r")(?![-0-9])"
)

OUTPUT_FIELDS = [
    "singapore_glyph",
    "moe_id",
    "grade",
    "canonical_glyph",
    "canonical_moe_id",
    "source",
    "source_locator",
    "key_literature",
    "cross_reference_targets",
    "also_standard_elsewhere",
    "glyph_encoding",
    "verification_status",
    "automatic_mapping_safe",
    "conversion_from_candidate",
    "moe_record_url",
    "evidence_excerpt",
]


@dataclass(frozen=True)
class Candidate:
    glyph: str
    moe_id: str
    grade: str
    canonical_moe_id: str
    canonical_glyph: str


@dataclass
class FormControl:
    tag: str
    type: str
    name: str
    value: str


@dataclass
class ParsedForm:
    action: str
    method: str
    controls: list[FormControl]
    text: str


class PageParser(HTMLParser):
    BLOCK_TAGS = {
        "p", "div", "section", "article", "header", "footer", "main",
        "li", "tr", "td", "th", "br",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "table", "ul", "ol",
    }

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.links: list[str] = []
        self._ignored_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        tag = tag.lower()

        if tag in {"script", "style"}:
            self._ignored_depth += 1
            return

        if self._ignored_depth:
            return

        if tag in self.BLOCK_TAGS:
            self.parts.append("\n")

        if tag == "a":
            href = dict(attrs).get("href")
            if href:
                self.links.append(html.unescape(href))

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()

        if tag in {"script", "style"}:
            if self._ignored_depth:
                self._ignored_depth -= 1
            return

        if self._ignored_depth:
            return

        if tag in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self._ignored_depth and data:
            self.parts.append(data)

    def text(self) -> str:
        raw = "".join(self.parts)
        raw = html.unescape(raw)
        raw = raw.replace("\u3000", " ")
        raw = re.sub(r"[ \t\r\f\v]+", " ", raw)
        raw = re.sub(r" *\n *", "\n", raw)
        raw = re.sub(r"\n{2,}", "\n", raw)
        return raw.strip()


class FormParser(HTMLParser):
    """
    Discover the site's live 字號查詢 form.

    We intentionally do not hard-code the two WORD fields: the current page is
    inspected at startup, which is why the script survived the earlier form
    uncertainty.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.forms: list[ParsedForm] = []
        self.current: ParsedForm | None = None

    def handle_starttag(self, tag: str, attrs) -> None:
        tag = tag.lower()
        attrs_dict = dict(attrs)

        if tag == "form":
            self.current = ParsedForm(
                action=html.unescape(attrs_dict.get("action", "") or ""),
                method=(attrs_dict.get("method", "get") or "get").lower(),
                controls=[],
                text="",
            )
            return

        if self.current is None:
            return

        if tag == "input":
            self.current.controls.append(
                FormControl(
                    tag="input",
                    type=(attrs_dict.get("type", "text") or "text").lower(),
                    name=attrs_dict.get("name", "") or "",
                    value=html.unescape(attrs_dict.get("value", "") or ""),
                )
            )

        elif tag == "button":
            self.current.controls.append(
                FormControl(
                    tag="button",
                    type=(attrs_dict.get("type", "submit") or "submit").lower(),
                    name=attrs_dict.get("name", "") or "",
                    value=html.unescape(attrs_dict.get("value", "") or ""),
                )
            )

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "form" and self.current is not None:
            self.current.text = re.sub(r"\s+", " ", self.current.text).strip()
            self.forms.append(self.current)
            self.current = None

    def handle_data(self, data: str) -> None:
        if self.current is not None and data:
            self.current.text += " " + data


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def parse_page(page: str) -> tuple[str, list[str]]:
    parser = PageParser()
    parser.feed(page)
    return parser.text(), parser.links


def normalize_inline(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def is_private_use(glyph: str) -> bool:
    for ch in glyph:
        cp = ord(ch)
        if (
            0xE000 <= cp <= 0xF8FF
            or 0xF0000 <= cp <= 0xFFFFD
            or 0x100000 <= cp <= 0x10FFFD
        ):
            return True
    return False


def glyph_encoding(glyph: str) -> str:
    if not glyph:
        return "missing_or_image_only"
    if is_private_use(glyph):
        return "moe_private_use"
    return "unicode"


def clean_grade(value: str) -> str:
    return value.strip()


def read_candidates(path: Path) -> list[Candidate]:
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)

        required = {
            "glyph",
            "moe_id",
            "grade",
            "canonical_moe_id",
            "canonical_glyph",
        }

        missing = required - set(reader.fieldnames or [])
        if missing:
            raise SystemExit(
                "Missing required CSV columns: "
                + ", ".join(sorted(missing))
            )

        out: list[Candidate] = []

        for row in reader:
            grade = clean_grade(row.get("grade") or "")

            if grade == "正字":
                continue

            moe_id = (row.get("moe_id") or "").strip()

            if not moe_id:
                continue

            out.append(
                Candidate(
                    glyph=row.get("glyph") or "",
                    moe_id=moe_id,
                    grade=grade,
                    canonical_moe_id=(
                        row.get("canonical_moe_id") or ""
                    ).strip(),
                    canonical_glyph=row.get("canonical_glyph") or "",
                )
            )

    return out


def connect_cache(path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(path)

    db.execute(
        """
        CREATE TABLE IF NOT EXISTS scan (
            moe_id TEXT PRIMARY KEY,
            checked_at TEXT NOT NULL,
            source TEXT NOT NULL,
            matched INTEGER NOT NULL,
            source_locator TEXT,
            key_literature TEXT,
            cross_reference_targets TEXT,
            also_standard_elsewhere INTEGER NOT NULL DEFAULT 0,
            record_url TEXT,
            evidence_excerpt TEXT,
            status TEXT NOT NULL,
            error TEXT
        )
        """
    )

    db.commit()
    return db


TERMINAL_STATUSES = {
    "verified_key_literature",
    "source_not_in_key_literature",
    "no_key_literature_block",
}


def cache_get(
    db: sqlite3.Connection,
    moe_id: str,
    source: str,
) -> dict | None:
    row = db.execute(
        """
        SELECT
            moe_id,
            checked_at,
            source,
            matched,
            source_locator,
            key_literature,
            cross_reference_targets,
            also_standard_elsewhere,
            record_url,
            evidence_excerpt,
            status,
            error
        FROM scan
        WHERE moe_id = ? AND source = ?
        """,
        (moe_id, source),
    ).fetchone()

    if not row:
        return None

    names = [
        "moe_id",
        "checked_at",
        "source",
        "matched",
        "source_locator",
        "key_literature",
        "cross_reference_targets",
        "also_standard_elsewhere",
        "record_url",
        "evidence_excerpt",
        "status",
        "error",
    ]

    return dict(zip(names, row))


def cache_put(db: sqlite3.Connection, result: dict) -> None:
    db.execute(
        """
        INSERT INTO scan (
            moe_id,
            checked_at,
            source,
            matched,
            source_locator,
            key_literature,
            cross_reference_targets,
            also_standard_elsewhere,
            record_url,
            evidence_excerpt,
            status,
            error
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(moe_id) DO UPDATE SET
            checked_at = excluded.checked_at,
            source = excluded.source,
            matched = excluded.matched,
            source_locator = excluded.source_locator,
            key_literature = excluded.key_literature,
            cross_reference_targets = excluded.cross_reference_targets,
            also_standard_elsewhere = excluded.also_standard_elsewhere,
            record_url = excluded.record_url,
            evidence_excerpt = excluded.evidence_excerpt,
            status = excluded.status,
            error = excluded.error
        """,
        (
            result["moe_id"],
            result["checked_at"],
            result["source"],
            int(result["matched"]),
            result.get("source_locator", ""),
            result.get("key_literature", ""),
            result.get("cross_reference_targets", ""),
            int(result.get("also_standard_elsewhere", False)),
            result.get("record_url", ""),
            result.get("evidence_excerpt", ""),
            result.get("status", ""),
            result.get("error", ""),
        ),
    )

    db.commit()


def browser_headers(referer: str | None = None) -> dict[str, str]:
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": (
            "text/html,application/xhtml+xml,application/xml;q=0.9,"
            "image/avif,image/webp,*/*;q=0.8"
        ),
        "Accept-Language": "zh-TW,zh;q=0.9,en;q=0.6",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
        "Upgrade-Insecure-Requests": "1",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "same-origin" if referer else "none",
        "Sec-Fetch-User": "?1",
    }

    if referer:
        headers["Referer"] = referer

    return headers


def fetch_request(
    opener,
    url: str,
    retries: int,
    timeout: float,
    referer: str | None = None,
    data: bytes | None = None,
) -> tuple[str, str]:
    last_error: Exception | None = None

    for attempt in range(retries):
        headers = browser_headers(referer)

        if data is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"

        req = Request(
            url,
            headers=headers,
            data=data,
            method="POST" if data is not None else "GET",
        )

        try:
            with opener.open(req, timeout=timeout) as response:
                body = response.read()
                final_url = response.geturl()
                charset = response.headers.get_content_charset() or "utf-8"

                return (
                    final_url,
                    body.decode(charset, errors="replace"),
                )

        except HTTPError as exc:
            error_body = b""

            try:
                error_body = exc.read(1200)
            except Exception:
                pass

            snippet = error_body.decode("utf-8", errors="replace")
            snippet = re.sub(r"\s+", " ", snippet).strip()[:500]

            last_error = RuntimeError(
                f"HTTP {exc.code} for {url}"
                + (f" | body: {snippet}" if snippet else "")
            )

            if exc.code not in {408, 425, 429, 500, 502, 503, 504}:
                raise last_error

        except (URLError, TimeoutError, ConnectionError) as exc:
            last_error = RuntimeError(
                f"{type(exc).__name__} for {url}: {exc}"
            )

        if attempt + 1 < retries:
            time.sleep(min(30.0, (2 ** attempt) + random.random()))

    raise RuntimeError(
        f"request failed after {retries} attempts: {last_error}"
    )


def make_opener(retries: int, timeout: float):
    jar = CookieJar()
    opener = build_opener(HTTPCookieProcessor(jar))

    fetch_request(
        opener=opener,
        url=HOME_URL,
        retries=retries,
        timeout=timeout,
    )

    return opener


def discover_id_search_form(
    opener,
    retries: int,
    timeout: float,
) -> tuple[str, ParsedForm]:
    form_url, page = fetch_request(
        opener=opener,
        url=ID_SEARCH_FORM_URL,
        retries=retries,
        timeout=timeout,
        referer=HOME_URL,
    )

    parser = FormParser()
    parser.feed(page)

    scored: list[tuple[int, ParsedForm]] = []

    for form in parser.forms:
        text_inputs = [
            c for c in form.controls
            if c.tag == "input"
            and c.type in {"text", "search", ""}
            and c.name
        ]

        score = 0

        if "字號" in form.text:
            score += 30
        if "本典字號" in form.text:
            score += 30
        if len(text_inputs) == 2:
            score += 30
        elif text_inputs:
            score += 10
        if "search" in (form.action or "").lower():
            score += 5

        scored.append((score, form))

    if not scored:
        raise RuntimeError("No HTML forms found on 字號查詢 page.")

    scored.sort(key=lambda item: item[0], reverse=True)
    score, form = scored[0]

    if score < 40:
        raise RuntimeError(
            "Could not confidently identify the MOE 字號查詢 form."
        )

    return form_url, form


def build_form_submission(
    form_page_url: str,
    form: ParsedForm,
    query: str,
) -> tuple[str, bytes | None]:
    """
    Fill 字號1 with an EXACT moe_id and leave 字號2 empty.
    """

    params: list[tuple[str, str]] = []
    text_input_index = 0
    submit_added = False

    for control in form.controls:
        if not control.name:
            continue

        if control.tag == "input" and control.type in {"text", "search", ""}:
            text_input_index += 1

            if text_input_index == 1:
                params.append((control.name, query))
            else:
                params.append((control.name, ""))

            continue

        if control.type == "hidden":
            params.append((control.name, control.value))
            continue

        if control.type in {"submit", "image"} and not submit_added:
            params.append((control.name, control.value))
            submit_added = True

    if text_input_index == 0:
        raise RuntimeError(
            "The discovered 字號查詢 form has no named text field."
        )

    action_url = urljoin(
        form_page_url,
        form.action or form_page_url,
    )

    if form.method.lower() == "post":
        return (
            action_url,
            urlencode(params, doseq=True).encode("utf-8"),
        )

    parts = urlsplit(action_url)
    existing = parse_qsl(parts.query, keep_blank_values=True)
    query_string = urlencode(existing + params, doseq=True)

    url = urlunsplit(
        (
            parts.scheme,
            parts.netloc,
            parts.path,
            query_string,
            parts.fragment,
        )
    )

    return url, None


def submit_exact_id_search(
    opener,
    form_page_url: str,
    form: ParsedForm,
    moe_id: str,
    retries: int,
    timeout: float,
) -> tuple[str, str]:
    url, data = build_form_submission(
        form_page_url=form_page_url,
        form=form,
        query=moe_id,
    )

    return fetch_request(
        opener=opener,
        url=url,
        data=data,
        retries=retries,
        timeout=timeout,
        referer=form_page_url,
    )


def extract_numeric_detail_ids(page: str) -> list[int]:
    _text, links = parse_page(page)
    values: list[int] = []

    def add(value: int) -> None:
        if value not in values:
            values.append(value)

    for href in links:
        if "dictView.jsp" not in href:
            continue

        match = re.search(
            r"(?:[?&])ID=(-?\d+)",
            html.unescape(href),
        )

        if match:
            value = int(match.group(1))

            # Search-result detail records use positive IDs.
            if value > 0:
                add(value)

    raw = html.unescape(page)

    for match in re.finditer(
        r"dictView\.jsp\?[^\"'<>]*?\bID=(-?\d+)",
        raw,
        flags=re.IGNORECASE,
    ):
        value = int(match.group(1))

        if value > 0:
            add(value)

    return values


def make_detail_url(numeric_id: int) -> str:
    return DETAIL_URL + "?" + urlencode(
        {
            "ID": str(numeric_id),
            "q": "1",
        }
    )


def page_record_id(visible_text: str) -> str | None:
    """
    Read the record ID from the page's labelled record row.

    A variant page begins with the canonical heading, e.g.:
        A00694 嘴

    so simply taking the first MOE ID is WRONG.

    Actual record rows are labelled:
        異 體 字 A00694-005
        附 錄 字 A00004-007
        正 字 A00694
    """

    label_patterns = [
        r"異\s*體\s*字",
        r"附\s*錄\s*字",
        r"正\s*字",
    ]

    for label in label_patterns:
        match = re.search(
            label
            + r"\s*(?:[:：|])?\s*("
            + MOE_ID_PATTERN
            + r")",
            visible_text,
        )

        if match:
            return match.group(1)

    return None


def make_result(
    moe_id: str,
    source: str,
    *,
    matched: bool,
    status: str,
    record_url: str = "",
    source_locator: str = "",
    key_literature: str = "",
    cross_reference_targets: str = "",
    also_standard_elsewhere: bool = False,
    evidence_excerpt: str = "",
    error: str = "",
) -> dict:
    return {
        "moe_id": moe_id,
        "checked_at": utc_now(),
        "source": source,
        "matched": matched,
        "source_locator": source_locator,
        "key_literature": key_literature,
        "cross_reference_targets": cross_reference_targets,
        "also_standard_elsewhere": also_standard_elsewhere,
        "record_url": record_url,
        "evidence_excerpt": evidence_excerpt,
        "status": status,
        "error": error,
    }


def extract_record_evidence(
    expected_moe_id: str,
    source: str,
    record_url: str,
    page: str,
) -> dict:
    visible_text, _links = parse_page(page)
    actual_id = page_record_id(visible_text)

    if actual_id != expected_moe_id:
        return make_result(
            expected_moe_id,
            source,
            matched=False,
            status="record_id_mismatch",
            record_url=record_url,
            error=(
                f"Expected {expected_moe_id}; "
                f"labelled record row displayed {actual_id!r}."
            ),
        )

    # Slice at the labelled record row, not at the canonical heading.
    record_start = None

    for label in [
        r"異\s*體\s*字",
        r"附\s*錄\s*字",
        r"正\s*字",
    ]:
        match = re.search(
            label
            + r"\s*(?:[:：|])?\s*"
            + re.escape(expected_moe_id),
            visible_text,
        )

        if match:
            record_start = match.start()
            break

    record = (
        visible_text[record_start:]
        if record_start is not None
        else visible_text
    )

    # Generic bibliography starts here. It must never count as
    # record-specific evidence.
    shape_pos = record.find("形體資料表")

    if shape_pos >= 0:
        record = record[:shape_pos]

    key_pos = record.find("〔關鍵文獻〕")

    if key_pos < 0:
        return make_result(
            expected_moe_id,
            source,
            matched=False,
            status="no_key_literature_block",
            record_url=record_url,
            also_standard_elsewhere=("另兼正字" in record),
        )

    after_key = record[key_pos:]
    stops: list[int] = []

    for marker in ["研訂說明", "⇒", "＃"]:
        pos = after_key.find(marker)

        if pos >= 0:
            stops.append(pos)

    stop = min(stops) if stops else min(len(after_key), 2000)
    key_block = after_key[:stop]
    key_inline = normalize_inline(key_block)

    if source not in key_block:
        return make_result(
            expected_moe_id,
            source,
            matched=False,
            status="source_not_in_key_literature",
            record_url=record_url,
            key_literature=key_inline,
            also_standard_elsewhere=("另兼正字" in record),
        )

    locator = ""

    source_match = re.search(
        r"《\s*"
        + re.escape(source)
        + r"\s*(?:[．·]\s*([^》]+?))?\s*》",
        key_inline,
    )

    if source_match and source_match.group(1):
        locator = source_match.group(1).strip()

    cross_refs: list[str] = []

    for target in re.findall(
        r"⇒\s*「([^」]+)」\s*之異體",
        record,
    ):
        if target not in cross_refs:
            cross_refs.append(target)

    return make_result(
        expected_moe_id,
        source,
        matched=True,
        status="verified_key_literature",
        record_url=record_url,
        source_locator=locator,
        key_literature=key_inline,
        cross_reference_targets="；".join(cross_refs),
        also_standard_elsewhere=("另兼正字" in record),
        evidence_excerpt=normalize_inline(after_key[:500]),
    )


_thread_local = threading.local()


def worker_opener(retries: int, timeout: float):
    opener = getattr(_thread_local, "opener", None)

    if opener is None:
        opener = make_opener(retries, timeout)
        _thread_local.opener = opener

    return opener


def resolve_exact_id(
    candidate: Candidate,
    form_page_url: str,
    form: ParsedForm,
    source: str,
    retries: int,
    timeout: float,
    delay: float,
) -> dict:
    moe_id = candidate.moe_id

    try:
        opener = worker_opener(retries, timeout)

        search_url, search_page = submit_exact_id_search(
            opener=opener,
            form_page_url=form_page_url,
            form=form,
            moe_id=moe_id,
            retries=retries,
            timeout=timeout,
        )

        # Defensive case: if a future MOE version redirects a one-hit search
        # straight to a detail page, accept it.
        search_text, _links = parse_page(search_page)

        if page_record_id(search_text) == moe_id:
            result = extract_record_evidence(
                expected_moe_id=moe_id,
                source=source,
                record_url=search_url,
                page=search_page,
            )

            if delay > 0:
                time.sleep(delay)

            return result

        numeric_ids = extract_numeric_detail_ids(search_page)

        if not numeric_ids:
            return make_result(
                moe_id,
                source,
                matched=False,
                status="exact_id_search_no_result",
                error=(
                    f"Exact MOE 字號 search for {moe_id} returned "
                    "no positive dictView detail link."
                ),
            )

        seen_record_ids: list[str] = []

        for numeric_id in numeric_ids:
            detail_url = make_detail_url(numeric_id)

            final_url, detail_page = fetch_request(
                opener=opener,
                url=detail_url,
                retries=retries,
                timeout=timeout,
                referer=search_url,
            )

            detail_text, _detail_links = parse_page(detail_page)
            actual_id = page_record_id(detail_text)

            if actual_id:
                seen_record_ids.append(actual_id)

            if actual_id == moe_id:
                result = extract_record_evidence(
                    expected_moe_id=moe_id,
                    source=source,
                    record_url=final_url,
                    page=detail_page,
                )

                if delay > 0:
                    time.sleep(delay)

                return result

        return make_result(
            moe_id,
            source,
            matched=False,
            status="exact_id_result_mismatch",
            error=(
                f"Exact search returned {len(numeric_ids)} detail link(s), "
                f"but labelled record IDs were "
                f"{'；'.join(seen_record_ids) or '(none)'}."
            ),
        )

    except Exception as exc:
        return make_result(
            moe_id,
            source,
            matched=False,
            status="request_error",
            error=f"{type(exc).__name__}: {exc}",
        )


def result_to_output(candidate: Candidate, result: dict) -> dict:
    cross_refs = (result.get("cross_reference_targets") or "").strip()
    encoding = glyph_encoding(candidate.glyph)

    review_reasons: list[str] = []

    if cross_refs:
        review_reasons.append("cross_reference")
    if encoding == "missing_or_image_only":
        review_reasons.append("missing_or_image_only_glyph")
    if encoding == "moe_private_use":
        review_reasons.append("moe_private_use_glyph")

    if review_reasons:
        verification_status = (
            "verified_needs_review:"
            + ";".join(review_reasons)
        )
        automatic_safe = "no"
    else:
        verification_status = "verified_direct"
        automatic_safe = "yes"

    return {
        "singapore_glyph": candidate.glyph,
        "moe_id": candidate.moe_id,
        "grade": candidate.grade,
        "canonical_glyph": candidate.canonical_glyph,
        "canonical_moe_id": candidate.canonical_moe_id,
        "source": result.get("source") or DEFAULT_SOURCE,
        "source_locator": result.get("source_locator") or "",
        "key_literature": result.get("key_literature") or "",
        "cross_reference_targets": cross_refs,
        "also_standard_elsewhere": (
            "yes" if result.get("also_standard_elsewhere") else "no"
        ),
        "glyph_encoding": encoding,
        "verification_status": verification_status,
        "automatic_mapping_safe": automatic_safe,
        "conversion_from_candidate": candidate.canonical_glyph,
        "moe_record_url": result.get("record_url") or "",
        "evidence_excerpt": result.get("evidence_excerpt") or "",
    }


def write_bom_csv(
    path: Path,
    rows: list[dict],
    fields: list[str],
) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=fields,
            extrasaction="ignore",
        )
        writer.writeheader()
        writer.writerows(rows)


ERROR_STATUSES = {
    "record_id_mismatch",
    "exact_id_search_no_result",
    "exact_id_result_mismatch",
    "request_error",
}


def write_outputs(
    candidates: list[Candidate],
    db: sqlite3.Connection,
    source: str,
    verified_path: Path,
    review_path: Path,
    errors_path: Path,
) -> tuple[int, int, int]:
    verified: list[dict] = []
    review: list[dict] = []
    errors: list[dict] = []

    for candidate in candidates:
        result = cache_get(db, candidate.moe_id, source)

        if not result:
            continue

        if result["status"] in ERROR_STATUSES:
            errors.append(
                {
                    "moe_id": candidate.moe_id,
                    "glyph": candidate.glyph,
                    "canonical_moe_id": candidate.canonical_moe_id,
                    "canonical_glyph": candidate.canonical_glyph,
                    "status": result["status"],
                    "error": result.get("error") or "",
                    "record_url": result.get("record_url") or "",
                }
            )
            continue

        if not result["matched"]:
            continue

        row = result_to_output(candidate, result)
        verified.append(row)

        if row["automatic_mapping_safe"] == "no":
            review.append(row)

    write_bom_csv(
        verified_path,
        verified,
        OUTPUT_FIELDS,
    )

    write_bom_csv(
        review_path,
        review,
        OUTPUT_FIELDS,
    )

    write_bom_csv(
        errors_path,
        errors,
        [
            "moe_id",
            "glyph",
            "canonical_moe_id",
            "canonical_glyph",
            "status",
            "error",
            "record_url",
        ],
    )

    return len(verified), len(review), len(errors)


def count_progress(
    candidates: list[Candidate],
    db: sqlite3.Connection,
    source: str,
) -> tuple[int, int, int, int]:
    resolved = 0
    matches = 0
    negatives = 0
    errors = 0

    for candidate in candidates:
        result = cache_get(db, candidate.moe_id, source)

        if not result:
            continue

        if result["status"] in TERMINAL_STATUSES:
            resolved += 1

            if result["matched"]:
                matches += 1
            else:
                negatives += 1
        else:
            errors += 1

    return resolved, matches, negatives, errors


def run_self_tests(
    form_page_url: str,
    form: ParsedForm,
    source: str,
    retries: int,
    timeout: float,
) -> None:
    positive = Candidate(
        glyph="咀",
        moe_id=SELF_TEST_ID,
        grade="異體字",
        canonical_moe_id="A00694",
        canonical_glyph="嘴",
    )

    print(
        f"Self-test 1: exact 字號 {SELF_TEST_ID} "
        f"-> 《{source}．{SELF_TEST_LOCATOR}》 ..."
    )

    result = resolve_exact_id(
        candidate=positive,
        form_page_url=form_page_url,
        form=form,
        source=source,
        retries=retries,
        timeout=timeout,
        delay=0,
    )

    if not (
        result.get("matched")
        and result.get("source_locator") == SELF_TEST_LOCATOR
    ):
        print("SELF-TEST 1 FAILED.")
        print(f"Status: {result.get('status')}")
        print(f"URL:    {result.get('record_url')}")
        print(f"Error:  {result.get('error')}")
        print(f"Key:    {result.get('key_literature')}")
        raise SystemExit(2)

    print(
        f"PASS: {SELF_TEST_ID} -> "
        f"《{source}．{SELF_TEST_LOCATOR}》"
    )

    appendix = Candidate(
        glyph="\U000f0004",
        moe_id=APPENDIX_SELF_TEST_ID,
        grade="附錄字",
        canonical_moe_id="A00004",
        canonical_glyph="三",
    )

    print(
        f"Self-test 2: exact 附錄字 {APPENDIX_SELF_TEST_ID} "
        "must resolve its own labelled record ..."
    )

    result = resolve_exact_id(
        candidate=appendix,
        form_page_url=form_page_url,
        form=form,
        source=source,
        retries=retries,
        timeout=timeout,
        delay=0,
    )

    if result.get("status") in ERROR_STATUSES:
        print("SELF-TEST 2 FAILED.")
        print(f"Status: {result.get('status')}")
        print(f"URL:    {result.get('record_url')}")
        print(f"Error:  {result.get('error')}")
        raise SystemExit(2)

    print(
        f"PASS: {APPENDIX_SELF_TEST_ID} resolved as an "
        f"{appendix.grade} record."
    )
    print()


def format_seconds(seconds: float) -> str:
    if seconds < 0 or seconds == float("inf"):
        return "?"

    hours, remainder = divmod(int(seconds), 3600)
    minutes, secs = divmod(remainder, 60)

    if hours:
        return f"{hours}h {minutes}m"
    if minutes:
        return f"{minutes}m {secs}s"
    return f"{secs}s"


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "csv",
        type=Path,
        help="Path to moe_variants_1141231.csv",
    )

    parser.add_argument(
        "--source",
        default=DEFAULT_SOURCE,
    )

    parser.add_argument(
        "--workers",
        type=int,
        default=3,
        help=(
            "Concurrent MOE lookups. Default: 3. "
            "Use 1 for the gentlest possible crawl."
        ),
    )

    parser.add_argument(
        "--delay",
        type=float,
        default=0.15,
        help="Pause after each resolved record per worker. Default: 0.15s.",
    )

    parser.add_argument(
        "--timeout",
        type=float,
        default=30.0,
    )

    parser.add_argument(
        "--retries",
        type=int,
        default=5,
    )

    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Testing only: process first N candidate rows.",
    )

    parser.add_argument(
        "--skip-self-test",
        action="store_true",
    )

    args = parser.parse_args()

    csv_path = args.csv.resolve()

    if not csv_path.exists():
        raise SystemExit(f"CSV does not exist: {csv_path}")

    out_dir = csv_path.parent

    verified_path = out_dir / "singapore_simplified_verified.csv"
    review_path = out_dir / "singapore_simplified_review.csv"
    errors_path = out_dir / "singapore_simplified_errors.csv"
    cache_path = out_dir / "singapore_simplified_scan_v9.sqlite3"

    candidates = read_candidates(csv_path)

    if args.limit > 0:
        candidates = candidates[:args.limit]

    print(f"Version:     {SCRIPT_VERSION}")
    print(f"Input:       {csv_path}")
    print(f"Candidates:  {len(candidates):,} non-正字 records")
    print(f"Source:      《{args.source}》")
    print(f"Workers:     {args.workers}")
    print(f"Checkpoint:  {cache_path}")
    print(f"Verified:    {verified_path}")
    print(f"Review:      {review_path}")
    print(f"Errors:      {errors_path}")
    print()

    db = connect_cache(cache_path)

    print("Session:     opening MOE and discovering 字號查詢 ...")

    try:
        discovery_opener = make_opener(
            retries=args.retries,
            timeout=args.timeout,
        )

        form_page_url, form = discover_id_search_form(
            opener=discovery_opener,
            retries=args.retries,
            timeout=args.timeout,
        )

    except Exception as exc:
        print("MOE FORM DISCOVERY FAILED.")
        print(f"{type(exc).__name__}: {exc}")
        raise SystemExit(2)

    text_fields = [
        c.name
        for c in form.controls
        if c.tag == "input"
        and c.type in {"text", "search", ""}
        and c.name
    ]

    print(f"字號查詢:    method={form.method.upper()}")
    print(f"字號 fields: {text_fields}")
    print()

    if not args.skip_self_test:
        run_self_tests(
            form_page_url=form_page_url,
            form=form,
            source=args.source,
            retries=args.retries,
            timeout=args.timeout,
        )

    pending = []

    for candidate in candidates:
        cached = cache_get(db, candidate.moe_id, args.source)

        if cached and cached["status"] in TERMINAL_STATUSES:
            continue

        pending.append(candidate)

    print(f"Already cleanly checked: {len(candidates) - len(pending):,}")
    print(f"Remaining:               {len(pending):,}")
    print()

    started = time.monotonic()
    completed_this_run = 0

    try:
        # Submit in manageable batches so Ctrl+C does not leave tens of
        # thousands of queued futures hanging around.
        batch_size = max(100, args.workers * 100)

        for batch_start in range(0, len(pending), batch_size):
            batch = pending[batch_start:batch_start + batch_size]

            with ThreadPoolExecutor(
                max_workers=max(1, args.workers)
            ) as pool:
                futures = {
                    pool.submit(
                        resolve_exact_id,
                        candidate,
                        form_page_url,
                        form,
                        args.source,
                        args.retries,
                        args.timeout,
                        args.delay,
                    ): candidate
                    for candidate in batch
                }

                for future in as_completed(futures):
                    candidate = futures[future]

                    try:
                        result = future.result()
                    except Exception as exc:
                        result = make_result(
                            candidate.moe_id,
                            args.source,
                            matched=False,
                            status="request_error",
                            error=f"{type(exc).__name__}: {exc}",
                        )

                    cache_put(db, result)
                    completed_this_run += 1

                    if (
                        completed_this_run == 1
                        or completed_this_run % 100 == 0
                        or completed_this_run == len(pending)
                    ):
                        resolved, matches, negatives, errors = count_progress(
                            candidates,
                            db,
                            args.source,
                        )

                        elapsed = max(
                            0.001,
                            time.monotonic() - started,
                        )

                        rate = completed_this_run / elapsed

                        remaining = (
                            len(pending) - completed_this_run
                        )

                        eta = (
                            remaining / rate
                            if rate
                            else float("inf")
                        )

                        print(
                            f"[{completed_this_run:>6,}/{len(pending):,}] "
                            f"clean checks {resolved:,} "
                            f"| SG matches {matches:,} "
                            f"| clean negatives {negatives:,} "
                            f"| errors {errors:,} "
                            f"| ETA {format_seconds(eta)}"
                        )

    except KeyboardInterrupt:
        print()
        print("Interrupted by user. Checkpoint is already current.")

    finally:
        verified_count, review_count, error_count = write_outputs(
            candidates=candidates,
            db=db,
            source=args.source,
            verified_path=verified_path,
            review_path=review_path,
            errors_path=errors_path,
        )

        db.close()

    print()
    print("Current results written.")
    print(f"Verified Singapore attestations: {verified_count:,}")
    print(f"Rows needing manual review:      {review_count:,}")
    print(f"Lookup errors:                    {error_count:,}")
    print()
    print("The original MOE CSV was not modified.")


if __name__ == "__main__":
    main()
