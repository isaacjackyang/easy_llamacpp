from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import fitz


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "finalize_scanned_pdf.py"


def make_pdf(path: Path, *, text: str = "") -> None:
    document = fitz.open()
    page = document.new_page(width=200, height=300)
    page.draw_rect(fitz.Rect(10, 10, 190, 290), color=(0, 0, 0))
    if text:
        page.insert_text((20, 40), text)
    document.save(path)
    document.close()


class FinalizeScannedPdfTests(unittest.TestCase):
    def run_finalizer(self, root: Path, *, source_text: str = "", translated_items: int = 1):
        original = root / "source.pdf"
        translated = root / "translated.pdf"
        output = root / "out"
        report = root / "report.json"
        make_pdf(original, text=source_text)
        make_pdf(translated)
        report.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "input_pdf": str(original.resolve()),
                    "output_pdf": str(translated.resolve()),
                    "translated_items": translated_items,
                }
            ),
            encoding="utf-8",
        )
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--original",
                str(original),
                "--translated",
                str(translated),
                "--output-dir",
                str(output),
                "--target-language",
                "zh-TW",
                "--output-mode",
                "both",
                "--report-json",
                str(report),
            ],
            capture_output=True,
            text=True,
        )
        return result, output

    def test_image_only_pdf_creates_verified_mono_and_dual_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.run_finalizer(Path(directory))
            self.assertEqual(result.returncode, 0, result.stderr)
            mono = output / "source.no_watermark.zh-TW.mono.pdf"
            dual = output / "source.no_watermark.zh-TW.dual.pdf"
            self.assertTrue(mono.is_file())
            self.assertTrue(dual.is_file())
            with fitz.open(dual) as document:
                self.assertEqual(document.page_count, 1)
                self.assertEqual(document[0].rect.width, 400)

    def test_text_pdf_is_left_for_babeldoc(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.run_finalizer(Path(directory), source_text="paragraph")
            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertFalse(output.exists() and any(output.glob("*.pdf")))

    def test_zero_ocr_translations_is_not_reported_as_success(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.run_finalizer(Path(directory), translated_items=0)
            self.assertEqual(result.returncode, 1)
            self.assertIn("zero translated text regions", result.stderr)
            self.assertFalse(output.exists() and any(output.glob("*.pdf")))


if __name__ == "__main__":
    unittest.main()
