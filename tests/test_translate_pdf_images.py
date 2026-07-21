from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "translate_pdf_images.py"
SPEC = importlib.util.spec_from_file_location("translate_pdf_images", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class TranslatePdfImagesTests(unittest.TestCase):
    def test_four_point_polygon_orientation_is_preserved(self):
        polygon = MODULE.normalized_polygon(
            [[10, 10], [90, 30], [85, 50], [5, 30]], 100, 100
        )
        self.assertEqual(polygon, [[100, 100], [900, 300], [850, 500], [50, 300]])
        self.assertAlmostEqual(MODULE.polygon_orientation(polygon), 14.04, places=2)
        self.assertEqual(MODULE.polygon_direction(14.04), "rotated")

    def test_paddle_response_preserves_polygon_confidence_and_order(self):
        payload = {
            "pages": [
                {
                    "rec_texts": ["Hello"],
                    "rec_scores": [0.93],
                    "rec_polys": [[[10, 20], [110, 20], [110, 50], [10, 50]]],
                }
            ]
        }
        regions = MODULE.parse_paddle_regions(
            payload, Image.new("RGB", (200, 100), "white"), "paddle-ppocrv6"
        )
        self.assertEqual(len(regions), 1)
        self.assertEqual(regions[0]["polygon"], [[50, 200], [550, 200], [550, 500], [50, 500]])
        self.assertEqual(regions[0]["confidence"], 0.93)
        self.assertEqual(regions[0]["reading_order"], 0)

    def test_hybrid_ocr_falls_back_to_rapid_when_paddle_is_offline(self):
        config = {
            "provider": "auto",
            "paddle_base_url": "http://127.0.0.1:8765",
            "timeout": 1,
            "minimum_confidence": 0.55,
            "structure_assist": "off",
        }
        rapid = [{"bbox": [1, 1, 10, 10], "source": "fallback", "confidence": 0.9}]
        with patch.object(MODULE, "detect_paddle_ocr", side_effect=RuntimeError("GPU OOM")), patch.object(
            MODULE, "detect_rapidocr", return_value=rapid
        ):
            regions, diagnostics = MODULE.detect_hybrid_ocr(
                Image.new("RGB", (20, 20), "white"), config
            )
        self.assertEqual(regions, rapid)
        self.assertTrue(diagnostics["fallback"])
        self.assertIn("GPU OOM", diagnostics["fallback_reason"])

    def test_unlimited_box_is_replaced_by_paddle_crop_polygon(self):
        paddle_crop = [
            {
                "bbox": [100, 100, 900, 900],
                "polygon": [[100, 100], [900, 100], [900, 900], [100, 900]],
                "source": "missed text",
                "confidence": 0.91,
                "orientation_degrees": 0.0,
                "text_direction": "horizontal",
                "detector": "paddle-ppocrv6",
            }
        ]
        with patch.object(MODULE, "detect_paddle_ocr", return_value=paddle_crop):
            additions = MODULE.relocalize_unlimited_regions(
                Image.new("RGB", (1000, 1000), "white"),
                [],
                [{"source": "missed text", "bbox": [200, 200, 600, 400]}],
                "http://127.0.0.1:8765",
                1,
            )
        self.assertEqual(len(additions), 1)
        self.assertEqual(additions[0]["detector"], "paddle-ppocrv6-unlimited-relocalized")
        self.assertNotEqual(additions[0]["bbox"], [200, 200, 600, 400])
        self.assertTrue(additions[0]["unlimited_assisted"])

    def test_grouping_preserves_source_polygons(self):
        items = [
            {
                "bbox": [100, 100, 300, 120],
                "polygon": [[100, 100], [300, 100], [300, 120], [100, 120]],
                "source": "A line",
                "confidence": 0.9,
                "orientation_degrees": 0.0,
                "text_direction": "horizontal",
                "detector": "paddle-ppocrv6",
            }
        ]
        grouped = MODULE.group_ocr_lines(items)
        self.assertEqual(grouped[0]["source_regions"][0]["polygon"], items[0]["polygon"])

    def test_sensitive_ocr_accepts_plausible_missed_sentence(self):
        self.assertTrue(
            MODULE.plausible_english_ocr(
                "Place all your problems and distractions in the Security Repository Box."
            )
        )

    def test_sensitive_ocr_rejects_gibberish(self):
        self.assertFalse(
            MODULE.plausible_english_ocr(
                "Keu aeun aoinos Xue ioata1 pue aouanrrut yons woiy papaau aq Kew se ytasku"
            )
        )
        self.assertFalse(
            MODULE.plausible_english_ocr(
                "ue st aiaun heun mouy ttrm nok Aue aas nok saods 6utiayoity pue urp aun 1oy xooi"
            )
        )

    def test_strict_traditional_chinese_rejects_latin_gibberish(self):
        self.assertFalse(
            MODULE.translation_matches_target(
                "以 Kpoq aua xeiar pue sared 為基準", "zh-TW", strict=True
            )
        )
        self.assertTrue(
            MODULE.translation_matches_target(
                "將所有問題放入安全儲存箱中", "zh-TW", strict=True
            )
        )

    def test_document_codes_are_not_translation_units(self):
        self.assertFalse(MODULE.should_translate_ocr_text("RBX -1", "en"))
        self.assertFalse(MODULE.should_translate_ocr_text("C-1", "en"))
        self.assertFalse(MODULE.should_translate_ocr_text("RB X-2", "en"))
        self.assertFalse(MODULE.should_translate_ocr_text("REBAL II", "en"))
        self.assertFalse(MODULE.should_translate_ocr_text("ECLBM 02", "en"))
        self.assertFalse(MODULE.should_translate_ocr_text("ECEBM O1", "en"))
        self.assertFalse(MODULE.should_translate_ocr_text("e t 5 5 1", "en"))
        self.assertFalse(MODULE.should_translate_ocr_text("g 1- a g", "en"))
        self.assertFalse(MODULE.should_translate_ocr_text("yoc.", "en"))
        self.assertTrue(MODULE.should_translate_ocr_text("you", "en"))
        self.assertTrue(MODULE.should_translate_ocr_text("GATEWAY NOTES", "en"))

    def test_compass_label_line_is_nonlinguistic(self):
        self.assertTrue(MODULE.is_compass_label_line("N, NE, E, SE, S, SW, W, NW."))
        self.assertFalse(MODULE.is_compass_label_line("Walk north, then turn east."))

    def test_footer_collision_is_dropped_near_page_bottom(self):
        source = "22. Distracting Factors Approved For Release 2003/09/10: CIA-RDP96-"
        self.assertTrue(MODULE.is_footer_collision(source, [4, 953, 605, 977]))
        self.assertFalse(MODULE.is_footer_collision(source, [4, 53, 605, 77]))
        garbled = "effective theyPbiYl'Become. The more you ApBr8i8yFy RelfasE20B3 easier"
        self.assertTrue(MODULE.is_footer_collision(garbled, [86, 941, 941, 976]))

    def test_strict_target_allows_one_preserved_proper_term(self):
        translated = "\u524d\u5f80 Focus 10 \u4e26\u70ba EBT \u5145\u80fd"
        self.assertTrue(
            MODULE.translation_matches_target(translated, "zh-TW", strict=True)
        )

    def test_strict_target_allows_repeated_proper_term(self):
        translated = "\u524d\u5f80 Focus 10\uff0c\u518d\u5f9e Focus 10 \u5340\u57df\u53d6\u51fa\u526a\u5f71"
        self.assertTrue(
            MODULE.translation_matches_target(translated, "zh-TW", strict=True)
        )

    def test_same_row_fragments_merge_without_joining_next_line(self):
        items = [
            {"bbox": [100, 100, 300, 120], "source": "Do your", "confidence": 0.9},
            {"bbox": [310, 102, 500, 121], "source": "exercise", "confidence": 0.9},
            {"bbox": [100, 140, 500, 160], "source": "Next line", "confidence": 0.9},
        ]
        merged = MODULE.group_ocr_same_row(items)
        self.assertEqual(len(merged), 2)
        self.assertEqual(merged[0]["source"], "Do your exercise")
        self.assertEqual(merged[1]["source"], "Next line")

    def test_big5_mojibake_is_repaired(self):
        source = "\u7b2c\u4e00\u7a2e\u65b9\u6cd5"
        mojibake = source.encode("cp950").decode("latin1")
        repaired = MODULE.repair_big5_mojibake(mojibake)
        self.assertEqual(source, repaired)

    def test_big5_mojibake_with_ascii_terms_is_repaired(self):
        source = "\u7b2c\u4e00\u7a2e\u65b9\u6cd5\uff1a\u524d\u5f80 Focus 10 \u7684 EBT"
        mojibake = source.encode("cp950").decode("latin1")
        repaired = MODULE.repair_big5_mojibake(mojibake)
        self.assertEqual(source, repaired)


if __name__ == "__main__":
    unittest.main()
