#!/usr/bin/env python3
"""Refine a completed source inventory without rescanning the PALCC corpus.

This is a second-stage triage pass over the CSVs produced by inventory_sources.py.
It corrects relationships that title-only matching cannot safely decide, splits
identifier-only NIJL projects away from human review, and inspects CODH text
payloads for embedded Han-dominant passages.

It never edits corpus files and performs no network access.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import re
import shutil
import unicodedata
import zipfile
from collections import Counter
from pathlib import Path
from typing import Any, Iterable
from xml.etree import ElementTree as ET

TITLE_FOLD = str.maketrans({
    "学":"學","国":"國","経":"經","礼":"禮","旧":"舊","与":"與","万":"萬","図":"圖","広":"廣","会":"會",
    "訳":"譯","説":"說","戦":"戰","伝":"傳","実":"實","録":"錄","歴":"歷","仏":"佛","宝":"寶","体":"體",
    "徳":"德","発":"發","来":"來","楽":"樂","読":"讀","遥":"遙","游":"遊","荘":"莊","寿":"壽","医":"醫",
    "薬":"藥","芸":"藝","気":"氣","帰":"歸","応":"應","竜":"龍","沢":"澤","台":"臺","湾":"灣","号":"號",
    "声":"聲","処":"處","尽":"盡","観":"觀","雑":"雜","総":"總","禅":"禪","静":"靜","円":"圓","覚":"覺",
    "変":"變","権":"權","済":"濟","増":"增","独":"獨","当":"當","塩":"鹽","浜":"濱","桜":"櫻",
})
PUNCT_RE = re.compile(r"[\s\u3000\-‐‑‒–—―_·・,，.。:：;；!！?？/／\\|｜'‘’\"“”\(\)（）\[\]［］\{\}｛｝<>＜＞《》〈〉『』「」【】〔〕]+")
HAN_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
KANA_RE = re.compile(r"[\u3040-\u309f\u30a0-\u30ff]")
LATIN_RE = re.compile(r"[A-Za-z]")
W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

# Some Kanripo catalogue titles contain a role marker which describes the payload,
# not part of the work title. Keep this list deliberately narrow: it is used only
# while reconciling Kanripo source titles against PALCC work titles.
KANRIPO_CATALOGUE_ROLE_SUFFIXES = ("正文", "本文", "原文", "經文")

# Conventional title variants which refer to the same textual work. These are
# explicit equivalence groups, not fuzzy substitutions. Add future groups only when
# the bibliographic identity is established.
TITLE_ALIAS_GROUPS = (
    ("春秋左傳", "春秋左氏傳"),
)

UD_TARGETS = [
    ("UD_Classical_Chinese-Kyoto", "KR1h0004", "論語", "", "論語"),
    ("UD_Classical_Chinese-Kyoto", "KR1h0001", "孟子", "", "孟子"),
    ("UD_Classical_Chinese-Kyoto", "KR1d0052", "禮記", "", "禮記"),
    ("UD_Classical_Chinese-Kyoto", "KR2b0041", "十八史略", "", "十八史略"),
    ("UD_Classical_Chinese-Kyoto", "KR4a0001", "楚辭", "", "楚辭"),
    ("UD_Classical_Chinese-Kyoto", "KR2e0003", "戰國策", "", "戰國策"),
    ("UD_Classical_Chinese-Kyoto", "KR4h0169", "唐詩三百首", "", "唐詩三百首"),
    ("UD_Classical_Chinese-Kyoto", "KR6c0127", "摩訶般若波羅蜜大明呪經", "", "摩訶般若波羅蜜大明呪經"),
    ("UD_Classical_Chinese-Kyoto", "KR6c0023", "金剛般若波羅蜜經", "", "金剛般若波羅蜜經"),
    ("UD_Classical_Chinese-Kyoto", "KR6f0082", "佛說阿彌陀經", "", "佛說阿彌陀經"),
    ("UD_Classical_Chinese-TueCL", "TueCL", "莊子", "逍遙遊", "莊子"),
]


def clean(value: Any) -> str:
    return "" if value is None else str(value).strip()


def title_norm(value: str) -> str:
    text = unicodedata.normalize("NFKC", clean(value)).translate(TITLE_FOLD)
    return PUNCT_RE.sub("", text).casefold()


def kanripo_title_norm(value: str) -> tuple[str, bool]:
    """Normalize a Kanripo catalogue title and remove a narrow payload-role suffix.

    Returns the normalized title plus a flag recording whether a suffix was removed.
    The removal happens after punctuation normalization, so both ``(正文)`` and
    ``（正文）`` are handled without creating a general parenthesis-stripping rule.
    """
    norm = title_norm(value)
    for suffix in KANRIPO_CATALOGUE_ROLE_SUFFIXES:
        suffix_norm = title_norm(suffix)
        if norm.endswith(suffix_norm) and len(norm) > len(suffix_norm):
            return norm[:-len(suffix_norm)], True
    return norm, False


def title_alias_norms(value: str, *, kanripo_catalogue: bool = False) -> set[str]:
    norm = kanripo_title_norm(value)[0] if kanripo_catalogue else title_norm(value)
    if not norm:
        return set()
    result = {norm}
    for group in TITLE_ALIAS_GROUPS:
        group_norms = {title_norm(member) for member in group}
        if norm in group_norms:
            result.update(group_norms)
    return result


def read_csv(path: Path) -> list[dict[str, str]]:
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


def load_last_inventory(staging_root: Path) -> Path:
    required = ["corpus_works.csv", "codh_matches.csv", "kanripo_matches.csv", "nijl_matches.csv"]
    state_path = staging_root / "_state" / "last_inventory.json"
    if state_path.is_file():
        try:
            payload = json.loads(state_path.read_text(encoding="utf-8"))
            output = Path(payload["output_dir"])
            if not output.is_absolute():
                output = (staging_root / output).resolve()
            if all((output / name).is_file() for name in required):
                return output
        except Exception:
            pass

    # A lost convenience pointer must not force another deep corpus scan. Reuse the
    # newest completed inventory that still has the required source reports.
    candidates = sorted(
        [path for path in (staging_root / "_inventory").glob("*") if path.is_dir()],
        key=lambda path: path.name,
        reverse=True,
    )
    for output in candidates:
        if all((output / name).is_file() for name in required):
            return output
    raise FileNotFoundError(f"No completed inventory with required reports found under {staging_root / '_inventory'}")


def exact_title_index(corpus_rows: list[dict[str, str]]) -> dict[str, list[dict[str, str]]]:
    index: dict[str, list[dict[str, str]]] = {}
    for row in corpus_rows:
        for norm in title_alias_norms(row.get("title", "")):
            bucket = index.setdefault(norm, [])
            if row not in bucket:
                bucket.append(row)
    return index


def has_primary_count_data(corpus_rows: list[dict[str, str]]) -> bool:
    return bool(corpus_rows and "primary_text_file_count" in corpus_rows[0])


def row_has_primary_text(row: dict[str, str]) -> bool:
    return intish(row.get("primary_text_file_count")) > 0


def build_ud(output: Path, refined: Path, corpus_rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    index = exact_title_index(corpus_rows)
    rows: list[dict[str, Any]] = []
    for treebank, upstream_id, source_work, source_section, target in UD_TARGETS:
        exact = index.get(title_norm(target), [])
        if treebank == "UD_Classical_Chinese-TueCL":
            action = "ANNOTATE_EXISTING_CHAPTER"
            note = "TueCL contains 莊子・逍遙遊. Treat 逍遙遊 as a chapter/section alignment, not a standalone missing work."
        elif source_work in {"摩訶般若波羅蜜大明呪經", "金剛般若波羅蜜經"} and not exact:
            action = "NEW_WORK_FROM_UD"
            if source_work == "金剛般若波羅蜜經":
                note = "Kyoto KR6c0023 is 姚秦天竺三藏鳩摩羅什譯. Similarly named PALCC translations/commentaries are not interchangeable with this exact source."
            else:
                note = "Kyoto KR6c0127 is 姚秦天竺三藏鳩摩羅什譯. The fuzzy 摩訶般若波羅蜜經 hit is a different work."
        elif exact and has_primary_count_data(corpus_rows) and not any(row_has_primary_text(row) for row in exact):
            action = "FILL_MISSING_PRIMARY_TEXT_AND_ANNOTATE"
            note = "Exact PALCC metadata record exists, but the deep inventory found no primary text files. Reuse the existing work record/IDs and add source text before attaching annotation."
        elif exact:
            action = "ANNOTATE_EXISTING_WORK"
            note = ""
        else:
            action = "REVIEW_MISSING_TARGET"
            note = "No exact PALCC title found."
        rows.append({
            "treebank": treebank,
            "upstream_source_id": upstream_id,
            "source_work": source_work,
            "source_section": source_section,
            "action": action,
            "palcc_exact_candidate_count": len(exact),
            "palcc_titles": " | ".join(row.get("title", "") for row in exact[:20]),
            "palcc_paths": " | ".join(row.get("path", "") for row in exact[:20]),
            "note": note,
        })
    write_csv(refined / "ud_annotation_targets.csv", rows)
    return rows


def decode_bytes(data: bytes) -> str:
    for encoding in ("utf-8-sig", "utf-8", "cp932", "shift_jis"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            pass
    return data.decode("utf-8", errors="replace")


def codh_metadata(staging_root: Path) -> dict[str, dict[str, str]]:
    path = staging_root / "codh_japanese_classical_books" / "raw" / "metadata.zip"
    records: dict[str, dict[str, str]] = {}
    if not path.exists():
        return records
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if not name.lower().endswith(".csv"):
                continue
            sid = name.split("/", 1)[0]
            rows = list(csv.DictReader(io.StringIO(decode_bytes(archive.read(name)))))
            if rows:
                records[sid] = {str(key): clean(value) for key, value in rows[0].items()}
    return records


def docx_text(data: bytes) -> str:
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        xml = archive.read("word/document.xml")
    root = ET.fromstring(xml)
    paragraphs: list[str] = []
    for paragraph in root.findall(f".//{{{W_NS}}}p"):
        text = "".join(node.text or "" for node in paragraph.findall(f".//{{{W_NS}}}t"))
        if text:
            paragraphs.append(text)
    return "\n".join(paragraphs)


def codh_texts(staging_root: Path) -> dict[str, str]:
    path = staging_root / "codh_japanese_classical_books" / "raw" / "text.zip"
    result: dict[str, list[str]] = {}
    if not path.exists():
        return {}
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if name.endswith("/") or "/text/" not in name:
                continue
            sid = name.split("/", 1)[0]
            data = archive.read(name)
            text = ""
            if name.lower().endswith(".txt"):
                text = decode_bytes(data)
            elif name.lower().endswith(".docx"):
                try:
                    text = docx_text(data)
                except Exception:
                    text = ""
            if text:
                result.setdefault(sid, []).append(text)
    return {sid: "\n".join(parts) for sid, parts in result.items()}


def script_counts(text: str) -> tuple[int, int, int]:
    return len(HAN_RE.findall(text)), len(KANA_RE.findall(text)), len(LATIN_RE.findall(text))


def detect_han_segments(text: str, min_han: int = 80, max_kana_ratio: float = 0.03) -> list[tuple[int, int, str]]:
    text = re.sub(r"<Image:[^>]+>", "\n", text)
    lines = [line.strip() for line in re.split(r"[\r\n]+", text)]
    chunks: list[tuple[int, int, str]] = []
    current: list[str] = []

    def flush() -> None:
        nonlocal current
        if not current:
            return
        chunk = " ".join(current)
        han, kana, _latin = script_counts(chunk)
        if han >= min_han and kana / (han + kana + 1e-9) <= max_kana_ratio:
            chunks.append((han, kana, chunk))
        current = []

    for line in lines:
        if not line:
            flush()
            continue
        han, kana, _latin = script_counts(line)
        ratio = kana / (han + kana + 1e-9) if han + kana else 1.0
        if han >= 5 and ratio <= max_kana_ratio:
            current.append(line)
        else:
            flush()
    flush()
    return chunks


def build_codh(staging_root: Path, output: Path, refined: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    source_rows = read_csv(output / "codh_matches.csv")
    metadata = codh_metadata(staging_root)
    texts = codh_texts(staging_root)
    rows: list[dict[str, Any]] = []
    segments: list[dict[str, Any]] = []
    for source in source_rows:
        if intish(source.get("has_text_payload")) != 1:
            continue
        sid = source.get("source_id", "")
        title = source.get("source_title", "")
        text = texts.get(sid, "")
        han, kana, _latin = script_counts(text)
        chunks = detect_han_segments(text)
        meta = metadata.get(sid, {})
        for index, (seg_han, seg_kana, chunk) in enumerate(chunks, start=1):
            segments.append({
                "source_id": sid,
                "source_title": title,
                "segment_index": index,
                "han_chars": seg_han,
                "kana_chars": seg_kana,
                "sample": re.sub(r"\s+", " ", chunk)[:1200],
                "source_url": f"https://codh.rois.ac.jp/pmjt/book/{sid}/",
                "status": "BOUNDARY_AND_METADATA_REVIEW_REQUIRED",
            })
        action = "EXTRACT_EMBEDDED_LITERARY_CHINESE" if chunks else "DO_NOT_IMPORT_AS_WHOLE_LITERARY_CHINESE"
        note = (
            "Host transcription is Japanese/mixed, but contains strict Han-dominant passages worth reviewing as preface/postface/題詞/etc."
            if chunks else
            "No long near-Han-only passage was found with the conservative detector; retain the source, but do not treat the whole transcription as Literary Chinese."
        )
        rows.append({
            "source_id": sid,
            "title": title,
            "codh_work_id": meta.get("著作ID", ""),
            "category": meta.get("オープンデータ分類", ""),
            "authors": meta.get("記載著者名表記 記載著者名よみ 他等 役割 伝 記載著者部編等", ""),
            "publication": meta.get("出版表連番 書肆 刊年 出版表部編等", ""),
            "print_or_manuscript": meta.get("刊写の別", ""),
            "description": meta.get("解題", ""),
            "han_chars": han,
            "kana_chars": kana,
            "han_share_of_han_plus_kana": round(han / (han + kana), 4) if han + kana else "",
            "embedded_han_segments": len(chunks),
            "embedded_han_chars": sum(item[0] for item in chunks),
            "action": action,
            "note": note,
            "source_url": f"https://codh.rois.ac.jp/pmjt/book/{sid}/",
        })
    write_csv(refined / "codh_text_triage.csv", rows)
    write_csv(refined / "codh_embedded_han_segments.csv", segments)
    return rows, segments


def kanripo_exact_candidates(title: str, index: dict[str, list[dict[str, str]]]) -> tuple[list[dict[str, str]], bool]:
    candidates: list[dict[str, str]] = []
    seen_paths: set[str] = set()
    _cleaned_norm, qualifier_removed = kanripo_title_norm(title)
    for norm in title_alias_norms(title, kanripo_catalogue=True):
        for candidate in index.get(norm, []):
            path = candidate.get("path", "")
            if path in seen_paths:
                continue
            seen_paths.add(path)
            candidates.append(candidate)
    return candidates, qualifier_removed


def build_kanripo(output: Path, refined: Path, corpus_rows: list[dict[str, str]]) -> Counter[str]:
    rows = read_csv(output / "kanripo_matches.csv")
    primary_by_path = {row.get("path", ""): intish(row.get("primary_text_file_count")) for row in corpus_rows}
    primary_counts_known = has_primary_count_data(corpus_rows)
    exact_index = exact_title_index(corpus_rows)
    for row in rows:
        title = row.get("source_title", "")
        exact_candidates, qualifier_removed = kanripo_exact_candidates(title, exact_index)
        if exact_candidates:
            first = exact_candidates[0]
            source_direct = kanripo_title_norm(title)[0]
            direct_candidate = any(title_norm(candidate.get("title", "")) == source_direct for candidate in exact_candidates)
            if direct_candidate and qualifier_removed:
                match_basis = "exact_title_after_catalogue_qualifier_cleanup"
            elif direct_candidate:
                match_basis = "exact_title"
            elif qualifier_removed:
                match_basis = "catalogue_qualifier_cleanup+canonical_title_alias"
            else:
                match_basis = "canonical_title_alias"
            status = "exact_title" if len(exact_candidates) == 1 else "exact_title_ambiguous"
            row["match_status"] = status
            row["match_score"] = "1.0"
            row["palcc_title"] = first.get("title", "")
            row["palcc_path"] = first.get("path", "")
            row["palcc_work_id"] = first.get("work_id", "")
            row["palcc_corpus_root"] = first.get("corpus_root", "")
            row["candidate_count"] = str(len(exact_candidates))
            row["candidate_titles"] = " | ".join(candidate.get("title", "") for candidate in exact_candidates)
            row["candidate_paths"] = " | ".join(candidate.get("path", "") for candidate in exact_candidates)
            row["refined_match_basis"] = match_basis
        else:
            status = row.get("match_status", "")
            row["refined_match_basis"] = "inventory_match"

        score = floatish(row.get("match_score"))
        candidate_paths = [part.strip() for part in row.get("candidate_paths", "").split(" | ") if part.strip()]
        candidate_primary = [primary_by_path.get(path, 0) for path in candidate_paths]
        row["candidate_primary_text_file_counts"] = " | ".join(str(value) for value in candidate_primary)
        row["all_exact_candidates_metadata_only"] = int(
            bool(primary_counts_known and candidate_paths and candidate_primary and all(value == 0 for value in candidate_primary))
        )
        if not title or status == "source_title_missing":
            queue = "TITLE_UNRESOLVED"
        elif status in {"exact_title", "exact_title_ambiguous"} and row["all_exact_candidates_metadata_only"]:
            queue = "FILL_MISSING_PRIMARY_TEXT"
        elif status in {"exact_title", "exact_title_ambiguous"}:
            queue = "DOWNLOAD_FOR_WITNESS_COMPARE"
        elif status in {"strong_title_match", "review_title_match"}:
            queue = "TITLE_FAMILY_REVIEW"
        elif status == "no_title_match" and (score >= 0.75 or len(title) <= 3):
            queue = "TITLE_FAMILY_REVIEW"
        elif status == "no_title_match":
            queue = "PROBABLE_NEW_WORK"
        else:
            queue = "TITLE_FAMILY_REVIEW"
        row["refined_queue"] = queue

    fields = [
        "source_id","source_title","source_author","source_period","source_catalog_label","source_url","refined_queue",
        "refined_match_basis","match_status","match_score","palcc_title","palcc_path","candidate_count","candidate_titles","candidate_paths",
        "candidate_primary_text_file_counts","all_exact_candidates_metadata_only",
    ]
    mapping = {
        "DOWNLOAD_FOR_WITNESS_COMPARE": "kanripo_existing_title_witnesses.csv",
        "FILL_MISSING_PRIMARY_TEXT": "kanripo_fill_missing_primary_text.csv",
        "TITLE_FAMILY_REVIEW": "kanripo_title_review.csv",
        "PROBABLE_NEW_WORK": "kanripo_probable_new_works.csv",
        "TITLE_UNRESOLVED": "kanripo_unresolved_titles.csv",
    }
    counts = Counter(row["refined_queue"] for row in rows)
    for queue, filename in mapping.items():
        subset = [row for row in rows if row["refined_queue"] == queue]
        write_csv(refined / filename, subset, fields)
    id_files = {
        "DOWNLOAD_FOR_WITNESS_COMPARE": "kanripo_existing_ids.txt",
        "FILL_MISSING_PRIMARY_TEXT": "kanripo_fill_missing_primary_ids.txt",
        "TITLE_FAMILY_REVIEW": "kanripo_review_ids.txt",
        "PROBABLE_NEW_WORK": "kanripo_probable_new_ids.txt",
    }
    for queue, filename in id_files.items():
        ids = [row.get("source_id", "") for row in rows if row["refined_queue"] == queue]
        (refined / filename).write_text("\n".join(ids) + "\n", encoding="utf-8")
    return counts


def build_nijl(staging_root: Path, output: Path, refined: Path) -> Counter[str]:
    rows = read_csv(output / "nijl_matches.csv")
    metadata = codh_metadata(staging_root)
    for row in rows:
        linked = intish(row.get("codh_linked")) == 1
        source_title = row.get("source_title", "")
        status = row.get("match_status", "")
        row["refined_source_title"] = source_title if linked else ""
        row["project_title_hint"] = "" if linked else source_title
        if linked and status in {"exact_title", "exact_title_ambiguous"} and len(source_title) >= 4:
            queue = "DOWNLOAD_FOR_WITNESS_COMPARE"
        elif linked and (
            (status in {"exact_title", "exact_title_ambiguous"} and len(source_title) <= 3)
            or status in {"strong_title_match", "review_title_match"}
        ):
            queue = "RELATED_OR_TITLE_COLLISION_REVIEW"
        elif linked and status == "no_title_match" and source_title:
            queue = "TITLED_UNMATCHED_LANGUAGE_SCREEN"
        elif not row["refined_source_title"]:
            queue = "IDENTIFIER_ONLY_UNRESOLVED"
        else:
            queue = "RELATED_OR_TITLE_COLLISION_REVIEW"
        row["refined_queue"] = queue
        meta = metadata.get(row.get("source_id", ""), {})
        row["codh_work_id"] = meta.get("著作ID", "")
        row["codh_category"] = meta.get("オープンデータ分類", "")
        row["codh_authors"] = meta.get("記載著者名表記 記載著者名よみ 他等 役割 伝 記載著者部編等", "")
        row["codh_publication"] = meta.get("出版表連番 書肆 刊年 出版表部編等", "")
        row["codh_print_ms"] = meta.get("刊写の別", "")

    fields = [
        "source_id","source_id_kind","refined_source_title","project_title_hint","project","source_url","group","codh_linked",
        "codh_work_id","codh_category","codh_authors","codh_publication","codh_print_ms","refined_queue",
        "match_status","match_score","palcc_title","palcc_path","candidate_count","candidate_titles","candidate_paths",
        "candidate_primary_text_file_counts","all_exact_candidates_metadata_only",
    ]
    mapping = {
        "DOWNLOAD_FOR_WITNESS_COMPARE": "nijl_existing_title_witnesses.csv",
        "RELATED_OR_TITLE_COLLISION_REVIEW": "nijl_related_or_collision_review.csv",
        "TITLED_UNMATCHED_LANGUAGE_SCREEN": "nijl_titled_unmatched.csv",
        "IDENTIFIER_ONLY_UNRESOLVED": "nijl_identifier_only_unresolved.csv",
    }
    counts = Counter(row["refined_queue"] for row in rows)
    for queue, filename in mapping.items():
        write_csv(refined / filename, [row for row in rows if row["refined_queue"] == queue], fields)
    projects = [row.get("project", "") for row in rows if row["refined_queue"] == "DOWNLOAD_FOR_WITNESS_COMPARE"]
    (refined / "nijl_existing_project_paths.txt").write_text("\n".join(projects) + "\n", encoding="utf-8")
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging-root", type=Path, required=True)
    parser.add_argument("--inventory-dir", type=Path, default=None, help="Completed inventory directory; defaults to last_inventory.json output_dir.")
    args = parser.parse_args()

    staging_root = args.staging_root.expanduser().resolve()
    output = args.inventory_dir.expanduser().resolve() if args.inventory_dir else load_last_inventory(staging_root)
    refined = output / "refined"
    if refined.exists():
        shutil.rmtree(refined)
    refined.mkdir(parents=True)

    corpus_rows = read_csv(output / "corpus_works.csv")
    ud_rows = build_ud(output, refined, corpus_rows)
    codh_rows, segments = build_codh(staging_root, output, refined)
    kanripo_counts = build_kanripo(output, refined, corpus_rows)
    nijl_counts = build_nijl(staging_root, output, refined)

    summary = {
        "basis": str(output),
        "corpus_work_records": len(corpus_rows),
        "ud": {
            "targets": len(ud_rows),
            "existing_annotation_targets": sum(row["action"].startswith("ANNOTATE_EXISTING") for row in ud_rows),
            "fill_missing_primary_and_annotate": sum(row["action"] == "FILL_MISSING_PRIMARY_TEXT_AND_ANNOTATE" for row in ud_rows),
            "new_work_from_ud": sum(row["action"] == "NEW_WORK_FROM_UD" for row in ud_rows),
        },
        "codh": {
            "text_bearing_records": len(codh_rows),
            "host_works_with_embedded_literary_chinese": sum(row["action"] == "EXTRACT_EMBEDDED_LITERARY_CHINESE" for row in codh_rows),
            "embedded_segments": len(segments),
            "embedded_han_chars": sum(int(row["han_chars"]) for row in segments),
        },
        "kanripo": dict(kanripo_counts),
        "nijl": dict(nijl_counts),
        "corpus_files_changed": 0,
    }
    (refined / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = [
        "FANYA HANWEN REFINED SOURCE TRIAGE",
        "==================================",
        "",
        f"PALCC work records: {len(corpus_rows):,}",
        "Corpus files changed: 0",
        "",
        "UD",
        f"  Alignment targets: {len(ud_rows):,}",
        f"  Existing-work/chapter annotation targets: {summary['ud']['existing_annotation_targets']:,}",
        f"  Metadata-only targets needing text + annotation: {summary['ud']['fill_missing_primary_and_annotate']:,}",
        f"  New exact source works from UD: {summary['ud']['new_work_from_ud']:,}",
        "",
        "CODH",
        f"  Text-bearing records: {len(codh_rows):,}",
        f"  Host works with embedded Literary-Chinese passages: {summary['codh']['host_works_with_embedded_literary_chinese']:,}",
        f"  Strict Han-dominant candidate segments: {len(segments):,}",
        f"  Han characters in those segments: {summary['codh']['embedded_han_chars']:,}",
        "",
        "KANRIPO",
        f"  Exact-title witness downloads: {kanripo_counts['DOWNLOAD_FOR_WITNESS_COMPARE']:,}",
        f"  Exact-title metadata-only works needing primary text: {kanripo_counts['FILL_MISSING_PRIMARY_TEXT']:,}",
        f"  Title-family review: {kanripo_counts['TITLE_FAMILY_REVIEW']:,}",
        f"  Probable new works: {kanripo_counts['PROBABLE_NEW_WORK']:,}",
        f"  Title unresolved: {kanripo_counts['TITLE_UNRESOLVED']:,}",
        "",
        "NIJL",
        f"  Exact non-short title witness downloads: {nijl_counts['DOWNLOAD_FOR_WITNESS_COMPARE']:,}",
        f"  Related/title-collision review: {nijl_counts['RELATED_OR_TITLE_COLLISION_REVIEW']:,}",
        f"  CODH-linked titled but unmatched: {nijl_counts['TITLED_UNMATCHED_LANGUAGE_SCREEN']:,}",
        f"  Identifier-only/unresolved: {nijl_counts['IDENTIFIER_ONLY_UNRESOLVED']:,}",
        "",
        "Refinement rules",
        "  * Unlinked NIJL GitLab descriptions are hints only, not authoritative titles.",
        "  * NIJL exact title matches of <=3 characters go to collision review.",
        "  * Fuzzy/containment matches are relationships to review, not witness identity.",
        "  * Kanripo catalogue payload markers such as （正文） are excluded from work-title identity.",
        "  * Established Kanripo/PALCC title aliases are exact bibliographic equivalences, not fuzzy matches.",
        "  * TueCL is 莊子・逍遙遊, not a missing standalone work.",
        "  * Kyoto KR6c0023 and KR6c0127 are exact-source new-work candidates unless PALCC later gains exact editions.",
        "",
        "Queues are triage only; download-for-witness-compare never means overwrite.",
        "",
    ]
    # This report contains Han script, so preserve the corpus-wide UTF-8 BOM rule.
    (refined / "summary.txt").write_text("\n".join(lines), encoding="utf-8-sig")
    print("\n".join(lines))
    print(f"Refined reports: {refined}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
