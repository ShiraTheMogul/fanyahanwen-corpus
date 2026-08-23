#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import quote

import requests
from bs4 import BeautifulSoup, NavigableString, Tag

API_ENDPOINT = "https://zh.wikisource.org/w/api.php"
ROOT_TITLE = "史記"
WORK_RELATIVE = Path("中國漢文") / "clean" / "漢朝" / "西漢" / "史記"
EXPECTED_JUAN = 130
MIN_CLEAN_CHARACTERS = 80

HEADERS = {
    "User-Agent": (
        "FanyaHanwenCorpusShijiRescraper/1.0 "
        "(https://github.com/ShiraTheMogul/fanyahanwen-corpus)"
    )
}

JUAN_TITLES = [
    "五帝本紀第一", "夏本紀第二", "殷本紀第三", "周本紀第四", "秦本紀第五", "秦始皇本紀第六",
    "項羽本紀第七", "高祖本紀第八", "呂后本紀第九", "孝文本紀第十", "孝景本紀第十一", "孝武本紀第十二",
    "三代世表第一", "十二諸侯年表第二", "六國年表第三", "秦楚之際月表第四", "漢興以來諸侯王年表第五",
    "高祖功臣侯者年表第六", "惠景閒侯者年表第七", "建元以來侯者年表第八", "建元以來王子侯者年表第九",
    "漢興以來將相名臣年表第十", "禮書第一", "樂書第二", "律書第三", "曆書第四", "天官書第五", "封禪書第六",
    "河渠書第七", "平準書第八", "吳太伯世家第一", "齊太公世家第二", "魯周公世家第三", "燕召公世家第四",
    "管蔡世家第五", "陳杞世家第六", "衛康叔世家第七", "宋微子世家第八", "晉世家第九", "楚世家第十",
    "越王勾踐世家第十一", "鄭世家第十二", "趙世家第十三", "魏世家第十四", "韓世家第十五", "田敬仲完世家第十六",
    "孔子世家第十七", "陳涉世家第十八", "外戚世家第十九", "楚元王世家第二十", "荊燕世家第二十一",
    "齊悼惠王世家第二十二", "蕭相國世家第二十三", "曹相國世家第二十四", "留侯世家第二十五",
    "陳丞相世家第二十六", "絳侯周勃世家第二十七", "梁孝王世家第二十八", "五宗世家第二十九", "三王世家第三十",
    "伯夷列傳第一", "管晏列傳第二", "老子韓非列傳第三", "司馬穰苴列傳第四", "孫子吳起列傳第五", "伍子胥列傳第六",
    "仲尼弟子列傳第七", "商君列傳第八", "蘇秦列傳第九", "張儀列傳第十", "樗里子甘茂列傳第十一", "穰侯列傳第十二",
    "白起王翦列傳第十三", "孟子荀卿列傳第十四", "孟嘗君列傳第十五", "平原君虞卿列傳第十六", "魏公子列傳第十七",
    "春申君列傳第十八", "范睢蔡澤列傳第十九", "樂毅列傳第二十", "廉頗藺相如列傳第二十一", "田單列傳第二十二",
    "魯仲連鄒陽列傳第二十三", "屈原賈生列傳第二十四", "呂不韋列傳第二十五", "刺客列傳第二十六", "李斯列傳第二十七",
    "蒙恬列傳第二十八", "張耳陳餘列傳第二十九", "魏豹彭越列傳第三十", "黥布列傳第三十一", "淮陰侯列傳第三十二",
    "韓信盧綰列傳第三十三", "田儋列傳第三十四", "樊酈滕灌列傳第三十五", "張丞相列傳第三十六", "酈生陸賈列傳第三十七",
    "傅靳蒯成列傳第三十八", "劉敬叔孫通列傳第三十九", "季布欒布列傳第四十", "袁盎鼂錯列傳第四十一",
    "張釋之馮唐列傳第四十二", "萬石張叔列傳第四十三", "田叔列傳第四十四", "扁鵲倉公列傳第四十五", "吳王濞列傳第四十六",
    "魏其武安列傳第四十七", "韓長孺列傳第四十八", "李將軍列傳第四十九", "匈奴列傳第五十", "衛將軍驃騎列傳第五十一",
    "平津侯主父列傳第五十二", "南越列傳第五十三", "東越列傳第五十四", "朝鮮列傳第五十五", "西南夷列傳第五十六",
    "司馬相如列傳第五十七", "淮南衡山列傳第五十八", "循吏列傳第五十九", "汲鄭列傳第六十", "儒林列傳第六十一",
    "酷吏列傳第六十二", "大宛列傳第六十三", "游俠列傳第六十四", "佞幸列傳第六十五", "滑稽列傳第六十六",
    "日者列傳第六十七", "龜策列傳第六十八", "貨殖列傳第六十九", "太史公自序第七十",
]

