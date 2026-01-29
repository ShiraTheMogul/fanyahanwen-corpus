#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations

import argparse
import hashlib
import random
import re
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import requests
from bs4 import BeautifulSoup


BASE = "https://inscription.asdc.sinica.edu.tw"
FULLTEXT_FORM_URL = BASE + "/expl_search.php"   # 全文檢索資料庫
LIST_URL = BASE + "/dore/listm.php"             # 結果頁


# -----------------------------
# Character safety helpers
# -----------------------------

def is_han_character(char: str) -> bool:
    cp = ord(char)
    if 0x4E00 <= cp <= 0x9FFF:   return True
    if 0x3400 <= cp <= 0x4DBF:   return True
    if 0x20000 <= cp <= 0x2A6DF: return True
    if 0x2A700 <= cp <= 0x2B73F: return True
    if 0x2B740 <= cp <= 0x2B81D: return True
    if 0x2B820 <= cp <= 0x2CEAD: return True
    if 0x2CEB0 <= cp <= 0x2EBE0: return True
    if 0x31350 <= cp <= 0x323AF: return True
    if 0x2EBF0 <= cp <= 0x2EE5D: return True
    if 0x323B0 <= cp <= 0x33479: return True
    if 0x2F800 <= cp <= 0x2FA1F: return True
    return False


def is_traditional_punctuation(char: str) -> bool:
    cp = ord(char)
    if 0x3000 <= cp <= 0x303F: return True
    if 0xFE10 <= cp <= 0xFE1F: return True
    if 0xFE30 <= cp <= 0xFE4F: return True
    if 0xFF00 <= cp <= 0xFFEF: return True
    return char in {
        '。', '，', '、', '；', '：', '？', '！', '「', '」', '『', '』',
        '《', '》', '（', '）', '［', '］', '｛', '｝', '【', '】', '…',
        '—', '～', '・', '〃', '〄', '々', '〆', '〇', '〈', '〉', '〖',
        '〗', '〘', '〙', '〚', '〛', '〜', '〝', '〞', '〟', '〰', '〱',
        '〲', '〳', '〴', '〵', '〶', '〷', '〸', '〹', '〺'
    }


def has_forbidden_latin(text: str) -> bool:
    for ch in text:
        cp = ord(ch)
        if "A" <= ch <= "Z" or "a" <= ch <= "z":
            return True
        if 0xFF21 <= cp <= 0xFF3A or 0xFF41 <= cp <= 0xFF5A:
            return True
    return False


def is_unicode_complete_inscription(text: str) -> bool:
    if not text:
        return False
    if "�" in text:
        return False
    if has_forbidden_latin(text):
        return False

    for ch in text:
        if ch.isspace():
            continue
        if ch.isdigit():
            continue
        if is_han_character(ch):
            continue
        if is_traditional_punctuation(ch):
            continue
        if ch in {"·", "・", "—", "-", "‐"}:
            continue
        return False
    return True


# -----------------------------
# HTTP + HTML helpers
# -----------------------------

def set_encoding(resp: requests.Response) -> None:
    if resp.encoding is None or resp.encoding.lower() == "iso-8859-1":
        resp.encoding = resp.apparent_encoding or "utf-8"


def dump_debug(path: Path, name: str, html: str) -> None:
    path.mkdir(parents=True, exist_ok=True)
    out = path / name
    out.write_text(html, encoding="utf-8", errors="replace")
    print(f"[debug] dumped HTML -> {out}")


def extract_js_var(html: str, varname: str) -> str:
    # e.g. _colList = 'textYanKuan,dynNum,...';
    m = re.search(rf"{re.escape(varname)}\s*=\s*'([^']*)'", html)
    if m:
        return m.group(1)
    m = re.search(rf"{re.escape(varname)}\s*=\s*\"([^\"]*)\"", html)
    if m:
        return m.group(1)
    return ""


def looks_like_results_page(html: str) -> bool:
    return ("summary=\"list\"" in html) or ("summary='list'" in html)


def looks_like_initq_shell(html: str) -> bool:
    return ("onload='initQ()'" in html or 'onload="initQ()"' in html) and (not looks_like_results_page(html))


