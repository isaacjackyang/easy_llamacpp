#!/usr/bin/env python3
"""Translate raster PDF text with PaddleOCR-first, polygon-aware redrawing.

PP-OCRv6 is the primary detector. RapidOCR is the local fallback, while
PP-StructureV3 and Unlimited-OCR are optional assistive readers. Unlimited-OCR
coordinates are never used for erasing: every proposed region must first be
relocalized by PaddleOCR.
"""

from __future__ import annotations

import argparse
import base64
import difflib
import hashlib
import json
import math
import re
import sys
import time
from pathlib import Path

import fitz
import numpy as np
import requests
from PIL import Image, ImageDraw, ImageFont

try:
    from rapidocr_onnxruntime import RapidOCR
except ImportError as exc:
    raise RuntimeError(
        "RapidOCR is required in the BabelDOC venv: install rapidocr_onnxruntime"
    ) from exc


DEFAULT_FONT = Path(r"C:\Windows\Fonts\msjh.ttc")
OCR_ENGINE: RapidOCR | None = None
OCR_ENGINE_SENSITIVE: RapidOCR | None = None
COMMON_ENGLISH_WORDS = {
    "a", "about", "all", "an", "and", "are", "as", "at", "be", "been",
    "body", "box", "but", "by", "can", "do", "each", "for", "from", "had",
    "has", "have", "he", "her", "his", "how", "i", "if", "in", "into",
    "is", "it", "its", "may", "more", "no", "not", "of", "on", "one",
    "or", "our", "out", "place", "problems", "repository", "security",
    "she", "so", "some", "such", "than", "that", "the", "their", "them",
    "then", "there", "these", "they", "this", "through", "to", "two", "up",
    "use", "was", "we", "were", "what", "when", "which", "while", "will",
    "with", "you", "your",
}
PYDEPS_DIR = Path(__file__).resolve().parent.parent / ".cache" / "pydeps"
if PYDEPS_DIR.is_dir():
    sys.path.insert(0, str(PYDEPS_DIR))
try:
    from opencc import OpenCC
except ImportError:
    OpenCC = None  # type: ignore[assignment]

try:
    TRADITIONAL_CONVERTER = OpenCC("s2twp") if OpenCC is not None else None
except Exception:
    TRADITIONAL_CONVERTER = None
FALLBACK_TRADITIONAL_MAP = str.maketrans(
    {
        "国": "國",
        "军": "軍",
        "门": "門",
        "罗": "羅",
        "应": "應",
        "学": "學",
        "级": "級",
        "陆": "陸",
        "马": "馬",
        "兰": "蘭",
        "乔": "喬",
        "题": "題",
        "过": "過",
        "与": "與",
        "评": "評",
        "机": "機",
        "终": "終",
        "实": "實",
        "进": "進",
        "够": "夠",
        "辅": "輔",
        "该": "該",
        "运": "運",
        "这": "這",
        "项": "項",
        "极": "極",
        "复": "複",
        "难": "難",
        "医": "醫",
        "师": "師",
        "对": "對",
        "话": "話",
        "参": "參",
        "层": "層",
        "资": "資",
        "讯": "訊",
        "随": "隨",
        "获": "獲",
        "类": "類",
        "识": "識",
        "质": "質",
        "须": "須",
        "构": "構",
        "个": "個",
        "说": "說",
        "采": "採",
        "脑": "腦",
        "术": "術",
        "响": "響",
        "骤": "驟",
        "后": "後",
        "论": "論",
        "释": "釋",
        "时": "時",
        "维": "維",
        "扩": "擴",
        "发": "發",
        "现": "現",
        "将": "將",
        "状": "狀",
        "态": "態",
        "纳": "納",
        "语": "語",
        "义": "義",
        "污": "污",
        "于": "於",
        "观": "觀",
        "框": "框",
        "梦": "夢",
        "体": "體",
        "验": "驗",
        "书": "書",
        "仅": "僅",
        "私": "私",
        "尝": "嘗",
        "权": "權",
        "损": "損",
        "害": "害",
        "邮": "郵",
        "箱": "箱",
    }
)


def to_traditional_taiwan(text: str) -> str:
    if not text:
        return text
    if TRADITIONAL_CONVERTER is not None:
        text = TRADITIONAL_CONVERTER.convert(text)
    else:
        text = text.translate(FALLBACK_TRADITIONAL_MAP)
    phrase_replacements = {
        "批准": "核准",
        "研究所": "研究院",
        "資訊和安全司令部": "情報與安全司令部",
        "實用性": "實務性",
        "品質": "品質",
        "程式": "程式",
        "蓋特威": "Gateway",
    }
    for source, replacement in phrase_replacements.items():
        text = text.replace(source, replacement)
    return text


def repair_big5_mojibake(text: str) -> str:
    if re.search(r"[\u3400-\u9fff]", text):
        return text
    try:
        repaired = text.encode("latin1").decode("cp950")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text
    return repaired if re.search(r"[\u3400-\u9fff]", repaired) else text


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-pdf", required=True)
    parser.add_argument("--output-pdf")
    parser.add_argument("--base-url", default="http://127.0.0.1:8080/v1")
    parser.add_argument("--model", required=True)
    parser.add_argument("--source-language", default="en")
    parser.add_argument("--target-language", default="zh-TW")
    parser.add_argument("--pages", default="")
    parser.add_argument("--font", default=str(DEFAULT_FONT))
    parser.add_argument("--cache-dir", default="")
    parser.add_argument("--report-json", default="")
    parser.add_argument("--min-area-ratio", type=float, default=0.015)
    parser.add_argument("--max-images-per-page", type=int, default=12)
    parser.add_argument("--max-image-dimension", type=int, default=1800)
    parser.add_argument("--flatten-pages", action="store_true")
    parser.add_argument("--page-render-zoom", type=float, default=2.0)
    parser.add_argument("--timeout-seconds", type=int, default=300)
    parser.add_argument(
        "--ocr-provider", choices=("auto", "paddle", "rapid"), default="auto"
    )
    parser.add_argument("--paddle-ocr-base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--paddle-min-confidence", type=float, default=0.55)
    parser.add_argument(
        "--structure-assist", choices=("auto", "off", "always"), default="auto"
    )
    parser.add_argument("--unlimited-ocr-base-url", default="")
    parser.add_argument("--unlimited-ocr-model", default="")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def parse_pages(spec: str, page_count: int) -> set[int]:
    if not spec or spec.lower() == "all":
        return set(range(page_count))
    result: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            left, right = part.split("-", 1)
            start = int(left) if left else 1
            end = int(right) if right else page_count
            result.update(range(max(1, start) - 1, min(page_count, end)))
        else:
            value = int(part)
            if 1 <= value <= page_count:
                result.add(value - 1)
    return result


def image_candidates(page: fitz.Page, min_area_ratio: float, limit: int) -> list[dict]:
    page_area = max(1.0, page.rect.width * page.rect.height)
    candidates: list[dict] = []
    seen: set[tuple[int, int, int, int]] = set()
    smasks = {int(item[0]): int(item[1]) for item in page.get_images(full=True)}
    for info in page.get_image_info(xrefs=True):
        rect = fitz.Rect(info.get("bbox", (0, 0, 0, 0))) & page.rect
        xref = int(info.get("xref", 0) or 0)
        if rect.is_empty or rect.width < 36 or rect.height < 24:
            continue
        if (rect.width * rect.height) / page_area < min_area_ratio:
            continue
        key = tuple(round(v * 2) for v in (rect.x0, rect.y0, rect.x1, rect.y1))
        if key in seen:
            continue
        seen.add(key)
        candidates.append({"rect": rect, "xref": xref, "smask": smasks.get(xref, 0)})
    candidates.sort(key=lambda item: item["rect"].width * item["rect"].height, reverse=True)
    return candidates[:limit]


def extract_xref_image(doc: fitz.Document, xref: int) -> Image.Image:
    pix = fitz.Pixmap(doc, xref)
    if pix.colorspace is None or pix.colorspace.n != 3 or pix.alpha:
        converted = fitz.Pixmap(fitz.csRGB, pix)
        pix = converted
    return Image.frombytes("RGB", (pix.width, pix.height), pix.samples)


def downscale(image: Image.Image, max_dimension: int) -> Image.Image:
    largest = max(image.size)
    if largest <= max_dimension:
        return image
    ratio = max_dimension / largest
    return image.resize(
        (max(1, round(image.width * ratio)), max(1, round(image.height * ratio))),
        Image.Resampling.LANCZOS,
    )


def png_bytes(image: Image.Image) -> bytes:
    import io

    buffer = io.BytesIO()
    # Pillow's optimized PNG stream can produce image objects that render as
    # black blocks in some Poppler versions after PyMuPDF inserts the stream.
    image.save(buffer, format="PNG", optimize=False)
    return buffer.getvalue()


def cache_key(
    image_bytes: bytes, source: str, target: str, model: str, pipeline: str
) -> str:
    digest = hashlib.sha256()
    digest.update(image_bytes)
    digest.update(f"\0{source}\0{target}\0{model}\0{pipeline}".encode())
    return digest.hexdigest()