assert len(JUAN_TITLES) == EXPECTED_JUAN

# Legacy four-document scrape: preserve these IDs by the pages they really
# represent, not by their misleading old local filenames.
KNOWN_LEGACY_PAGE_IDS = {
    18: 172255,
    38: 172253,
    44: 172256,
    92: 172254,
}

DROP_SELECTORS = [
    "script", "style", "noscript", "figure", ".thumb", ".mw-editsection", ".reference", ".references",
    ".mw-navigation", ".navbox", ".toc", ".catlinks", ".printfooter", ".licenseContainer",
    ".ws-noexport", ".noprint", ".metadata", ".sisterproject", ".sisternav",
    ".ws-header", ".wst-header", ".wikisource-header", ".headertemplate", ".header-template",
]

BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "body", "center", "dd", "details", "div", "dl", "dt",
    "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li",
    "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
}


@dataclass(frozen=True)
class RevisionInfo:
    revid: int
    timestamp: str
    user: str
    contributors: tuple[str, ...]
    page_title: str = ""


@dataclass(frozen=True)
class ScrapedPage:
    juan: int
    title: str
    page_title: str
    text: str
    revision: RevisionInfo
    categories: tuple[str, ...]


def api_get(session: requests.Session, params: dict[str, Any], *, retries: int = 4) -> dict[str, Any]:
    payload = dict(params)
    payload["format"] = "json"
    payload["formatversion"] = "2"
    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            response = session.get(API_ENDPOINT, params=payload, timeout=60)
            response.raise_for_status()
            data = response.json()
            if "error" in data:
                raise RuntimeError(f"MediaWiki API error: {data['error']}")
            return data
        except Exception as exc:  # requests + JSON/API failures
            last_error = exc
            if attempt < retries:
                time.sleep(float(attempt))
    raise RuntimeError(f"MediaWiki request failed after {retries} attempts: {last_error}")


def canonical_page_title(juan: int) -> str:
    return f"{ROOT_TITLE}/卷{juan:03d}"


def wiki_url(page_title: str, oldid: int | None = None) -> str:
    encoded = quote(page_title.replace(" ", "_"), safe="/_")
    if oldid:
        return f"https://zh.wikisource.org/w/index.php?title={encoded}&oldid={oldid}"
    return f"https://zh.wikisource.org/wiki/{encoded}"


def fetch_revision_info(session: requests.Session, page_title: str) -> RevisionInfo:
    latest = api_get(session, {
        "action": "query", "prop": "revisions", "titles": page_title, "redirects": 1,
        "rvprop": "ids|timestamp|user", "rvlimit": 1,
    })
    pages = latest.get("query", {}).get("pages", [])
    if not pages or pages[0].get("missing"):
        raise RuntimeError(f"Missing Wikisource page: {page_title}")
    resolved_page_title = str(pages[0].get("title") or page_title).strip() or page_title
    revision = (pages[0].get("revisions") or [None])[0]
    if not revision:
        raise RuntimeError(f"No revision returned for {resolved_page_title}")

    contributors: list[str] = []
    cont: dict[str, Any] = {}
    while True:
        params: dict[str, Any] = {
            "action": "query", "prop": "contributors", "titles": resolved_page_title,
            "pclimit": "max",
        }
        params.update(cont)
        data = api_get(session, params)
        result_pages = data.get("query", {}).get("pages", [])
        for contributor in (result_pages[0].get("contributors") or []) if result_pages else []:
            name = str(contributor.get("name", "")).strip()
            if name and name not in contributors:
                contributors.append(name)
        if "continue" not in data:
            break
        cont = data["continue"]

    revision_user = str(revision.get("user", "")).strip()
    if revision_user and revision_user not in contributors:
        contributors.append(revision_user)

    return RevisionInfo(
        revid=int(revision["revid"]),
        timestamp=str(revision.get("timestamp", "")),
        user=revision_user,
        contributors=tuple(contributors),
        page_title=resolved_page_title,
    )


