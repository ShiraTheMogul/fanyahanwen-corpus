#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
shijing_scraper.py (wikitext-indexed + wikitext-extracted)

Index:
- Built from ROOT WIKITEXT (詩經)

Extraction per poem page:
- Uses that page's WIKITEXT (not HTML)
- Extracts poem from <poem>...</poem> or from ":"-prefixed poem lines
- Extracts 毛詩序 from heading section

Outputs:
  out_dir/詩經/<母類>/<子類>/<篇名>/<篇名>.txt
  out_dir/詩經/<母類>/<子類>/<篇名>/<篇名>_毛詩序.txt (if present)
  out_dir/詩經/<母類>/<子類>/<篇名>/<篇名>_{魯詩說,齊詩說,韓詩說}.txt (if present)
  out_dir/詩經/序/序.txt
  out_dir/shijing_index.json
  out_dir/shijing_index.csv

Run:
  python shijing_scraper.py out_shijing --sleep 0.6
  python shijing_scraper.py out_shijing --test --max-poems 10
"""

import argparse
import csv
import json
import os
import re
import time
from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Optional, Tuple

import requests

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "SikuCorpusScraper/0.5 "
        "(chippy2001@live.co.uk; https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

# === Banner killer (exact variants you supplied) ===
BANNER_LF = (
    "此作品在全世界都属于\n"
    "公有领域\n"
    "，因为作者逝世已经超过年，且作品于年月日之前出版。"
)
BANNER_CRLF = BANNER_LF.replace("\n", "\r\n")
BANNER_LF_VARIANTS = [
    BANNER_LF,
    BANNER_CRLF,
    BANNER_LF.replace("属于", "屬於"),
    BANNER_CRLF.replace("属于", "屬於"),
    BANNER_LF.replace("公有领域", "公有領域").replace("因为", "因為").replace("已经", "已經"),
    BANNER_CRLF.replace("公有领域", "公有領域").replace("因为", "因為").replace("已经", "已經"),
]
BANNER_REGEXES = [
    r"此作品在全世界都[属屬]於\s*[\s\S]{0,120}?公有[领領]域[\s\S]{0,200}?之前出版。?",
    r"\{\{PD-old\}\}",
]

SHENGSHI_TITLES = {"南陔", "白華", "華黍", "由庚", "崇丘", "由儀"}
MOTHERS = ["國風", "小雅", "大雅", "周頌", "魯頌", "商頌"]


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)

def safe_filename(name: str) -> str:
    name = name.strip()
    return re.sub(r'[\\/:*?"<>|]', "_", name)

def api_get(params: Dict[str, Any], timeout: int = 30) -> Dict[str, Any]:
    params = dict(params)
    params["format"] = "json"
    params["formatversion"] = 2
    r = requests.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=timeout)
    r.raise_for_status()
    data = r.json()
    if "error" in data:
        raise RuntimeError(str(data["error"]))
    return data

def fetch_wikitext(title: str) -> str:
    data = api_get({
        "action": "query",
        "prop": "revisions",
        "titles": title,
        "rvprop": "content",
        "rvslots": "main",
    })
    pages = data.get("query", {}).get("pages", [])
    if not pages:
        return ""
    revs = pages[0].get("revisions", [])
    if not revs:
        return ""
    slots = revs[0].get("slots", {})
    main = slots.get("main", {})
    return main.get("content", "") or ""

def normalize_ws_text(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    # Kill stray edit artifacts if they appear as literal text
    lines = []
    for line in text.split("\n"):
        s = line.strip()
        if s in {"编辑", "[编辑]", "編輯", "[編輯]"}:
            continue
        if re.fullmatch(r"\[\s*(編輯|编辑)\s*\]", s):
            continue
        lines.append(line)
    return "\n".join(lines).strip()

def kill_banners(text: str) -> str:
    if not text:
        return text
    t = text
    for v in BANNER_LF_VARIANTS:
        t = t.replace(v, "")
    for rx in BANNER_REGEXES:
        t = re.sub(rx, "", t, flags=re.S)
    return normalize_ws_text(t)

# -------------------------
# Index model + builder from root wikitext
# -------------------------

@dataclass
class ShijingIndexRow:
    mao_no: int
    mother: str
    subgroup: str
    title: str
    page_title: str
    url: str

def build_index_from_root_wikitext(root_title: str = "詩經") -> List[ShijingIndexRow]:
    wt = fetch_wikitext(root_title)
    if not wt:
        raise RuntimeError("Root wikitext is empty for 詩經.")

    current_mother: Optional[str] = None
    current_subgroup: Optional[str] = None
    mao_no = 0
    rows: List[ShijingIndexRow] = []

    mother_heading_rx = re.compile(r"^==\s*(" + "|".join(map(re.escape, MOTHERS)) + r")\s*==\s*$")
    subgroup_rx = re.compile(r"'''\s*([^']+?)\s*'''")
    poem_line_rx = re.compile(r"^\s*#\s*\[\[\s*/([^|\]#]+)\s*(?:\|([^\]]+))?\]\]\s*$")

    for raw_line in wt.splitlines():
        line = raw_line.strip()

        m = mother_heading_rx.match(line)
        if m:
            current_mother = m.group(1)
            current_subgroup = None
            continue

        if current_mother:
            sm = subgroup_rx.search(line)
            if sm:
                current_subgroup = sm.group(1).strip()
                continue

            pm = poem_line_rx.match(line)
            if pm:
                if not current_subgroup:
                    current_subgroup = "（未分組）"

                target = pm.group(1).strip()
                display = (pm.group(2) or "").strip()

                page_title = f"{root_title}/{target}"
                title = display if display and re.search(r"[一-龥]", display) else target
                title = re.sub(r"\s+", "", title)

                mao_no += 1
                url = "https://zh.wikisource.org/wiki/" + requests.utils.quote(page_title)

                rows.append(
                    ShijingIndexRow(
                        mao_no=mao_no,
                        mother=current_mother,
                        subgroup=current_subgroup,
                        title=title,
                        page_title=page_title,
                        url=url,
                    )
                )

    return rows

# -------------------------
# Wikitext extraction helpers
# -------------------------

def strip_wiki_wrappers(text: str) -> str:
    """
    Remove common structural tags/templates that wrap the poem in wikitext.
    Keep the content.
    """
    if not text:
        return text
    t = text

    # Remove include wrappers (but keep their contents)
    t = re.sub(r"</?onlyinclude\s*>", "", t, flags=re.I)
    t = re.sub(r"</?center\s*>", "", t, flags=re.I)
    t = re.sub(r"<div[^>]*>", "", t, flags=re.I)
    t = re.sub(r"</div\s*>", "", t, flags=re.I)

    # Remove templatestyles lines
    t = re.sub(r"<templatestyles[^>]*?/?>", "", t, flags=re.I)

    # Remove file/image links inside sections (they are not poem text)
    t = re.sub(r"\[\[File:[^\]]+\]\]", "", t, flags=re.I)

    return t

def resolve_template_linguisitic_variants(t: str) -> str:
    """
    Handle the two big offenders:
    - {{另|逑|仇}}  -> 逑 (first option)
    - -{zh-hans:后; zh-hant:後}- -> 後 (prefer zh-hant if present)
    """
    if not t:
        return t

    # {{另|A|B}} -> A
    def repl_alt(m: re.Match) -> str:
        inner = m.group(1)
        parts = inner.split("|")
        # parts[0] is '另'
        if len(parts) >= 2:
            return parts[1]
        return ""

    t = re.sub(r"\{\{([^{}]*?)\}\}", lambda m: _template_dispatch(m.group(1)), t)

    # -{...}- language conversion: prefer zh-hant if present, else first value
    t = re.sub(r"-\{([^{}]+?)\}-", _langconv_pick, t)

    return t

def _langconv_pick(m: re.Match) -> str:
    inner = m.group(1)
    # Try to pick zh-hant:XXX
    mh = re.search(r"zh-hant\s*:\s*([^;]+)", inner, flags=re.I)
    if mh:
        return mh.group(1).strip()
    # Else pick zh-hans
    ms = re.search(r"zh-hans\s*:\s*([^;]+)", inner, flags=re.I)
    if ms:
        return ms.group(1).strip()
    # Else: if it's "A;B" style, take first chunk
    return inner.split(";")[0].strip()

def _template_dispatch(inner: str) -> str:
    # Split name|args
    parts = inner.split("|")
    name = parts[0].strip()

    # {{另|A|B}} -> A
    if name == "另":
        return parts[1].strip() if len(parts) >= 2 else ""

    # Some pages use {{Template:國風}} etc at the end: drop these
    if "國風" in name or "Template:" in name:
        return ""

    # Unknown template: drop it (safe for clean poems)
    return ""

def extract_heading_section(wt: str, heading: str) -> str:
    """
    Extract text under a heading like ===毛詩序=== until the next heading of same or higher level.
    We accept both ===毛詩序=== and variations with spaces.
    """
    # Match "=== heading ==="
    rx = re.compile(rf"^===\s*{re.escape(heading)}\s*===\s*$", flags=re.M)
    m = rx.search(wt)
    if not m:
        return ""

    start = m.end()
    rest = wt[start:]

    # Stop at next heading line starting with "==="
    stop = re.search(r"^==+[^=].*==+\s*$", rest, flags=re.M)
    chunk = rest[: stop.start()] if stop else rest
    return chunk.strip()

def find_poem_block(wt: str) -> str:
    """
    Return the first <poem>...</poem> block content found in the supplied wikitext.
    If none, return "".
    """
    m = re.search(r"<poem>([\s\S]*?)</poem>", wt, flags=re.I)
    if not m:
        return ""
    return m.group(1)

def extract_colon_poem_lines(wt: str) -> str:
    """
    Fallback: some content is formatted as lines starting with ":".
    Collect consecutive ":" lines.
    """
    lines = []
    for line in wt.splitlines():
        if line.lstrip().startswith(":"):
            # Strip one leading ":" and whitespace
            s = re.sub(r"^\s*:\s*", "", line)
            if s.strip():
                lines.append(s.rstrip())
        elif lines:
            # stop once we started and then hit a non-":" line
            break
    return "\n".join(lines).strip()

def extract_poem_from_page_wikitext(
    page_wt: str,
    mother: str,
    subgroup: str,
    title: str,
    clean: bool = True,
) -> Tuple[str, str, Dict[str, str]]:
    """
    Extract:
      poem_text
      mao_text (毛詩序)
      extras: 魯詩說/齊詩說/韓詩說 (optional)

    Strategy:
    - Prefer poem section under ===<title>===, else under ===詩文===, else any <poem> block.
    - In clean mode: stop before 注釋/註解 sections by not using them at all (we just ignore those headings).
    """
    wt = page_wt

    # Grab school commentaries if present (store separately)
    extras: Dict[str, str] = {}
    for sec in ["魯詩說", "齊詩說", "韓詩說"]:
        chunk = extract_heading_section(wt, sec)
        if chunk:
            extras[sec] = clean_wikitext_chunk(chunk, for_poem=False)

    # Mao preface
    mao_chunk = extract_heading_section(wt, "毛詩序")
    mao_text = clean_wikitext_chunk(mao_chunk, for_poem=False) if mao_chunk else ""

    # Poem content chunk: try ===title=== first
    poem_chunk = extract_heading_section(wt, title)

    # If not found, try ===詩文===
    if not poem_chunk:
        poem_chunk = extract_heading_section(wt, "詩文")

    # If still not found, use whole page (as a last resort) to find <poem>
    search_space = poem_chunk if poem_chunk else wt

    poem_body = find_poem_block(search_space)
    if not poem_body:
        # Fallback to ":" lines
        poem_body = extract_colon_poem_lines(search_space)

    poem_text = clean_wikitext_chunk(poem_body, for_poem=True)

    # Shengshi placeholder
    if title in SHENGSHI_TITLES and not poem_text:
        poem_text = "(笙詩)"

    return poem_text, mao_text, extras

def clean_wikitext_chunk(chunk: str, for_poem: bool) -> str:
    """
    Convert a wikitext chunk to clean plain text.

    For poems:
    - remove wiki wrappers
    - resolve {{另|...}} and -{zh-hant:...}- conversions
    - keep line breaks
    """
    if not chunk:
        return ""

    t = strip_wiki_wrappers(chunk)

    # Remove references and templates used for notes
    t = re.sub(r"<references\s*/\s*>", "", t, flags=re.I)
    t = re.sub(r"<ref[^>]*>[\s\S]*?</ref>", "", t, flags=re.I)

    # Drop headings inside the chunk if any
    t = re.sub(r"^==+.*?==+\s*$", "", t, flags=re.M)

    # Resolve key templates / conversions
    t = resolve_template_linguisitic_variants(t)

    # Convert wiki links:
    # [[X|Y]] -> Y ; [[X]] -> X
    t = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", t)
    t = re.sub(r"\[\[([^\]]+)\]\]", r"\1", t)

    # Drop leftover templates like {{Template:國風}} etc
    t = re.sub(r"\{\{[^{}]+\}\}", "", t)

    # If poem lines have leading ":" (common in <poem>), remove them
    if for_poem:
        t = re.sub(r"^\s*:\s*", "", t, flags=re.M)

    t = kill_banners(t)

    # In clean poem mode, avoid any trailing annotation like "三章..." lines if they appear as prose
    # (We keep them if you want later, but default is to keep only verse-like lines.)
    if for_poem:
        # If there are blank lines, keep them; otherwise keep as-is
        pass

    return normalize_ws_text(t)


# -------------------------
# Output writers
# -------------------------

def write_index(out_dir: str, rows: List[ShijingIndexRow]) -> None:
    ensure_dir(out_dir)
    json_path = os.path.join(out_dir, "shijing_index.json")
    csv_path = os.path.join(out_dir, "shijing_index.csv")

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump([asdict(r) for r in rows], f, ensure_ascii=False, indent=2)

    fieldnames = list(asdict(rows[0]).keys()) if rows else ["mao_no", "mother", "subgroup", "title", "page_title", "url"]
    with open(csv_path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(asdict(r))

def write_poem_files(
    out_dir: str,
    row: ShijingIndexRow,
    poem_text: str,
    mao_text: str,
    extras: Dict[str, str],
) -> None:
    poem_dir = os.path.join(
        out_dir,
        "詩經",
        safe_filename(row.mother),
        safe_filename(row.subgroup),
        safe_filename(row.title),
    )
    ensure_dir(poem_dir)

    header = (
        f"# WORK_TITLE: 詩經\n"
        f"# MAO_NO: {row.mao_no:03d}\n"
        f"# CATEGORIES: {row.mother}，{row.subgroup}\n"
        f"# DISPLAY_TITLE: {row.title}\n"
        f"# PAGE_TITLE: {row.page_title}\n"
        f"# URL: {row.url}\n\n"
    )

    with open(os.path.join(poem_dir, f"{safe_filename(row.title)}.txt"), "w", encoding="utf-8") as f:
        f.write(header + (poem_text or "").strip() + "\n")

    if mao_text.strip():
        with open(os.path.join(poem_dir, f"{safe_filename(row.title)}_毛詩序.txt"), "w", encoding="utf-8") as f:
            f.write(header + mao_text.strip() + "\n")

    # Write the three tradition commentaries if present
    for k, v in extras.items():
        if k in {"魯詩說", "齊詩說", "韓詩說"} and v.strip():
            with open(os.path.join(poem_dir, f"{safe_filename(row.title)}_{safe_filename(k)}.txt"), "w", encoding="utf-8") as f:
                f.write(header + v.strip() + "\n")

def scrape_front_matter(out_dir: str, page_title: str = "詩經/序") -> None:
    wt = fetch_wikitext(page_title)
    if not wt:
        return

    # For 序, just clean the whole page lightly (no need to hunt <poem>)
    text = clean_wikitext_chunk(wt, for_poem=False)

    d = os.path.join(out_dir, "詩經", "序")
    ensure_dir(d)
    with open(os.path.join(d, "序.txt"), "w", encoding="utf-8") as f:
        f.write(f"# WORK_TITLE: 詩經\n# DISPLAY_TITLE: 序\n# PAGE_TITLE: {page_title}\n\n{text}\n")


# -------------------------
# Main
# -------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="Dedicated 詩經 scraper (index+extract from wikitext)")
    ap.add_argument("out_dir", help="Output directory")
    ap.add_argument("--sleep", type=float, default=0.6, help="Sleep between requests (seconds)")
    ap.add_argument("--test", action="store_true", help="Test mode")
    ap.add_argument("--max-poems", type=int, default=12, help="In test mode, max poems to scrape")
    args = ap.parse_args()

    ensure_dir(args.out_dir)

    # Foreword page
    scrape_front_matter(args.out_dir, "詩經/序")

    # Index
    rows = build_index_from_root_wikitext("詩經")
    write_index(args.out_dir, rows)

    if not rows:
        raise RuntimeError("Index is empty. Root wikitext parsing found 0 poems.")

    if args.test:
        rows = rows[: max(1, args.max_poems)]

    # Cache wikitext by page_title
    wt_cache: Dict[str, str] = {}

    for i, row in enumerate(rows, start=1):
        print(f"[{i}/{len(rows)}] {row.mao_no:03d} {row.mother}/{row.subgroup}/{row.title}")

        if row.page_title not in wt_cache:
            wt_cache[row.page_title] = fetch_wikitext(row.page_title)
            time.sleep(args.sleep)

        page_wt = wt_cache[row.page_title]
        if not page_wt:
            print("  !! empty wikitext")
            continue

        poem_text, mao_text, extras = extract_poem_from_page_wikitext(
            page_wt=page_wt,
            mother=row.mother,
            subgroup=row.subgroup,
            title=row.title,
            clean=True,
        )

        write_poem_files(args.out_dir, row, poem_text, mao_text, extras)

    print("Done.")


if __name__ == "__main__":
    main()