def extract_json_object(text: str) -> dict:
    cleaned = text.strip()
    cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.I)
    cleaned = re.sub(r"\s*```$", "", cleaned)
    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start < 0 or end <= start:
        raise ValueError(f"Model did not return JSON: {text[:300]}")
    return json.loads(cleaned[start : end + 1])


def normalized_box(points: object, width: int, height: int) -> list[int] | None:
    if not isinstance(points, (list, tuple)) or len(points) < 2:
        return None
    try:
        xs = [float(point[0]) for point in points]
        ys = [float(point[1]) for point in points]
    except (TypeError, ValueError, IndexError):
        return None
    x0 = max(0, min(1000, round(min(xs) * 1000 / width)))
    y0 = max(0, min(1000, round(min(ys) * 1000 / height)))
    x1 = max(0, min(1000, round(max(xs) * 1000 / width)))
    y1 = max(0, min(1000, round(max(ys) * 1000 / height)))
    if x1 - x0 < 2 or y1 - y0 < 2:
        return None
    return [x0, y0, x1, y1]


def normalized_polygon(points: object, width: int, height: int) -> list[list[int]] | None:
    """Return the detector's complete four-point polygon on a 0..1000 canvas."""
    if not isinstance(points, (list, tuple)) or len(points) != 4:
        return None
    polygon: list[list[int]] = []
    try:
        for point in points:
            polygon.append(
                [
                    max(0, min(1000, round(float(point[0]) * 1000 / width))),
                    max(0, min(1000, round(float(point[1]) * 1000 / height))),
                ]
            )
    except (TypeError, ValueError, IndexError):
        return None
    if normalized_box(polygon, 1000, 1000) is None:
        return None
    return polygon


def polygon_box(polygon: list[list[int]]) -> list[int]:
    return [
        min(point[0] for point in polygon),
        min(point[1] for point in polygon),
        max(point[0] for point in polygon),
        max(point[1] for point in polygon),
    ]


def polygon_orientation(polygon: list[list[int]]) -> float:
    angle = math.degrees(
        math.atan2(polygon[1][1] - polygon[0][1], polygon[1][0] - polygon[0][0])
    )
    while angle > 90:
        angle -= 180
    while angle <= -90:
        angle += 180
    return round(angle, 2)


def polygon_direction(angle: float) -> str:
    if abs(angle) <= 8:
        return "horizontal"
    if abs(angle) >= 82:
        return "vertical"
    return "rotated"


def make_ocr_region(
    points: object,
    source: object,
    confidence: object,
    width: int,
    height: int,
    detector: str,
) -> dict | None:
    text = str(source).strip()
    try:
        score = float(confidence)
    except (TypeError, ValueError):
        return None
    polygon = normalized_polygon(points, width, height)
    if not text or polygon is None:
        return None
    angle = polygon_orientation(polygon)
    return {
        "bbox": polygon_box(polygon),
        "polygon": polygon,
        "source": text,
        "confidence": round(score, 4),
        "orientation_degrees": angle,
        "text_direction": polygon_direction(angle),
        "detector": detector,
    }


def detect_rapidocr(image: Image.Image, sensitive: bool = False) -> list[dict]:
    global OCR_ENGINE, OCR_ENGINE_SENSITIVE
    if sensitive:
        if OCR_ENGINE_SENSITIVE is None:
            OCR_ENGINE_SENSITIVE = RapidOCR(
                det_limit_side_len=1600,
                det_thresh=0.15,
                det_box_thresh=0.25,
                det_unclip_ratio=1.8,
            )
        engine = OCR_ENGINE_SENSITIVE
    else:
        if OCR_ENGINE is None:
            OCR_ENGINE = RapidOCR()
        engine = OCR_ENGINE
    result, _ = engine(np.asarray(image.convert("RGB")))
    detected: list[dict] = []
    for entry in result or []:
        if not isinstance(entry, (list, tuple)) or len(entry) < 3:
            continue
        source = str(entry[1]).strip()
        try:
            confidence = float(entry[2])
        except (TypeError, ValueError):
            continue
        # Single Latin fragments are common beside rotated chart labels. They
        # are not useful translation units and can duplicate a complete word.
        if confidence < 0.55 or not source or (len(source) == 1 and source.isascii() and source.isalpha()):
            continue
        region = make_ocr_region(
            entry[0], source, confidence, image.width, image.height, "rapidocr"
        )
        if region is None:
            continue
        detected.append(region)
    return detected


def paddle_ocr_endpoint(base_url: str) -> str:
    base = base_url.rstrip("/")
    return base + "/ocr" if base.endswith("/v1") else base + "/v1/ocr"


def iter_recognition_payloads(value: object):
    """Yield Paddle result objects that carry parallel OCR result arrays."""
    if isinstance(value, dict):
        if all(key in value for key in ("rec_texts", "rec_scores", "rec_polys")):
            yield value
        for child in value.values():
            yield from iter_recognition_payloads(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_recognition_payloads(child)


def parse_paddle_regions(
    payload: object, image: Image.Image, detector: str
) -> list[dict]:
    regions: list[dict] = []
    seen: set[tuple[str, tuple[int, ...]]] = set()
    for result in iter_recognition_payloads(payload):
        texts = result.get("rec_texts", [])
        scores = result.get("rec_scores", [])
        polygons = result.get("rec_polys", [])
        if not isinstance(texts, list) or not isinstance(polygons, list):
            continue
        for index, text_value in enumerate(texts):
            if index >= len(polygons):
                continue
            score = scores[index] if isinstance(scores, list) and index < len(scores) else 0.0
            region = make_ocr_region(
                polygons[index], text_value, score, image.width, image.height, detector
            )
            if region is None:
                continue
            key = (
                region["source"].casefold(),
                tuple(value for point in region["polygon"] for value in point),
            )
            if key in seen:
                continue
            seen.add(key)
            region["reading_order"] = len(regions)
            regions.append(region)
    return regions


def detect_paddle_ocr(
    image: Image.Image,
    base_url: str,
    timeout: int,
    mode: str = "ppocrv6",
    sensitive: bool = False,
) -> list[dict]:
    options = {}
    if sensitive:
        options = {
            "text_det_limit_side_len": 1600,
            "text_det_thresh": 0.15,
            "text_det_box_thresh": 0.25,
            "text_det_unclip_ratio": 1.8,
            "text_rec_score_thresh": 0.0,
        }
    payload = {
        "filename": "ocr-page.png",
        "data_base64": base64.b64encode(png_bytes(image.convert("RGB"))).decode("ascii"),
        "mode": mode,
        "score_threshold": 0.0,
        "coordinate_mode": True,
        "options": options,
    }
    response = requests.post(
        paddle_ocr_endpoint(base_url), json=payload, timeout=max(15, timeout)
    )
    response.raise_for_status()
    body = response.json()
    if isinstance(body, dict) and body.get("ok") is False:
        raise RuntimeError(str(body.get("error") or "PaddleOCR service rejected request"))
    detector = "paddle-ppstructurev3" if mode == "ppstructurev3" else "paddle-ppocrv6"
    return parse_paddle_regions(body, image, detector)


def looks_like_table(regions: list[dict]) -> bool:
    if len(regions) < 6:
        return False
    rows: list[list[dict]] = []
    for item in sorted(regions, key=lambda value: (value["bbox"][1], value["bbox"][0])):
        center = (item["bbox"][1] + item["bbox"][3]) / 2
        height = max(1, item["bbox"][3] - item["bbox"][1])
        row = next(
            (
                candidate
                for candidate in reversed(rows[-4:])
                if abs(
                    center
                    - sum((cell["bbox"][1] + cell["bbox"][3]) / 2 for cell in candidate)
                    / len(candidate)
                )
                <= height * 0.65
            ),
            None,
        )
        if row is None:
            rows.append([item])
        else:
            row.append(item)
    return sum(1 for row in rows if len(row) >= 2) >= 3


def ocr_assist_reasons(regions: list[dict], minimum_confidence: float) -> list[str]:
    if not regions:
        return ["missed-page"]
    scores = [float(item.get("confidence", 0.0)) for item in regions]
    reasons: list[str] = []
    if sum(score < minimum_confidence for score in scores) / len(scores) >= 0.20:
        reasons.append("low-confidence")
    if sum(scores) / len(scores) < max(0.72, minimum_confidence + 0.12):
        reasons.append("low-mean-confidence")
    if looks_like_table(regions):
        reasons.append("table-layout")
    return reasons


def text_similarity(left: str, right: str) -> float:
    normalize = lambda value: re.sub(r"\W+", "", value, flags=re.UNICODE).casefold()
    return difflib.SequenceMatcher(None, normalize(left), normalize(right)).ratio()


def merge_structure_regions(primary: list[dict], structure: list[dict]) -> list[dict]:
    """Use PP-Structure order and add only its genuinely missing precise polygons."""
    merged = list(primary)
    for order, candidate in enumerate(structure):
        match = next(
            (
                item
                for item in merged
                if overlap_ratio(candidate["bbox"], item["bbox"]) >= 0.45
                and text_similarity(candidate["source"], item["source"]) >= 0.45
            ),
            None,
        )
        if match is not None:
            match["reading_order"] = order
            match["structure_assisted"] = True
            continue
        candidate["reading_order"] = order
        candidate["structure_assisted"] = True
        merged.append(candidate)
    return merged


def parse_unlimited_detections(text: str) -> list[dict]:
    """Parse coarse Unlimited-OCR boxes; callers must relocalize every result."""
    detections: list[dict] = []
    pattern = re.compile(
        r"(?:<\|det\|>)?\s*([^\[\]\n]{1,300}?)\s*"
        r"\[\s*(\d{1,4})\s*,\s*(\d{1,4})\s*,\s*(\d{1,4})\s*,\s*(\d{1,4})\s*\]",
        re.MULTILINE,
    )
    for match in pattern.finditer(text):
        source = re.sub(r"<\|/?det\|>", "", match.group(1)).strip(" :-\t")
        box = [max(0, min(1000, int(value))) for value in match.groups()[1:]]
        if source and box[2] - box[0] >= 2 and box[3] - box[1] >= 2:
            detections.append({"source": source, "bbox": box})
    return detections


def request_unlimited_detections(
    image: Image.Image, base_url: str, model: str, timeout: int
) -> list[dict]:
    payload = {
        "model": model,
        "temperature": 0,
        "max_tokens": 4096,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "<|grounding|>OCR this image."},
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": "data:image/png;base64,"
                            + base64.b64encode(png_bytes(image.convert("RGB"))).decode("ascii")
                        },
                    },
                ],
            }
        ],
    }
    return parse_unlimited_detections(
        post_chat_text(payload, base_url, timeout, "Unlimited-OCR assist")
    )