def fetch_categories(session: requests.Session, page_title: str) -> tuple[str, ...]:
    data = api_get(session, {
        "action": "query", "prop": "categories", "titles": page_title, "redirects": 1,
        "cllimit": "max",
    })
    pages = data.get("query", {}).get("pages", [])
    categories: list[str] = []
    for category in (pages[0].get("categories") or []) if pages else []:
        title = str(category.get("title", ""))
        title = title.removeprefix("Category:")
        if title and title not in categories:
            categories.append(title)
    return tuple(categories)


def fetch_rendered_html(session: requests.Session, page_title: str, oldid: int) -> str:
    data = api_get(session, {
        "action": "parse", "oldid": oldid, "prop": "text",
        "disableeditsection": 1, "disablelimitreport": 1,
    })
    html = data.get("parse", {}).get("text", "")
    if isinstance(html, dict):
        html = html.get("*", "")
    if not str(html).strip():
        raise RuntimeError(f"No rendered HTML returned for {page_title} at revision {oldid}")
    return str(html)


def stop_before_collation(root: Tag) -> None:
    """Delete 校勘記 and everything after it from the rendered article body.

    The heading is usually a direct child of ``mw-parser-output``, but templates
    can wrap sections inside one or more ``div`` elements.  At every ancestor
    level, remove the siblings following the branch that contains 校勘記.  This
    prevents a later footer or sibling wrapper from surviving merely because the
    heading itself was nested.
    """
    stop_heading = None
    for heading in root.find_all(["h1", "h2", "h3", "h4", "h5", "h6"]):
        label = heading.get_text("", strip=True).replace("[編輯]", "").replace("[编辑]", "")
        if "校勘記" in label or "校勘记" in label:
            stop_heading = heading
            break
    if stop_heading is None:
        return

    branch: Tag | None = stop_heading
    first = True
    while branch is not None and branch is not root:
        sibling = branch.find_next_sibling()
        while sibling is not None:
            next_sibling = sibling.find_next_sibling()
            sibling.decompose()
            sibling = next_sibling

        parent = branch.parent if isinstance(branch.parent, Tag) else None
        if first:
            branch.decompose()
            first = False
        branch = parent


def remove_page_furniture(root: Tag) -> None:
    stop_before_collation(root)
    for selector in DROP_SELECTORS:
        for element in list(root.select(selector)):
            element.decompose()

    # Wikisource states that these rendered section headings were added for
    # reading convenience and are not part of the ancient text. Metadata keeps
    # the canonical chapter title, so headings need not be duplicated in body.
    for heading in list(root.find_all(["h1", "h2", "h3", "h4", "h5", "h6"])):
        heading.decompose()

    # Remove compact page furniture while retaining real historical tables.
    # Do not delete a large wrapper merely because a nested header contains a
    # navigation marker: some MediaWiki skins wrap most of the article in divs.
    modern_project_markers = (
        "維基百科", "维基百科", "維基大典", "维基大典",
        "本文的各章節標題", "本文的各章节标题", "三家註版", "三家注版",
    )
    for element in reversed(list(root.find_all(["table", "div", "nav", "center"]))):
        if getattr(element, "attrs", None) is None:
            continue
        text = element.get_text(" ", strip=True)
        classes = " ".join(str(value) for value in (element.get("class") or []))
        ident = str(element.get("id") or "")
        marker = f"{classes} {ident}".lower()
        class_furniture = any(word in marker for word in ("header", "navbox", "navigation", "sisterproject"))
        compact_navigation = len(text) <= 1200 and ("◄" in text or "►" in text)
        compact_modern_box = len(text) <= 1200 and any(word in text for word in modern_project_markers)
        if class_furniture or compact_navigation or compact_modern_box:
            element.decompose()


