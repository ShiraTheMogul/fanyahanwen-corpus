import re
import sys
from pathlib import Path

import pdfplumber


# ---------- CONFIG ----------

# Your 64 gua, in order, with the *reading you want*.
# (Order here = order of TSV rows.)
HEXAGRAMS = [
    ("乾", "qián"),
    ("坤", "kūn"),
    ("屯", "zhūn"),
    ("蒙", "méng"),
    ("需", "xū"),
    ("訟", "sòng"),
    ("師", "shī"),
    ("比", "bǐ"),
    ("小畜", "xiǎoxù"),
    ("履", "lǚ"),
    ("泰", "tài"),
    ("否", "pǐ"),
    ("同人", "tóngrén"),
    ("大有", "dàyǒu"),
    ("謙", "qiān"),
    ("豫", "yù"),
    ("隨", "suí"),
    ("蠱", "gǔ"),
    ("臨", "lín"),
    ("觀", "guàn"),
    ("噬嗑", "shìhé"),
    ("賁", "bì"),
    ("剝", "bō"),
    ("復", "fù"),
    ("無妄", "wúwàng"),
    ("大畜", "dàchù"),
    ("頤", "yí"),
    ("大過", "dàguò"),
    ("坎", "kǎn"),
    ("離", "lí"),
    ("咸", "xián"),
    ("恆", "héng"),
    ("遯", "dùn"),
    ("大壯", "dàzhuàng"),
    ("晉", "jìn"),
    ("明夷", "míngyí"),
    ("家人", "jiārén"),
    ("睽", "kuí"),
    ("蹇", "jiǎn"),
    ("解", "jiě"),
    ("損", "sǔn"),
    ("益", "yì"),
    ("夬", "guài"),
    ("姤", "gòu"),
    ("萃", "cuì"),
    ("升", "shēng"),
    ("困", "kùn"),
    ("井", "jǐng"),
    ("革", "gé"),
    ("鼎", "dǐng"),
    ("震", "zhèn"),
    ("艮", "gèn"),
    ("漸", "jiàn"),
    ("歸妹", "guīmèi"),
    ("豐", "fēng"),
    ("旅", "lǚ"),
    ("巽", "xùn"),
    ("兌", "duì"),
    ("渙", "huàn"),
    ("節", "jié"),
    ("中孚", "zhōngfú"),
    ("小過", "xiǎoguò"),
    ("既濟", "jìjì"),
    ("未濟", "wèijì"),
]


# non-ASCII = “probably a Han graph, not pinyin”
PINYIN_LETTERS = "A-Za-züÜāēīōūǖǘǚǜáéíóúǎěǐǒǔàèìòùńňĀĒĪŌŪÁÉÍÓÚǍĚǏǑǓÀÈÌÒÙ"


def normalize_pinyin(p: str) -> str:
    """Normalise spacing etc so matches your list."""
    return p.strip()


# header with GRAPH + PINYIN + MC, e.g. "乾  qián  MC gjen"
HEADER_CHAR_RE = re.compile(
    rf"^([^{PINYIN_LETTERS}\s]+)\s+([{PINYIN_LETTERS}]+)\s+MC\s+(\S+)\s*$"
)

# header with only PINYIN + MC (secondary reading), e.g. "gān  MC kan"
HEADER_PINYIN_ONLY_RE = re.compile(
    rf"^([{PINYIN_LETTERS}]+)\s+MC\s+(\S+)\s*$"
)

# obvious junk we don't want in definitions
JUNK_PATTERNS = (
    "Paul W. Kroll - 978-90-04-48899-1",
    "Heruntergeladen von Brill.com",
    "<PARSED TEXT FOR PAGE",
    "via Universitat Leipzig",
)


def should_skip_line(line: str) -> bool:
    s = line.strip()
    if not s:
        return True
    for pat in JUNK_PATTERNS:
        if pat in s:
            return True
    return False


def build_entry_index(pdf_path: Path):
    """
    Return a dict: (graph, pinyin) -> {"mc": MC, "defs": [lines...]}.
    """
    entries = {}
    current_char = None  # the current Han graph
    current_key = None   # (graph, pinyin)

    with pdfplumber.open(str(pdf_path)) as pdf:
        for page in pdf.pages:
            text = page.extract_text() or ""
            for raw_line in text.splitlines():
                line = raw_line.rstrip()

                # 1) GRAPH + PINYIN + MC
                m = HEADER_CHAR_RE.match(line)
                if m:
                    graph, py, mc = m.groups()
                    py_norm = normalize_pinyin(py)
                    current_char = graph
                    current_key = (graph, py_norm)
                    if current_key not in entries:
                        entries[current_key] = {"mc": mc, "defs": []}
                    else:
                        # if somehow duplicated, reset defs to the first instance
                        # and ignore subsequent duplicates
                        pass
                    continue

                # 2) PINYIN + MC only (alternate reading for same char)
                m2 = HEADER_PINYIN_ONLY_RE.match(line)
                if m2 and current_char:
                    py, mc = m2.groups()
                    py_norm = normalize_pinyin(py)
                    current_key = (current_char, py_norm)
                    if current_key not in entries:
                        entries[current_key] = {"mc": mc, "defs": []}
                    else:
                        # same graph+py already seen; ignore duplicate
                        pass
                    continue

                # 3) Definition lines
                if current_key is not None and not should_skip_line(line):
                    entries[current_key]["defs"].append(line.strip())

    return entries


def main(pdf_file: str, out_tsv: str):
    pdf_path = Path(pdf_file)
    if not pdf_path.exists():
        print(f"PDF not found: {pdf_path}")
        sys.exit(1)

    entries = build_entry_index(pdf_path)

    out_path = Path(out_tsv)
    # UTF-8 with BOM (utf-8-sig) so Excel behaves
    with out_path.open("w", encoding="utf-8-sig", newline="") as f:
        # Header row (optional: comment out if you don’t want it)
        f.write("MC\tDefinition\n")

        for graph, py in HEXAGRAMS:
            mc = "(NOT FOUND)"
            definition = ""

            # Single-character gua: look up by (graph, pinyin)
            if len(graph) == 1:
                key = (graph, py)
                if key in entries:
                    mc = entries[key]["mc"]
                    definition = " ".join(entries[key]["defs"]).strip()
            else:
                # Multi-character gua:
                # Kroll usually gives the *hexagram name* gloss under one
                # of the constituent graphs (like 蠱, 泰, etc.), not as its
                # own headword. We can’t reliably detect that here, so mark
                # them as NOT FOUND and let you handle manually.
                # (You can always tweak this block later if you want to be fancy.)
                mc = "(NOT FOUND)"
                definition = ""

            # Make sure we don’t leak headwords/pinyin into the def — we only
            # ever collected lines *after* the MC header, so this should be clean.
            f.write(f"{mc}\t{definition}\n")

    print(f"Done. Wrote: {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python extract_kroll_yijing_mc_def.py Kroll.pdf yijing_kroll_mc_def.tsv")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
