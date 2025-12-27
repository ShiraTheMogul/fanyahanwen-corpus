#!/usr/bin/env python3
import argparse
import re
from collections import defaultdict
from typing import Dict, Set, Tuple

import pandas as pd

# ------------------------------------------------------------
# CJK ranges (Hanzi + extensions)
# ------------------------------------------------------------

CJK_RANGES = [
    (0x3400, 0x4DBF),   # Extension A
    (0x4E00, 0x9FFF),   # CJK Unified Ideographs
    (0x20000, 0x2A6DF), # Extension B
    (0x2A700, 0x2B73F), # Extension C
    (0x2B740, 0x2B81D), # Extension D
    (0x2B820, 0x2CEAD), # Extension E
    (0x2CEB0, 0x2EBE0), # Extension F
    (0x31350, 0x323AF), # Extension H
    (0x2EBF0, 0x2EE5D), # Extension I
    (0x323B0, 0x33479), # Extension J
    (0x2F800, 0x2FA1F), # CJK Compatibility/Supplement
]


def is_cjk(ch: str) -> bool:
    """Return True if ch is in one of the CJK ranges we care about."""
    if not ch:
        return False
    code = ord(ch)
    for start, end in CJK_RANGES:
        if start <= code <= end:
            return True
    return False


# ------------------------------------------------------------
# 漢典 dictionary loading (Hanzi)
# ------------------------------------------------------------

def load_hanzi_dict_for_encoding(path: str, encoding: str) -> Tuple[Dict[str, str], Set[str]]:
    """
    Load 漢典 dictionary entries using a specific encoding.

    Headword rule:
    - line.strip() is exactly ONE character
    - that character is CJK

    We also track characters that appear as headwords more than once
    (multi-entry), so we can skip merging them later.
    """
    entries: Dict[str, str] = {}
    multi_entry_chars: Set[str] = set()

    current_char = None
    current_lines = []

    with open(path, "r", encoding=encoding, errors="replace") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            stripped = line.strip()

            if stripped and len(stripped) == 1 and is_cjk(stripped):
                # New headword
                if current_char is not None:
                    block = "\n".join(current_lines)
                    if current_char in entries:
                        # Seen this char before: mark as multi-entry and append
                        multi_entry_chars.add(current_char)
                        entries[current_char] += "\n" + block
                    else:
                        entries[current_char] = block
                current_char = stripped
                current_lines = []
            else:
                if current_char is not None:
                    current_lines.append(line)

    # Final entry
    if current_char is not None:
        block = "\n".join(current_lines)
        if current_char in entries:
            multi_entry_chars.add(current_char)
            entries[current_char] += "\n" + block
        else:
            entries[current_char] = block

    return entries, multi_entry_chars


def load_hanzi_dict(path: str, encodings=None):
    """
    Try multiple encodings, choose the one that yields the most entries.

    Returns:
        entries: {hanzi -> entry_text}
        multi_entry_chars: set of hanzi that had multiple headword entries
        best_encoding: chosen encoding
    """
    if encodings is None:
        encodings = ["utf-8-sig", "utf-8", "gb18030", "big5", "utf-16-le", "utf-16-be"]

    best_entries: Dict[str, str] = {}
    best_multi: Set[str] = set()
    best_encoding = None
    best_count = -1

    for enc in encodings:
        try:
            entries, multi = load_hanzi_dict_for_encoding(path, enc)
            count = len(entries)
            print(f"  [encoding test] {enc}: {count} entries")
            if count > best_count:
                best_count = count
                best_entries = entries
                best_multi = multi
                best_encoding = enc
        except Exception as e:
            print(f"  [encoding test] {enc}: ERROR ({e})")

    print(f"Using encoding '{best_encoding}' with {best_count} entries.")
    return best_entries, best_multi, best_encoding


# ------------------------------------------------------------
# 拼音 extraction
# ------------------------------------------------------------

def extract_pinyin(entry_text: str):
    """
    Try to extract the 拼音 field from an entry.

    Returns:
        - a string containing pinyin(s), or
        - None if not found.
    """
    m = re.search(r"拼音[:：]\s*([^\n]+)", entry_text)
    if not m:
        return None

    line = m.group(1)

    cut_tokens = [
        "注音", "五笔", "五筆", "仓颉", "倉頡", "郑码", "鄭碼",
        "笔顺", "筆順", "UniCode", "基本解释", "基本解釋",
    ]
    for token in cut_tokens:
        idx = line.find(token)
        if idx != -1:
            line = line[:idx]
            break

    return line.strip(" 　")  # strip ASCII + full-width spaces