def extract_text(root: Tag) -> str:
    parts: list[str] = []

    def newline() -> None:
        if not parts:
            return
        if not parts[-1].endswith("\n"):
            parts.append("\n")

    def table_text(table: Tag) -> str:
        # Tables in the ten 表 carry primary-source structure. Preserve each row
        # as one line and each cell boundary as a tab so a plain-text corpus
        # reader can still distinguish columns. Generic DOM walking would turn
        # every cell into an unrelated paragraph and destroy that structure.
        rows: list[str] = []
        for row in table.find_all("tr"):
            if row.find_parent("table") is not table:
                continue
            cells = row.find_all(["th", "td"], recursive=False)
            if not cells:
                continue
            values: list[str] = []
            for cell in cells:
                value = cell.get_text(" ", strip=True).replace("\xa0", " ").replace("\u3000", " ")
                value = re.sub(r" +", " ", value).strip()
                values.append(value)
            if any(values):
                rows.append("\t".join(values).rstrip("\t"))
        return "\n".join(rows)

    def walk(node: Any) -> None:
        if isinstance(node, NavigableString):
            value = str(node).replace("\xa0", " ").replace("\u3000", " ")
            if value:
                parts.append(value)
            return
        if not isinstance(node, Tag):
            return
        name = (node.name or "").lower()
        if name in {"script", "style", "noscript"}:
            return
        if name == "table":
            rendered = table_text(node)
            if rendered:
                newline()
                parts.append(rendered)
                newline()
            return
        if name in {"br", "hr"}:
            newline()
            return
        block = name in BLOCK_TAGS
        if block:
            newline()
        for child in node.children:
            walk(child)
        if block:
            newline()

    walk(root)
    text = "".join(parts).replace("\r\n", "\n").replace("\r", "\n")
    # Keep table tabs intact. Only ordinary spaces are collapsed here.
    text = re.sub(r" +", " ", text)
    text = "\n".join(line.strip() for line in text.splitlines())
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    text = re.sub(r"\[\s*(?:編輯|编辑)\s*\]", "", text)
    text = re.sub(r" +([，、。；：？！）》〉」』])", r"\1", text)
    text = re.sub(r"([《〈「『（(]) +", r"\1", text)
    text = re.sub(r" *· *", "·", text)
    return text.strip() + "\n" if text.strip() else ""


def clean_rendered_html(html: str) -> str:
    soup = BeautifulSoup(html, "html.parser")
    root = soup.find(class_="mw-parser-output") or soup
    remove_page_furniture(root)
    text = extract_text(root)
    # Defensive stops for license/footer leakage if Wikisource templates change.
    for marker in ("本作品在全世界都屬於", "本作品在全世界都属于", "取自「https://zh.wikisource.org", "檢索自“https://zh.wikisource.org"):
        if marker in text:
            text = text.split(marker, 1)[0].rstrip() + "\n"
    return text


def scrape_page(session: requests.Session, juan: int, root_categories: Iterable[str] = ()) -> ScrapedPage:
    page_title = canonical_page_title(juan)
    revision = fetch_revision_info(session, page_title)
    resolved_page_title = revision.page_title or page_title
    html = fetch_rendered_html(session, resolved_page_title, revision.revid)
    text = clean_rendered_html(html)
    if len(text.strip()) < MIN_CLEAN_CHARACTERS:
        raise RuntimeError(f"Cleaned {page_title} is unexpectedly short ({len(text.strip())} characters)")
    page_categories = list(fetch_categories(session, resolved_page_title))
    for category in root_categories:
        value = str(category).strip()
        if value and value not in page_categories:
            page_categories.append(value)
    return ScrapedPage(
        juan=juan,
        title=JUAN_TITLES[juan - 1],
        page_title=resolved_page_title,
        text=text,
        revision=revision,
        categories=tuple(page_categories),
    )


