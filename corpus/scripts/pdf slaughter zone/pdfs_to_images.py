#!/usr/bin/env python3
"""
Convert PDFs to page images (one folder per PDF), with optional dedupe.

Default output: JPG.

Requires:
  pip install pymupdf
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys

import fitz  # PyMuPDF


def safe_folder_name(name: str) -> str:
    bad = '<>:"/\\|?*'
    for ch in bad:
        name = name.replace(ch, "＿")
    name = name.strip().strip(".")
    return name or "untitled"


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    """
    Hash a file without loading it all into memory.
    Pattern you can reuse anywhere:
      - open in 'rb'
      - read fixed-size chunks
      - update hash
    """
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def render_pdf_to_images(
    pdf_path: Path,
    out_root: Path,
    dpi: int,
    fmt: str,
    overwrite: bool,
    skip_existing: bool,
    jpg_quality: int,
) -> int:
    stem = safe_folder_name(pdf_path.stem)
    out_dir = out_root / stem
    out_dir.mkdir(parents=True, exist_ok=True)

    scale = dpi / 72.0
    matrix = fitz.Matrix(scale, scale)

    try:
        doc = fitz.open(pdf_path)
    except Exception as e:
        print(f"[ERROR] Open failed: {pdf_path.name}: {e}", file=sys.stderr)
        return 0

    try:
        if doc.is_encrypted:
            ok = doc.authenticate("")
            if not ok:
                print(f"[ERROR] Encrypted (password required): {pdf_path.name}", file=sys.stderr)
                doc.close()
                return 0
    except Exception as e:
        print(f"[ERROR] Encryption check failed: {pdf_path.name}: {e}", file=sys.stderr)
        doc.close()
        return 0

    page_count = doc.page_count

    for i in range(page_count):
        page_num = i + 1
        out_file = out_dir / f"page_{page_num:04d}.{fmt}"

        if out_file.exists():
            if skip_existing:
                continue
            if not overwrite:
                # If you're running multiple times, this prevents accidental clobber
                continue

        try:
            page = doc.load_page(i)
            pix = page.get_pixmap(matrix=matrix, alpha=False)

            if fmt in ("jpg", "jpeg"):
                pix.save(str(out_file), output="jpg", jpg_quality=jpg_quality)
            else:
                pix.save(str(out_file))

        except Exception as e:
            print(
                f"[WARN] Page render failed: {pdf_path.name} page {page_num}/{page_count}: {e}",
                file=sys.stderr,
            )
            continue

    doc.close()
    print(f"[OK] {pdf_path.name} -> {out_dir} ({page_count} pages)")
    return page_count


def main() -> int:
    p = argparse.ArgumentParser(
        description="Convert all PDFs in a folder into per-page images (one folder per PDF), with optional dedupe."
    )
    p.add_argument("--input-dir", default=".", help="Folder containing PDFs (default: current folder).")
    p.add_argument("--output-dir", default="images_out", help="Output root (default: ./images_out).")
    p.add_argument("--dpi", type=int, default=400, help="Render DPI (default: 400). Typical: 300–600.")
    p.add_argument("--format", choices=["jpg", "jpeg", "png"], default="jpg", help="Image format (default: jpg).")
    p.add_argument("--jpg-quality", type=int, default=85, help="JPG quality 0–100 (default: 85).")
    p.add_argument("--overwrite", action="store_true", help="Overwrite existing images.")
    p.add_argument("--skip-existing", action="store_true", help="Skip pages that already have an output image.")

    # Dedupe controls
    p.add_argument(
        "--dedupe",
        action="store_true",
        help="Dedupe identical PDFs by SHA-256 before rendering.",
    )
    p.add_argument(
        "--dedupe-mode",
        choices=["skip", "alias"],
        default="skip",
        help="What to do with duplicates: skip (default) or alias (make a folder with a _DUPLICATE_OF.txt).",
    )

    args = p.parse_args()

    in_dir = Path(args.input_dir).resolve()
    out_root = Path(args.output_dir).resolve()
    out_root.mkdir(parents=True, exist_ok=True)

    fmt = "jpg" if args.format == "jpeg" else args.format

    pdfs = sorted(in_dir.glob("*.pdf"))
    if not pdfs:
        print(f"[INFO] No PDFs found in: {in_dir}")
        return 0

    # hash -> first-seen PDF path
    seen: dict[str, Path] = {}

    for pdf in pdfs:
        if args.dedupe:
            try:
                h = sha256_file(pdf)
            except Exception as e:
                print(f"[WARN] Hash failed, will process anyway: {pdf.name}: {e}", file=sys.stderr)
                h = None

            if h and h in seen:
                original = seen[h]
                print(f"[DUPE] {pdf.name} is identical to {original.name}")

                if args.dedupe_mode == "alias":
                    dup_dir = out_root / safe_folder_name(pdf.stem)
                    dup_dir.mkdir(parents=True, exist_ok=True)
                    marker = dup_dir / "_DUPLICATE_OF.txt"
                    marker.write_text(
                        f"This PDF is byte-identical to:\n{original.name}\n"
                        f"Original output folder:\n{safe_folder_name(original.stem)}\n",
                        encoding="utf-8",
                    )
                continue

            if h:
                seen[h] = pdf

        render_pdf_to_images(
            pdf_path=pdf,
            out_root=out_root,
            dpi=args.dpi,
            fmt=fmt,
            overwrite=args.overwrite,
            skip_existing=args.skip_existing,
            jpg_quality=args.jpg_quality,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
