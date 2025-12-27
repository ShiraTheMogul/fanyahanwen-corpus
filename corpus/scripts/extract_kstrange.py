import re
from PyPDF2 import PdfReader
import pandas as pd

# Same CJK ranges you listed
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
    if not ch:
        return False
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in CJK_RANGES)

def load_kstrange_map(pdf_path: str) -> dict[str, str]:
    """
    Parse TN 43-4 PDF and build a map Ideograph -> Reference.

    Lines look like:
        I B U+248E5𤣥玄
    , i.e. category, block, codepoint, then two glued CJK chars.
    tail[0] = ideograph, tail[-1] = reference.
    """
    reader = PdfReader(pdf_path)
    # <Cat> <Block> U+<hex><tail>
    line_re = re.compile(r'^([A-Z])\s+[A-Z]\s+U\+([0-9A-F]{4,6})(\S+)$')

    mapping: dict[str, str] = {}

    for page in reader.pages:
        text = page.extract_text() or ""
        for raw_line in text.splitlines():
            line = raw_line.strip()
            m = line_re.match(line)
            if not m:
                continue

            tail = m.group(3)  # e.g. '𤣥玄', '𡉆吉'
            if len(tail) < 2:
                continue

            src = tail[0]   # ideograph (weird form)
            tgt = tail[-1]  # reference (normal form)

            if is_cjk(src) and is_cjk(tgt):
                mapping[src] = tgt

    return mapping

if __name__ == "__main__":
    pdf_path = "tn43-4.pdf"
    out_csv = "tn43_kstrange_map.csv"

    kstrange_map = load_kstrange_map(pdf_path)
    print("Pairs found:", len(kstrange_map))

    # A few sample prints so you can see something in console
    for i, (src, tgt) in enumerate(sorted(kstrange_map.items())):
        print(f"{src}\t{tgt}")
        if i >= 20:  # don’t flood console; adjust or remove as you like
            break

    # Save full dataset to CSV
    df = pd.DataFrame(
        [{"ideograph": src, "reference": tgt} for src, tgt in kstrange_map.items()]
    )
    df.to_csv(out_csv, index=False, encoding="utf-8-sig")
    print("Full mapping written to:", out_csv)
