#!/usr/bin/env python3
"""Translate text embedded in raster PDF images with OCR-first redrawing.

RapidOCR supplies precise text boxes and source strings. An OpenAI-compatible
local model translates those strings only. The vision model is used for boxes
only when RapidOCR cannot detect any text in an image.
"""

from __future__ import annotations

import argparse
import base64
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
    parser.add_argument("--min-area-ratio", type=float, default=0.015)
    parser.add_argument("--max-images-per-page", type=int, default=12)
    parser.add_argument("--max-image-dimension", type=int, default=1800)
    parser.add_argument("--timeout-seconds", type=int, default=300)
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


def cache_key(image_bytes: bytes, source: str, target: str, model: str) -> str:
    digest = hashlib.sha256()
    digest.update(image_bytes)
    digest.update(f"\0{source}\0{target}\0{model}\0rapidocr-v4".encode())
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


def detect_rapidocr(image: Image.Image) -> list[dict]:
    global OCR_ENGINE
    if OCR_ENGINE is None:
        OCR_ENGINE = RapidOCR()
    result, _ = OCR_ENGINE(np.asarray(image.convert("RGB")))
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
        box = normalized_box(entry[0], image.width, image.height)
        if box is None:
            continue
        detected.append(
            {
                "bbox": box,
                "source": source,
                "confidence": round(confidence, 4),
                "detector": "rapidocr",
            }
        )
    return detected


def source_matches_language(text: str, source_language: str) -> bool:
    if source_language.lower().startswith("zh"):
        return bool(re.search(r"[\u3400-\u9fff]", text))
    if source_language.lower() == "en":
        return bool(re.search(r"[A-Za-z]", text))
    return True


def language_name(code: str) -> str:
    return {
        "en": "English",
        "zh-tw": "Traditional Chinese (繁體中文)",
        "zh-cn": "Simplified Chinese (简体中文)",
    }.get(code.lower(), code)


def translation_matches_target(text: str, target_language: str) -> bool:
    target = target_language.lower()
    if target.startswith("zh"):
        has_han = bool(re.search(r"[\u3400-\u9fff]", text))
        has_japanese_kana = bool(re.search(r"[\u3040-\u30ff]", text))
        return has_han and not has_japanese_kana
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


