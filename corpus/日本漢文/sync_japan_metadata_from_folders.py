#!/usr/bin/env python3
"""
Synchronise Japanese corpus metadata from the reviewed folder structure.

This is intended for a finished/reviewed staging tree such as:

    japan_periodised_review/
      日本/明治時代/伊予国/高松栗林公園碑記/高松栗林公園碑記.txt
      日本/明治時代/佐倉藩/下総国/太田南畝/太田南畝.txt
      大日本帝国/朝鮮/<work>/<file>.txt

It rewrites metadata inside the staged copies so that folder placement becomes
canonical:

    日本/明治時代/伊予国/...              -> NATION: 日本, TIMES: 明治時代, REGION: 伊予国
    日本/明治時代/佐倉藩/下総国/...     -> NATION: 日本, TIMES: 明治時代, REGION: 佐倉藩，下総国
    大日本帝国/朝鮮/...                 -> NATION: 大日本帝国，朝鮮, TIMES: 大日本帝国, REGION: 朝鮮

Safety model:
- default is dry-run: manifest + summary only;
- use --apply to modify files in place;
- when --apply is used, changed files are backed up first, preserving paths.

Important vocabulary:
- "folder-derived metadata" means NATION/TIMES/REGION are taken from the path.
- "flattened REGION" means all region/domain folders between the period folder
  and the work folder are joined into one REGION value.

Example:
    日本/明治時代/佐倉藩/下総国/太田南畝/太田南畝.txt

The work folder is 太田南畝, so the region/domain folders are:
    佐倉藩
    下総国

The resulting metadata is:
    # REGION: 佐倉藩，下総国

Character normalisation:
- by default, the script uses a conservative built-in map for common simplified
  folder-name slips, e.g. 远江国 -> 遠江国 and 陆奥国 -> 陸奥国.
- OpenCC mode can now normalise NATION, TIMES, and REGION, not just REGION.
  For Japanese shinjitai -> traditional/kyūjitai, use --opencc-config jp2t.
  If your local OpenCC install does not provide jp2t, the script falls back
  to a built-in Japanese metadata conversion map for folder-derived metadata.
- you can chain configs with commas, e.g. --opencc-config s2t,jp2t. This is
  useful when the tree has mostly Japanese shinjitai but a few accidental
  simplified forms.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import re
import shutil
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

HEADER_RE = re.compile(r"^#\s*([^:]+):\s*(.*)$")

BACKUP_SUFFIXES = (
    ".bak",
    ".bak2",
    ".orig",
    ".tmp",
)

TOP_LEVEL_ROOTS = {"日本", "倭", "大日本帝国", "大日本帝國"}
PERIOD_FOLDERS = {
    "弥生時代",
    "彌生時代",
    "古墳時代",
    "飛鳥時代",
    "奈良時代",
    "平安時代",
    "鎌倉時代",
    "室町時代",
    "安土桃山時代",
    "江戸時代",
    "江戶時代",
    "明治時代",
    "大正時代",
    "昭和時代",
    "平成時代",
    "令和時代",
}

# These are organisational folders, not regions/domains to put into REGION.
GENERIC_REGION_COMPONENTS = {
    "未分類",
    "無年代",
    "境界年需核",
    "跨期年份需核",
    "日本漢文",
    "日本漢詩",
    "漢詩",
    "漢文",
    "待分類",
    "需核",
}

# A folder such as 都道府県 groups real regions beneath it.
REGION_GROUPING_COMPONENTS = {
    "都道府県",
}

# Audit files this script may produce. Avoid reading them if someone places the
# manifest under the same tree.
AUDIT_FILENAMES = {
    "japan_folder_metadata_manifest.csv",
    "japan_folder_metadata_summary.md",
}

# Conservative normalisation for slips caused by simplified-character folders.
# This is deliberately NOT full s2t conversion. It fixes obvious accidents while
# keeping Japanese folder spellings such as 国 and 帝国.
CONSERVATIVE_TRADITIONAL_MAP = str.maketrans({
    "远": "遠",
    "陆": "陸",
    "台": "臺",
    "湾": "灣",
})

# Built-in fallback for Japanese shinjitai / common new-character forms in
# metadata. This is intentionally used only for folder-derived metadata values,
# never for the text body. It covers the place/period forms that occur in this
# staging tree and common kanbun metadata terms.
JAPAN_METADATA_KYUJITAI_MAP = str.maketrans({
    # core country / region labels
    "国": "國",
    "県": "縣",
    "台": "臺",
    "湾": "灣",
    "総": "總",
    "奥": "奧",
    "広": "廣",
    "蔵": "藏",
    "浜": "濱",
    "戸": "戶",
    "縄": "繩",
    "姫": "姬",
    "讃": "讚",
    # accidental simplified forms sometimes found in folder names
    "远": "遠",
    "陆": "陸",
    "总": "總",
    "广": "廣",
    "县": "縣",
    "国": "國",
    "湾": "灣",
    # common shinjitai/new forms that may appear in metadata folders
    "徳": "德",
    "沢": "澤",
    "滝": "瀧",
    "竜": "龍",
    "亀": "龜",
    "鉄": "鐵",
    "円": "圓",
    "会": "會",
    "学": "學",
    "仏": "佛",
    "礼": "禮",
    "医": "醫",
    "芸": "藝",
    "号": "號",
    "処": "處",
    "条": "條",
    "実": "實",
    "写": "寫",
    "宝": "寶",
    "寿": "壽",
    "浅": "淺",
    "桜": "櫻",
    "栄": "榮",
    "塩": "鹽",
    "勧": "勸",
    "旧": "舊",
    "伝": "傳",
    "関": "關",
})


def builtin_jp2t_metadata(s: str) -> str:
    """Convert folder-derived Japanese metadata to traditional/kyūjitai forms."""
    return s.translate(JAPAN_METADATA_KYUJITAI_MAP)


@dataclass
class DerivedMetadata:
    nation: Optional[str]
    times: Optional[str]
    region: Optional[str]
    reason: str
    skipped: bool = False


@dataclass
class FileChange:
    path: Path
    relative_path: str
    old_nation: str
    new_nation: str
    old_times: str
    new_times: str
    old_region: str
    new_region: str
    changed: bool
    skipped: bool
    reason: str


def make_converter(mode: str, opencc_config: str):
    """Return a function that normalises folder-derived metadata values.

    mode values:
    - conservative: use the built-in small map, e.g. 远 -> 遠.
    - none: no character normalisation.
    - japan-traditional: use the built-in Japanese metadata kyūjitai map.
    - opencc: use OpenCC if installed. If the requested chain contains jp2t
      but the local OpenCC package does not provide that config, the script
      falls back to the built-in Japanese metadata kyūjitai map instead of
      failing.
    """
    if mode == "none":
        return lambda s: s

    if mode == "conservative":
        return lambda s: s.translate(CONSERVATIVE_TRADITIONAL_MAP)

    if mode == "japan-traditional":
        return builtin_jp2t_metadata

    if mode == "opencc":
        try:
            from opencc import OpenCC  # type: ignore
        except Exception as exc:  # pragma: no cover - depends on local env
            raise SystemExit(
                "OpenCC was requested but the Python opencc package is not available. "
                "Install one, or rerun with --character-mode japan-traditional. "
                f"Original import error: {exc}"
            )

        config_names = [part.strip() for part in opencc_config.split(",") if part.strip()]
        if not config_names:
            raise SystemExit("--opencc-config was empty. Use a config such as s2t, jp2t, or s2t,jp2t.")

        converters = []
        fallback_notes: List[str] = []
        for config_name in config_names:
            lower_name = config_name.lower().removesuffix(".json")
            try:
                converters.append(OpenCC(config_name))
                continue
            except Exception as exc:  # pragma: no cover - depends on local env
                if lower_name == "jp2t":
                    converters.append(builtin_jp2t_metadata)
                    fallback_notes.append(
                        "OpenCC config 'jp2t' was not available in this install; "
                        "using the script's built-in Japanese metadata conversion map for that step."
                    )
                    continue
                raise SystemExit(
                    f"Could not initialise OpenCC config {config_name!r}. "
                    "Check which OpenCC config files your install provides, or remove that config from the chain. "
                    f"Original error: {exc}"
                )

        for note in fallback_notes:
            print(f"NOTE: {note}", file=sys.stderr)

        def convert_chain(s: str) -> str:
            out = s
            for conv in converters:
                if callable(conv) and not hasattr(conv, "convert"):
                    out = conv(out)
                else:
                    out = conv.convert(out)
            return out

        return convert_chain

    raise ValueError(f"unknown character mode: {mode}")

def root_key(value: str) -> str:
    """Return a stable key for recognising root folders after conversion.

    This deliberately does not control output. It only lets the script recognise
    both 大日本帝国 and 大日本帝國 as the same structural root.
    """
    if value == "大日本帝國":
        return "大日本帝国"
    return value


def is_backup_file(path: Path) -> bool:
    name = path.name
    return any(name.endswith(suffix) for suffix in BACKUP_SUFFIXES)


def split_header_and_body(lines: List[str]) -> Tuple[List[str], List[str]]:
    """Return (header_lines, body_lines), treating initial # lines as metadata."""
    header: List[str] = []
    body: List[str] = []
    in_header = True
    for line in lines:
        if in_header and line.startswith("#"):
            header.append(line)
        else:
            in_header = False
            body.append(line)
    return header, body


