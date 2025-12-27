import argparse
import re
import time
from typing import Dict, List, Optional

import pandas as pd
import requests
import mwparserfromhell
from tqdm import tqdm

WIKT_API = "https://en.wiktionary.org/w/api.php"

# Conservative Han regex: BMP + Ext-A + Compatibility + supplementary planes.
HAN_RE = re.compile(
    r"["
    r"\u3400-\u4DBF"          # Ext-A
    r"\u4E00-\u9FFF"          # Unified
    r"\uF900-\uFAFF"          # Compatibility
    r"\U00020000-\U0002EBEF"  # Ext-B..Ext-F-ish
    r"]+"
)


def fetch_wikitext_batch(titles: List[str], *, session: requests.Session, sleep_s: float = 0.0) -> Dict[str, Optional[str]]:
    """
    Returns dict: title -> wikitext (str) or None if missing.
    Uses MediaWiki API (stable) rather than scraping action=edit HTML.
    """
    params = {
        "action": "query",
        "prop": "revisions",
        "rvslots": "main",
        "rvprop": "content",
        "format": "json",
        "formatversion": 2,
        "titles": "|".join(titles),
    }
    r = session.get(WIKT_API, params=params, timeout=30)
    r.raise_for_status()
    data = r.json()

    out: Dict[str, Optional[str]] = {}
    for page in data.get("query", {}).get("pages", []):
        title = page.get("title")
        if page.get("missing"):
            out[title] = None
            continue

        revs = page.get("revisions") or []
        if not revs:
            out[title] = None
            continue

        slots = revs[0].get("slots", {})
        main = slots.get("main", {})
        out[title] = main.get("content")

    if sleep_s:
        time.sleep(sleep_s)
    return out


def extract_level2_section(wikitext: str, header: str) -> Optional[str]:
    """
    Extracts a ==Header== section (level 2) until the next level-2 header.
    """
    pat = re.compile(rf"(?m)^\s*==\s*{re.escape(header)}\s*==\s*$")
    m = pat.search(wikitext)
    if not m:
        return None
    start = m.end()
    m2 = re.search(r"(?m)^\s*==[^=].*?==\s*$", wikitext[start:])
    end = start + m2.start() if m2 else len(wikitext)
    return wikitext[start:end]


def _strip_wikilink(s: str) -> str:
    """
    Turns [[A|B]] into A (link target) and [[A]] into A.
    """
    s = s.strip()
    if s.startswith("[[") and s.endswith("]]"):
        inner = s[2:-2]
        return inner.split("|", 1)[0].strip()
    return s