def post(session: requests.Session, url: str, data, referer: str) -> str:
    headers = {
        "User-Agent": "FanyaHanwenCorpusScraper/0.4",
        "Referer": referer,
        "Origin": BASE,
        "Accept-Language": "zh-TW,zh;q=0.9,en;q=0.7",
    }
    r = session.post(url, data=data, headers=headers, timeout=60)
    set_encoding(r)
    return r.text


def get(session: requests.Session, url: str, referer: str) -> str:
    headers = {
        "User-Agent": "FanyaHanwenCorpusScraper/0.4",
        "Referer": referer,
        "Accept-Language": "zh-TW,zh;q=0.9,en;q=0.7",
    }
    r = session.get(url, headers=headers, timeout=60)
    set_encoding(r)
    return r.text


def serialize_form_preserve_duplicates(form_tag) -> List[Tuple[str, str]]:
    """
    Serialize <form> controls in document order, preserving duplicate names.
    This is the key fix vs dict payloads.
    """
    pairs: List[Tuple[str, str]] = []

    # document-order sweep
    for el in form_tag.find_all(["input", "select"], recursive=True):
        if el.name == "input":
            name = el.get("name")
            if not name:
                continue
            typ = (el.get("type") or "").lower()
            val = el.get("value") if el.get("value") is not None else ""

            if typ in {"hidden", "text", "search"}:
                pairs.append((name, val))
            elif typ == "checkbox":
                if el.has_attr("checked"):
                    pairs.append((name, val))
            else:
                # submit/button/etc -> ignore; queryQ() doesn’t rely on name/value of submit
                pass

        elif el.name == "select":
            name = el.get("name")
            if not name:
                continue
            opt = el.find("option", selected=True) or el.find("option")
            pairs.append((name, (opt.get("value") if opt and opt.get("value") is not None else "")))

    return pairs


def replace_all_then_append(pairs: List[Tuple[str, str]], key: str, value: str) -> List[Tuple[str, str]]:
    """
    Remove all occurrences of key, then append a single (key,value).
    Useful for setting paging knobs without leaving stale copies around.
    """
    out = [(k, v) for (k, v) in pairs if k != key]
    out.append((key, value))
    return out


def ensure_present(pairs: List[Tuple[str, str]], key: str, value: str) -> List[Tuple[str, str]]:
    if any(k == key for (k, _) in pairs):
        return pairs
    return pairs + [(key, value)]


# -----------------------------
# Parsing rows
# -----------------------------

def parse_rows_from_list(html: str) -> List[Dict[str, str]]:
    soup = BeautifulSoup(html, "lxml")
    table = soup.find("table", attrs={"summary": "list"})
    if table is None:
        snippet = html[:600]
        raise RuntimeError(f"Could not find results table. Page starts:\n{snippet}")

    out: List[Dict[str, str]] = []
    for tr in table.find_all("tr"):
        tds = tr.find_all("td")
        if len(tds) < 7:
            continue

        inscription_td = tds[1]
        has_img = inscription_td.find("img") is not None

        def td_text(i: int) -> str:
            return tds[i].get_text(" ", strip=True).replace("\xa0", " ").strip()

        out.append({
            "ENTRY_NUMBER": td_text(0),
            "INSCRIPTION": td_text(1),
            "TIMES": td_text(2),
            "MEDIUM": td_text(3),
            "SOURCE": td_text(4),
            "ID": td_text(5),
            "NO_BRONZE_COMPONENTS": td_text(6),
            "HAS_IMG": "1" if has_img else "0",
        })
    return out


def has_next_button(html: str) -> bool:
    return ("value='下頁'" in html) or ('value="下頁"' in html) or ("nextL(" in html)


def sha12(s: str) -> str:
    return hashlib.sha1(s.encode("utf-8", errors="replace")).hexdigest()[:12]


# -----------------------------
# Writing outputs
# -----------------------------

def medium_folder_name(medium: str) -> str:
    medium = (medium or "").strip()
    if medium in {"甲骨", "金文", "簡牘"}:
        return medium
    if not medium:
        return "未詳"
    return medium


def safe_filename(s: str) -> str:
    s = re.sub(r"[\\/:*?\"<>|]", "_", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:160] if len(s) > 160 else s


def compute_unique_id(parts: List[str]) -> str:
    h = hashlib.sha1()
    for p in parts:
        h.update(p.encode("utf-8", errors="replace"))
        h.update(b"\n")
    return h.hexdigest()[:12]