def parse_header_values(lines: Sequence[str]) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for line in lines:
        m = HEADER_RE.match(line)
        if m:
            values[m.group(1).strip()] = m.group(2).strip()
    return values


def flatten_region_from_after_period(
    parts_after_period: Sequence[str],
    converter,
    region_separator: str,
) -> Optional[str]:
    """Return flattened REGION from folders after the period folder.

    parts_after_period excludes the filename and excludes the top-level root and
    period folder.

    The last directory is treated as the work folder. Everything before that is
    eligible as region/domain structure, except purely organisational folders.

    Examples:
    - ["伊予国", "高松栗林公園碑記"] -> 伊予国
    - ["佐倉藩", "下総国", "太田南畝"] -> 佐倉藩，下総国
    - ["都道府県", "東京都", "some work"] -> 東京都
    - ["未分類", "some work"] -> None
    - ["some work"] -> None
    """
    dirs = list(parts_after_period)
    if len(dirs) < 2:
        return None

    # Last directory is the work folder. Do not turn the work title into REGION.
    possible_region_dirs = dirs[:-1]

    region_parts: List[str] = []
    for component in possible_region_dirs:
        if component in GENERIC_REGION_COMPONENTS:
            continue
        if component in REGION_GROUPING_COMPONENTS:
            continue
        normalised = converter(component)
        if normalised and normalised not in GENERIC_REGION_COMPONENTS:
            region_parts.append(normalised)

    if not region_parts:
        return None
    return region_separator.join(region_parts)