def pinyin_to_set(pinyin_str: str):
    """
    Convert a pinyin string to a set of readings.

    Split on whitespace, 、, ，, and ASCII punctuation.
    """
    if not pinyin_str:
        return set()
    tokens = re.split(r"[、，,;；\s]+", pinyin_str.strip())
    return {t for t in tokens if t}


# ------------------------------------------------------------
# Variant detection from 漢典
# ------------------------------------------------------------

def find_variant_base_char(entry_text: str):
    """
    Find the base character Y in a 漢典 entry that is essentially
    "same as Y" (possibly repeated), without multiple different bases.

    Rules:
      - Work primarily inside the 《康熙字典》 section if present.
      - If 康熙 section contains '又' → multiple senses → skip.
      - Collect all '同Y' (optionally quoted) where Y is CJK.
      - If there are NO such matches → skip.
      - If there are multiple different Y (e.g. 同甲, 同乙) → skip.
      - If all Y are the same (e.g. 同蟗 twice) → merge to that Y.
    """

    # 1) Isolate 康熙 section if present
    kx_idx = entry_text.find("《康熙字典》")
    if kx_idx != -1:
        ktext = entry_text[kx_idx:]
    else:
        ktext = entry_text

    # 2) Heuristic for multiple definitions: '又' in 康熙 section
    if "又" in ktext:
        return None

    # 3) Find all '同Y' not preceded by '疑'
    pattern = re.compile(r"(?<!疑)同[“\"『「]?(?P<char>.)[”\"』」]?")
    raw_matches = pattern.findall(ktext)

    # Keep only CJK base chars
    matches = [ch for ch in raw_matches if is_cjk(ch)]

    if not matches:
        # no usable '同Y'
        return None

    unique_bases = set(matches)
    if len(unique_bases) != 1:
        # multiple different base characters → ambiguous → do NOT merge
        return None

    # Exactly one unique base character
    base_char = next(iter(unique_bases))
    return base_char



def build_variant_mapping(entries: Dict[str, str], multi_entry_chars: Set[str]) -> Dict[str, str]:
    """
    Build variant -> base_hanzi mapping using 漢典 entries.

    Conditions for merging a variant V to base B:
      - V has only ONE 漢典 entry (not in multi_entry_chars).
      - find_variant_base_char(entry_text) returns a base hanzi B.
      - 拼音 constraint:
          if BOTH V and B have non-empty pinyin sets,
          then pinyin(V) must be a subset of pinyin(B).
    """
    mapping: Dict[str, str] = {}

    pinyin_map = {
        ch: pinyin_to_set(extract_pinyin(text))
        for ch, text in entries.items()
    }

    for char, text in entries.items():
        # Skip polysemous chars (multiple entries)
        if char in multi_entry_chars:
            continue

        base = find_variant_base_char(text)
        if not base:
            continue

        if base not in entries:
            # be conservative: require that base also has a 漢典 entry
            continue

        var_py = pinyin_map.get(char, set())
        base_py = pinyin_map.get(base, set())

        # 拼音 constraint
        if var_py and base_py and not var_py.issubset(base_py):
            continue

        mapping[char] = base

    return mapping

def resolve_root(char: str, mapping: Dict[str, str]) -> str:
    """
    Follow variant -> base mapping chains to find the ultimate orthodox root.

    Handles chains like A -> B, B -> C: root(A) = C.
    Also guards against cycles.
    """
    seen = set()
    current = char
    while current in mapping and current not in seen:
        seen.add(current)
        current = mapping[current]
    return current


# ------------------------------------------------------------
# Optional: Wiktionary zh-see mapping (simplified -> canonical)
# ------------------------------------------------------------

def load_wikt_zhsee_map(path: str) -> Dict[str, str]:
    """
    Load Wiktionary zh-see mapping: variant -> canonical hanzi.

    Expects a CSV with columns:
        from_char, to_char
    """
    df = pd.read_csv(path, encoding="utf-8-sig")
    if "from_char" not in df.columns or "to_char" not in df.columns:
        raise ValueError("wikt_zhsee_map.csv must have 'from_char' and 'to_char' columns.")

    mapping: Dict[str, str] = {}
    for _, row in df.iterrows():
        src = str(row["from_char"]).strip()
        tgt = str(row["to_char"]).strip()
        if len(src) == 1 and len(tgt) == 1:
            mapping[src] = tgt
    return mapping


# ------------------------------------------------------------
# Frequency merging
# ------------------------------------------------------------