def read_json_bom(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))



def existing_ids_by_juan(metadata: dict[str, Any]) -> dict[int, int]:
    output = dict(KNOWN_LEGACY_PAGE_IDS)

    def bare_chapter_title(value: str) -> str:
        # Wikisource redirects often use names such as 史記/淮陰侯列傳 while the
        # landing-page inventory prints 淮陰侯列傳第三十二.
        return re.sub(r"第[一二三四五六七八九十百]+$", "", value.strip())

    title_to_juan: dict[str, int] = {}
    for index, title in enumerate(JUAN_TITLES, start=1):
        title_to_juan[title] = index
        title_to_juan[bare_chapter_title(title)] = index

    for document in metadata.get("documents", []) or []:
        if not isinstance(document, dict):
            continue
        document_id = document.get("document_id")
        if not isinstance(document_id, int):
            continue

        sequence = document.get("sequence")
        if isinstance(sequence, int) and 1 <= sequence <= EXPECTED_JUAN:
            output[sequence] = document_id
            continue

        page_title = str(document.get("page_title", ""))
        match = re.search(r"史記/卷(\d{1,3})$", page_title)
        if match:
            output[int(match.group(1))] = document_id
            continue

        tail = page_title.split("/")[-1]
        if tail in title_to_juan:
            output[title_to_juan[tail]] = document_id
            continue

        # Only trust the new canonical three-digit local filenames.  The old
        # incomplete scrape used two-digit filenames as scrape-order counters,
        # so accepting those would reintroduce the original identity bug.
        file_name = str(document.get("file", ""))
        file_match = re.fullmatch(r"史記__juan_(\d{3})\.txt", file_name)
        if file_match:
            juan = int(file_match.group(1))
            if 1 <= juan <= EXPECTED_JUAN:
                output[juan] = document_id

    return output


def preserved_document_ids(metadata: dict[str, Any]) -> dict[int, int]:
    """Return only document IDs that can safely be carried into the rescrape.

    New documents are intentionally left without document_id. The repository's
    existing corpus_metadata_ids:repair task owns global ID allocation and runs
    before corpus_search:rebuild_manifest. Keeping allocation there avoids a
    second allocator and keeps the Git-LFS registry authoritative.
    """
    return existing_ids_by_juan(metadata)


def root_revision(session: requests.Session) -> RevisionInfo:
    return fetch_revision_info(session, ROOT_TITLE)


def merge_unique_records(existing: Any, additions: list[dict[str, Any]], *, keys: tuple[str, ...]) -> list[Any]:
    """Preserve existing provenance records while appending this rescrape's records."""
    output: list[Any] = list(existing) if isinstance(existing, list) else []
    seen: set[tuple[str, ...]] = set()
    for item in output:
        if isinstance(item, dict):
            seen.add(tuple(str(item.get(key, "")) for key in keys))
    for item in additions:
        identity = tuple(str(item.get(key, "")) for key in keys)
        if identity not in seen:
            output.append(item)
            seen.add(identity)
    return output


def merge_unique_notes(existing: Any, additions: list[str]) -> list[str]:
    output = [str(value) for value in existing] if isinstance(existing, list) else []
    for value in additions:
        if value not in output:
            output.append(value)
    return output