def derive_metadata(
    root: Path,
    file_path: Path,
    nation_separator: str,
    region_separator: str,
    include_unclassified: bool,
    converter,
) -> DerivedMetadata:
    try:
        rel = file_path.relative_to(root)
    except ValueError:
        return DerivedMetadata(None, None, None, "file is not under supplied root", skipped=True)

    parts = rel.parts
    if len(parts) < 2:
        return DerivedMetadata(None, None, None, "not enough folder depth", skipped=True)

    top_output = converter(parts[0])
    top = root_key(top_output)
    if top == "未分類" and not include_unclassified:
        return DerivedMetadata(None, None, None, "root-level 未分類 skipped", skipped=True)
    if top not in TOP_LEVEL_ROOTS:
        return DerivedMetadata(None, None, None, f"unsupported top-level folder: {parts[0]}", skipped=True)

    # 大日本帝国/<territory>/<work>/<file>.txt
    # Here the top folder is both the imperial frame and the period. The next
    # folder is the governed territory/polity. top_output, not top, is used in
    # metadata so OpenCC can produce 大日本帝國 when requested.
    if top == "大日本帝国":
        territory = None
        dirs_after_top = list(parts[1:-1])
        if dirs_after_top and dirs_after_top[0] not in GENERIC_REGION_COMPONENTS:
            territory = converter(dirs_after_top[0])
        if territory:
            return DerivedMetadata(
                nation=f"{top_output}{nation_separator}{territory}",
                times=top_output,
                region=territory,
                reason=f"derived from {top_output}/<territory>/... folder path",
            )
        return DerivedMetadata(
            nation=top_output,
            times=top_output,
            region=None,
            reason=f"derived from {top_output} folder path; no territory folder found",
        )

    # 日本/<period>/<region-or-未分類>/<work>/<file>.txt
    # 倭/<period>/<region-or-未分類>/<work>/<file>.txt
    if len(parts) < 3:
        return DerivedMetadata(top_output, None, None, f"{top_output} file has no period folder", skipped=True)

    period = converter(parts[1])
    if period not in PERIOD_FOLDERS:
        return DerivedMetadata(top, None, None, f"second folder is not a known period: {parts[1]}", skipped=True)

    region = flatten_region_from_after_period(parts[2:-1], converter=converter, region_separator=region_separator)
    return DerivedMetadata(
        nation=top_output,
        times=period,
        region=region,
        reason=f"derived from {top_output}/<period>/<flattened-region-folders>/<work>/... folder path",
    )