def write_entry(base_dir: Path, nation: str, layer: str, row: Dict[str, str]) -> Optional[Path]:
    inscription = row["INSCRIPTION"].strip()

    if row.get("HAS_IMG") == "1":
        return None
    if not is_unicode_complete_inscription(inscription):
        return None

    out_dir = base_dir / nation / layer / medium_folder_name(row["MEDIUM"])
    out_dir.mkdir(parents=True, exist_ok=True)

    uid = compute_unique_id([
        nation, layer,
        row.get("MEDIUM", ""),
        row.get("TIMES", ""),
        row.get("SOURCE", ""),
        row.get("ID", ""),
        row.get("ENTRY_NUMBER", ""),
        inscription,
    ])

    fname = safe_filename(f"{row.get('ID','')}_{uid}.txt")
    out_path = out_dir / fname
    if out_path.exists():
        return out_path

    title = f"ASDC｜{row.get('MEDIUM','')}｜{row.get('TIMES','')}｜{row.get('SOURCE','')}｜{row.get('ID','')}"

    meta = [
        f"# TITLE: {title}",
        "# SOURCE_DB: 先秦甲骨金文簡牘詞彙資料庫",
        "# URL: https://inscription.asdc.sinica.edu.tw",
        f"# ENTRY_NUMBER: {row.get('ENTRY_NUMBER','')}",
        f"# TIMES: {row.get('TIMES','')}",
        f"# MEDIUM: {row.get('MEDIUM','')}",
        f"# SOURCE: {row.get('SOURCE','')}",
        f"# ID: {row.get('ID','')}",
        f"# NO_BRONZE_COMPONENTS: {row.get('NO_BRONZE_COMPONENTS','')}",
        f"# UNIQUE_ID: {uid}",
        f"# 「本研究參考中央研究院歷史語言研究所金文工作室製作之『先秦甲骨金文簡牘詞彙資料庫』http://inscription.sinica.edu.tw」",
        "",
        inscription,
        "",
    ]
    out_path.write_text("\n".join(meta), encoding="utf-8", errors="replace")
    return out_path


# -----------------------------
# Bootstrap + paging
# -----------------------------

def bootstrap_empty_search(session: requests.Session, piece_len: int, dump_dir: Optional[Path]) -> Tuple[List[Tuple[str, str]], str]:
    """
    True “查詢” emulation:

    - GET expl_search.php
    - Serialize the form preserving duplicate _logicOp/_parenthesis fields
    - Add JS-only _colList as a submitted field
    - Force _op/_resVer and paging knobs
    - POST to /dore/listm.php
    """
    html_form = get(session, FULLTEXT_FORM_URL, referer=BASE + "/c_index.php")
    if dump_dir:
        dump_debug(dump_dir, "bootstrap_form_full.html", html_form)

    soup = BeautifulSoup(html_form, "lxml")
    form = soup.find("form")
    if form is None:
        raise RuntimeError("Could not find <form> on expl_search.php")

    col_list = extract_js_var(html_form, "_colList").strip()
    if not col_list:
        raise RuntimeError("Could not extract _colList from expl_search.php")

    pairs = serialize_form_preserve_duplicates(form)

    # JS-only var must be submitted
    pairs = ensure_present(pairs, "_colList", col_list)

    # Let the backend infer query mode; _op is often blank on initial query pages.
    pairs = replace_all_then_append(pairs, "_op", "")

    # DORE expects a “fresh” resVer (looks like a unix timestamp in real pages).
    pairs = replace_all_then_append(pairs, "_resVer", str(int(time.time())))

    # paging knobs
    pairs = replace_all_then_append(pairs, "_recNo", "0")
    pairs = replace_all_then_append(pairs, "_pieceLen", str(piece_len))

    html0 = post(session, LIST_URL, pairs, referer=FULLTEXT_FORM_URL)
    if dump_dir:
        dump_debug(dump_dir, "bootstrap_results_full.html", html0)

    if looks_like_initq_shell(html0):
        # This is *exactly* the symptom you pasted.
        raise RuntimeError("Got initQ shell page from /dore/listm.php (no results table). Still not matching queryQ().")

    if not looks_like_results_page(html0):
        snippet = html0[:700]
        raise RuntimeError(f"Unexpected first results page (no list table). Starts:\n{snippet}")

    # For paging: take the form from the RESULTS page and serialize it (again preserving duplicates).
    soup0 = BeautifulSoup(html0, "lxml")
    form0 = soup0.find("form", attrs={"name": "_f0"}) or soup0.find("form")
    if form0 is None:
        raise RuntimeError("Results page had no paging form (_f0).")

    paging_pairs = serialize_form_preserve_duplicates(form0)

    # Keep colList present for safety (sometimes present only as JS var on results too)
    col_list2 = extract_js_var(html0, "_colList").strip()
    if col_list2:
        paging_pairs = ensure_present(paging_pairs, "_colList", col_list2)
    else:
        paging_pairs = ensure_present(paging_pairs, "_colList", col_list)

    paging_pairs = replace_all_then_append(paging_pairs, "_pieceLen", str(piece_len))

    return paging_pairs, html0


