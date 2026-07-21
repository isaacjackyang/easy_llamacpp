#!/usr/bin/env python3
"""Finalize OCR-redrawn, image-only PDFs without sending them to BabelDOC."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

import fitz


NOT_IMAGE_ONLY = 3


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--original", required=True, type=Path)
    parser.add_argument("--translated", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--target-language", required=True)
    parser.add_argument("--output-mode", choices=("mono", "dual", "both"), default="both")
    parser.add_argument("--report-json", required=True, type=Path)
    return parser.parse_args()


def has_extractable_text(document: fitz.Document) -> bool:
    return any(page.get_text("text").strip() for page in document)


def create_dual(original: fitz.Document, translated: fitz.Document, output: Path) -> None:
    if original.page_count != translated.page_count:
        raise ValueError(
            f"Page-count mismatch: original={original.page_count}, translated={translated.page_count}"
        )
    temporary = output.with_name(output.stem + ".partial.pdf")
    temporary.unlink(missing_ok=True)
    dual = fitz.open()
    try:
        for page_number in range(original.page_count):
            source_page = original[page_number]
            translated_page = translated[page_number]
            height = max(source_page.rect.height, translated_page.rect.height)
            source_width = source_page.rect.width * height / source_page.rect.height
            translated_width = translated_page.rect.width * height / translated_page.rect.height
            page = dual.new_page(width=source_width + translated_width, height=height)
            page.show_pdf_page(fitz.Rect(0, 0, source_width, height), original, page_number)
            page.show_pdf_page(
                fitz.Rect(source_width, 0, source_width + translated_width, height),
                translated,
                page_number,
            )
        dual.save(temporary, garbage=3, deflate=True)
        temporary.replace(output)
    finally:
        dual.close()
        temporary.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    original_path = args.original.resolve()
    translated_path = args.translated.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    report_path = args.report_json.resolve()
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if report.get("schema_version") != 1:
        raise ValueError(f"Unsupported image-stage report: {report_path}")
    if Path(str(report.get("input_pdf", ""))).resolve() != original_path:
        raise ValueError("Image-stage report does not match the original PDF")
    if Path(str(report.get("output_pdf", ""))).resolve() != translated_path:
        raise ValueError("Image-stage report does not match the translated PDF")

    original = fitz.open(original_path)
    translated = fitz.open(translated_path)
    try:
        if has_extractable_text(original):
            return NOT_IMAGE_ONLY
        if int(report.get("translated_items", 0) or 0) < 1:
            raise ValueError("OCR/image translation produced zero translated text regions")

        stem = original_path.stem
        prefix = f"{stem}.no_watermark.{args.target_language}"
        outputs: list[Path] = []
        if args.output_mode in ("mono", "both"):
            mono_path = output_dir / f"{prefix}.mono.pdf"
            mono_temp = mono_path.with_name(mono_path.stem + ".partial.pdf")
            try:
                shutil.copyfile(translated_path, mono_temp)
                mono_temp.replace(mono_path)
            finally:
                mono_temp.unlink(missing_ok=True)
            outputs.append(mono_path)
        if args.output_mode in ("dual", "both"):
            dual_path = output_dir / f"{prefix}.dual.pdf"
            create_dual(original, translated, dual_path)
            outputs.append(dual_path)
    finally:
        original.close()
        translated.close()

    print("Translation complete:")
    for output in sorted(outputs):
        print(f"  {output}")
    print("Image-only source detected; BabelDOC paragraph stage was skipped.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # noqa: BLE001 - command-line boundary
        print(f"ERROR: Failed to finalize scanned PDF: {error}", file=sys.stderr)
        raise SystemExit(1)