def normalize_form_token(raw: str) -> List[str]:
    """
    Normalizes tokens like:
      *儵 -> 儵
      亖-ancient -> 亖
      肆-financial -> 肆
      [[說]] -> 說
      A/B -> A, B
    Returns list because slash variants are split.
    """
    raw = _strip_wikilink(raw.strip())

    parts = [p.strip() for p in raw.split("/") if p.strip()]
    results: List[str] = []
    for p in parts:
        p = p.lstrip("*").strip()
        p = p.split(":", 1)[0].strip()
        p = p.split("-", 1)[0].strip()
        m = HAN_RE.search(p)
        if m:
            results.append(m.group(0))

    # dedupe preserve order
    seen = set()
    out = []
    for x in results:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def parse_comma_list(value: str) -> List[str]:
    items: List[str] = []
    for raw in value.split(","):
        raw = raw.strip()
        if not raw:
            continue
        items.extend(normalize_form_token(raw))

    seen = set()
    out: List[str] = []
    for x in items:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def extract_wikt_forms_for_title(title: str, wikitext: str) -> List[dict]:
    """
    Extract relations from templates inside the ==Chinese== section.
    Captures:
      - {{zh-see|...}} and useful named params
      - {{zh-forms|s=...|t2=...|alt=...}}
      - {{Han simp|...|a=...}}
    """
    chinese = extract_level2_section(wikitext, "Chinese")
    if not chinese:
        return []

    wikicode = mwparserfromhell.parse(chinese)
    rows: List[dict] = []

    for tpl in wikicode.filter_templates(recursive=True):
        name = str(tpl.name).strip()
        name_lc = name.lower().replace("_", " ")

        # {{zh-see|TARGET}}
        if name_lc == "zh-see":
            if tpl.has(1):
                for t in normalize_form_token(str(tpl.get(1).value)):
                    rows.append({"source_title": title, "relation": "zh-see", "target": t, "template": "zh-see"})

            # supporting named params (optional but useful)
            for param in tpl.params:
                k = str(param.name).strip()
                if k in {"s", "simp", "simplified", "v", "var", "vt", "o", "a", "hv", "sv", "svt", "ss", "ns", "poj"}:
                    for t in parse_comma_list(str(param.value)):
                        rows.append({"source_title": title, "relation": f"zh-see:{k}", "target": t, "template": "zh-see"})

        # {{zh-forms|s=...|t2=...|alt=...}}
        elif name_lc == "zh-forms":
            for param in tpl.params:
                k = str(param.name).strip()
                v = str(param.value).strip()

                if k == "s" or re.fullmatch(r"s\d+", k):
                    for t in parse_comma_list(v):
                        rows.append({"source_title": title, "relation": k, "target": t, "template": "zh-forms"})

                elif k == "t" or re.fullmatch(r"t\d+", k):
                    for t in parse_comma_list(v):
                        rows.append({"source_title": title, "relation": k, "target": t, "template": "zh-forms"})

                elif k.startswith("alt"):
                    for t in parse_comma_list(v):
                        rows.append({"source_title": title, "relation": k, "target": t, "template": "zh-forms"})

        # {{Han simp|TRAD|...}} (plus optional a= alt trad)
        elif name_lc == "han simp":
            if tpl.has(1):
                for t in normalize_form_token(str(tpl.get(1).value)):
                    rows.append({"source_title": title, "relation": "Han simp:1", "target": t, "template": "Han simp"})
            if tpl.has("a"):
                for t in normalize_form_token(str(tpl.get("a").value)):
                    rows.append({"source_title": title, "relation": "Han simp:a", "target": t, "template": "Han simp"})

    return rows


def titles_from_dataframe(df: pd.DataFrame, col: Optional[str], cols: Optional[str]) -> List[str]:
    """
    Build the list of titles to fetch from CSV.
    Auto-detects variant/base if present.
    """
    if cols:
        use_cols = [c.strip() for c in cols.split(",") if c.strip()]
    elif col and col in df.columns:
        use_cols = [col]
    elif {"variant", "base"}.issubset(df.columns):
        use_cols = ["variant", "base"]
    else:
        raise SystemExit(
            f"Could not determine input columns. Use --col <name> or --cols a,b. Found: {df.columns.tolist()}"
        )

    titles: List[str] = []
    for c in use_cols:
        for v in df[c].dropna().tolist():
            s = str(v).strip()
            if not s:
                continue
            # Extract any Han runs (tolerant to stray junk)
            titles.extend(HAN_RE.findall(s))

    # dedupe preserve order
    seen = set()
    uniq: List[str] = []
    for t in titles:
        if t not in seen:
            seen.add(t)
            uniq.append(t)

    print(f"[debug] using columns {use_cols}; {len(uniq)} unique titles; first 10: {uniq[:10]}")
    return uniq


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="Input CSV")
    ap.add_argument("--col", default=None, help="Single column name (optional; auto-detects variant/base)")
    ap.add_argument("--cols", default=None, help="Comma-separated columns to union (e.g. variant,base)")
    ap.add_argument("--output", default="wikt_forms.csv", help="Output CSV")
    ap.add_argument("--batch", type=int, default=50, help="Titles per API request")
    ap.add_argument("--sleep", type=float, default=0.1, help="Sleep seconds per request")
    args = ap.parse_args()

    df = pd.read_csv(args.input, encoding="utf-8-sig")
    titles = titles_from_dataframe(df, args.col, args.cols)

    sess = requests.Session()
    sess.headers.update({"User-Agent": "variant-forms-scraper/1.0 (local research script)"})

    all_rows: List[dict] = []
    for i in tqdm(range(0, len(titles), args.batch), desc="Wiktionary"):
        chunk = titles[i:i + args.batch]
        pages = fetch_wikitext_batch(chunk, session=sess, sleep_s=args.sleep)
        for title, wtxt in pages.items():
            if not wtxt:
                continue
            all_rows.extend(extract_wikt_forms_for_title(title, wtxt))

    out = pd.DataFrame(all_rows)
    out.to_csv(args.output, index=False, encoding="utf-8-sig")
    print(f"Wrote {len(out)} rows to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
