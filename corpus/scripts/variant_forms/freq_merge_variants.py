#!/usr/bin/env python3
"""
Normalize LC frequency list using:

1. TN43 kStrange map (Ideograph -> Reference) from tn43_kstrange_map.csv
2. Excel Var-to-Rep_v1_0.xlsx (Variant_Character -> Representative_Character)
3. Unihan via cihai:
   - kTraditionalVariant (simplified -> traditional)
   - kZVariant (glyph variants collapse)
   (We ignore semantic variant fields completely.)

We *always* aim for:
- Traditional forms as canonical (never simplified if Unihan gives a traditional)
- Dropping stroke/radical-only junk (丨 etc.)
- Respecting DONT_MERGE: characters that should never be merged.

Usage:
    python freq_merge_variants.py input.csv output.csv Var-to-Rep.xlsx tn43_kstrange_map.csv
"""

import sys
import logging
from typing import Dict, Optional, Set

import pandas as pd
from cihai.core import Cihai

log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(message)s")

########################
# Config: Drops & Exceptions
########################

# Characters to drop as “pure radical / stroke” noise
RADICAL_BLACKLIST: Set[str] = {
    "丨", "丶", "丿", "亅", "乀", "乁", "乛", "乚",
}

# Stuff to force merges in when my dataset seems to fail.
DO_MERGE: Dict[str, str] = {
    # simplified / odd → traditional (canonical)
    "鲜": "鮮",
    "𡊮": "袁",
    "搅": "攪",
    "𠂻": "衷",
    "𥙷": "補",  
    "𥙷": "補", # chose 補 as canonical traditional form
    "𡨋": "冥",
    "𥳑": "簡",
    "𢃄": "帶",
    "农": "農",
    "𭣣": "收",
    "𠋣": "倚",
    "𠫭": "參",
    "孒": "孓",
    "𭛠": "役",
    "鬭": "鬥",
    "鬪": "鬥",
    "𩰚": "鬥", # 𩰚 is the orthodox form but 鬥 is more commonly used and available to users.
    "聴": "聽",
    "冦": "寇",
    "逰": "遊",
    "賫": "齎",
    "圗": "圖",
    "専": "專",
    "㖈": "䎛",
}


# Characters we NEVER want to merge, even if Unicode / datasets say they’re variants
DONT_MERGE: Set[str] = {
    "周",
    "于",
    "云",
    "气",
    "予",
    "芸",
    "余",
    "辨","瓣","辯",
    "台",
    "糸",
    "豊",
    "缶",
    "体",
    "浜",
    "蚕",
    "証",
    "医",
    "担",
    "胆",
    "灯",
    "臼","舊",
    "亘",
    "嶽",
    "黨",
    "斗",
}

# Load Wiktionary variant map
def load_wikt_zhsee_map(path: str) -> dict[str, str]:
    """Load Wiktionary zh-see mapping: variant -> canonical char."""
    df = pd.read_csv(path, encoding="utf-8")
    if "from_char" not in df.columns or "to_char" not in df.columns:
        raise ValueError("wikt_zhsee_map.csv must have 'from_char' and 'to_char' columns.")

    mapping: dict[str, str] = {}
    for _, row in df.iterrows():
        src = str(row["from_char"]).strip()
        tgt = str(row["to_char"]).strip()
        if len(src) == 1 and len(tgt) == 1:
            mapping[src] = tgt
    return mapping


########################
# CJK ranges
########################

CJK_RANGES = [
    (0x4E00, 0x9FFF),   # Unified
    (0x3400, 0x4DBF),   # Ext A
    (0x20000, 0x2A6DF), # Ext B
    (0x2A700, 0x2B73F), # Ext C
    (0x2B740, 0x2B81D), # Ext D
    (0x2B820, 0x2CEAD), # Ext E
    (0x2CEB0, 0x2EBE0), # Ext F
    (0x31350, 0x323AF), # Ext H
    (0x2EBF0, 0x2EE5D), # Ext I
    (0x323B0, 0x33479), # Ext J
    (0x2F800, 0x2FA1F), # Supplement
]

def is_cjk(ch: str) -> bool:
    if not ch or len(ch) != 1:
        return False
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in CJK_RANGES)

########################
# Unihan via cihai
########################

def init_unihan() -> Cihai:
    log.info("Initializing Cihai / Unihan…")
    app = Cihai()
    if not app.unihan.is_bootstrapped:
        app.unihan.bootstrap()
    app.unihan.add_plugin(
        "cihai.data.unihan.dataset.UnihanVariants",
        namespace="variants",
    )
    return app