def remap_crop_region(region: dict, crop_box: list[int]) -> dict:
    x0, y0, x1, y1 = crop_box
    polygon = [
        [
            round(x0 + point[0] * (x1 - x0) / 1000),
            round(y0 + point[1] * (y1 - y0) / 1000),
        ]
        for point in region["polygon"]
    ]
    remapped = dict(region)
    remapped["polygon"] = polygon
    remapped["bbox"] = polygon_box(polygon)
    remapped["orientation_degrees"] = polygon_orientation(polygon)
    remapped["text_direction"] = polygon_direction(remapped["orientation_degrees"])
    remapped["detector"] = "paddle-ppocrv6-unlimited-relocalized"
    remapped["unlimited_assisted"] = True
    return remapped


def relocalize_unlimited_regions(
    image: Image.Image,
    primary: list[dict],
    coarse_regions: list[dict],
    paddle_base_url: str,
    timeout: int,
) -> list[dict]:
    """Accept Unlimited suggestions only after crop-level Paddle localization."""
    additions: list[dict] = []
    for coarse in coarse_regions[:12]:
        if any(text_similarity(coarse["source"], item["source"]) >= 0.82 for item in primary):
            continue
        x0, y0, x1, y1 = coarse["bbox"]
        pad_x, pad_y = max(5, (x1 - x0) // 12), max(5, (y1 - y0) // 8)
        crop_box = [max(0, x0 - pad_x), max(0, y0 - pad_y), min(1000, x1 + pad_x), min(1000, y1 + pad_y)]
        pixels = (
            math.floor(crop_box[0] * image.width / 1000),
            math.floor(crop_box[1] * image.height / 1000),
            math.ceil(crop_box[2] * image.width / 1000),
            math.ceil(crop_box[3] * image.height / 1000),
        )
        crop = image.crop(pixels)
        if crop.width < 2 or crop.height < 2:
            continue
        localized = detect_paddle_ocr(
            crop.resize((crop.width * 2, crop.height * 2)),
            paddle_base_url,
            timeout,
            sensitive=True,
        )
        for region in localized:
            remapped = remap_crop_region(region, crop_box)
            if any(overlap_ratio(remapped["bbox"], item["bbox"]) >= 0.65 for item in primary + additions):
                continue
            additions.append(remapped)
    return additions


def detect_hybrid_ocr(image: Image.Image, config: dict, sensitive: bool = False) -> tuple[list[dict], dict]:
    provider = config.get("provider", "auto")
    diagnostics = {"requested_provider": provider, "provider": "rapidocr", "fallback": False, "assist_reasons": []}
    regions: list[dict]
    paddle_ready = False
    if provider != "rapid":
        try:
            regions = detect_paddle_ocr(
                image,
                config["paddle_base_url"],
                config["timeout"],
                sensitive=sensitive,
            )
            paddle_ready = True
            diagnostics["provider"] = "paddle-ppocrv6"
        except Exception as exc:  # service offline, init failure, and GPU OOM all fall back
            diagnostics["fallback"] = True
            diagnostics["fallback_reason"] = str(exc)
            print(f"      PaddleOCR unavailable ({exc}); falling back to RapidOCR")
            regions = detect_rapidocr(image, sensitive=sensitive)
    else:
        regions = detect_rapidocr(image, sensitive=sensitive)

    reasons = ocr_assist_reasons(regions, float(config.get("minimum_confidence", 0.55)))
    diagnostics["assist_reasons"] = reasons
    assist_mode = config.get("structure_assist", "auto")
    should_assist = assist_mode == "always" or (assist_mode == "auto" and bool(reasons))
    if should_assist and paddle_ready:
        try:
            structure = detect_paddle_ocr(
                image, config["paddle_base_url"], config["timeout"], mode="ppstructurev3"
            )
            regions = merge_structure_regions(regions, structure)
            diagnostics["structure_regions"] = len(structure)
        except Exception as exc:  # an assist failure must not discard primary OCR
            diagnostics["structure_error"] = str(exc)
            print(f"      PP-StructureV3 assist skipped ({exc})")
        unlimited_url = str(config.get("unlimited_base_url", "")).strip()
        unlimited_model = str(config.get("unlimited_model", "")).strip()
        if unlimited_url and unlimited_model:
            try:
                coarse = request_unlimited_detections(
                    image, unlimited_url, unlimited_model, config["timeout"]
                )
                additions = relocalize_unlimited_regions(
                    image, regions, coarse, config["paddle_base_url"], config["timeout"]
                )
                regions.extend(additions)
                diagnostics["unlimited_candidates"] = len(coarse)
                diagnostics["unlimited_relocalized"] = len(additions)
            except Exception as exc:
                diagnostics["unlimited_error"] = str(exc)
                print(f"      Unlimited-OCR assist skipped ({exc})")
    return regions, diagnostics


def union_box(items: list[dict]) -> list[int]:
    return [
        min(item["bbox"][0] for item in items),
        min(item["bbox"][1] for item in items),
        max(item["bbox"][2] for item in items),
        max(item["bbox"][3] for item in items),
    ]


def source_regions(items: list[dict]) -> list[dict]:
    regions: list[dict] = []
    for item in items:
        nested = item.get("source_regions")
        if isinstance(nested, list):
            regions.extend(region for region in nested if isinstance(region, dict))
            continue
        region = {
            key: item[key]
            for key in (
                "bbox",
                "polygon",
                "source",
                "confidence",
                "orientation_degrees",
                "text_direction",
                "detector",
                "reading_order",
            )
            if key in item
        }
        regions.append(region)
    return regions


def median(values: list[float], fallback: float = 0.0) -> float:
    if not values:
        return fallback
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def group_ocr_lines(lines: list[dict]) -> list[dict]:
    """Merge OCR lines into paragraph-like blocks before translation/redraw."""
    if not lines:
        return []
    sorted_lines = sorted(lines, key=lambda item: (item["bbox"][1], item["bbox"][0]))
    heights = [max(1, item["bbox"][3] - item["bbox"][1]) for item in sorted_lines]
    typical_height = median(heights, 18)
    max_line_gap = max(14, typical_height * 1.45)
    max_indent_delta = 95
    max_group_lines = 6
    max_group_height = max(80, typical_height * 7.5)

    groups: list[list[dict]] = []
    current: list[dict] = []
    for item in sorted_lines:
        if not current:
            current = [item]
            continue
        box = union_box(current)
        last = current[-1]["bbox"]
        item_box = item["bbox"]
        gap = item_box[1] - last[3]
        same_band = item_box[1] <= box[3] + max_line_gap
        same_column = (
            abs(item_box[0] - box[0]) <= max_indent_delta
            or abs(item_box[2] - box[2]) <= max_indent_delta
            or min(item_box[2], box[2]) - max(item_box[0], box[0]) > 0
        )
        would_be_too_tall = (max(box[3], item_box[3]) - min(box[1], item_box[1])) > max_group_height
        would_be_too_many_lines = len(current) >= max_group_lines
        if (
            gap <= max_line_gap
            and same_band
            and same_column
            and not would_be_too_tall
            and not would_be_too_many_lines
        ):
            current.append(item)
        else:
            groups.append(current)
            current = [item]
    if current:
        groups.append(current)

    merged: list[dict] = []
    for group in groups:
        ordered = sorted(group, key=lambda item: (item["bbox"][1], item["bbox"][0]))
        source = " ".join(item["source"].strip() for item in ordered if item["source"].strip())
        if not source:
            continue
        confidence_values = [float(item.get("confidence", 0.0)) for item in group]
        merged_item = {
                "bbox": union_box(group),
                "polygon": [
                    [union_box(group)[0], union_box(group)[1]],
                    [union_box(group)[2], union_box(group)[1]],
                    [union_box(group)[2], union_box(group)[3]],
                    [union_box(group)[0], union_box(group)[3]],
                ],
                "source": source,
                "confidence": round(sum(confidence_values) / max(1, len(confidence_values)), 4),
                "detector": "ocr-block",
                "line_count": len(group),
                "source_regions": source_regions(group),
            }
        if len(group) == 1:
            for key in ("orientation_degrees", "text_direction"):
                if key in group[0]:
                    merged_item[key] = group[0][key]
        merged.append(merged_item)
    return merged


def group_ocr_same_row(items: list[dict]) -> list[dict]:
    """Merge adjacent OCR fragments on one visual row without joining paragraphs."""
    if not items:
        return []
    rows: list[list[dict]] = []
    for item in sorted(
        items,
        key=lambda value: (
            (value["bbox"][1] + value["bbox"][3]) / 2,
            value["bbox"][0],
        ),
    ):
        item_box = item["bbox"]
        item_height = max(1, item_box[3] - item_box[1])
        item_center = (item_box[1] + item_box[3]) / 2
        matching_row = None
        for row in reversed(rows[-4:]):
            row_box = union_box(row)
            row_height = max(1, row_box[3] - row_box[1])
            row_center = (row_box[1] + row_box[3]) / 2
            vertical_overlap = max(
                0, min(item_box[3], row_box[3]) - max(item_box[1], row_box[1])
            )
            if (
                vertical_overlap / min(item_height, row_height) >= 0.40
                or abs(item_center - row_center) <= max(item_height, row_height) * 0.35
            ):
                matching_row = row
                break
        if matching_row is None:
            rows.append([item])
        else:
            matching_row.append(item)

    merged: list[dict] = []
    for row in rows:
        ordered = sorted(row, key=lambda value: value["bbox"][0])
        segment: list[dict] = []
        for item in ordered:
            if segment and item["bbox"][0] - segment[-1]["bbox"][2] > 120:
                merged.append(merge_ocr_row_segment(segment))
                segment = []
            segment.append(item)
        if segment:
            merged.append(merge_ocr_row_segment(segment))
    return sorted(merged, key=lambda value: (value["bbox"][1], value["bbox"][0]))


def merge_ocr_row_segment(items: list[dict]) -> dict:
    ordered = sorted(items, key=lambda value: value["bbox"][0])
    box = union_box(items)
    merged = {
        "bbox": box,
        "polygon": [[box[0], box[1]], [box[2], box[1]], [box[2], box[3]], [box[0], box[3]]],
        "source": " ".join(item["source"].strip() for item in ordered),
        "confidence": round(
            sum(float(item.get("confidence", 0.0)) for item in items) / len(items),
            4,
        ),
        "detector": "ocr-line",
        "line_count": 1,
        "source_regions": source_regions(items),
    }
    if len(items) == 1:
        for key in ("orientation_degrees", "text_direction"):
            if key in items[0]:
                merged[key] = items[0][key]
    return merged


def source_matches_language(text: str, source_language: str) -> bool:
    if source_language.lower().startswith("zh"):
        return bool(re.search(r"[\u3400-\u9fff]", text))
    if source_language.lower() == "en":
        return bool(re.search(r"[A-Za-z]", text))
    return True


def should_translate_ocr_text(text: str, source_language: str) -> bool:
    if not source_matches_language(text, source_language):
        return False
    if source_language.lower() == "en":
        compact = text.strip()
        if re.fullmatch(
            r"[A-Z](?:\s*[A-Z]){0,11}\s*[-/:]\s*[A-Z0-9-]{1,12}",
            compact,
        ):
            return False
        if re.fullmatch(r"[A-Z]{3,12}\s+[IVXLCDM]{1,8}", compact):
            return False
        code_parts = compact.split()
        if (
            len(code_parts) == 2
            and re.fullmatch(r"[A-Z]{3,12}", code_parts[0])
            and re.fullmatch(r"[A-Z0-9]{1,6}", code_parts[1])
            and re.search(r"\d", code_parts[1])
        ):
            return False
        letters = re.findall(r"[A-Za-z]", compact)
        if len(letters) <= 2 and re.search(r"\d", compact):
            return False
        alpha_tokens = re.findall(r"[A-Za-z]+", compact)
        if (
            len(alpha_tokens) == 1
            and len(alpha_tokens[0]) <= 3
            and alpha_tokens[0].lower() not in COMMON_ENGLISH_WORDS
        ):
            return False
        if (
            alpha_tokens
            and all(len(token) == 1 for token in alpha_tokens)
            and re.search(r"\d", compact)
        ):
            return False
    return True


def is_compass_label_line(text: str) -> bool:
    tokens = re.findall(r"[A-Za-z]+", repair_big5_mojibake(text).upper())
    return len(tokens) >= 4 and all(
        token in {"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
        for token in tokens
    )


def is_footer_collision(source: str, bbox: list[int]) -> bool:
    if len(bbox) != 4 or bbox[3] < 930:
        return False
    if bbox[3] >= 950 and bbox[3] - bbox[1] >= 25 and len(source) >= 60:
        return True
    fingerprint = re.search(
        r"(?:CIA|ClA|IAR)[-A-Za-z0-9]*RDP96|"
        r"(?:Approved|ApBr\w*|Relfas\w*)[^\n]{0,30}(?:Release|20\d{2})",
        source,
        flags=re.I,
    )
    return bool(fingerprint)


def plausible_english_ocr(text: str) -> bool:
    tokens = re.findall(r"[A-Za-z]+", text.lower())
    if not tokens:
        return False
    if len(tokens) <= 2:
        return text.strip().isupper() or any(
            token in COMMON_ENGLISH_WORDS for token in tokens
        )
    common_count = sum(token in COMMON_ENGLISH_WORDS for token in tokens)
    return common_count >= 3 or common_count / len(tokens) >= 0.20


def clean_pdf_text(text: str) -> str:
    def unspace_letters(match: re.Match[str]) -> str:
        return match.group(0).replace(" ", "")

    lines: list[str] = []
    for line in text.replace("\r", "\n").split("\n"):
        line = re.sub(r"\s+", " ", line).strip()
        if not line:
            continue
        line = re.sub(r"\b(?:[A-Za-z]\s+){2,}[A-Za-z]\b", unspace_letters, line)
        lines.append(line)
    return " ".join(lines)


def detect_pdf_text_blocks(page: fitz.Page) -> list[dict]:
    blocks: list[dict] = []
    page_width = max(1.0, float(page.rect.width))
    page_height = max(1.0, float(page.rect.height))
    for block in page.get_text("blocks"):
        if len(block) < 5:
            continue
        x0, y0, x1, y1, text = block[:5]
        source = clean_pdf_text(str(text))
        if not source:
            continue
        bbox = [
            max(0, min(1000, round(float(x0) * 1000 / page_width))),
            max(0, min(1000, round(float(y0) * 1000 / page_height))),
            max(0, min(1000, round(float(x1) * 1000 / page_width))),
            max(0, min(1000, round(float(y1) * 1000 / page_height))),
        ]
        if bbox[2] - bbox[0] < 2 or bbox[3] - bbox[1] < 2:
            continue
        blocks.append(
            {
                "bbox": bbox,
                "source": source,
                "confidence": 1.0,
                "detector": "pdf-text-block",
                "line_count": max(1, str(text).count("\n")),
            }
        )
    return blocks


def box_area(box: list[int]) -> int:
    return max(0, box[2] - box[0]) * max(0, box[3] - box[1])


def overlap_ratio(box_a: list[int], box_b: list[int]) -> float:
    x0 = max(box_a[0], box_b[0])
    y0 = max(box_a[1], box_b[1])
    x1 = min(box_a[2], box_b[2])
    y1 = min(box_a[3], box_b[3])
    overlap = box_area([x0, y0, x1, y1])
    smaller = max(1, min(box_area(box_a), box_area(box_b)))
    return overlap / smaller


def box_is_covered(box: list[int], covering_boxes: list[list[int]]) -> bool:
    center_x = (box[0] + box[2]) / 2
    center_y = (box[1] + box[3]) / 2
    for cover in covering_boxes:
        expanded = [
            cover[0] - 12,
            cover[1] - 12,
            cover[2] + 12,
            cover[3] + 12,
        ]
        if expanded[0] <= center_x <= expanded[2] and expanded[1] <= center_y <= expanded[3]:
            return True
        if overlap_ratio(box, cover) >= 0.25:
            return True
    return False


def language_name(code: str) -> str:
    return {
        "en": "English",
        "zh-tw": "Traditional Chinese (Taiwan)",
        "zh-cn": "Simplified Chinese",
    }.get(code.lower(), code)


def translation_matches_target(
    text: str, target_language: str, strict: bool = False
) -> bool:
    target = target_language.lower()
    if target.startswith("zh"):
        has_han = bool(re.search(r"[\u3400-\u9fff]", text))
        has_japanese_kana = bool(re.search(r"[\u3040-\u30ff]", text))
        long_lowercase_runs = {
            run.casefold() for run in re.findall(r"[a-z]{4,}", text)
        }
        return (
            has_han
            and not has_japanese_kana
            and (not strict or len(long_lowercase_runs) <= 1)
        )
    if target == "en":
        return bool(re.search(r"[A-Za-z]", text)) and not re.search(r"[\u3400-\u9fff]", text)
    return bool(text.strip())


def post_chat_request(payload: dict, base_url: str, timeout: int, label: str) -> dict:
    url = base_url.rstrip("/") + "/chat/completions"
    last_error: Exception | None = None
    for attempt in range(1, 4):
        try:
            response = requests.post(url, json=payload, timeout=timeout)
            response.raise_for_status()
            content = response.json()["choices"][0]["message"]["content"]
            return extract_json_object(content)
        except Exception as exc:  # noqa: BLE001 - preserve API failure context
            last_error = exc
            if attempt < 3:
                time.sleep(2**attempt)
    raise RuntimeError(f"{label} failed after 3 attempts: {last_error}")


def post_chat_text(payload: dict, base_url: str, timeout: int, label: str) -> str:
    url = base_url.rstrip("/") + "/chat/completions"
    last_error: Exception | None = None
    for attempt in range(1, 4):
        try:
            response = requests.post(url, json=payload, timeout=timeout)
            response.raise_for_status()
            return str(response.json()["choices"][0]["message"]["content"]).strip()
        except Exception as exc:  # noqa: BLE001 - preserve API failure context
            last_error = exc
            if attempt < 3:
                time.sleep(2**attempt)
    raise RuntimeError(f"{label} failed after 3 attempts: {last_error}")


def batched(items: list[dict], size: int) -> list[list[dict]]:
    return [items[index : index + size] for index in range(0, len(items), size)]


def request_ocr_translations(
    detected: list[dict],
    base_url: str,
    model: str,
    source: str,
    target: str,
    timeout: int,
    strict_target: bool = False,
) -> list[dict]:
    unique_texts: list[dict] = []
    text_to_id: dict[str, int] = {}
    for item in detected:
        text = item["source"]
        key = text.casefold()
        if not should_translate_ocr_text(text, source):
            continue
        if key not in text_to_id:
            text_to_id[key] = len(unique_texts)
            unique_texts.append({"text": text, "boxes": [item["bbox"]]})
        else:
            unique_texts[text_to_id[key]]["boxes"].append(item["bbox"])
    if not unique_texts:
        return []

    all_candidates = [
        {"id": index, "text": item["text"], "boxes": item["boxes"]}
        for index, item in enumerate(unique_texts)
    ]
    source_name = language_name(source)
    target_name = language_name(target)
    translations: dict[str, str] = {}

    def request_json_batch(candidates: list[dict]) -> dict:
        prompt = f"""
Translate every human-readable {source_name} OCR block to {target_name}. The
blocks came from a scanned PDF page and may represent headings, address blocks,
table cells, or whole paragraphs. Return one JSON item for every input id; do
not omit long paragraphs, dates, labels, or short fragments. Preserve the
meaning and make the translation concise enough to fit back into the same PDF
region. Keep document codes, URLs, citations, formulas, acronyms, isolated
numbers, and personal names unchanged only when they are not ordinary prose. If
an input should remain unchanged, return the original text as its translation.
Every actual translation must be written in {target_name}; never return
Japanese for a Chinese target. Do not correct OCR spelling or capitalization
unless needed for understandable translation.

Return ONLY compact JSON in this exact shape:
{{"items":[{{"id":0,"translation":"..."}}]}}

Input:
{json.dumps(candidates, ensure_ascii=False, separators=(',', ':'))}
""".strip()
        payload = {
            "model": model,
            "temperature": 0,
            "max_tokens": 4096,
            "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "user", "content": prompt}],
        }
        return post_chat_request(payload, base_url, timeout, "OCR text translation")

    def request_single(candidate: dict, force_translation: bool = False) -> str:
        instruction = (
            "If the string contains English prose, headings, or sentence fragments, "
            f"translate them to {target_name}; do not return English prose unchanged."
            if force_translation
            else (
                "If it should not be translated, return the original string exactly."
            )
        )
        prompt = f"""
Translate this {source_name} OCR block from a scanned PDF to {target_name}.
Return only the translation. Keep document codes, URLs, citations, formulas,
acronyms, isolated numbers, and personal names unchanged only when they are not
ordinary prose. {instruction}

String:
{candidate["text"]}
""".strip()
        payload = {
            "model": model,
            "temperature": 0,
            "max_tokens": 1024,
            "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "user", "content": prompt}],
        }
        text = post_chat_text(payload, base_url, timeout, "OCR single text translation")
        return re.sub(r"^```(?:text)?\s*|\s*```$", "", text, flags=re.I).strip().strip('"')

    def accept_translation(item_id: int, translation: str) -> None:
        translation = to_traditional_taiwan(translation.strip())
        if not (0 <= item_id < len(unique_texts)) or not translation:
            return
        original = unique_texts[item_id]["text"]
        if (
            original.casefold() != translation.casefold()
            and translation_matches_target(translation, target, strict=strict_target)
        ):
            translations[original.casefold()] = translation

    for batch in batched(all_candidates, 12):
        try:
            parsed = request_json_batch(batch)
            for item in parsed.get("items", []):
                if not isinstance(item, dict):
                    continue
                try:
                    item_id = int(item.get("id"))
                except (TypeError, ValueError):
                    continue
                accept_translation(item_id, str(item.get("translation", "")).strip())
        except Exception as batch_exc:  # noqa: BLE001 - fall back to single strings
            print(f"      batch JSON translation failed; falling back to single strings: {batch_exc}")
            for candidate in batch:
                try:
                    accept_translation(int(candidate["id"]), request_single(candidate))
                except Exception as single_exc:  # noqa: BLE001 - keep the page moving
                    print(f"      skipped OCR string after translation failure: {single_exc}")

    missing = [
        candidate
        for candidate in all_candidates
        if unique_texts[int(candidate["id"])]["text"].casefold() not in translations
    ]
    if missing:
        print(f"      retrying {len(missing)} untranslated OCR block(s) individually")
    for candidate in missing:
        try:
            accept_translation(int(candidate["id"]), request_single(candidate, force_translation=True))
        except Exception as single_exc:  # noqa: BLE001 - keep the page moving
            print(f"      skipped untranslated OCR string after forced retry: {single_exc}")

    unresolved = [
        candidate["text"]
        for candidate in unique_texts
        if candidate["text"].casefold() not in translations
    ]
    if strict_target and unresolved:
        preview = "; ".join(unresolved[:3])
        raise RuntimeError(
            f"{len(unresolved)} scanned OCR line(s) still lack a valid "
            f"{target_name} translation: {preview}"
        )

    translated: list[dict] = []
    for item in detected:
        translation = translations.get(item["source"].casefold())
        if translation:
            translated.append({**item, "translation": translation})
    return translated


def request_vision_fallback(
    image: Image.Image,
    base_url: str,
    model: str,
    source: str,
    target: str,
    timeout: int,
) -> list[dict]:
    data = png_bytes(downscale(image, 1800))
    encoded = base64.b64encode(data).decode("ascii")
    prompt = f"""
Inspect this image and find every visible piece of human-readable {source} text
that should be translated to {target}. Include chart labels, legends, callouts,
table cells, captions embedded in the raster image, and screenshot UI text.
Do not include formulas, code, URLs, citations, model names, acronyms, isolated
numbers, or text already written in the target language.

Return ONLY compact JSON in this exact shape:
{{"items":[{{"bbox":[x0,y0,x1,y1],"source":"...","translation":"..."}}]}}

Coordinates are integers normalized from 0 to 1000 relative to the image.
Boxes must tightly cover the original text. Translation must be concise enough
to fit the same box. If nothing needs translation, return {{"items":[]}}.
""".strip()
    payload = {
        "model": model,
        "temperature": 0,
        "max_tokens": 2048,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{encoded}"},
                    },
                ],
            }
        ],
    }
    parsed = post_chat_request(payload, base_url, timeout, "Vision fallback")
    return validate_items(parsed.get("items", []), detector="vision-fallback")