def rewrite_metadata_text(
    text: str,
    new_nation: Optional[str],
    new_times: Optional[str],
    new_region: Optional[str],
    clear_missing_region: bool,
) -> Tuple[str, Dict[str, str]]:
    """Rewrite NATION/TIMES/REGION lines and return (new_text, old_values)."""
    had_trailing_newline = text.endswith("\n")
    lines = text.splitlines()
    header, body = split_header_and_body(lines)
    old_values = parse_header_values(header)

    desired: Dict[str, Optional[str]] = {
        "NATION": new_nation,
        "TIMES": new_times,
        "REGION": new_region,
    }

    seen = {"NATION": False, "TIMES": False, "REGION": False}
    rewritten_header: List[str] = []

    for line in header:
        m = HEADER_RE.match(line)
        if not m:
            rewritten_header.append(line)
            continue
        key = m.group(1).strip()
        if key not in seen:
            rewritten_header.append(line)
            continue
        seen[key] = True
        value = desired[key]
        if key == "REGION" and value is None and clear_missing_region:
            # Remove stale region metadata when the folder path has no region.
            continue
        if value is None:
            rewritten_header.append(line)
        else:
            rewritten_header.append(f"# {key}: {value}")

    # Add missing NATION/TIMES. Add REGION only when folder-derived value exists.
    if new_nation is not None and not seen["NATION"]:
        rewritten_header.append(f"# NATION: {new_nation}")
    if new_times is not None and not seen["TIMES"]:
        rewritten_header.append(f"# TIMES: {new_times}")
    if new_region is not None and not seen["REGION"]:
        rewritten_header.append(f"# REGION: {new_region}")

    new_lines = rewritten_header + body
    new_text = "\n".join(new_lines)
    if had_trailing_newline:
        new_text += "\n"
    return new_text, old_values


def iter_text_files(root: Path) -> Iterable[Path]:
    for path in root.rglob("*.txt"):
        if not path.is_file():
            continue
        if is_backup_file(path):
            continue
        if path.name in AUDIT_FILENAMES:
            continue
        if any(part.startswith("_metadata_backup") for part in path.parts):
            continue
        yield path


def backup_file(root: Path, file_path: Path, backup_dir: Path) -> None:
    rel = file_path.relative_to(root)
    target = backup_dir / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(file_path, target)


