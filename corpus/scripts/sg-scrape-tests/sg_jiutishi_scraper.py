#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright


BASE = "https://nus.edu.sg/nuslibraries/dsprojects/sg-jiutishi/"
POEM_RE = re.compile(r"/poem/(\d+)", re.IGNORECASE)


@dataclass(frozen=True)
class Poem:
    url: str
    title: str
    author: str
    source: str
    text: str
    nation: str = "新加坡"
    times: Optional[str] = None


def safe_filename(name: str, max_len: int = 150) -> str:
    """
    Reusable pattern: whenever filenames come from scraped text,
    sanitize reserved characters and trim length.
    """
    name = (name or "").strip()
    name = re.sub(r'[<>:"/\\|?*\x00-\x1F]+', "_", name)
    name = re.sub(r"\s+", " ", name).strip()
    name = name.rstrip(". ").strip()
    if len(name) > max_len:
        name = name[:max_len].rstrip()
    return name or "untitled"


def clean_text(s: str) -> str:
    s = s.replace("\u00a0", " ")
    s = re.sub(r"[ \t]+\n", "\n", s)
    s = re.sub(r"\n{3,}", "\n\n", s).strip()
    return s


def extract_category_from_title(html: str, fallback: str) -> str:
    """
    The page title is typically: '名勝古跡 | 新加坡舊體詩庫'
    Pattern: read <title>, split on '|'.
    """
    soup = BeautifulSoup(html, "html.parser")
    if soup.title and soup.title.get_text(strip=True):
        return soup.title.get_text(strip=True).split("|")[0].strip()
    return fallback


def map_poems_to_place(rendered_html: str, page_url: str) -> Dict[str, str]:
    """
    Walk DOM in document order:
      - if we hit a place heading (h2/h3), set current_place
      - if we hit a poem link, assign it current_place

    Pattern: "state machine while scanning DOM".
    """
    soup = BeautifulSoup(rendered_html, "html.parser")
    current_place = "unknown_place"
    poem_to_place: Dict[str, str] = {}

    container = soup.find("main") or soup.body or soup

    for el in container.descendants:
        if not getattr(el, "name", None):
            continue

        if el.name in ("h2", "h3"):
            t = el.get_text(" ", strip=True)
            if t and len(t) <= 20 and re.search(r"[\u4e00-\u9fff]", t):
                current_place = t

        if el.name == "a" and el.get("href"):
            href = el["href"]
            if "/poem/" in href:
                poem_url = urljoin(page_url, href).split("#")[0]
                poem_to_place[poem_url] = current_place

    return poem_to_place


def parse_poem_page(html: str, url: str) -> Optional[Poem]:
    """
    Parse a poem page into title/author/text/source.

    Pattern: try robust heuristics rather than single selectors:
      - title: first good heading
      - author: first small heading not source-like
      - source: last line with 《...》 or '錄自'
      - text: paragraph with highest newline density
    """
    soup = BeautifulSoup(html, "html.parser")

    # Title
    title = None
    for tag in soup.find_all(["h1", "h2", "h3", "h4"]):
        t = tag.get_text(" ", strip=True)
        if t and "新加坡舊體詩庫" not in t and t not in ("首頁", "專題", "更多"):
            title = t
            break
    if not title:
        return None

    # Author
    author = "unknown_author"
    for tag in soup.find_all(["h6", "h5"]):
        t = tag.get_text(" ", strip=True)
        if t and "《" not in t and "》" not in t and len(t) <= 20:
            author = t
            break

    # Source
    source = url
    for tag in soup.find_all(["h6", "h5", "p"]):
        t = tag.get_text(" ", strip=True)
        if t and ("錄自" in t or ("《" in t and "》" in t)):
            source = t  # keep last matching line

    # Text
    ps = [p.get_text("\n", strip=True) for p in soup.find_all("p")]
    ps = [p for p in ps if p and re.search(r"[\u4e00-\u9fff]", p)]
    if ps:
        text = max(ps, key=lambda x: (x.count("\n"), len(x)))
    else:
        mainish = soup.find("main") or soup.find("article") or soup.body
        text = mainish.get_text("\n", strip=True) if mainish else ""

    text = clean_text(text)
    if not text or len(text) < 5:
        return None

    return Poem(
        url=url,
        title=title.strip(),
        author=author.strip(),
        source=source.strip(),
        text=text,
    )


def write_poem(out_dir: Path, category: str, place: str, poem: Poem) -> Path:
    """
    Output:
      out_dir/<category>/<place>/<title>.txt

    Pattern: build directories with mkdir(parents=True, exist_ok=True)
    """
    cat_dir = out_dir / safe_filename(category)
    place_dir = cat_dir / safe_filename(place)
    place_dir.mkdir(parents=True, exist_ok=True)

    path = place_dir / (safe_filename(poem.title) + ".txt")
    if path.exists():
        return path

    lines = [
        f"# TITLE: {poem.title}",
        f"# AUTHOR: {poem.author}",
        f"# NATION: {poem.nation}",
        f"# SOURCE: {poem.source} {poem.url}".strip(),
        "",
        poem.text,
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list-url", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--sleep", type=float, default=0.5)
    ap.add_argument("--skip-place", default=None)
    ap.add_argument("--headful", action="store_true", help="Show browser window")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    slug = urlparse(args.list_url).path.rstrip("/").split("/")[-1]

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headful)
        ctx = browser.new_context()
        page = ctx.new_page()

        page.goto(args.list_url, wait_until="networkidle")
        rendered = page.content()

        category = extract_category_from_title(rendered, fallback=slug)
        poem_to_place = map_poems_to_place(rendered, args.list_url)
        poem_urls = sorted(poem_to_place.keys())

        print(f"[info] category={category} poems_found={len(poem_urls)}", flush=True)
        print(f"[info] writing to out_dir={out_dir.resolve()}", flush=True)

        if not poem_urls:
            (out_dir / "_debug_rendered_listpage.html").write_text(rendered, encoding="utf-8")
            print("[warn] 0 poems even in browser render; wrote _debug_rendered_listpage.html", flush=True)
            browser.close()
            return

        wrote = 0
        skipped = 0
        failed = 0

        for i, poem_url in enumerate(poem_urls, start=1):
            place = poem_to_place.get(poem_url, "unknown_place")
            if args.skip_place and place == args.skip_place:
                skipped += 1
                continue

            try:
                print(f"[info] visiting ({i}/{len(poem_urls)}) {poem_url}", flush=True)

                page.goto(poem_url, wait_until="networkidle")
                html = page.content()

                poem = parse_poem_page(html, poem_url)
                if poem is None:
                    failed += 1
                    print(f"[warn] parse_failed {poem_url}", flush=True)
                    continue

                out_path = write_poem(out_dir, category, place, poem)
                if out_path.exists():
                    wrote += 1

                print(f"[ok] ({i}/{len(poem_urls)}) {place} / {poem.title} -> {out_path}", flush=True)

                time.sleep(args.sleep)

            except Exception as e:
                failed += 1
                print(f"[err] ({i}/{len(poem_urls)}) {poem_url} error={repr(e)}", flush=True)

        print(f"[done] wrote={wrote} skipped_by_place={skipped} failed={failed}", flush=True)
        browser.close()


if __name__ == "__main__":
    main()