def request_vision_line_translation(
    image: Image.Image,
    item: dict,
    base_url: str,
    model: str,
    target: str,
    timeout: int,
) -> dict | None:
    box = item["bbox"]
    x0 = max(0, math.floor(box[0] * image.width / 1000))
    y0 = max(0, math.floor(box[1] * image.height / 1000))
    x1 = min(image.width, math.ceil(box[2] * image.width / 1000))
    y1 = min(image.height, math.ceil(box[3] * image.height / 1000))
    vertical_pad = max(4, (y1 - y0) // 2)
    crop = image.crop((x0, max(0, y0 - vertical_pad), x1, min(image.height, y1 + vertical_pad)))
    encoded = base64.b64encode(png_bytes(crop)).decode("ascii")
    target_name = language_name(target)
    payload = {
        "model": model,
        "temperature": 0,
        "max_tokens": 512,
        "chat_template_kwargs": {"enable_thinking": False},
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": (
                            "Read the single English text line centered in this crop and "
                            f"translate it to fluent {target_name}. Ignore neighboring "
                            f"partial lines. Return only the {target_name} translation."
                        ),
                    },
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{encoded}"},
                    },
                ],
            }
        ],
    }
    translation = post_chat_text(
        payload, base_url, timeout, "Vision line translation"
    )
    translation = re.sub(
        r"^```(?:text)?\s*|\s*```$", "", translation, flags=re.I
    ).strip().strip('"')
    translation = to_traditional_taiwan(repair_big5_mojibake(translation))
    if not translation_matches_target(translation, target, strict=True):
        if is_compass_label_line(translation):
            return None
        raise RuntimeError(
            f"Vision line did not return valid {target_name}: {translation[:160]}"
        )
    return {
        **item,
        "translation": translation,
        "detector": "vision-line",
    }