def write_manifest(changes: Sequence[FileChange], manifest_path: Path) -> None:
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "relative_path",
                "changed",
                "skipped",
                "old_nation",
                "new_nation",
                "old_times",
                "new_times",
                "old_region",
                "new_region",
                "reason",
            ],
        )
        writer.writeheader()
        for c in changes:
            writer.writerow({
                "relative_path": c.relative_path,
                "changed": "yes" if c.changed else "no",
                "skipped": "yes" if c.skipped else "no",
                "old_nation": c.old_nation,
                "new_nation": c.new_nation,
                "old_times": c.old_times,
                "new_times": c.new_times,
                "old_region": c.old_region,
                "new_region": c.new_region,
                "reason": c.reason,
            })


def write_summary(changes: Sequence[FileChange], summary_path: Path, apply: bool, backup_dir: Optional[Path], character_mode: str, opencc_config: str, region_separator: str) -> None:
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    total = len(changes)
    changed = sum(1 for c in changes if c.changed)
    skipped = sum(1 for c in changes if c.skipped)
    nation_counts = Counter(c.new_nation for c in changes if c.new_nation and not c.skipped)
    times_counts = Counter(c.new_times for c in changes if c.new_times and not c.skipped)
    region_counts = Counter(c.new_region for c in changes if c.new_region and not c.skipped)
    reasons = Counter(c.reason for c in changes)

    lines: List[str] = []
    lines.append("# Japan folder metadata sync report")
    lines.append("")
    lines.append(f"Mode: {'APPLY / files rewritten' if apply else 'DRY RUN / no files rewritten'}")
    lines.append(f"Character mode: {character_mode}")
    if character_mode == "opencc":
        lines.append(f"OpenCC config: {opencc_config}")
    lines.append(f"Region separator: {region_separator}")
    if backup_dir:
        lines.append(f"Backup directory: {backup_dir}")
    lines.append(f"Files scanned: {total}")
    lines.append(f"Files that would change / changed: {changed}")
    lines.append(f"Files skipped: {skipped}")
    lines.append("")

    lines.append("## New NATION values")
    for key, count in nation_counts.most_common():
        lines.append(f"- {key}: {count}")
    lines.append("")

    lines.append("## New TIMES values")
    for key, count in times_counts.most_common():
        lines.append(f"- {key}: {count}")
    lines.append("")

    lines.append("## New REGION values")
    for key, count in region_counts.most_common():
        lines.append(f"- {key}: {count}")
    lines.append("")

    lines.append("## Reasons")
    for key, count in reasons.most_common():
        lines.append(f"- {key}: {count}")
    lines.append("")

    lines.append("## Changed files")
    for c in changes:
        if c.changed:
            lines.append(f"- {c.relative_path}: NATION {c.old_nation!r} -> {c.new_nation!r}; TIMES {c.old_times!r} -> {c.new_times!r}; REGION {c.old_region!r} -> {c.new_region!r}")

    summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Synchronise NATION/TIMES/REGION metadata from a reviewed Japan staging folder tree.")
    ap.add_argument("root", type=Path, help="Root of the reviewed tree, e.g. .../japan_periodised_review")
    ap.add_argument("--apply", action="store_true", help="Actually rewrite files. Without this, only manifest and summary are written.")
    ap.add_argument("--manifest", type=Path, help="Manifest CSV path. Default: <root>/japan_folder_metadata_manifest.csv")
    ap.add_argument("--summary", type=Path, help="Summary Markdown path. Default: <root>/japan_folder_metadata_summary.md")
    ap.add_argument("--backup-dir", type=Path, help="Backup directory used with --apply. Default: <root>/_metadata_backup_<timestamp>")
    ap.add_argument("--include-unclassified", action="store_true", help="Also process root-level 未分類. Default skips it because it has no reliable folder-derived period.")
    ap.add_argument("--keep-existing-region-if-folder-has-none", action="store_true", help="Do not remove existing REGION when the folder path has no region/domain component.")
    ap.add_argument("--nation-separator", default="，", help="Separator for combined imperial NATION values. Default: fullwidth comma ，")
    ap.add_argument("--region-separator", default="，", help="Separator for flattened REGION folder layers. Default: fullwidth comma ，")
    ap.add_argument(
        "--character-mode",
        choices=["conservative", "none", "japan-traditional", "opencc"],
        default="conservative",
        help="Normalise folder-derived metadata. Default conservative fixes slips like 远->遠 without changing 国->國. Use japan-traditional to convert Japanese metadata without OpenCC.",
    )
    ap.add_argument(
        "--opencc-config",
        default="s2t,jp2t",
        help="OpenCC config used only with --character-mode opencc. Default: s2t,jp2t. If jp2t is unavailable locally, a built-in Japanese metadata fallback is used for that step.",
    )
    args = ap.parse_args()

    root = args.root.resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"Root folder does not exist or is not a directory: {root}")

    converter = make_converter(args.character_mode, args.opencc_config)

    manifest_path = args.manifest or (root / "japan_folder_metadata_manifest.csv")
    summary_path = args.summary or (root / "japan_folder_metadata_summary.md")

    backup_dir: Optional[Path] = None
    if args.apply:
        if args.backup_dir:
            backup_dir = args.backup_dir.resolve()
        else:
            stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_dir = root / f"_metadata_backup_{stamp}"
        backup_dir.mkdir(parents=True, exist_ok=True)

    changes: List[FileChange] = []
    clear_missing_region = not args.keep_existing_region_if_folder_has_none

    for path in sorted(iter_text_files(root)):
        rel = path.relative_to(root).as_posix()
        derived = derive_metadata(
            root,
            path,
            nation_separator=args.nation_separator,
            region_separator=args.region_separator,
            include_unclassified=args.include_unclassified,
            converter=converter,
        )

        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = path.read_text(encoding="utf-8", errors="replace")

        header, _body = split_header_and_body(text.splitlines())
        old = parse_header_values(header)
        old_nation = old.get("NATION", "")
        old_times = old.get("TIMES", "")
        old_region = old.get("REGION", "")

        if derived.skipped:
            changes.append(FileChange(
                path=path,
                relative_path=rel,
                old_nation=old_nation,
                new_nation="",
                old_times=old_times,
                new_times="",
                old_region=old_region,
                new_region="",
                changed=False,
                skipped=True,
                reason=derived.reason,
            ))
            continue

        new_text, old_values = rewrite_metadata_text(
            text,
            new_nation=derived.nation,
            new_times=derived.times,
            new_region=derived.region,
            clear_missing_region=clear_missing_region,
        )
        will_change = new_text != text
        changes.append(FileChange(
            path=path,
            relative_path=rel,
            old_nation=old_nation,
            new_nation=derived.nation or "",
            old_times=old_times,
            new_times=derived.times or "",
            old_region=old_region,
            new_region=derived.region or "",
            changed=will_change,
            skipped=False,
            reason=derived.reason,
        ))

        if args.apply and will_change:
            assert backup_dir is not None
            backup_file(root, path, backup_dir)
            path.write_text(new_text, encoding="utf-8")

    write_manifest(changes, manifest_path)
    write_summary(
        changes,
        summary_path,
        apply=args.apply,
        backup_dir=backup_dir,
        character_mode=args.character_mode,
        opencc_config=args.opencc_config,
        region_separator=args.region_separator,
    )

    changed_count = sum(1 for c in changes if c.changed)
    skipped_count = sum(1 for c in changes if c.skipped)
    print(f"Scanned {len(changes)} .txt files")
    print(f"{'Changed' if args.apply else 'Would change'} {changed_count} files")
    print(f"Skipped {skipped_count} files")
    print(f"Wrote manifest: {manifest_path}")
    print(f"Wrote summary: {summary_path}")
    if backup_dir:
        print(f"Backed up changed files to: {backup_dir}")
    if not args.apply:
        print("Dry run only. Re-run with --apply to rewrite metadata.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
