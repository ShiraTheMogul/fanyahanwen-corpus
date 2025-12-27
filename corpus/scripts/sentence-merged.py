#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations

import csv
import unicodedata
from pathlib import Path


def norm(s: str) -> str:
    """Normalize sentence keys to improve matching."""
    if s is None:
        return ""
    s = unicodedata.normalize("NFKC", s).strip()
    s = s.replace("\ufeff", "").replace("\u200b", "")
    # collapse whitespace
    s = " ".join(s.split())
    return s


def load_sentence_to_rom(csv_path: Path) -> dict[str, str]:
    """
    Load mapping: shanghainese sentence -> romanisation_pdf
    If duplicates occur, first seen wins (simple + predictable).
    """
    mapping: dict[str, str] = {}
    with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            raise SystemExit("CSV has no header row.")

        # Be tolerant: accept BOM-polluted header names too
        fieldnames = [fn.replace("\ufeff", "") for fn in reader.fieldnames]
        # Build a remap so row[...] works even if BOM was present
        remap = {orig: cleaned for orig, cleaned in zip(reader.fieldnames, fieldnames)}

        # Find the two fields we actually need
        sh_field = None
        rom_field = None
        for fn in fieldnames:
            if fn == "shanghainese":
                sh_field = fn
            if fn == "romanisation_pdf":
                rom_field = fn
        if sh_field is None or rom_field is None:
            raise SystemExit(f"CSV must contain 'shanghainese' and 'romanisation_pdf'. Found: {fieldnames}")

        for raw_row in reader:
            # normalize keys of the row via remap
            row = {remap[k]: v for k, v in raw_row.items()}
            sh = norm(row.get("shanghainese", ""))
            rom = (row.get("romanisation_pdf") or "").strip()
            if not sh or not rom:
                continue
            if sh not in mapping:
                mapping[sh] = rom

    return mapping


def merge_selected_notes(anki_path: Path, mapping: dict[str, str], out_path: Path, log_path: Path) -> None:
    """
    Replace only romanisation field (index 4) if sentence field (index 3) matches CSV.
    Keeps everything else identical.
    """
    header_lines: list[str] = []
    out_lines: list[str] = []
    log_rows: list[list[str]] = [["lineno", "status", "sentence", "old_rom", "new_rom"]]

    total = 0
    matched = 0
    skipped_malformed = 0

    with anki_path.open("r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, start=1):
            line = line.rstrip("\n")
            if not line:
                continue

            if line.startswith("#"):
                header_lines.append(line)
                continue

            fields = line.split("\t")
            # Expect exactly 9 fields per your export layout
            if len(fields) != 9:
                skipped_malformed += 1
                out_lines.append(line)
                log_rows.append([str(lineno), "malformed_passthrough", "", "", ""])
                continue

            total += 1
            sentence = fields[3]
            old_rom = fields[4]
            k = norm(sentence)

            if k in mapping:
                fields[4] = mapping[k]
                matched += 1
                log_rows.append([str(lineno), "matched", sentence, old_rom, fields[4]])
            else:
                log_rows.append([str(lineno), "no_match", sentence, old_rom, old_rom])

            out_lines.append("\t".join(fields))

    # Write output (preserve header lines exactly, then the rows)
    with out_path.open("w", encoding="utf-8", newline="") as f:
        for h in header_lines:
            f.write(h + "\n")
        for l in out_lines:
            f.write(l + "\n")

    # Write log
    with log_path.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, delimiter="\t")
        w.writerows(log_rows)

    print("Done.")
    print(f"Notes processed: {total}")
    print(f"Matched + replaced romanisation: {matched}")
    print(f"Malformed lines passed through unchanged: {skipped_malformed}")
    print(f"Wrote: {out_path}")
    print(f"Log:   {log_path}")


def main():
    csv_path = Path("sentences.csv")
    anki_path = Path("Selected Notes.txt")
    out_path = Path("New_Notes.txt")
    log_path = Path("merge_log.tsv")

    mapping = load_sentence_to_rom(csv_path)
    merge_selected_notes(anki_path, mapping, out_path, log_path)


if __name__ == "__main__":
    main()
