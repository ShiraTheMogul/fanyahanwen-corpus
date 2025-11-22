#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
special_works_scraper.py

Produces the following output:
  base_output/
    raw/<work_id>/... <- the raw page output, including wiki formatting and legal notices
    clean/<work_id>/... <- just the content
    special_index.csv
    special_index.json
"""

import os
import re
import csv
import json
import time
import sys
from typing import Dict, List, Tuple, Optional, Set

import requests
from bs4 import BeautifulSoup


API_ENDPOINT = "https://zh.wikisource.org/w/api.php"

HEADERS = {
    "User-Agent": (
        "SikuCorpusScraper/0.1 "
        "(chippy2001@live.co.uk; "
        "https://github.com/ShiraTheMogul; "
        "https://en.wikisource.org/wiki/User:Shira_the_Mogul)"
    )
}

# Stop phrases to chop off public-domain boilerplate etc.
PD_STOP_PATTERNS = [
    "本作品在全世界都属于",
    "本作品在全世界都屬於",
    "本作品在美国属于",
    "本作品在美國屬於",
    "Public domain Public domain false false",
    "Public domain",
]


# -------------------------------------------------------------------
# Basic utilities
# -------------------------------------------------------------------

def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def api_get(params: Dict) -> Dict:
    params = dict(params)
    params["format"] = "json"
    resp = requests.get(API_ENDPOINT, params=params, headers=HEADERS, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    if "error" in data:
        raise RuntimeError(f"API error: {data['error']}")
    return data


def normalise_title_for_path(title: str) -> str:
    """
    Make a safe-ish folder/file stub from a page title.
    We keep Chinese chars etc, but strip weird whitespace.
    """
    title = title.strip()
    # Replace slashes with underscores
    title = title.replace("/", "_")
    # Collapse whitespace
    title = re.sub(r"\s+", " ", title)
    return title


def strip_public_domain_footer(text: str) -> str:
    """
    Cut off public-domain boilerplate and anything after it if found.
    """
    for pat in PD_STOP_PATTERNS:
        idx = text.find(pat)
        if idx != -1:
            return text[:idx].rstrip()
    return text


def clean_vertical_weirdness(text: str) -> str:
    """
    Cheap fix for the '〈\\n㑹昌二年\\n〉' vertical layout weirdness:
    merge standalone angle-bracket blocks into a single inline chunk.
    """
    lines = text.splitlines()
    cleaned_lines: List[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == "〈" and (i + 2) < len(lines) and lines[i + 2].strip() == "〉":
            middle = lines[i + 1].strip()
            cleaned_lines.append(f"〈{middle}〉")
            i += 3
            continue
        cleaned_lines.append(line)
        i += 1
    text = "\n".join(cleaned_lines)
    return text


def clean_html_to_text(html: str) -> str:
    """
    Convert MediaWiki HTML to plain text, then clean up a bit.
    """
    soup = BeautifulSoup(html, "html.parser")

    # Drop some obvious non-textual stuff
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()

    text = soup.get_text("\n")

    # Normalise newlines and spaces
    text = re.sub(r"\r\n?", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)

    # Remove excessive blank lines
    text = re.sub(r"\n{3,}", "\n\n", text)

    text = text.strip()
    text = clean_vertical_weirdness(text)
    text = strip_public_domain_footer(text)
    return text


def fetch_html_for_page(title: str) -> str:
    """
    Fetch HTML for a page, preferring parse->text.
    """
    # First try parse&prop=text (HTML)
    try:
        data = api_get({
            "action": "parse",
            "page": title,
            "prop": "text",
            "disablelimitreport": 1,
        })
        html = data["parse"]["text"]["*"]
        if html:
            return html
    except Exception as e:
        print(f"    !! API error (parse): {e}")

    # As a fallback, try prop=extracts for plain text (less styled)
    try:
        data = api_get({
            "action": "query",
            "prop": "extracts",
            "explaintext": 0,
            "titles": title,
        })
        pages = data["query"]["pages"]
        page = next(iter(pages.values()))
        if "extract" in page:
            return page["extract"]
    except Exception as e:
        print(f"    !! API error (extracts fallback): {e}")

    print(f"    !! Empty HTML returned for page (after fallbacks): {title}")
    return ""


def extract_links_from_page(title: str) -> List[str]:
    """
    Return a list of *page titles* that this page links to.
    Uses 'parse&prop=links' which returns MediaWiki titles.
    """
    links: List[str] = []
    try:
        data = api_get({
            "action": "parse",
            "page": title,
            "prop": "links",
        })
        for item in data.get("parse", {}).get("links", []):
            # For zh.wikisource, link objects usually have "*" as the title
            t = item.get("*")
            if t:
                links.append(t)
    except Exception as e:
        print(f"    !! API error while extracting links from {title}: {e}")
    return links


# -------------------------------------------------------------------
# Discovery per work
# -------------------------------------------------------------------

def discover_juan_from_toc(root_title: str) -> List[str]:
    """
    For works like 皇明從信錄: main page is a TOC listing '卷一', '卷二', ...
    We read links from the root page and filter by titles starting with 'root_title/'.
    """
    print(f"Discovering juan pages for {root_title} via TOC links...")
    links = extract_links_from_page(root_title)
    juan_pages: List[str] = []
    prefix = root_title + "/"

    for t in links:
        if t.startswith(prefix):
            # Heuristic: if the last part contains '卷', treat as a juan
            last = t.split("/", 1)[-1]
            if "卷" in last or re.search(r"\d+", last):
                juan_pages.append(t)
            if "第" in last or re.search(r"\d+", last):
                juan_pages.append(t)

    juan_pages = sorted(set(juan_pages))
    print(f"  -> Found {len(juan_pages)} juan pages for {root_title}")
    return juan_pages


def discover_yongle_volumes() -> List[str]:
    """
    Discover 永樂大典 volumes via allpages with prefix '永樂大典/卷'.
    This picks up pages like '永樂大典/卷00480'.
    """
    root_prefix = "永樂大典/卷"
    print(f"Discovering 永樂大典 volumes via allpages with prefix '{root_prefix}'...")
    titles: List[str] = []
    gapcontinue: Optional[str] = None

    while True:
        params = {
            "action": "query",
            "list": "allpages",
            "apnamespace": 0,
            "apprefix": root_prefix,
            "aplimit": "max",
        }
        if gapcontinue:
            params["apcontinue"] = gapcontinue

        data = api_get(params)
        pages = data.get("query", {}).get("allpages", [])
        for p in pages:
            titles.append(p["title"])

        gapcontinue = data.get("continue", {}).get("apcontinue")
        if not gapcontinue:
            break

    titles = sorted(set(titles))
    print(f"  -> Found {len(titles)} 永樂大典 volume pages")
    return titles


def discover_gujin_bfs(root_title: str, max_pages: Optional[int] = None) -> List[str]:
    """
    OLD MODE (kept for reference): BFS starting at root_title, walking all links
    whose title starts with root_title. This hits a *lot* of pages and is slow
    for 古今圖書集成, so we now prefer discover_gujin_hierarchy() below.
    """
    print(f"Starting BFS discovery for {root_title} (this may be large)...")
    visited: Set[str] = set()
    queue: List[str] = [root_title]
    result: List[str] = []

    while queue:
        title = queue.pop(0)
        if title in visited:
            continue
        visited.add(title)

        if not title.startswith(root_title):
            continue

        result.append(title)
        if max_pages is not None and len(result) >= max_pages:
            break

        links = extract_links_from_page(title)
        for t in links:
            if t.startswith(root_title) and t not in visited:
                queue.append(t)

    print(f"  -> BFS discovered {len(result)} pages under {root_title}")
    return sorted(result)


def discover_gujin_hierarchy(root_title: str,
                             max_pages: Optional[int] = None) -> List[str]:
    """
    New, structured discovery for 欽定古今圖書集成.

    Hierarchy (as on Wikisource):
        root (欽定古今圖書集成)
          -> 彙編 pages (e.g. 欽定古今圖書集成/曆象彙編)
              -> 典 pages (e.g. 欽定古今圖書集成/曆象彙編/乾象典)
                  -> 卷 pages (e.g. .../第001卷)

    We only return the leaf 卷 pages as scrape targets.
    """
    print(f"Discovering 古今圖書集成 pages via hierarchy (彙編 → 典 → 卷)...")

    all_target_pages: List[str] = []

    # 1) discover 彙編 pages from the root page
    links_root = extract_links_from_page(root_title)
    hui_pages = sorted({
        t for t in links_root
        if t.startswith(root_title + "/") and t.endswith("彙編")
    })

    print(f"  -> Found {len(hui_pages)} 彙編 pages from root.")

    # 2) for each 彙編, discover 典 pages
    dian_pages: List[str] = []
    for hui in hui_pages:
        links_hui = extract_links_from_page(hui)
        for t in links_hui:
            # Example: 欽定古今圖書集成/曆象彙編/乾象典
            if t.startswith(hui + "/") and t.endswith("典"):
                dian_pages.append(t)

    dian_pages = sorted(set(dian_pages))
    print(f"  -> Found {len(dian_pages)} 典 pages under all 彙編.")

    # 3) for each 典, discover 卷 pages of the form .../第NN卷
    for dian_idx, dian in enumerate(dian_pages, start=1):
        print(f"    [典 {dian_idx}/{len(dian_pages)}] {dian} ...")
        links_dian = extract_links_from_page(dian)

        vol_pages = sorted({
            t for t in links_dian
            if t.startswith(dian + "/第") and "卷" in t
        })

        print(f"      -> {len(vol_pages)} 卷 pages discovered.")

        all_target_pages.extend(vol_pages)

        if max_pages is not None and len(all_target_pages) >= max_pages:
            all_target_pages = all_target_pages[:max_pages]
            print(f"      !! Reached max_pages={max_pages}, stopping discovery.")
            break

    all_target_pages = sorted(set(all_target_pages))
    print(f"  => Total 古今圖書集成 卷 pages discovered: {len(all_target_pages)}")
    return all_target_pages


# -------------------------------------------------------------------
# Scraping + index
# -------------------------------------------------------------------

def save_text_pair(base_output: str,
                   work_id: str,
                   page_title: str,
                   juan_index: int) -> Tuple[str, str, int, int]:
    """
    Fetch HTML, convert to RAW/CLEAN text, save to disk.
    Returns (raw_relpath, clean_relpath, chars_raw, chars_clean)
    """
    html = fetch_html_for_page(page_title)
    raw_text = clean_html_to_text(html) if html else ""
    clean_text = raw_text  # you can add further cleaning here if you like

    # Folder per work_id
    raw_dir = os.path.join(base_output, "raw", work_id)
    clean_dir = os.path.join(base_output, "clean", work_id)
    ensure_dir(raw_dir)
    ensure_dir(clean_dir)

    # File naming: <work_id>__juan_XXXX.txt for juan-like pages
    fname_stub = f"{work_id}__juan_{juan_index:04d}.txt"
    raw_path = os.path.join(raw_dir, fname_stub)
    clean_path = os.path.join(clean_dir, fname_stub)

    with open(raw_path, "w", encoding="utf-8") as f:
        f.write(raw_text)
    with open(clean_path, "w", encoding="utf-8") as f:
        f.write(clean_text)

    rel_raw = os.path.relpath(raw_path, base_output)
    rel_clean = os.path.relpath(clean_path, base_output)
    return rel_raw, rel_clean, len(raw_text), len(clean_text)


def run_special_scrape(base_output: str,
                       sleep_sec: float = 0.5,
                       test_mode: bool = False,
                       max_pages_per_work: Optional[int] = None) -> None:
    """
    Orchestrates scraping of the three target works.
    """

    # You can expand this list later.
    WORKS = [
        {
            "name": "大越史略",
            "root_title": "大越史略",       # https://zh.wikisource.org/wiki/九雲夢
            "mode": "toc_juan",
            "work_id": "大越史略",
        },
        {
            "name": "皇黎一統志",
            "root_title": "皇黎一統志",   # https://zh.wikisource.org/wiki/芝峰類說
            "mode": "toc_juan",
            "work_id": "皇黎一統志",
        },
        {
            "name": "越史略",
            "root_title": "越史略",     # https://zh.wikisource.org/wiki/高麗史
            "mode": "toc_juan",
            "work_id": "越史略",
        },
        {
            "name": "鄭氏世家",
            "root_title": "鄭氏世家",   # https://zh.wikisource.org/wiki/三國史記
            "mode": "toc_juan",
            "work_id": "鄭氏世家",
        },
    ]

    ensure_dir(base_output)
    ensure_dir(os.path.join(base_output, "raw"))
    ensure_dir(os.path.join(base_output, "clean"))

    index_rows: List[Dict] = []

    print("Starting special works scrape.")
    print(f"  Base output: {base_output}")
    print(f"  RAW dir:      {os.path.join(base_output, 'raw')}")
    print(f"  CLEAN dir:    {os.path.join(base_output, 'clean')}")
    print(f"  sleep={sleep_sec:.2f}s | {'TEST' if test_mode else 'FULL'} mode")
    print()

    for wi, work in enumerate(WORKS, start=1):
        root_title = work["root_title"]
        work_id = work["work_id"]
        mode = work["mode"]

        display_name = work.get("name", root_title)

        print(f"### [{wi}/{len(WORKS)}] {display_name} ###")
        print(f"== Work: {root_title} (mode: {mode}) ==")
        
        # Discover pages for this work
        if mode == "toc_juan":
            pages = discover_juan_from_toc(root_title)
        elif mode == "yongle_allpages":
            pages = discover_yongle_volumes()
        elif mode == "gujin_hierarchy":
            pages = discover_gujin_hierarchy(
                root_title,
                max_pages=(50 if test_mode and max_pages_per_work is None else max_pages_per_work)
            )
        elif mode == "gujin_bfs":
            # legacy option if you ever want to use BFS explicitly
            pages = discover_gujin_bfs(
                root_title,
                max_pages=(50 if test_mode and max_pages_per_work is None else max_pages_per_work)
            )
        else:
            print(f"  !! Unknown mode {mode}, skipping.")
            continue

        if test_mode and max_pages_per_work is not None:
            pages = pages[:max_pages_per_work]

        print(f"  -> {len(pages)} pages to scrape for {root_title}")
        print()

        for j, page_title in enumerate(pages, start=1):
            # SPECIAL: parse juan_index from 永樂大典/卷NNN
            if mode == "yongle_allpages":
                m = re.search(r"/卷0*([0-9]+)$", page_title)
                if m:
                    juan_index = int(m.group(1))
                else:
                    juan_index = j  # fallback if pattern fails
            else:
                juan_index = j

            print(f"  [{j}/{len(pages)}] {page_title} (juan {juan_index}) ...")

            try:
                raw_rel, clean_rel, cr, cc = save_text_pair(
                    base_output=base_output,
                    work_id=work_id,
                    page_title=page_title,
                    juan_index=juan_index,
                )
            except Exception as e:
                print(f"    !! Error while scraping {page_title}: {e}")
                continue

            print(f"    -> Saved RAW to   {raw_rel}")
            print(f"    -> Saved CLEAN to {clean_rel}")

            index_rows.append({
                "root_title": root_title,
                "work_id": work_id,
                "mode": mode,
                "page_title": page_title,
                "juan_index": juan_index,  # use parsed value here
                "raw_path": raw_rel,
                "clean_path": clean_rel,
                "chars_raw": cr,
                "chars_clean": cc,
            })

            time.sleep(sleep_sec)

        print()

    # Write indices
    csv_path = os.path.join(base_output, "special_index.csv")
    json_path = os.path.join(base_output, "special_index.json")

    fieldnames = [
        "root_title",
        "work_id",
        "mode",
        "page_title",
        "juan_index",
        "raw_path",
        "clean_path",
        "chars_raw",
        "chars_clean",
    ]

    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in index_rows:
            writer.writerow(row)

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(index_rows, f, ensure_ascii=False, indent=2)

    print(f"Wrote CSV index:  {csv_path}")
    print(f"Wrote JSON index: {json_path}")
    print("Done.")


# -------------------------------------------------------------------
# CLI
# -------------------------------------------------------------------

def main(argv: List[str]) -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="Scrape 皇明從信錄, 永樂大典, 欽定古今圖書集成 from zh.wikisource"
    )
    parser.add_argument(
        "output_dir",
        nargs="?",
        default="scrape_output",
        help="Base output directory (default: scrape_output)",
    )
    parser.add_argument(
        "--sleep",
        type=float,
        default=0.5,
        help="Sleep between requests in seconds (default: 0.5)",
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Test mode: smaller 古今圖書集成 scrape (via max-pages-per-work).",
    )
    parser.add_argument(
        "--max-pages-per-work",
        type=int,
        default=None,
        help="Optional hard cap on pages per work (after discovery).",
    )

    args = parser.parse_args(argv[1:])

    run_special_scrape(
        base_output=args.output_dir,
        sleep_sec=args.sleep,
        test_mode=args.test,
        max_pages_per_work=args.max_pages_per_work,
    )


if __name__ == "__main__":
    main(sys.argv)