# -----------------------------
# Main
# -----------------------------

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus-root", required=True)
    ap.add_argument("--nation", required=True)
    ap.add_argument("--layer", default="raw")
    ap.add_argument("--piece-len", type=int, default=100)
    ap.add_argument("--sleep", type=float, default=1.0)
    ap.add_argument("--max-pages", type=int, default=0)
    ap.add_argument("--proxy", default="")
    ap.add_argument("--dump-debug", action="store_true")
    args = ap.parse_args()

    out_root = Path(args.corpus_root).resolve()
    dump_dir = Path("asdc_debug") if args.dump_debug else None

    sess = requests.Session()
    if args.proxy.strip():
        sess.proxies.update({"http": args.proxy.strip(), "https": args.proxy.strip()})

    paging_pairs, html = bootstrap_empty_search(sess, args.piece_len, dump_dir)

    pages = 0
    wrote_total = 0
    recno = 0
    seen_hashes: set[str] = set()

    while True:
        if args.max_pages and pages >= args.max_pages:
            print("[stop] hit --max-pages")
            break

        # update paging fields the way nextL(recno) effectively does
        req = list(paging_pairs)
        req = replace_all_then_append(req, "_op", "l")
        req = replace_all_then_append(req, "_recNo", str(recno))
        req = replace_all_then_append(req, "_pieceLen", str(args.piece_len))

        html = post(sess, LIST_URL, req, referer=LIST_URL)
        pages += 1

        if looks_like_initq_shell(html):
            if dump_dir:
                dump_debug(dump_dir, f"initq_shell_recno_{recno}.html", html)
            raise RuntimeError("Paging request returned initQ shell (session fields no longer valid).")

        if not looks_like_results_page(html):
            if dump_dir:
                dump_debug(dump_dir, f"unexpected_page_recno_{recno}.html", html)
            snippet = html[:700]
            raise RuntimeError(f"Paging returned non-results page. Starts:\n{snippet}")

        h = sha12(html)
        if h in seen_hashes:
            if dump_dir:
                dump_debug(dump_dir, f"repeated_page_recno_{recno}.html", html)
            print(f"[warn] HTML hash repeated ({h}) — paging stuck at recno={recno}. Stopping.")
            break
        seen_hashes.add(h)

        rows = parse_rows_from_list(html)

        kept = 0
        skipped_img = 0
        skipped_non_unicode = 0

        for row in rows:
            if row.get("HAS_IMG") == "1":
                skipped_img += 1
                continue
            if not is_unicode_complete_inscription(row["INSCRIPTION"]):
                skipped_non_unicode += 1
                continue
            if write_entry(out_root, args.nation, args.layer, row) is not None:
                kept += 1

        wrote_total += kept
        print(
            f"[page] recno={recno} pages={pages} total_seen={len(rows)} "
            f"kept={kept} skipped_img={skipped_img} skipped_non_unicode={skipped_non_unicode} "
            f"wrote_total={wrote_total}"
        )

        if not has_next_button(html):
            print("[stop] No 下頁 button found — reached final page.")
            break

        recno += args.piece_len
        time.sleep(max(0.0, args.sleep) + random.uniform(0.0, 0.25))

    print(f"[done] pages={pages} wrote_total={wrote_total}")


if __name__ == "__main__":
    main()
