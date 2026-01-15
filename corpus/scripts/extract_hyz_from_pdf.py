#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Extract HYZ inscriptions into corpus files, preserving scholarly symbols.
Unknown/unencoded/image-derived glyphs are substituted as '□' in transcription,
and each substitution is recorded in a sidecar TSV evidence file (Option A).

Outputs:
  out_root/
    花园庄东地甲骨/
      HYZ 443-444 443.1.txt
      HYZ 443-444 443.1.evidence.tsv   (only if needed)
      譯文/ ...                        (optional)
      REVIEW_INDEX.tsv                 (always, lists files needing review)
"""

import argparse
import re
from pathlib import Path

import fitz  # PyMuPDF


# ----------------- CJK range utilities -----------------
def is_cjk(ch: str) -> bool:
    cp = ord(ch)
    return (
        (0x3400 <= cp <= 0x4DBF) or   # Ext A
        (0x4E00 <= cp <= 0x9FFF) or   # Unified
        (0x20000 <= cp <= 0x2A6DF) or # Ext B
        (0x2A700 <= cp <= 0x2B73F) or # Ext C
        (0x2B740 <= cp <= 0x2B81D) or # Ext D
        (0x2B820 <= cp <= 0x2CEAD) or # Ext E
        (0x2CEB0 <= cp <= 0x2EBE0) or # Ext F
        (0x31350 <= cp <= 0x323AF) or # Ext H
        (0x2EBF0 <= cp <= 0x2EE5D) or # Ext I
        (0x323B0 <= cp <= 0x33479) or # Ext J
        (0x2F800 <= cp <= 0x2FA1F)    # Supplement
    )


def is_private_use(ch: str) -> bool:
    cp = ord(ch)
    return (
        (0xE000 <= cp <= 0xF8FF) or     # BMP PUA
        (0xF0000 <= cp <= 0xFFFFD) or   # Plane 15 PUA
        (0x100000 <= cp <= 0x10FFFD)    # Plane 16 PUA
    )


# Keep editorial and epigraphic symbols (do NOT treat these as garbage).
ALLOWED_NON_CJK = set(
    " \t\r\n"
    "0123456789"
    ".,;:!?\"'`-—–"
    "，。、；：？！"
    "()[]【】《》〈〉"
    "…"
    "□"          # one missing graph (when actually present in text layer)
    "|"
    "=" "≈" "/" "<" ">"
    "*"
    "↔"
)

# Some PDFs output “tofu” or replacement characters.
SUSPICIOUS_CHARS = set(["�", "\uFFFD"])  # replacement char


# ----------------- Sanitization with evidence -----------------
def sanitize_transcription_with_evidence(raw: str, *, page_no: int, line_hint: str):
    """
    Returns (clean_text, evidence_rows)
    evidence_rows are dicts with:
      - char_index: 1-based index in the clean_text (excluding newlines)
      - inserted: the character inserted (always □ here)
      - raw_char: the original raw character (may be empty if missing)
      - raw_codepoint: e.g. U+E123
      - reason: private_use | suspicious | disallowed
      - page: page number (1-based for humans)
      - context: short line hint
    """
    evidence = []
    out = []
    clean_index = 0  # 1-based in output; increment when we append non-newline chars

    for ch in raw:
        # Preserve newlines only if they are meaningful; most HYZ lines are single-line.
        # We keep them, but don't count them in char_index.
        if ch == "\n":
            out.append(ch)
            continue

        keep = is_cjk(ch) or (ch in ALLOWED_NON_CJK)
        suspicious = (ch in SUSPICIOUS_CHARS) or is_private_use(ch)

        if keep and not suspicious:
            out.append(ch)
            if ch not in ("\r",):
                clean_index += 1
            continue

        # If it's a *known* scholarly symbol like □, keep it even if "suspicious" tests trigger.
        # (Some fonts do weird things, but □ itself is safe.)
        if ch == "□":
            out.append(ch)
            clean_index += 1
            continue

        # Otherwise: substitute as missing graph marker □ and record evidence.
        inserted = "□"
        out.append(inserted)
        clean_index += 1

        cp = ord(ch) if ch else None
        codepoint = f"U+{cp:04X}" if cp is not None else ""
        if is_private_use(ch):
            reason = "private_use"
        elif ch in SUSPICIOUS_CHARS:
            reason = "replacement_char"
        else:
            reason = "disallowed_or_image_glyph"

        evidence.append({
            "char_index": clean_index,
            "inserted": inserted,
            "raw_char": ch,
            "raw_codepoint": codepoint,
            "reason": reason,
            "page": page_no,
            "context": line_hint[:80].replace("\t", " ").replace("\n", " "),
        })

    text = "".join(out)

    # Normalize whitespace: HYZ transcriptions typically don’t want internal runs of spaces.
    text = re.sub(r"[ \t]+", " ", text).strip()

    # Collapse huge runs: if extractor produced 5 unknown glyphs, keep it readable as □□
    text = re.sub(r"□{3,}", "□□", text)

    return text, evidence


# ----------------- Parsing -----------------
HYZ_HEADER_RE = re.compile(r"^\s*HYZ\s+(\d+(?:[-+]\d+)?)\s*$")
ACCOUNT_RE = re.compile(r"^\s*(\d+(?:[-+]\d+)?\.\d+)\s*(.*)$")


def find_start_page(doc: fitz.Document, needle: str) -> int:
    for i in range(doc.page_count):
        text = doc.load_page(i).get_text("text")
        if needle in text:
            return i
    return 0


def write_corpus_file(path: Path, catalog: str, source: str, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    header = (
        "# WORK_BASE_TITLE: 花园庄东地甲骨\n"
        "# AUTHOR: \n"
        "# NATION: 商殷朝\n"
        "# TIMES: \n"
        "# CATEGORIES: 商殷朝，甲骨文\n"
        f"# CATALOG: {catalog}\n"
        f"# SOURCE: {source}\n\n"
    )
    path.write_text(header + body.rstrip() + "\n", encoding="utf-8")


def write_evidence_tsv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Simple TSV schema (stable for later tooling)
    cols = ["char_index", "inserted", "raw_char", "raw_codepoint", "reason", "page", "context"]
    lines = ["\t".join(cols)]
    for r in rows:
        lines.append("\t".join(str(r.get(c, "")) for c in cols))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pdf", required=True, help="Path to the PDF")
    ap.add_argument("--out-dir", required=True, help="Output directory (root)")
    ap.add_argument("--work-dir-name", default="花园庄东地甲骨", help="Subfolder name")
    ap.add_argument("--translations-subdir", default="譯文", help="Where to store translations")
    ap.add_argument("--with-translations", action="store_true", help="Write translation files too")
    ap.add_argument("--start-needle", default="The Oracle Bone Inscriptions", help="Where to start parsing")
    args = ap.parse_args()

    source = (
        "Schwartz, A. C. (2019). The Oracle Bone Inscriptions from Huayuanzhuang East. "
        "De Gruyter. https://doi.org/10.1515/9781501505294-001"
    )

    doc = fitz.open(args.pdf)
    start = find_start_page(doc, args.start_needle)

    out_root = Path(args.out_dir) / args.work_dir_name
    trans_root = out_root / args.translations_subdir
    out_root.mkdir(parents=True, exist_ok=True)

    # REVIEW_INDEX rows: filename, substitutions_count, pages (comma), first_reason
    review_rows = []

    current_piece = None
    current_account_id = None
    current_zh = ""
    current_en = ""
    current_zh_page = None
    current_zh_line_hint = ""
    expecting_en = False

    def flush_account():
        nonlocal current_account_id, current_zh, current_en, expecting_en, current_zh_page, current_zh_line_hint

        if not current_account_id:
            return

        catalog = f"HYZ {current_account_id}"
        base_name = f"HYZ {current_account_id}.txt"
        out_path = out_root / base_name

        clean_zh, evidence = sanitize_transcription_with_evidence(
            current_zh,
            page_no=(current_zh_page or 1),
            line_hint=current_zh_line_hint or current_zh[:80]
        )

        if clean_zh:
            write_corpus_file(out_path, catalog=catalog, source=source, body=clean_zh)

        if evidence:
            ev_path = out_root / f"HYZ {current_account_id}.evidence.tsv"
            write_evidence_tsv(ev_path, evidence)

            pages = sorted({str(r["page"]) for r in evidence})
            review_rows.append({
                "file": base_name,
                "substitutions": len(evidence),
                "pages": ",".join(pages),
                "first_reason": evidence[0]["reason"],
            })
        else:
            # If an older evidence file exists from previous runs, remove it (overwrite semantics).
            ev_path = out_root / f"HYZ {current_account_id}.evidence.tsv"
            if ev_path.exists():
                ev_path.unlink()

        if args.with_translations:
            en_clean = re.sub(r"\s+", " ", current_en).strip()
            if en_clean:
                write_corpus_file(
                    trans_root / base_name,
                    catalog=catalog,
                    source=source,
                    body=en_clean
                )

        # Reset
        current_account_id = None
        current_zh = ""
        current_en = ""
        current_zh_page = None
        current_zh_line_hint = ""
        expecting_en = False

    for pno in range(start, doc.page_count):
        page_text = doc.load_page(pno).get_text("text")
        lines = [ln.rstrip("\r") for ln in page_text.splitlines()]

        for ln in lines:
            m_h = HYZ_HEADER_RE.match(ln)
            if m_h:
                flush_account()
                current_piece = m_h.group(1)
                continue

            m_a = ACCOUNT_RE.match(ln)
            if m_a and current_piece:
                flush_account()
                current_account_id = m_a.group(1)
                rest = m_a.group(2).strip()
                current_zh = rest
                current_zh_page = pno + 1  # human 1-based
                current_zh_line_hint = ln.strip()
                expecting_en = True
                continue

            if current_account_id:
                if expecting_en:
                    if ln.strip():
                        # If it looks English-ish, treat as translation; else as transcription wrap.
                        if re.search(r"[A-Za-z]", ln):
                            current_en += (" " + ln.strip())
                        else:
                            current_zh += (" " + ln.strip())
                    if current_en.strip():
                        expecting_en = False
                else:
                    if re.search(r"[A-Za-z]", ln):
                        current_en += (" " + ln.strip())

    flush_account()

    # Write REVIEW_INDEX.tsv
    idx_path = out_root / "REVIEW_INDEX.tsv"
    cols = ["file", "substitutions", "pages", "first_reason"]
    lines = ["\t".join(cols)]
    for r in sorted(review_rows, key=lambda x: (-x["substitutions"], x["file"])):
        lines.append("\t".join(str(r.get(c, "")) for c in cols))
    idx_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"Done. Output written to: {out_root}")
    print(f"Review index: {idx_path}")

if __name__ == "__main__":
    main()