def build_metadata(
    old_metadata: dict[str, Any], pages: list[ScrapedPage], document_ids: dict[int, int],
    landing: RevisionInfo, retrieved_on: str,
) -> dict[str, Any]:
    work_id = old_metadata.get("work_id")
    if not isinstance(work_id, int):
        raise RuntimeError("Existing 史記 metadata has no integer work_id; refusing to invent a replacement")

    digital_contributors = sorted({
        name
        for revision in [landing, *(page.revision for page in pages)]
        for name in [revision.user, *revision.contributors]
        if name
    })
    landing_page_title = landing.page_title or ROOT_TITLE
    landing_fixed = wiki_url(landing_page_title, landing.revid)
    live = wiki_url(landing_page_title)

    documents: list[dict[str, Any]] = []
    for page in pages:
        document = {
            "file": f"史記__juan_{page.juan:03d}.txt",
            "path": f"中國漢文/clean/漢朝/西漢/史記/史記__juan_{page.juan:03d}.txt",
            "title": page.title,
            "page_title": page.page_title,
            "source_alias_page_title": canonical_page_title(page.juan),
            "sequence": page.juan,
            "chapter": page.title,
            "source_url": wiki_url(page.page_title, page.revision.revid),
            "source_live_url": wiki_url(page.page_title),
            "source_revision_id": page.revision.revid,
            "source_revision_time": page.revision.timestamp,
            "source_revision_user": page.revision.user,
            "source_contributors": list(page.revision.contributors),
            "source_categories": list(page.categories),
            "body_start_line": 1,
        }
        preserved_id = document_ids.get(page.juan)
        if isinstance(preserved_id, int) and preserved_id > 0:
            document["document_id"] = preserved_id
        documents.append(document)

    # A transcription refresh must not silently redetermine historical metadata.
    # Start with the repository's existing work record, then replace only fields
    # that describe this digital witness and its 130 document records.
    digital_contributor_records = [
        {"name": name, "role": "digital_contributor_to_consulted_wikisource_pages"}
        for name in digital_contributors
    ]
    new_contributors = [
        {"name": "Sima, Tan 司馬談", "role": "predecessor; historical_project_conception_and_preparatory_work"},
        {"name": "Chu, Shaosun 褚少孫", "role": "supplementer"},
        {"name": "Chinese Wikisource contributors", "role": "digital_edition_contributor_community"},
        *digital_contributor_records,
        {"name": "Wikimedia Foundation", "role": "digital_host_and_custodian"},
    ]
    new_source = {
        "kind": "digital_transcription",
        "citation": (
            f"Sima, Qian 司馬遷 (with predecessor Sima, Tan 司馬談; supplemented by Chu, Shaosun 褚少孫). "
            f"(n.d.). 史記. In Chinese Wikisource contributors (Digital Eds.), 維基文庫. "
            f"Wikimedia Foundation. Retrieved "
            f"{date.fromisoformat(retrieved_on).strftime('%B')} {date.fromisoformat(retrieved_on).day}, "
            f"{date.fromisoformat(retrieved_on).year}, from {live}. "
            "(Originally published ca. 1st century BCE)."
        ),
        "url": landing_fixed,
        "live_url": live,
        "revision_id": landing.revid,
        "revision_time": landing.timestamp,
        "retrieved_on": retrieved_on,
        "licence": "CC BY-SA 4.0 and GFDL",
        "digital_contributors": digital_contributors,
    }
    new_notes = [
        "《史記》通行本為一百三十卷：十二本紀、十表、八書、三十世家、七十列傳。",
        "Chinese Wikisource describes the work as 司馬遷撰、褚少孫補. Page-level fixed revisions and contributor lists are retained on every document record.",
        "The four document IDs from the previous incomplete scrape are preserved by their true canonical juan identities (卷十八、卷三十八、卷四十四、卷九十二).",
        "Historical dating fields are preserved from the existing corpus metadata; this rescrape does not reinterpret the work's composition date.",
    ]
    existing_rights = old_metadata.get("rights") if isinstance(old_metadata.get("rights"), dict) else {}
    rights = dict(existing_rights)
    rights.update({
        "ancient_text": "public_domain",
        "wikisource_text": "CC BY-SA 4.0 and GFDL",
        "note": "Ancient text is public domain. Wikisource contributor-added punctuation, transcription and editorial work remain under the licences stated by Chinese Wikisource.",
    })

    existing_authors = old_metadata.get("authors")
    if existing_authors in (None, [], "", ["司馬遷"], "司馬遷"):
        refreshed_authors: Any = ["Sima, Qian 司馬遷"]
    else:
        refreshed_authors = existing_authors

    metadata = dict(old_metadata)
    metadata.update({
        "schema_version": max(int(old_metadata.get("schema_version", 1)), 1),
        "work_id": work_id,
        "corpus_root": old_metadata.get("corpus_root") or "中國漢文",
        "macro_region": old_metadata.get("macro_region") or "中國",
        "period": "西漢",
        "polity": "漢",
        "title": old_metadata.get("title") or "史記",
        "work_base_title": old_metadata.get("work_base_title") or old_metadata.get("title") or "史記",
        "authors": refreshed_authors,
        "contributors": merge_unique_records(old_metadata.get("contributors"), new_contributors, keys=("name", "role")),
        "source_categories": sorted({category for page in pages for category in page.categories}),
        "rights": rights,
        "edition": "Chinese Wikisource digital transcription",
        "edition_label": "維基文庫",
        "sources": merge_unique_records(old_metadata.get("sources"), [new_source], keys=("kind", "url", "revision_id")),
        "transcription_status": "Rescraped from the rendered Chinese Wikisource text for all 130 canonical juan; Wikisource navigation, convenience headings, reference markers and 校勘記 excluded from corpus body.",
        "notes": merge_unique_notes(old_metadata.get("notes"), new_notes),
        "documents": documents,
    })

    # Preserve date/year fields exactly when the existing corpus record has them.
    # Do not manufacture a single completion year as a side effect of replacing
    # the digital transcription.
    for key in ("date_label", "year_start", "year_end", "dating_status"):
        if key in old_metadata:
            metadata[key] = old_metadata[key]
        else:
            metadata.pop(key, None)

    return metadata


