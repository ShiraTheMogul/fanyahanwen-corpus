#!/usr/bin/env python3
"""Build a small, browser-ready Oracular WOFF2 from the original TTF.

The original font contains a very large oracle-glyph inventory mapped to
supplementary private-use and unassigned code points. The corpus does not use
those code points, so serving them wastes bandwidth and makes conversion slow.

This script keeps only standard Unicode Han characters that the site's font
switcher can request. It does not alter or overwrite the source TTF.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

try:
    from fontTools import subset
    from fontTools.ttLib import TTFont
except ImportError as exc:  # pragma: no cover - user-facing dependency check
    raise SystemExit(
        "fontTools is not installed. Run:\n"
        "  python3 -m venv .venv-fonts\n"
        "  source .venv-fonts/bin/activate\n"
        "  python -m pip install 'fonttools[woff]'\n"
        "Then run this script again."
    ) from exc


# Unicode 17.0 assigned Han ranges. The source font is intersected with these
# ranges, so absent characters are simply skipped.
STANDARD_HAN_RANGES: tuple[tuple[int, int], ...] = (
    (0x3400, 0x4DBF),   # CJK Unified Ideographs Extension A
    (0x4E00, 0x9FFF),   # CJK Unified Ideographs
    (0xF900, 0xFAFF),   # CJK Compatibility Ideographs block
    (0x20000, 0x2A6DF), # Extension B
    (0x2A700, 0x2B73F), # Extension C
    (0x2B740, 0x2B81D), # Extension D
    (0x2B820, 0x2CEAD), # Extension E
    (0x2CEB0, 0x2EBE0), # Extension F
    (0x2EBF0, 0x2EE5D), # Extension I
    (0x2F800, 0x2FA1D), # Compatibility Ideographs Supplement
    (0x30000, 0x3134A), # Extension G
    (0x31350, 0x323AF), # Extension H
    (0x323B0, 0x33479), # Extension J
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Subset Oracular-Regular.ttf into a standard-Han WOFF2."
    )
    parser.add_argument("source", type=Path, help="Path to Oracular-Regular.ttf")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("app/assets/fonts/oracular/Oracular-Web-Regular.woff2"),
        help=(
            "Output WOFF2 path. Default: "
            "app/assets/fonts/oracular/Oracular-Web-Regular.woff2"
        ),
    )
    return parser.parse_args()


def unicode_cmap(font: TTFont) -> dict[int, str]:
    mappings: dict[int, str] = {}
    for table in font["cmap"].tables:
        if table.isUnicode():
            mappings.update(table.cmap)
    return mappings


def in_standard_han_range(codepoint: int) -> bool:
    return any(start <= codepoint <= finish for start, finish in STANDARD_HAN_RANGES)


def is_private_use(codepoint: int) -> bool:
    return (
        0xE000 <= codepoint <= 0xF8FF
        or 0xF0000 <= codepoint <= 0xFFFFD
        or 0x100000 <= codepoint <= 0x10FFFD
    )


def human_size(number: int) -> str:
    value = float(number)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.1f} {unit}"
        value /= 1024
    raise AssertionError("unreachable")


def copy_license(source: Path, output_dir: Path) -> None:
    candidates = (
        source.with_name("LICENSE.txt"),
        source.with_name("LICENSE"),
        source.with_name("OFL.txt"),
        source.with_name("OFL-1.1.txt"),
    )
    for candidate in candidates:
        if candidate.is_file():
            destination = output_dir / candidate.name
            shutil.copy2(candidate, destination)
            print(f"Copied licence: {destination}")
            return
    print("Warning: no licence file was found beside the source TTF.")


def build(source: Path, output: Path) -> None:
    if not source.is_file():
        raise SystemExit(f"Source font does not exist: {source}")
    if source.suffix.lower() != ".ttf":
        raise SystemExit(f"Expected a .ttf source font, got: {source.name}")

    print(f"Reading source: {source}")
    source_font = TTFont(source, lazy=False)
    source_cmap = unicode_cmap(source_font)
    keep = {cp for cp in source_cmap if in_standard_han_range(cp)}

    if not keep:
        raise SystemExit("No standard Unicode Han mappings were found in the source font.")

    source_pua = sum(1 for cp in source_cmap if is_private_use(cp))
    rejected_other = len(source_cmap) - len(keep) - source_pua

    print(f"Source size: {human_size(source.stat().st_size)}")
    print(f"Source glyphs: {len(source_font.getGlyphOrder()):,}")
    print(f"Source Unicode mappings: {len(source_cmap):,}")
    print(f"Keeping standard Han mappings: {len(keep):,}")
    print(f"Dropping private-use mappings: {source_pua:,}")
    print(f"Dropping other non-standard mappings: {rejected_other:,}")

    options = subset.Options()
    options.flavor = "woff2"
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.name_languages = ["*"]
    options.glyph_names = True
    options.symbol_cmap = True
    options.legacy_cmap = True
    options.notdef_glyph = True
    options.notdef_outline = True
    options.recommended_glyphs = True
    options.drop_tables = ["DSIG"]

    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=keep)
    subsetter.subset(source_font)

    output.parent.mkdir(parents=True, exist_ok=True)
    source_font.flavor = "woff2"
    source_font.save(output)

    # Read the result back. This catches broken WOFF2 output immediately rather
    # than leaving the browser to report a vague "failed to decode" message.
    result_font = TTFont(output, lazy=False)
    result_cmap = unicode_cmap(result_font)
    unexpected = set(result_cmap) - keep
    result_pua = [cp for cp in result_cmap if is_private_use(cp)]

    if unexpected:
        samples = ", ".join(f"U+{cp:04X}" for cp in sorted(unexpected)[:10])
        raise SystemExit(f"Verification failed: unexpected mappings remain: {samples}")
    if result_pua:
        samples = ", ".join(f"U+{cp:04X}" for cp in sorted(result_pua)[:10])
        raise SystemExit(f"Verification failed: private-use mappings remain: {samples}")

    print("Verification passed.")
    print(f"Output: {output}")
    print(f"Output size: {human_size(output.stat().st_size)}")
    print(f"Output glyphs: {len(result_font.getGlyphOrder()):,}")
    print(f"Output Unicode mappings: {len(result_cmap):,}")

    copy_license(source, output.parent)


if __name__ == "__main__":
    arguments = parse_args()
    try:
        build(arguments.source.expanduser().resolve(), arguments.output.expanduser())
    except Exception as exc:  # keep the terminal error concrete and readable
        print(f"Error: {exc}", file=sys.stderr)
        raise