def validate_items(items: object, detector: str = "") -> list[dict]:
    if not isinstance(items, list):
        return []
    valid: list[dict] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        box = item.get("bbox")
        source = str(item.get("source", "")).strip()
        translation = to_traditional_taiwan(
            repair_big5_mojibake(str(item.get("translation", "")).strip())
        )
        if not isinstance(box, list) or len(box) != 4 or not source or not translation:
            continue
        try:
            coords = [max(0, min(1000, int(round(float(value))))) for value in box]
        except (TypeError, ValueError):
            continue
        if coords[2] - coords[0] < 3 or coords[3] - coords[1] < 3:
            continue
        if is_footer_collision(source, coords):
            continue
        if source.casefold() == translation.casefold():
            continue
        item_detector = str(item.get("detector", detector or "unknown"))
        valid_item = {
            "bbox": coords,
            "source": source,
            "translation": translation,
            "detector": item_detector,
        }
        polygon = item.get("polygon")
        if isinstance(polygon, list) and len(polygon) == 4:
            try:
                valid_item["polygon"] = [
                    [
                        max(0, min(1000, int(round(float(point[0]))))),
                        max(0, min(1000, int(round(float(point[1]))))),
                    ]
                    for point in polygon
                ]
            except (TypeError, ValueError, IndexError):
                pass
        for numeric_key in ("confidence", "orientation_degrees"):
            try:
                if numeric_key in item:
                    valid_item[numeric_key] = float(item[numeric_key])
            except (TypeError, ValueError):
                pass
        if isinstance(item.get("text_direction"), str):
            valid_item["text_direction"] = item["text_direction"]
        if isinstance(item.get("reading_order"), int):
            valid_item["reading_order"] = item["reading_order"]
        raw_regions = item.get("source_regions")
        if isinstance(raw_regions, list):
            preserved_regions: list[dict] = []
            for region in raw_regions:
                if not isinstance(region, dict) or not isinstance(region.get("bbox"), list):
                    continue
                preserved_regions.append(
                    {
                        key: region[key]
                        for key in (
                            "bbox",
                            "polygon",
                            "source",
                            "confidence",
                            "orientation_degrees",
                            "text_direction",
                            "detector",
                            "reading_order",
                        )
                        if key in region
                    }
                )
            if preserved_regions:
                valid_item["source_regions"] = preserved_regions
        if isinstance(item.get("line_count"), int):
            valid_item["line_count"] = int(item["line_count"])
        valid.append(valid_item)
    return valid