def merge_frequencies(freq_csv_path: str, variant_mapping: Dict[str, str],
                      out_csv_path: str, out_encoding: str = "utf-16-le") -> pd.DataFrame:
    """
    Merge frequency counts for variant characters into their orthodox base.
    Recompute rank (1 = most frequent) and write a new CSV.

    Input CSV is assumed to have columns: 'chars', 'n'.
    Any existing rank column is ignored; we recompute.
    """
    df = pd.read_csv(freq_csv_path, dtype={"chars": str})
    if "chars" not in df.columns or "n" not in df.columns:
        raise ValueError("Frequency CSV must contain 'chars' and 'n' columns.")

    canonical_totals = defaultdict(int)

    for _, row in df.iterrows():
        ch = row["chars"]
        n = int(row["n"])
        root = resolve_root(ch, variant_mapping)
        canonical_totals[root] += n

    merged_rows = [{"chars": ch, "n": total}
                   for ch, total in canonical_totals.items()]

    merged_df = pd.DataFrame(merged_rows)
    merged_df = merged_df.sort_values("n", ascending=False).reset_index(drop=True)
    merged_df["rank"] = merged_df.index + 1

    merged_df.to_csv(out_csv_path, index=False, encoding="utf-8-sig")
    return merged_df


def write_mapping_csv(mapping: Dict[str, str], path: str, entries: Dict[str, str]):
    """
    Write variant->base mapping to a CSV (UTF-8-SIG).
    """
    rows = []
    for v, b in sorted(mapping.items()):
        rows.append({"variant": v, "base": b})
    df = pd.DataFrame(rows)
    df.to_csv(path, index=False, encoding="utf-8-sig")


# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Merge Hanzi variants based on 漢典 '同Y' definitions, with optional Wiktionary zh-see."
    )
    parser.add_argument("dict_path", help="Path to 漢典 dictionary file (e.g. 漢典20120920.txt)")
    parser.add_argument("freq_csv", help="Path to frequency CSV (must contain 'chars' and 'n' columns)")
    parser.add_argument(
        "-o", "--out-csv",
        default="LC_frequency_list_merged_variants.csv",
        help="Output CSV path for merged frequencies (default: LC_frequency_list_merged_variants.csv)."
    )
    parser.add_argument(
        "--dict-encoding",
        default=None,
        help="Force a specific encoding for 漢典 file (otherwise auto-detect)."
    )
    parser.add_argument(
        "--mapping-csv",
        default="variant_mapping.csv",
        help="Write variant->base mapping to this CSV (default: variant_mapping.csv)."
    )
    parser.add_argument(
        "--wikt-zhsee-map",
        default=None,
        help="Optional path to wikt_zhsee_map.csv (variant->canonical from Wiktionary)."
    )

    args = parser.parse_args()

    # 1) Load 漢典 dictionary
    print("Loading 漢典 dictionary...")
    if args.dict_encoding:
        entries, multi_entry_chars = load_hanzi_dict_for_encoding(args.dict_path, args.dict_encoding)
        print(f"Loaded {len(entries)} entries with encoding '{args.dict_encoding}'.")
    else:
        entries, multi_entry_chars, chosen_enc = load_hanzi_dict(args.dict_path)
        print(f"Loaded {len(entries)} entries using auto-detected encoding '{chosen_enc}'.")
    print(f"Characters with multiple 漢典 headword entries (skipped as variants): {len(multi_entry_chars)}")

    # 2) Build variant mapping from 漢典
    print("Building variant mapping from 漢典 '同Y' definitions and 拼音 constraint...")
    variant_mapping = build_variant_mapping(entries, multi_entry_chars)
    print(f"Found {len(variant_mapping)} variant mappings from 漢典.")

    # 3) Optional: integrate Wiktionary zh-see mapping
    if args.wikt_zhsee_map:
        ans = input(
            f"Also merge simplified variants via Wiktionary zh-see map "
            f"from '{args.wikt_zhsee_map}'? [y/N] "
        ).strip().lower()

        if ans == "y":
            print("Loading Wiktionary zh-see mapping...")
            wikt_map = load_wikt_zhsee_map(args.wikt_zhsee_map)
            print(f"Loaded {len(wikt_map)} mappings from Wiktionary.")

            before = len(variant_mapping)
            # Wiktionary mappings layered on top of 漢典 ones
            variant_mapping.update(wikt_map)
            after = len(variant_mapping)
            print(f"Combined mapping size: {before} -> {after} entries.")
        else:
            print("Skipping Wiktionary zh-see integration.")

    # 4) Write mapping CSV
    if args.mapping_csv:
        print(f"Writing variant mapping to {args.mapping_csv} ...")
        write_mapping_csv(variant_mapping, args.mapping_csv, entries)

    # 5) Merge frequencies
    print("Merging frequencies and recomputing ranks...")
    merged_df = merge_frequencies(args.freq_csv, variant_mapping, args.out_csv, out_encoding="utf-8-sig")
    print(f"Done. Wrote merged frequency list to {args.out_csv}")
    print(f"Final number of distinct characters: {len(merged_df)}")


if __name__ == "__main__":
    main()