########################
# External mappings
########################

def load_varrep_xlsx(path: str) -> Dict[str, str]:
    """Excel: Variant_Character -> Representative_Character"""
    log.info("Loading Var→Rep mapping from %s", path)
    df = pd.read_excel(path)
    if "Variant_Character" not in df.columns or "Representative_Character" not in df.columns:
        raise ValueError("Excel must have 'Variant_Character' and 'Representative_Character' columns.")
    mapping: Dict[str, str] = {}
    for _, row in df.iterrows():
        var = str(row["Variant_Character"])
        rep = str(row["Representative_Character"])
        if len(var) == 1 and len(rep) == 1:
            mapping[var] = rep
    log.info("Loaded %d variant→rep pairs from Excel.", len(mapping))
    return mapping

def load_kstrange_map_csv(path: str) -> Dict[str, str]:
    """TN43 CSV: Ideograph -> Reference (from tn43_kstrange_map.csv)"""
    log.info("Loading TN43 kStrange map from %s", path)
    df = pd.read_csv(path, encoding="utf-8")
    if "ideograph" not in df.columns or "reference" not in df.columns:
        raise ValueError("TN43 CSV must have 'ideograph' and 'reference' columns.")
    mapping: Dict[str, str] = {}
    for _, row in df.iterrows():
        src = str(row["ideograph"])
        tgt = str(row["reference"])
        if len(src) == 1 and len(tgt) == 1:
            mapping[src] = tgt
    log.info("Loaded %d Ideograph→Reference pairs from TN43.", len(mapping))
    return mapping

########################
# Per-character Unihan helpers
########################

def get_glyph(ch: str, app: Cihai, glyph_cache: Dict[str, Optional[object]]):
    if ch in glyph_cache:
        return glyph_cache[ch]
    q = app.unihan.lookup_char(ch)
    glyph = q.first()
    glyph_cache[ch] = glyph
    return glyph

def get_traditional_from_unihan(ch: str, app: Cihai, glyph_cache: Dict[str, Optional[object]]) -> Optional[str]:
    """
    If Unihan says this char has a traditional variant (kTraditionalVariant),
    return the first candidate; else None.
    """
    glyph = get_glyph(ch, app, glyph_cache)
    if glyph is None:
        return None
    raw = getattr(glyph, "kTraditionalVariant", None)
    if not raw:
        return None
    parts = str(raw).split()
    return parts[0] if parts else None

def get_zvariant_canonical(ch: str, app: Cihai, glyph_cache: Dict[str, Optional[object]]) -> Optional[str]:
    """
    If this char has Z-variants, return a stable canonical among ch + its Z-variants
    (lexicographically smallest).
    """
    glyph = get_glyph(ch, app, glyph_cache)
    if glyph is None:
        return None
    raw = getattr(glyph, "kZVariant", None)
    if not raw:
        return None
    cands = {ch}
    for token in str(raw).split():
        # token may be a single char or some tag; we only consider 1-char tokens
        if len(token) == 1:
            cands.add(token)
    if len(cands) <= 1:
        return None
    return sorted(cands)[0]

########################
# Core normalization
########################