def load_or_translate(
    image: Image.Image,
    cache_dir: Path,
    base_url: str,
    model: str,
    source: str,
    target: str,
    timeout: int,
    ocr_config: dict,
    line_layout: bool = False,
) -> list[dict]:
    data = png_bytes(downscale(image, 1800))
    pipeline = "hybrid-ocr-v1-scanned-rows" if line_layout else "hybrid-ocr-v1-blocks"
    pipeline += "-" + str(ocr_config.get("provider", "auto"))
    pipeline += "-" + str(ocr_config.get("structure_assist", "auto"))
    pipeline += "-unlimited" if ocr_config.get("unlimited_base_url") else "-no-unlimited"
    pipeline += f"-confidence-{float(ocr_config.get('minimum_confidence', 0.55)):.2f}"
    key = cache_key(data, source, target, model, pipeline)
    cache_file = cache_dir / f"{key}.json"
    if cache_file.exists():
        try:
            cached = json.loads(cache_file.read_text(encoding="utf-8"))
            if cached.get("pipeline") == pipeline:
                return validate_items(cached.get("items", []))
            print(f"      ignoring stale image-translation cache: {cache_file.name}")
        except (OSError, json.JSONDecodeError, AttributeError) as exc:
            print(f"      ignoring invalid image-translation cache: {cache_file.name} ({exc})")
    detected, diagnostics = detect_hybrid_ocr(image, ocr_config)
    vision_candidates: list[dict] = []
    if line_layout:
        sensitive_detected, sensitive_diagnostics = detect_hybrid_ocr(
            image, {**ocr_config, "structure_assist": "off"}, sensitive=True
        )
        diagnostics["sensitive_provider"] = sensitive_diagnostics.get("provider")
        for candidate in sensitive_detected:
            if (
                plausible_english_ocr(candidate["source"])
                and not any(
                overlap_ratio(candidate["bbox"], existing["bbox"]) >= 0.50
                for existing in detected
                )
            ):
                detected.append(candidate)
        before_filter = len(detected)
        retained: list[dict] = []
        for item in detected:
            word_count = len(re.findall(r"[A-Za-z]+", item["source"]))
            long_implausible = word_count >= 8 and not plausible_english_ocr(
                item["source"]
            )
            wide_low_quality = (
                item["bbox"][2] - item["bbox"][0] >= 300
                and float(item.get("confidence", 0.0)) < 0.85
                and not should_translate_ocr_text(item["source"], source)
            )
            if long_implausible or wide_low_quality:
                vision_candidates.append(item)
            else:
                retained.append(item)
        detected = retained
        rejected_count = before_filter - len(detected)
        if rejected_count:
            print(
                f"      routing {rejected_count} low-quality OCR line(s) "
                "to vision fallback"
            )
    if detected:
        translation_units = (
            group_ocr_same_row(detected)
            if line_layout or "table-layout" in diagnostics.get("assist_reasons", [])
            else group_ocr_lines(detected)
        )
        print(
            f"      {diagnostics['provider']}: {len(detected)} text polygon(s), "
            f"{len(translation_units)} {'line(s)' if line_layout else 'block(s)'}; "
            f"translating {'lines' if line_layout else 'blocks'}"
        )
        items = request_ocr_translations(
            translation_units,
            base_url,
            model,
            source,
            target,
            timeout,
            strict_target=line_layout,
        )
    else:
        print("      OCR providers: no text detected; using vision-box fallback")
        items = request_vision_fallback(image, base_url, model, source, target, timeout)
    if line_layout and vision_candidates:
        for candidate in vision_candidates:
            translated_candidate = request_vision_line_translation(
                image, candidate, base_url, model, target, timeout
            )
            if translated_candidate is not None:
                items.append(translated_candidate)
    # An automatic RapidOCR fallback is intentionally not cached. A later run
    # should retry Paddle after its service/GPU is healthy again.
    if not diagnostics.get("fallback"):
        cache_dir.mkdir(parents=True, exist_ok=True)
        cache_payload = json.dumps(
            {"pipeline": pipeline, "items": items, "ocr": diagnostics},
            ensure_ascii=False,
            indent=2,
        )
        cache_temp = cache_file.with_suffix(".json.tmp")
        cache_temp.write_text(cache_payload, encoding="utf-8")
        cache_temp.replace(cache_file)
    return items


def save_document_atomic(document: fitz.Document, output_pdf: Path) -> None:
    output_pdf.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_pdf.with_name(output_pdf.stem + ".partial.pdf")
    temporary.unlink(missing_ok=True)
    try:
        document.save(temporary, garbage=3, deflate=True)
        temporary.replace(output_pdf)
    finally:
        temporary.unlink(missing_ok=True)


def write_report(path: Path | None, payload: dict) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def pixel_box(
    normalized: list[int], width: int, height: int, detector: str = ""
) -> tuple[int, int, int, int]:
    raw_x0 = math.floor(normalized[0] * width / 1000)
    raw_y0 = math.floor(normalized[1] * height / 1000)
    raw_x1 = math.ceil(normalized[2] * width / 1000)
    raw_y1 = math.ceil(normalized[3] * height / 1000)
    raw_width = raw_x1 - raw_x0
    raw_height = raw_y1 - raw_y0
    if detector == "pdf-text-block":
        x_left_pad = x_right_pad = max(2, round(raw_width * 0.10))
        y_pad = max(2, round(raw_height * 0.18))
    elif detector == "rapidocr-block":
        x_left_pad = x_right_pad = max(1, round(raw_width * 0.08))
        y_pad = max(2, round(raw_height * 0.16))
    elif detector == "rapidocr":
        x_left_pad = x_right_pad = max(1, round(raw_width * 0.08))
        y_pad = max(1, round(raw_height * 0.035))
    elif raw_height > raw_width * 2:
        x_left_pad = max(6, round(raw_width * 0.70))
        x_right_pad = max(4, round(raw_width * 0.20))
        y_pad = max(4, round(raw_height * 0.06))
    else:
        x_left_pad = x_right_pad = max(4, round(raw_width * 0.30))
        y_pad = max(4, round(raw_height * 0.06))
    x0 = max(0, raw_x0 - x_left_pad)
    y0 = max(0, raw_y0 - y_pad)
    # Keep inserted patch rectangles strictly inside the parent image bounds.
    # Some Poppler builds mis-handle a nested image whose edge is exactly equal
    # to the source image edge and render unrelated raster regions as black.
    x1 = min(max(1, width - 1), raw_x1 + x_right_pad)
    y1 = min(max(1, height - 1), raw_y1 + y_pad)
    return x0, y0, x1, y1