def validate_scrape(pages: list[ScrapedPage]) -> None:
    if len(pages) != EXPECTED_JUAN:
        raise RuntimeError(f"Expected {EXPECTED_JUAN} juan, got {len(pages)}")
    numbers = [page.juan for page in pages]
    if numbers != list(range(1, EXPECTED_JUAN + 1)):
        raise RuntimeError("Scraped juan sequence is incomplete or out of order")
    for page in pages:
        if "校勘記" in page.text or "校勘记" in page.text:
            raise RuntimeError(f"Editorial 校勘記 leaked into cleaned body: {page.page_title}")
        if "◄" in page.text or "►" in page.text:
            raise RuntimeError(f"Wikisource navigation leaked into cleaned body: {page.page_title}")


def write_stage(stage: Path, pages: list[ScrapedPage], metadata: dict[str, Any]) -> None:
    stage.mkdir(parents=True, exist_ok=True)
    for page in pages:
        target = stage / f"史記__juan_{page.juan:03d}.txt"
        target.write_text(page.text, encoding="utf-8-sig", newline="\n")
    (stage / "metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8-sig", newline="\n"
    )


def install_stage(stage: Path, work_dir: Path) -> None:
    expected = {f"史記__juan_{number:03d}.txt" for number in range(1, EXPECTED_JUAN + 1)} | {"metadata.json"}
    staged = {path.name for path in stage.iterdir() if path.is_file()}
    if staged != expected:
        missing = sorted(expected - staged)
        extra = sorted(staged - expected)
        raise RuntimeError(f"Staged file set mismatch; missing={missing[:5]} extra={extra[:5]}")

    # Atomic per-file replacement after a complete validated stage exists.
    work_dir.mkdir(parents=True, exist_ok=True)
    for source in sorted(stage.glob("史記__juan_*.txt")):
        os.replace(source, work_dir / source.name)
    os.replace(stage / "metadata.json", work_dir / "metadata.json")

    # Remove obsolete text files only after the complete canonical set exists.
    keep = {f"史記__juan_{number:03d}.txt" for number in range(1, EXPECTED_JUAN + 1)}
    for old in work_dir.glob("史記__juan_*.txt"):
        if old.name not in keep:
            old.unlink()


