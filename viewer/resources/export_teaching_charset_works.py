#!/usr/bin/env python3
"""
Export whole corpus works whose Han characters are limited to a teaching character set.

Default purpose:
  allowed set = uploaded 808 common CJK characters + Cangjie root-key characters
  unit tested = whole work, not individual chapter file
  output      = CSV/JSON indexes + a ZIP containing every allowed work file

No third-party packages are required.
If OpenCC is available, the script can use it to expand simplified forms to traditional forms.
A built-in small simplified-to-traditional map is also used, because the 808 list contains
simplified forms while the Fanya Hanwen corpus is mostly traditional.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

# Cangjie root-key characters.
# 24 normal root keys: 日月金木水火土竹戈十大中一弓人心手口尸廿山女田卜
# Plus common special key: 難. If you also want 重, pass --cangjie-roots with 重 added.
DEFAULT_CANGJIE_ROOTS = "日月金木水火土竹戈十大中一弓人心手口尸廿山女田卜難"

# A deliberately conservative built-in expansion map for common simplified forms in the 808 list.
# This is not meant to replace OpenCC; it prevents the worst false negatives when OpenCC is absent.
# Several entries map to more than one traditional form where the simplified graph merges forms.
S2T_EXTRA: Dict[str, str] = {
    "个": "個", "来": "來", "伟": "偉", "备": "備", "传": "傳", "伤": "傷",
    "价": "價", "亿": "億", "儿": "兒", "两": "兩", "册": "冊", "别": "別",
    "则": "則", "动": "動", "务": "務", "胜": "勝", "劳": "勞", "势": "勢",
    "劝": "勸", "区": "區", "协": "協", "参": "參", "问": "問", "丧": "喪",
    "单": "單", "严": "嚴", "国": "國", "园": "園", "圆": "圓", "图": "圖",
    "团": "團", "坚": "堅", "报": "報", "场": "場", "壮": "壯", "寿": "壽",
    "妇": "婦", "学": "學", "实": "實", "写": "寫", "将": "將", "对": "對",
    "师": "師", "广": "廣", "强": "強", "从": "從", "恶": "惡", "爱": "愛",
    "庆": "慶", "忧": "憂", "忆": "憶", "应": "應", "战": "戰", "户": "戶",
    "执": "執", "扬": "揚", "败": "敗", "敌": "敵", "数": "數", "时": "時",
    "昼": "晝", "书": "書", "会": "會", "东": "東", "业": "業", "极": "極",
    "荣": "榮", "乐": "樂", "树": "樹", "桥": "橋", "权": "權", "欢": "歡",
    "岁": "歲", "历": "歷曆", "归": "歸", "杀": "殺", "气": "氣", "决": "決",
    "净": "淨", "浅": "淺", "减": "減", "渔": "漁", "汉": "漢", "洁": "潔",
    "无": "無", "烟": "煙", "灯": "燈", "争": "爭", "独": "獨", "现": "現",
    "产": "產", "画": "畫", "异": "異", "当": "當噹", "发": "發髮", "尽": "盡",
    "礼": "禮", "种": "種", "竞": "競", "笔": "筆", "节": "節", "约": "約",
    "红": "紅", "纸": "紙", "细": "細", "终": "終", "结": "結", "绝": "絕",
    "给": "給", "统": "統", "经": "經", "绿": "綠", "线": "線", "练": "練",
    "续": "續", "义": "義", "习": "習", "圣": "聖", "闻": "聞", "声": "聲",
    "听": "聽", "与": "與", "兴": "興", "举": "舉", "万": "萬", "叶": "葉",
    "艺": "藝", "药": "藥", "处": "處", "虚": "虛", "号": "號", "众": "眾衆",
    "见": "見", "视": "視", "亲": "親", "观": "觀", "计": "計", "训": "訓",
    "记": "記", "访": "訪", "设": "設", "许": "許", "试": "試", "诗": "詩",
    "话": "話", "认": "認", "语": "語", "诚": "誠", "误": "誤", "说": "說",
    "谁": "誰", "课": "課", "调": "調", "谈": "談", "请": "請", "论": "論",
    "诸": "諸", "讲": "講", "谢": "謝", "证": "證", "识": "識", "议": "議",
    "读": "讀", "变": "變", "让": "讓", "丰": "豐", "贝": "貝", "财": "財",
    "贫": "貧", "货": "貨", "责": "責", "贮": "貯", "贵": "貴", "买": "買",
    "贺": "賀", "赏": "賞", "贤": "賢", "卖": "賣", "质": "質", "车": "車",
    "军": "軍", "轻": "輕", "农": "農", "连": "連", "进": "進", "运": "運",
    "过": "過", "达": "達", "远": "遠", "选": "選", "遗": "遺", "乡": "鄉",
    "医": "醫", "针": "針", "银": "銀", "钱": "錢", "钟": "鐘鍾", "铁": "鐵",
    "长": "長", "门": "門", "闭": "閉", "开": "開", "闲": "閒閑", "间": "間",
    "关": "關", "阴": "陰", "阳": "陽", "陆": "陸", "云": "雲", "电": "電",
    "静": "靜", "顶": "頂", "顺": "順", "须": "須鬚", "领": "領", "头": "頭",
    "题": "題", "愿": "願", "风": "風", "飞": "飛", "饭": "飯", "饮": "飲",
    "养": "養", "馀": "餘余", "马": "馬", "惊": "驚", "体": "體", "鱼": "魚",
    "鲜": "鮮", "鸟": "鳥", "鸣": "鳴", "麦": "麥", "黄": "黃", "点": "點",
    "齿": "齒", "韩": "韓",
}

HAN_RANGES: Tuple[Tuple[int, int], ...] = (
    (0x3400, 0x4DBF),    # CJK Extension A
    (0x4E00, 0x9FFF),    # CJK Unified Ideographs
    (0xF900, 0xFAFF),    # CJK Compatibility Ideographs
    (0x20000, 0x2A6DF),  # Extension B
    (0x2A700, 0x2B73F),  # Extension C
    (0x2B740, 0x2B81F),  # Extension D
    (0x2B820, 0x2CEAF),  # Extension E
    (0x2CEB0, 0x2EBEF),  # Extension F and related range
    (0x30000, 0x3134F),  # Extension G
    (0x31350, 0x323AF),  # Extension H
    (0x323B0, 0x3347F),  # Extension I/J area
)

# Folders generated from source files. Skipping them avoids duplicate exports of the same work.
DEFAULT_SKIP_DIRS = "kanbun,hanmun,hanvan,.git,node_modules,tmp,log,storage"

WORK_TITLE_KEYS = (
    "WORK_TITLE",
    "WORK_BASE_TITLE",
    "WORK",
    "BOOK_TITLE",
    "COLLECTION_TITLE",
)

CHAPTER_SUFFIX_PATTERNS = (
    # 越南亡國史__0001__front_matter.txt -> 越南亡國史
    re.compile(r"__\d{3,}__.*$"),
    # 越南亡國史_0001_front_matter.txt -> 越南亡國史
    re.compile(r"_\d{3,}_.*$"),
    # foo-0001.txt / foo_0001.txt -> foo
    re.compile(r"[-_]\d{3,}$"),
    # Work 卷一 / Work 卷第十二 / Work 第三章 -> Work
    re.compile(r"[\s_\-]*(卷第?[一二三四五六七八九十百千〇零兩\d]+|第[一二三四五六七八九十百千〇零兩\d]+[章回篇]|序|跋|目錄|凡例)$"),
)

@dataclass
class FileRecord:
    rel_path: str
    abs_path: Path
    meta: Dict[str, str]
    body_han_count: int
    unique_han: Set[str]
    bad_han: Counter
    bad_non_han: Counter

@dataclass
class WorkRecord:
    group_key: str
    title: str = ""
    files: List[FileRecord] = field(default_factory=list)

    def total_han(self) -> int:
        return sum(f.body_han_count for f in self.files)

    def unique_han(self) -> Set[str]:
        out: Set[str] = set()
        for f in self.files:
            out.update(f.unique_han)
        return out

    def bad_han(self) -> Counter:
        out: Counter = Counter()
        for f in self.files:
            out.update(f.bad_han)
        return out

    def bad_non_han(self) -> Counter:
        out: Counter = Counter()
        for f in self.files:
            out.update(f.bad_non_han)
        return out

    def allowed(self) -> bool:
        return not self.bad_han() and not self.bad_non_han()


def is_han(ch: str) -> bool:
    cp = ord(ch)
    return any(start <= cp <= end for start, end in HAN_RANGES)


def read_text(path: Path) -> str:
    # utf-8-sig consumes a BOM if one exists. errors='replace' prevents one bad byte from killing the run.
    return path.read_text(encoding="utf-8-sig", errors="replace")


def split_front_matter(raw: str) -> Tuple[Dict[str, str], str]:
    lines = raw.splitlines(keepends=True)
    meta: Dict[str, str] = {}
    i = 0
    while i < len(lines) and lines[i].startswith("#"):
        line = lines[i].lstrip("#").strip()
        if ":" in line:
            key, value = line.split(":", 1)
            meta[key.strip().upper()] = value.strip()
        i += 1
    return meta, "".join(lines[i:])


def clean_char_file_text(raw: str) -> Set[str]:
    # The uploaded 808 file is one character per line, but this also tolerates spaces or comments.
    chars: Set[str] = set()
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        for ch in line:
            if is_han(ch):
                chars.add(ch)
    return chars


def maybe_opencc_expand(chars: Set[str], command: str, config: str, verbose: bool) -> Set[str]:
    """Try optional OpenCC expansion. Failure is non-fatal."""
    expanded = set(chars)

    # Python package path.
    try:
        import opencc  # type: ignore
        converter = opencc.OpenCC(config)
        converted = converter.convert("".join(sorted(chars)))
        expanded.update(ch for ch in converted if is_han(ch))
        if verbose:
            print(f"OpenCC Python expansion added {len(expanded) - len(chars)} total extra chars so far.")
        return expanded
    except Exception:
        pass

    # Command-line path.
    exe = shutil.which(command)
    if not exe:
        if verbose:
            print("OpenCC not found; using built-in variant map only.")
        return expanded

    try:
        proc = subprocess.run(
            [exe, "-c", config],
            input="".join(sorted(chars)).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        converted = proc.stdout.decode("utf-8", errors="replace")
        expanded.update(ch for ch in converted if is_han(ch))
        if verbose:
            print(f"OpenCC command expansion added {len(expanded) - len(chars)} total extra chars so far.")
    except Exception as exc:
        if verbose:
            print(f"OpenCC command failed; continuing without it: {exc}")

    return expanded


def expand_allowed_chars(chars: Set[str], use_opencc: bool, opencc_command: str, opencc_config: str, verbose: bool) -> Set[str]:
    expanded = set(chars)

    for ch in list(chars):
        for trad in S2T_EXTRA.get(ch, ""):
            if is_han(trad):
                expanded.add(trad)

    if use_opencc:
        expanded = maybe_opencc_expand(expanded, opencc_command, opencc_config, verbose)

    return expanded


def infer_work_stem(path: Path) -> str:
    stem = path.stem
    changed = True
    while changed:
        changed = False
        for pattern in CHAPTER_SUFFIX_PATTERNS:
            new_stem = pattern.sub("", stem).strip(" _-")
            if new_stem != stem and new_stem:
                stem = new_stem
                changed = True
    return stem or path.stem


def group_key_for(rel_path: Path, meta: Dict[str, str], mode: str) -> Tuple[str, str]:
    """Return (group_key, display_title)."""
    if mode == "file":
        return (f"file::{rel_path.as_posix()}", rel_path.stem)

    if mode == "folder":
        title = rel_path.parent.name or rel_path.stem
        return (f"folder::{rel_path.parent.as_posix()}", title)

    # Default: metadata first, then filename-stem inference.
    for key in WORK_TITLE_KEYS:
        title = meta.get(key, "").strip()
        if title:
            # Include parent path so different works with the same title in different places do not merge by accident.
            return (f"meta::{rel_path.parent.as_posix()}::{title}", title)

    inferred = infer_work_stem(rel_path)
    if inferred != rel_path.stem:
        return (f"stem::{rel_path.parent.as_posix()}::{inferred}", inferred)

    return (f"file::{rel_path.as_posix()}", rel_path.stem)


def bad_non_han_counter(body: str) -> Counter:
    """Count non-Han letters. Punctuation, symbols, numbers, and whitespace are allowed."""
    bad = Counter()
    for ch in body:
        if is_han(ch) or ch.isspace():
            continue
        category = unicodedata.category(ch)
        if category[0] in {"P", "S", "N"}:  # punctuation, symbols, numbers
            continue
        if category[0] == "L":              # Latin, kana, hangul, etc.
            bad[ch] += 1
    return bad


def analyse_file(path: Path, rel_path: Path, allowed: Set[str], include_front_matter: bool, reject_non_han: bool) -> FileRecord:
    raw = read_text(path)
    meta, body = split_front_matter(raw)
    test_text = raw if include_front_matter else body

    unique_han: Set[str] = set()
    bad_han: Counter = Counter()
    han_count = 0
    for ch in test_text:
        if not is_han(ch):
            continue
        han_count += 1
        unique_han.add(ch)
        if ch not in allowed:
            bad_han[ch] += 1

    non_han_bad = bad_non_han_counter(test_text) if reject_non_han else Counter()

    return FileRecord(
        rel_path=rel_path.as_posix(),
        abs_path=path,
        meta=meta,
        body_han_count=han_count,
        unique_han=unique_han,
        bad_han=bad_han,
        bad_non_han=non_han_bad,
    )


def iter_text_files(corpus_root: Path, skip_dirs: Set[str]) -> Iterable[Path]:
    for path in corpus_root.rglob("*.txt"):
        rel = path.relative_to(corpus_root)
        if any(part in skip_dirs for part in rel.parts):
            continue
        yield path


def counter_preview(counter: Counter, max_chars: int) -> str:
    if not counter:
        return ""
    chars = [ch for ch, _count in counter.most_common(max_chars)]
    if len(counter) > max_chars:
        chars.append("…")
    return "".join(chars)


def counter_json(counter: Counter, max_chars: int) -> str:
    return json.dumps(dict(counter.most_common(max_chars)), ensure_ascii=False)


def write_csv(path: Path, rows: Sequence[Dict[str, object]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fieldnames = list(rows[0].keys())
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def build_rows(works: Sequence[WorkRecord], max_report_chars: int) -> List[Dict[str, object]]:
    rows: List[Dict[str, object]] = []
    for work in works:
        bad_han = work.bad_han()
        bad_non_han = work.bad_non_han()
        rows.append({
            "allowed": "yes" if work.allowed() else "no",
            "title": work.title,
            "group_key": work.group_key,
            "file_count": len(work.files),
            "total_han_chars": work.total_han(),
            "unique_han_count": len(work.unique_han()),
            "disallowed_han_unique_count": len(bad_han),
            "disallowed_han_total_count": sum(bad_han.values()),
            "disallowed_han_preview": counter_preview(bad_han, max_report_chars),
            "disallowed_han_counts_json": counter_json(bad_han, max_report_chars),
            "bad_non_han_unique_count": len(bad_non_han),
            "bad_non_han_preview": counter_preview(bad_non_han, max_report_chars),
            "paths_json": json.dumps([f.rel_path for f in work.files], ensure_ascii=False),
        })
    return rows


def zip_allowed_works(zip_path: Path, corpus_root: Path, allowed_works: Sequence[WorkRecord], index_dir: Path) -> None:
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        # Add indexes first, inside a clear folder.
        # Do not add the ZIP into itself.
        for index_file in sorted(index_dir.glob("*")):
            if index_file.resolve() == zip_path.resolve():
                continue
            if index_file.is_file():
                zf.write(index_file, Path("_index") / index_file.name)

        # Add text files, preserving corpus-relative paths under texts/.
        seen_archive_names: Set[str] = set()
        for work in allowed_works:
            for f in work.files:
                rel = Path(f.rel_path)
                archive_name = (Path("texts") / rel).as_posix()
                if archive_name in seen_archive_names:
                    continue
                seen_archive_names.add(archive_name)
                zf.write(corpus_root / rel, archive_name)


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Find and export whole works whose Han characters are limited to an allowed character set.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--corpus-root", required=True, help="Path to the corpus folder, e.g. ../corpus")
    parser.add_argument("--chars-file", required=True, help="Text file containing the 808 common characters")
    parser.add_argument("--out-dir", default="storage/teaching_charset_exports", help="Output directory")
    parser.add_argument("--zip-name", default="teaching_charset_texts.zip", help="ZIP filename inside the run folder")
    parser.add_argument("--cangjie-roots", default=DEFAULT_CANGJIE_ROOTS, help="Extra Cangjie root characters to allow")
    parser.add_argument("--extra-chars-file", action="append", default=[], help="Additional allowed character file; may be used more than once")
    parser.add_argument("--group-by", choices=("metadata", "folder", "file"), default="metadata", help="How to decide what a whole work is")
    parser.add_argument("--skip-dirs", default=DEFAULT_SKIP_DIRS, help="Comma-separated folder names to skip")
    parser.add_argument("--include-front-matter", action="store_true", help="Also test # metadata lines. Usually leave this off.")
    parser.add_argument("--reject-non-han", action="store_true", help="Reject body text containing non-Han letters such as Latin/kana/hangul")
    parser.add_argument("--no-opencc", action="store_true", help="Do not try optional OpenCC simplified-to-traditional expansion")
    parser.add_argument("--opencc-command", default="opencc", help="OpenCC executable name/path if using command-line OpenCC")
    parser.add_argument("--opencc-config", default="s2t.json", help="OpenCC config name/path")
    parser.add_argument("--max-report-chars", type=int, default=200, help="Max bad chars to show in CSV/JSON preview fields")
    parser.add_argument("--dry-run", action="store_true", help="Build indexes only; do not create ZIP")
    parser.add_argument("--verbose", action="store_true", help="Print more progress information")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)

    corpus_root = Path(args.corpus_root).expanduser().resolve()
    chars_file = Path(args.chars_file).expanduser().resolve()
    out_root = Path(args.out_dir).expanduser().resolve()

    if not corpus_root.is_dir():
        print(f"ERROR: corpus root is not a directory: {corpus_root}", file=sys.stderr)
        return 2
    if not chars_file.is_file():
        print(f"ERROR: character file not found: {chars_file}", file=sys.stderr)
        return 2

    base_chars = clean_char_file_text(read_text(chars_file))
    base_chars.update(ch for ch in args.cangjie_roots if is_han(ch))

    for extra_file in args.extra_chars_file:
        extra_path = Path(extra_file).expanduser().resolve()
        if not extra_path.is_file():
            print(f"ERROR: extra character file not found: {extra_path}", file=sys.stderr)
            return 2
        base_chars.update(clean_char_file_text(read_text(extra_path)))

    allowed_chars = expand_allowed_chars(
        base_chars,
        use_opencc=not args.no_opencc,
        opencc_command=args.opencc_command,
        opencc_config=args.opencc_config,
        verbose=args.verbose,
    )

    timestamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = out_root / f"charset_export_{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)

    (run_dir / "allowed_chars.txt").write_text("\n".join(sorted(allowed_chars)) + "\n", encoding="utf-8")
    (run_dir / "settings.json").write_text(json.dumps({
        "created_at": dt.datetime.now().isoformat(timespec="seconds"),
        "corpus_root": str(corpus_root),
        "chars_file": str(chars_file),
        "base_allowed_char_count": len(base_chars),
        "expanded_allowed_char_count": len(allowed_chars),
        "cangjie_roots": args.cangjie_roots,
        "group_by": args.group_by,
        "skip_dirs": args.skip_dirs,
        "include_front_matter": args.include_front_matter,
        "reject_non_han": args.reject_non_han,
        "used_opencc": not args.no_opencc,
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    skip_dirs = {part.strip() for part in args.skip_dirs.split(",") if part.strip()}

    works_by_key: Dict[str, WorkRecord] = {}
    file_rows: List[Dict[str, object]] = []
    file_count = 0

    for path in iter_text_files(corpus_root, skip_dirs):
        file_count += 1
        rel_path = path.relative_to(corpus_root)
        rec = analyse_file(path, rel_path, allowed_chars, args.include_front_matter, args.reject_non_han)
        group_key, title = group_key_for(rel_path, rec.meta, args.group_by)
        work = works_by_key.get(group_key)
        if work is None:
            work = WorkRecord(group_key=group_key, title=title)
            works_by_key[group_key] = work
        work.files.append(rec)

        file_rows.append({
            "allowed_by_file": "yes" if not rec.bad_han and not rec.bad_non_han else "no",
            "group_key": group_key,
            "title": title,
            "path": rec.rel_path,
            "han_count": rec.body_han_count,
            "unique_han_count": len(rec.unique_han),
            "disallowed_han_unique_count": len(rec.bad_han),
            "disallowed_han_preview": counter_preview(rec.bad_han, args.max_report_chars),
            "bad_non_han_preview": counter_preview(rec.bad_non_han, args.max_report_chars),
        })

        if args.verbose and file_count % 5000 == 0:
            print(f"Scanned {file_count:,} files; grouped {len(works_by_key):,} works...")

    works = sorted(works_by_key.values(), key=lambda w: (not w.allowed(), w.title, w.group_key))
    allowed_works = [w for w in works if w.allowed()]
    rejected_works = [w for w in works if not w.allowed()]

    write_csv(run_dir / "all_works_index.csv", build_rows(works, args.max_report_chars))
    write_csv(run_dir / "allowed_works_index.csv", build_rows(allowed_works, args.max_report_chars))
    write_csv(run_dir / "rejected_works_index.csv", build_rows(rejected_works, args.max_report_chars))
    write_csv(run_dir / "file_level_index.csv", file_rows)

    # JSON is nicer for programmatic reuse later.
    (run_dir / "allowed_works_index.json").write_text(json.dumps(build_rows(allowed_works, args.max_report_chars), ensure_ascii=False, indent=2), encoding="utf-8")
    (run_dir / "rejected_works_index.json").write_text(json.dumps(build_rows(rejected_works, args.max_report_chars), ensure_ascii=False, indent=2), encoding="utf-8")

    zip_path = run_dir / args.zip_name
    if not args.dry_run:
        zip_allowed_works(zip_path, corpus_root, allowed_works, run_dir)

    print()
    print("Done.")
    print(f"Scanned files:      {file_count:,}")
    print(f"Grouped works:      {len(works):,}")
    print(f"Allowed works:      {len(allowed_works):,}")
    print(f"Rejected works:     {len(rejected_works):,}")
    print(f"Allowed characters: {len(allowed_chars):,}")
    print(f"Output folder:      {run_dir}")
    if args.dry_run:
        print("ZIP:                skipped because --dry-run was used")
    else:
        print(f"ZIP:                {zip_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