def normalize_char(
    ch: str,
    app: Cihai,
    varmap: Dict[str, str],
    kstrange_map: Dict[str, str],
    wikt_map: dict[str, str],
    cache: Dict[str, Optional[str]],
    glyph_cache: Dict[str, Optional[object]],
) -> Optional[str]:
    """
    Normalize a single character using layered rules:

    0. cache
    1. RADICAL_BLACKLIST -> drop
    2. non-singletons returned unchanged
    3. DONT_MERGE -> unchanged
    4. TN43 kStrange map: ch -> reference (and keep normalizing)
    5. Excel Var→Rep: ch -> representative (and keep normalizing)
    6. Unihan: if simplified (kTraditionalVariant) -> traditional
    7. Unihan: if Z-variants -> canonical among Z-cluster
    8. Final pass: if result still has kTraditionalVariant, treat it as simplified
       and map again to ensure no simplified canonical.

    Any step that doesn’t change the char is just skipped.
    Characters outside CJK ranges are dropped at the end.
    """
    if ch in cache:
        return cache[ch]

    orig = ch

    # 0. DO_MERGE: manually override these characters first
    if ch in DO_MERGE:
        ch = DO_MERGE[ch]

    # 0.5 Wiktionary zh-see: variant/simplified → canonical Chinese form
    if ch in wikt_map:
        ch = wikt_map[ch]

    # 1. Drop radical-only
    if ch in RADICAL_BLACKLIST:
        cache[orig] = None
        return None

    # 2. Multi-char items: just keep them (shouldn't happen in this corpus)
    if len(ch) != 1:
        cache[orig] = ch
        return ch

    # 3. Protected: never merge
    if ch in DONT_MERGE:
        cache[orig] = ch
        return ch

    current = ch
    seen = set()

    # We’ll iterate a few times to let TN43 / Excel / Unihan cascade
    for _ in range(5):
        if current is None:
            break
        if current in seen:
            break
        seen.add(current)

        # Re-apply radical & DONT_MERGE checks in case we hopped
        if current in RADICAL_BLACKLIST:
            current = None
            break
        if current in DONT_MERGE:
            break

        changed = False

        # 4. TN43 kStrange map
        if current in kstrange_map:
            new = kstrange_map[current]
            if new != current:
                current = new
                changed = True

        # 5. Excel Var→Rep map
        if current is not None and current in varmap:
            new = varmap[current]
            if new != current:
                current = new
                changed = True

        # 6. Unihan simplified -> traditional
        if current is not None:
            trad = get_traditional_from_unihan(current, app, glyph_cache)
            if trad and trad != current:
                current = trad
                changed = True

        # 7. Unihan Z-variants -> canonical
        if current is not None:
            zcanon = get_zvariant_canonical(current, app, glyph_cache)
            if zcanon and zcanon != current:
                current = zcanon
                changed = True

        if not changed:
            break

    # Final safety: if still None or non-CJK, drop
    if current is not None and not is_cjk(current):
        current = None

    # Extra anti-simplified pass: if current still *has* a kTraditionalVariant,
    # treat it as simplified and map one more time.
    if current is not None:
        trad2 = get_traditional_from_unihan(current, app, glyph_cache)
        if trad2 and trad2 != current:
            current = trad2
            # ensure final is CJK or drop
            if not is_cjk(current):
                current = None

    cache[orig] = current
    return current


########################
# Pipeline
########################

def rebuild_frequency(
    input_csv: str,
    output_csv: str,
    varrep_xlsx: str,
    tn43_csv: str,
) -> None:
    app = init_unihan()
    varmap = load_varrep_xlsx(varrep_xlsx)
    kstrange_map = load_kstrange_map_csv(tn43_csv)
    wikt_map = load_wikt_zhsee_map("wikt_zhsee_map.csv")  # or use a variable/arg

    log.info("Reading frequency list from %s", input_csv)
    df = pd.read_csv(input_csv, encoding="utf-8")

    if "chars" not in df.columns or "n" not in df.columns:
        raise ValueError("Input CSV must have 'chars' and 'n' columns.")

    cache: Dict[str, Optional[str]] = {}
    glyph_cache: Dict[str, Optional[object]] = {}

    log.info("Normalizing characters via TN43 + Excel + Unihan…")
    df["norm_char"] = df["chars"].astype(str).map(
        lambda ch: normalize_char(ch, app, varmap, kstrange_map, wikt_map, cache, glyph_cache)
    )

    # Drop rows where norm_char is None
    before = len(df)
    df = df.dropna(subset=["norm_char"])
    after = len(df)
    log.info("Dropped %d rows (radicals / non-CJK / excluded).", before - after)

    log.info("Aggregating frequencies over normalized characters…")
    agg = (
        df.groupby("norm_char", as_index=False)["n"]
          .sum()
          .sort_values("n", ascending=False)
    )

    agg["rank_1224_normalized"] = range(1, len(agg) + 1)
    agg = agg.rename(columns={"norm_char": "chars", "n": "n_merged"})

    log.info("Writing normalized frequency list to %s", output_csv)
    agg.to_csv(output_csv, index=False, encoding="utf-8-sig")
    log.info("Done. %d unique characters in normalized list.", len(agg))


def main(argv: list[str]) -> None:
    if len(argv) < 5:
        print(
            "Usage: python freq_merge_variants.py input_csv output_csv Var-to-Rep.xlsx tn43_kstrange_map.csv\n"
            "Example:\n"
            "  python freq_merge_variants.py "
            "LC_frequency_list_1224_ranked.csv "
            "LC_frequency_list_1224_ranked_normalized.csv "
            "Chinese Var-to-Rep_v1_0.xlsx "
            "tn43_kstrange_map.csv"
        )
        sys.exit(1)

    input_csv = argv[1]
    output_csv = argv[2]
    varrep_xlsx = argv[3]
    tn43_csv = argv[4]
    rebuild_frequency(input_csv, output_csv, varrep_xlsx, tn43_csv)


if __name__ == "__main__":
    main(sys.argv)