def request_ocr_translations(
    detected: list[dict],
    base_url: str,
    model: str,
    source: str,
    target: str,
    timeout: int,
) -> list[dict]:
    unique_texts: list[dict] = []
    text_to_id: dict[str, int] = {}
    for item in detected:
        text = item["source"]
        key = text.casefold()
        if not source_matches_language(text, source):
            continue
        if key not in text_to_id:
            text_to_id[key] = len(unique_texts)
            unique_texts.append({"text": text, "boxes": [item["bbox"]]})
        else:
            unique_texts[text_to_id[key]]["boxes"].append(item["bbox"])
    if not unique_texts:
        return []

    candidates = [
        {"id": index, "text": item["text"], "boxes": item["boxes"]}
        for index, item in enumerate(unique_texts)
    ]
    source_name = language_name(source)
    target_name = language_name(target)
    prompt = f"""
Translate eligible human-readable {source_name} strings to {target_name}. The strings
came from OCR in charts, diagrams, screenshots, and rasterized tables. Do not
translate formulas, code, URLs, citations, model/product names, acronyms,
isolated numbers, or strings already in the target language. A generic word is
still part of a model/product name when it is adjacent to that name; for
example, do NOT translate "Medium" in "Magistral Medium" or "GPT-OSS Medium".
The normalized boxes help identify adjacent labels. Keep translations concise.
Return only entries that should actually be translated. Every translation must
be written in {target_name}; never return Japanese for a Chinese target. Do not
correct OCR spelling or capitalization.

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
    parsed = post_chat_request(payload, base_url, timeout, "OCR text translation")
    translations: dict[str, str] = {}
    for item in parsed.get("items", []):
        if not isinstance(item, dict):
            continue
        try:
            item_id = int(item.get("id"))
        except (TypeError, ValueError):
            continue
        translation = str(item.get("translation", "")).strip()
        if not (0 <= item_id < len(unique_texts)) or not translation:
            continue
        original = unique_texts[item_id]["text"]
        if (
            original.casefold() != translation.casefold()
            and translation_matches_target(translation, target)
        ):
            translations[original.casefold()] = translation

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


def validate_items(items: object, detector: str = "") -> list[dict]:
    if not isinstance(items, list):
        return []
    valid: list[dict] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        box = item.get("bbox")
        source = str(item.get("source", "")).strip()
        translation = str(item.get("translation", "")).strip()
        if not isinstance(box, list) or len(box) != 4 or not source or not translation:
            continue
        try:
            coords = [max(0, min(1000, int(round(float(value))))) for value in box]
        except (TypeError, ValueError):
            continue
        if coords[2] - coords[0] < 3 or coords[3] - coords[1] < 3:
            continue
        if source.casefold() == translation.casefold():
            continue
        item_detector = str(item.get("detector", detector or "unknown"))
        valid.append(
            {
                "bbox": coords,
                "source": source,
                "translation": translation,
                "detector": item_detector,
            }
        )
    return valid


def load_or_translate(
    image: Image.Image,
    cache_dir: Path,
    base_url: str,
    model: str,
    source: str,
    target: str,
    timeout: int,
) -> list[dict]:
    data = png_bytes(downscale(image, 1800))
    key = cache_key(data, source, target, model)
    cache_file = cache_dir / f"{key}.json"
    if cache_file.exists():
        return validate_items(json.loads(cache_file.read_text(encoding="utf-8")).get("items", []))
    detected = detect_rapidocr(image)
    if detected:
        print(f"      RapidOCR: {len(detected)} text box(es); translating strings only")
        items = request_ocr_translations(detected, base_url, model, source, target, timeout)
    else:
        print("      RapidOCR: no text detected; using vision-box fallback")
        items = request_vision_fallback(image, base_url, model, source, target, timeout)
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(
        json.dumps({"pipeline": "rapidocr-v4", "items": items}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return items


def pixel_box(
    normalized: list[int], width: int, height: int, detector: str = ""
) -> tuple[int, int, int, int]:
    raw_x0 = math.floor(normalized[0] * width / 1000)
    raw_y0 = math.floor(normalized[1] * height / 1000)
    raw_x1 = math.ceil(normalized[2] * width / 1000)
    raw_y1 = math.ceil(normalized[3] * height / 1000)
    raw_width = raw_x1 - raw_x0
    raw_height = raw_y1 - raw_y0
    if detector == "rapidocr":
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
) -> tuple[ImageFont.FreeTypeFont, str]:
    upper = max(10, min(height, 96))
    for size in range(upper, 7, -1):
        font = ImageFont.truetype(str(font_path), size=size)
        wrapped = wrap_text(draw, text, font, max(4, width))
        box = draw.multiline_textbbox((0, 0), wrapped, font=font, spacing=max(1, size // 6))
        if box[2] - box[0] <= width and box[3] - box[1] <= height:
            return font, wrapped
    font = ImageFont.truetype(str(font_path), size=8)
    return font, wrap_text(draw, text, font, max(4, width))


def redraw(image: Image.Image, items: list[dict], font_path: Path) -> Image.Image:
    rgb = np.array(image.convert("RGB"))
    boxes: list[tuple[tuple[int, int, int, int], str]] = []
    for item in items:
        box = pixel_box(item["bbox"], image.width, image.height, item.get("detector", ""))
        x0, y0, x1, y1 = box
        if x1 <= x0 or y1 <= y0:
            continue
        boxes.append((box, item["translation"]))
    if not boxes:
        return image
    cleaned = rgb.copy()
    for (x0, y0, x1, y1), _ in boxes:
        pad = max(4, min(x1 - x0, y1 - y0) // 4)
        bx0, by0 = max(0, x0 - pad), max(0, y0 - pad)
        bx1, by1 = min(image.width, x1 + pad), min(image.height, y1 + pad)
        border_parts = [
            rgb[by0:y0, bx0:bx1].reshape(-1, 3),
            rgb[y1:by1, bx0:bx1].reshape(-1, 3),
            rgb[y0:y1, bx0:x0].reshape(-1, 3),
            rgb[y0:y1, x1:bx1].reshape(-1, 3),
        ]
        border = np.concatenate([part for part in border_parts if part.size], axis=0)
        background = np.median(border, axis=0).astype(np.uint8) if border.size else np.array([255, 255, 255], dtype=np.uint8)
        cleaned[y0:y1, x0:x1] = background
    result = Image.fromarray(cleaned)
    draw = ImageDraw.Draw(result)
    for (x0, y0, x1, y1), translation in boxes:
        width, height = max(4, x1 - x0), max(4, y1 - y0)
        font, wrapped = fit_text(draw, translation, font_path, width, height)
        area = np.array(result)[y0:y1, x0:x1]
        luminance = float(area.mean()) if area.size else 255.0
        color = (20, 20, 20) if luminance >= 128 else (245, 245, 245)
        draw.multiline_text((x0, y0), wrapped, fill=color, font=font, spacing=max(1, font.size // 6))
    return result


def main() -> int:
    args = parse_args()
    input_pdf = Path(args.input_pdf).resolve()
    output_pdf = Path(args.output_pdf).resolve() if args.output_pdf else None
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
    candidate_count = 0
    translated_images = 0
    translated_items = 0
    rebuilt_images: dict[int, tuple[bytes, int] | None] = {}
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
            if xref <= 0:
                print(f"    image {image_index}: skipped inline image without replaceable xref")
                continue
            if candidate["smask"]:
                print(f"    image {image_index}: skipped image xref {xref} with soft mask")
                continue
            if xref not in rebuilt_images:
                image = extract_xref_image(doc, xref)
                items = load_or_translate(
                    image,
                    cache_dir,
                    args.base_url,
                    args.model,
                    args.source_language,
                    args.target_language,
                    args.timeout_seconds,
                )
                if items:
                    rebuilt = redraw(image, items, font_path)
                    rebuilt_images[xref] = (png_bytes(rebuilt.convert("RGB")), len(items))
                else:
                    rebuilt_images[xref] = None
            rebuilt_entry = rebuilt_images[xref]
            if rebuilt_entry is None:
                continue
            rebuilt_stream, item_count = rebuilt_entry
            # Keep the original xref untouched. Replacing its raw stream can make
            # otherwise valid PDFs render as black blocks in some Poppler builds.
            # A full opaque PNG overlay gets a fresh, self-consistent image object.
            page.insert_image(rect, stream=rebuilt_stream, overlay=True, keep_proportion=False)
            translated_images += 1
            translated_items += item_count
            print(f"    image {image_index}: overlaid {item_count} redrawn text region(s)")

    if not args.dry_run:
        assert output_pdf is not None
        output_pdf.parent.mkdir(parents=True, exist_ok=True)
        doc.save(output_pdf, garbage=3, deflate=True)
        print(f"Image redraw complete: {output_pdf}")
    print(
        f"Image redraw summary: {candidate_count} candidate(s), "
        f"{translated_images} image(s), {translated_items} text region(s)"
    )
    doc.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"Image redraw failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