def repository_paths(repository_root: Path) -> tuple[Path, Path]:
    corpus_root = repository_root / "corpus"
    return corpus_root, corpus_root / WORK_RELATIVE


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Rescrape all 130 juan of 史記 from Chinese Wikisource")
    parser.add_argument("--repository-root", default=".", help="Repository root; default current directory")
    parser.add_argument("--apply", action="store_true", help="Replace the existing 史記 work after the full scrape validates")
    parser.add_argument("--sleep", type=float, default=0.20, help="Delay between juan requests; default 0.20 seconds")
    parser.add_argument("--retrieved-on", default=date.today().isoformat(), help="Retrieval date YYYY-MM-DD")
    parser.add_argument("--only", type=int, default=None, help="Developer smoke test: scrape one juan; cannot be combined with --apply")
    args = parser.parse_args(argv)

    if args.only is not None and args.apply:
        parser.error("--only cannot be combined with --apply")
    if args.only is not None and not 1 <= args.only <= EXPECTED_JUAN:
        parser.error("--only must be between 1 and 130")
    date.fromisoformat(args.retrieved_on)

    repository_root = Path(args.repository_root).resolve()
    _corpus_root, work_dir = repository_paths(repository_root)
    metadata_path = work_dir / "metadata.json"
    if not metadata_path.exists():
        raise RuntimeError(f"Existing 史記 metadata is missing: {metadata_path}")

    old_metadata = read_json_bom(metadata_path)
    ids: dict[int, int] = preserved_document_ids(old_metadata) if args.only is None else {}

    session = requests.Session()
    session.headers.update(HEADERS)
    landing = root_revision(session)
    root_categories = fetch_categories(session, ROOT_TITLE)

    selected = [args.only] if args.only is not None else list(range(1, EXPECTED_JUAN + 1))
    pages: list[ScrapedPage] = []
    for position, juan in enumerate(selected, start=1):
        print(f"[{position:03d}/{len(selected):03d}] {canonical_page_title(juan)} {JUAN_TITLES[juan - 1]}", flush=True)
        pages.append(scrape_page(session, juan, root_categories=root_categories))
        if args.sleep > 0:
            time.sleep(args.sleep)

    if args.only is not None:
        page = pages[0]
        print(f"Smoke test OK: {page.page_title}, revision {page.revision.revid}, {len(page.text)} characters")
        return 0

    validate_scrape(pages)
    metadata = build_metadata(old_metadata, pages, ids, landing, args.retrieved_on)

    if not args.apply:
        print(f"PLAN OK: {len(pages)} juan fetched and validated.")
        print(f"Would preserve work_id {metadata['work_id']} and install into {work_dir}")
        missing_ids = sum(1 for document in metadata["documents"] if "document_id" not in document)
        print(f"Preserved {len(metadata['documents']) - missing_ids} established document IDs; {missing_ids} new juan intentionally have no document_id yet.")
        print("The shared .metadata_id_registry.csv was not read or changed.")
        print("After --apply: cd viewer; run bin/rails corpus_search:rebuild_manifest, then bin/rails corpus_catalogue:rebuild.")
        return 0

    with tempfile.TemporaryDirectory(prefix="fanya-shiji-rescrape-") as tmp:
        stage = Path(tmp) / "史記"
        write_stage(stage, pages, metadata)
        install_stage(stage, work_dir)

    print(f"Installed {EXPECTED_JUAN} canonical juan in {work_dir}")
    missing_ids = sum(1 for document in metadata["documents"] if "document_id" not in document)
    print(f"Preserved work_id {metadata['work_id']}; {missing_ids} new document IDs remain for corpus_metadata_ids:repair.")
    print("The shared .metadata_id_registry.csv was not changed by this scraper.")
    print("Next: cd viewer")
    print("  bin/rails corpus_search:rebuild_manifest")
    print("  bin/rails corpus_catalogue:rebuild")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