def pixel_polygon(
    polygon: object, width: int, height: int
) -> list[tuple[int, int]] | None:
    if not isinstance(polygon, list) or len(polygon) != 4:
        return None
    try:
        return [
            (
                max(0, min(width - 1, round(float(point[0]) * width / 1000))),
                max(0, min(height - 1, round(float(point[1]) * height / 1000))),
            )
            for point in polygon
        ]
    except (TypeError, ValueError, IndexError):
        return None


def sampled_background(rgb: np.ndarray, box: tuple[int, int, int, int]) -> tuple[int, int, int]:
    height, width = rgb.shape[:2]
    x0, y0, x1, y1 = box
    pad = max(3, min(max(1, x1 - x0), max(1, y1 - y0)) // 4)
    bx0, by0 = max(0, x0 - pad), max(0, y0 - pad)
    bx1, by1 = min(width, x1 + pad), min(height, y1 + pad)
    border_parts = [
        rgb[by0:y0, bx0:bx1].reshape(-1, 3),
        rgb[y1:by1, bx0:bx1].reshape(-1, 3),
        rgb[y0:y1, bx0:x0].reshape(-1, 3),
        rgb[y0:y1, x1:bx1].reshape(-1, 3),
    ]
    usable = [part for part in border_parts if part.size]
    background = (
        np.median(np.concatenate(usable, axis=0), axis=0).astype(np.uint8)
        if usable
        else np.array([255, 255, 255], dtype=np.uint8)
    )
    if float(background.mean()) > 180:
        background = np.array([255, 255, 255], dtype=np.uint8)
    return tuple(int(value) for value in background)


def erase_ocr_regions(image: Image.Image, items: list[dict]) -> Image.Image:
    """Erase exact OCR polygons, including crop-relocalized Unlimited findings."""
    rgb = np.array(image.convert("RGB"))
    result = Image.fromarray(rgb.copy())
    draw = ImageDraw.Draw(result)
    for item in items:
        regions = item.get("source_regions")
        if not isinstance(regions, list) or not regions:
            regions = [item]
        for region in regions:
            polygon = pixel_polygon(region.get("polygon"), image.width, image.height)
            if polygon is not None:
                xs = [point[0] for point in polygon]
                ys = [point[1] for point in polygon]
                box = (min(xs), min(ys), max(xs) + 1, max(ys) + 1)
                draw.polygon(polygon, fill=sampled_background(rgb, box))
                continue
            box = pixel_box(
                region.get("bbox", item["bbox"]),
                image.width,
                image.height,
                str(region.get("detector", item.get("detector", ""))),
            )
            draw.rectangle(box, fill=sampled_background(rgb, box))
    return result


def wrap_text(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, width: int) -> str:
    lines: list[str] = []
    current = ""
    for char in text.replace("\r", "").replace("\n", " "):
        candidate = current + char
        if current and draw.textbbox((0, 0), candidate, font=font)[2] > width:
            lines.append(current)
            current = char
        else:
            current = candidate
    if current:
        lines.append(current)
    return "\n".join(lines)


def fit_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    font_path: Path,
    width: int,
    height: int,
    max_size: int | None = None,
) -> tuple[ImageFont.FreeTypeFont, str]:
    upper = max(8, min(height, max_size or 96))
    for size in range(upper, 7, -1):
        font = ImageFont.truetype(str(font_path), size=size)
        wrapped = wrap_text(draw, text, font, max(4, width))
        box = draw.multiline_textbbox((0, 0), wrapped, font=font, spacing=max(1, size // 6))
        if box[2] - box[0] <= width and box[3] - box[1] <= height:
            return font, wrapped
    font = ImageFont.truetype(str(font_path), size=8)
    return font, wrap_text(draw, text, font, max(4, width))


def draw_rotated_translation(
    result: Image.Image, item: dict, text: str, font_path: Path
) -> bool:
    """Draw a one-region translation along the OCR polygon's original angle."""
    try:
        angle = float(item.get("orientation_degrees", 0.0))
    except (TypeError, ValueError):
        return False
    if abs(angle) <= 8:
        return False
    regions = item.get("source_regions")
    region = regions[0] if isinstance(regions, list) and len(regions) == 1 else item
    polygon = pixel_polygon(region.get("polygon"), result.width, result.height)
    if polygon is None:
        return False
    edge_width = max(8, round(math.dist(polygon[0], polygon[1])))
    edge_height = max(8, round(math.dist(polygon[0], polygon[3])))
    layer = Image.new("RGBA", (edge_width, edge_height), (0, 0, 0, 0))
    layer_draw = ImageDraw.Draw(layer)
    font, wrapped = fit_text(
        layer_draw, text, font_path, edge_width, edge_height, max_size=edge_height
    )
    layer_draw.multiline_text(
        (0, 0), wrapped, fill=(20, 20, 20, 255), font=font, spacing=max(1, font.size // 6)
    )
    rotated = layer.rotate(-angle, expand=True, resample=Image.Resampling.BICUBIC)
    center_x = sum(point[0] for point in polygon) / 4
    center_y = sum(point[1] for point in polygon) / 4
    result.alpha_composite(
        rotated,
        (round(center_x - rotated.width / 2), round(center_y - rotated.height / 2)),
    ) if result.mode == "RGBA" else result.paste(
        rotated,
        (round(center_x - rotated.width / 2), round(center_y - rotated.height / 2)),
        rotated,
    )
    return True


def redraw_scanned_lines(
    image: Image.Image, items: list[dict], font_path: Path
) -> Image.Image:
    rgb = np.array(image.convert("RGB"))
    boxes: list[dict] = []
    for item in items:
        x0, y0, x1, y1 = pixel_box(
            item["bbox"], image.width, image.height, "rapidocr"
        )
        if x1 <= x0 or y1 <= y0:
            continue
        height = max(1, y1 - y0)
        width = max(1, x1 - x0)
        x_pad = max(3, round(width * 0.025))
        y_pad = max(3, round(height * 0.42))
        boxes.append(
            {
                "clean": (
                    max(0, x0 - x_pad),
                    max(0, y0 - y_pad),
                    min(image.width, x1 + x_pad),
                    min(image.height, y1 + y_pad),
                ),
                "text": (x0, y0, x1, y1),
                "item": item,
            }
        )
    if not boxes:
        return image

    result = erase_ocr_regions(image, [entry["item"] for entry in boxes])
    draw = ImageDraw.Draw(result)
    for entry in boxes:
        x0, y0, x1, y1 = entry["text"]
        translation = to_traditional_taiwan(
            repair_big5_mojibake(str(entry["item"]["translation"]))
        )
        if draw_rotated_translation(result, entry["item"], translation, font_path):
            continue
        width, height = max(4, x1 - x0), max(4, y1 - y0)
        size = max(8, round(height * 0.72))
        while size > 8:
            font = ImageFont.truetype(str(font_path), size=size)
            text_box = draw.textbbox((0, 0), translation, font=font)
            if text_box[2] - text_box[0] <= width:
                break
            size -= 1
        font = ImageFont.truetype(str(font_path), size=size)
        text_box = draw.textbbox((0, 0), translation, font=font)
        text_height = text_box[3] - text_box[1]
        draw.text(
            (x0, y0 + max(0, (height - text_height) / 2)),
            translation,
            fill=(20, 20, 20),
            font=font,
        )
    return result


def redraw(
    image: Image.Image,
    items: list[dict],
    font_path: Path,
    scanned_line_layout: bool = False,
) -> Image.Image:
    if scanned_line_layout:
        return redraw_scanned_lines(image, items, font_path)
    rgb = np.array(image.convert("RGB"))
    boxes: list[tuple[tuple[int, int, int, int], dict]] = []
    for item in items:
        box = pixel_box(item["bbox"], image.width, image.height, item.get("detector", ""))
        x0, y0, x1, y1 = box
        if x1 <= x0 or y1 <= y0:
            continue
        boxes.append((box, item))
    if not boxes:
        return image
    result = erase_ocr_regions(image, [item for _, item in boxes])
    draw = ImageDraw.Draw(result)
    for (x0, y0, x1, y1), item in boxes:
        translation = to_traditional_taiwan(
            repair_big5_mojibake(str(item["translation"]))
        )
        if draw_rotated_translation(result, item, translation, font_path):
            continue
        width, height = max(4, x1 - x0), max(4, y1 - y0)
        line_count = max(1, int(item.get("line_count", 1) or 1))
        if item.get("detector") in ("rapidocr-block", "ocr-block", "pdf-text-block"):
            average_source_len = len(str(item.get("source", ""))) / line_count
            if line_count == 1 and average_source_len < 80:
                max_size = min(44, max(10, round(height * 1.1)))
            elif line_count <= 3 and average_source_len < 35:
                max_size = min(42, max(12, round(height / line_count * 0.95)))
            else:
                max_size = min(20, max(9, round(height / (line_count * 1.55))))
        else:
            max_size = min(34, max(10, height))
        font, wrapped = fit_text(draw, translation, font_path, width, height, max_size=max_size)
        area = np.array(result)[y0:y1, x0:x1]
        luminance = float(area.mean()) if area.size else 255.0
        color = (20, 20, 20) if luminance >= 128 else (245, 245, 245)
        draw.multiline_text((x0, y0), wrapped, fill=color, font=font, spacing=max(1, font.size // 6))
    return result


def page_to_image(page: fitz.Page, zoom: float) -> Image.Image:
    pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
    return Image.frombytes("RGB", (pix.width, pix.height), pix.samples)


def main() -> int:
    args = parse_args()
    ocr_config = {
        "provider": args.ocr_provider,
        "paddle_base_url": args.paddle_ocr_base_url,
        "minimum_confidence": args.paddle_min_confidence,
        "structure_assist": args.structure_assist,
        "unlimited_base_url": args.unlimited_ocr_base_url,
        "unlimited_model": args.unlimited_ocr_model,
        "timeout": args.timeout_seconds,
    }
    input_pdf = Path(args.input_pdf).resolve()
    output_pdf = Path(args.output_pdf).resolve() if args.output_pdf else None
    report_json = Path(args.report_json).resolve() if args.report_json else None
    font_path = Path(args.font)
    if not input_pdf.is_file():
        raise FileNotFoundError(input_pdf)
    if not args.dry_run and output_pdf is None:
        raise ValueError("--output-pdf is required unless --dry-run is used")
    if not font_path.is_file():
        raise FileNotFoundError(f"Traditional Chinese font not found: {font_path}")
    cache_dir = Path(args.cache_dir).resolve() if args.cache_dir else input_pdf.parent / ".image-translation-cache"

    doc = fitz.open(input_pdf)
    selected_pages = parse_pages(args.pages, doc.page_count)
    source_has_text = any(page.get_text("text").strip() for page in doc)
    translated_page_numbers: set[int] = set()
    if args.flatten_pages:
        candidate_count = doc.page_count
        translated_images = 0
        translated_items = 0
        print(f"Flattened page redraw scan: {input_pdf}")
        if args.dry_run:
            for page_index in range(doc.page_count):
                print(f"  page {page_index + 1}: 1 rendered page candidate")
            print(
                f"Image redraw summary: {candidate_count} candidate(s), "
                f"{translated_images} image(s), {translated_items} text region(s)"
            )
            doc.close()
            return 0
        assert output_pdf is not None
        out_doc = fitz.open()
        for page_index in range(doc.page_count):
            page = doc[page_index]
            print(f"  page {page_index + 1}: rendered full page")
            image = page_to_image(page, args.page_render_zoom)
            if page_index in selected_pages:
                detected, ocr_diagnostics = detect_hybrid_ocr(image, ocr_config)
                grouped = (
                    group_ocr_same_row(detected)
                    if "table-layout" in ocr_diagnostics.get("assist_reasons", [])
                    else group_ocr_lines(detected)
                )
                text_blocks = detect_pdf_text_blocks(page)
                covered_boxes = [item["bbox"] for item in grouped]
                supplemental_blocks = [
                    item
                    for item in text_blocks
                    if source_matches_language(item["source"], args.source_language)
                    and not box_is_covered(item["bbox"], covered_boxes)
                ]
                combined_blocks = grouped + supplemental_blocks
                if combined_blocks:
                    print(
                        f"      {ocr_diagnostics['provider']}: {len(detected)} text polygon(s), "
                        f"{len(grouped)} block(s); "
                        f"PDF text supplemental: {len(supplemental_blocks)} block(s)"
                    )
                    items = request_ocr_translations(
                        combined_blocks,
                        args.base_url,
                        args.model,
                        args.source_language,
                        args.target_language,
                        args.timeout_seconds,
                    )
                else:
                    print("      OCR/PDF text: no text detected; using vision-box fallback")
                    items = request_vision_fallback(
                        image,
                        args.base_url,
                        args.model,
                        args.source_language,
                        args.target_language,
                        args.timeout_seconds,
                    )
                if items:
                    image = redraw(image, items, font_path)
                    translated_images += 1
                    translated_items += len(items)
                    translated_page_numbers.add(page_index + 1)
                    print(f"    page image: overlaid {len(items)} redrawn text region(s)")
            out_page = out_doc.new_page(width=page.rect.width, height=page.rect.height)
            out_page.insert_image(out_page.rect, stream=png_bytes(image.convert("RGB")), keep_proportion=False)
        save_document_atomic(out_doc, output_pdf)
        out_doc.close()
        doc.close()
        print(f"Image redraw complete: {output_pdf}")
        print(
            f"Image redraw summary: {candidate_count} candidate(s), "
            f"{translated_images} image(s), {translated_items} text region(s)"
        )
        write_report(
            report_json,
            {
                "schema_version": 1,
                "input_pdf": str(input_pdf),
                "output_pdf": str(output_pdf),
                "source_has_extractable_text": source_has_text,
                "selected_pages": [page + 1 for page in sorted(selected_pages)],
                "translated_pages": sorted(translated_page_numbers),
                "candidate_count": candidate_count,
                "translated_images": translated_images,
                "translated_items": translated_items,
            },
        )
        return 0
    candidate_count = 0
    translated_images = 0
    translated_items = 0
    rebuilt_images: dict[tuple[int, bool], tuple[bytes, int] | None] = {}
    print(f"Image redraw scan: {input_pdf}")
    for page_index in sorted(selected_pages):
        page = doc[page_index]
        candidates = image_candidates(page, args.min_area_ratio, args.max_images_per_page)
        candidate_count += len(candidates)
        print(f"  page {page_index + 1}: {len(candidates)} image candidate(s)")
        if args.dry_run:
            continue
        for image_index, candidate in enumerate(candidates, start=1):
            rect = candidate["rect"]
            xref = candidate["xref"]
            page_area = max(1.0, page.rect.width * page.rect.height)
            line_layout = (
                not bool(page.get_text("text").strip())
                and (rect.width * rect.height) / page_area >= 0.80
            )
            if xref <= 0:
                print(f"    image {image_index}: skipped inline image without replaceable xref")
                continue
            if candidate["smask"]:
                print(f"    image {image_index}: skipped image xref {xref} with soft mask")
                continue
            rebuilt_key = (xref, line_layout)
            if rebuilt_key not in rebuilt_images:
                image = extract_xref_image(doc, xref)
                items = load_or_translate(
                    image,
                    cache_dir,
                    args.base_url,
                    args.model,
                    args.source_language,
                    args.target_language,
                    args.timeout_seconds,
                    ocr_config,
                    line_layout=line_layout,
                )
                if items:
                    rebuilt = redraw(
                        image,
                        items,
                        font_path,
                        scanned_line_layout=line_layout,
                    )
                    rebuilt_images[rebuilt_key] = (
                        png_bytes(rebuilt.convert("RGB")),
                        len(items),
                    )
                else:
                    rebuilt_images[rebuilt_key] = None
            rebuilt_entry = rebuilt_images[rebuilt_key]
            if rebuilt_entry is None:
                continue
            rebuilt_stream, item_count = rebuilt_entry
            # Keep the original xref untouched. Replacing its raw stream can make
            # otherwise valid PDFs render as black blocks in some Poppler builds.
            # A full opaque PNG overlay gets a fresh, self-consistent image object.
            page.insert_image(rect, stream=rebuilt_stream, overlay=True, keep_proportion=False)
            translated_images += 1
            translated_items += item_count
            translated_page_numbers.add(page_index + 1)
            print(f"    image {image_index}: overlaid {item_count} redrawn text region(s)")

    if not args.dry_run:
        assert output_pdf is not None
        save_document_atomic(doc, output_pdf)
        print(f"Image redraw complete: {output_pdf}")
    print(
        f"Image redraw summary: {candidate_count} candidate(s), "
        f"{translated_images} image(s), {translated_items} text region(s)"
    )
    doc.close()
    if not args.dry_run:
        write_report(
            report_json,
            {
                "schema_version": 1,
                "input_pdf": str(input_pdf),
                "output_pdf": str(output_pdf),
                "source_has_extractable_text": source_has_text,
                "selected_pages": [page + 1 for page in sorted(selected_pages)],
                "translated_pages": sorted(translated_page_numbers),
                "candidate_count": candidate_count,
                "translated_images": translated_images,
                "translated_items": translated_items,
            },
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"Image redraw failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
