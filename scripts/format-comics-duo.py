#!/usr/bin/env python3
"""Reformat a web-captured comics PDF without redrawing or upscaling its artwork.

Keeps original images and reading order, removing webpage chrome. Wide strips
are folded into two rows only at a fully blank vertical gutter. Writes a PDF
and a companion JSON index for the phone's year-by-year bookshelf.
"""
import argparse
import json
import re
from collections import Counter
from pathlib import Path

import numpy as np
from pypdf import PdfReader
from pypdf.generic import ContentStream
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader


def safe_split(image):
    if image.width / image.height < 2.4:
        return None
    a = np.asarray(image.convert("L"))
    blank = (a >= 240).all(axis=0)
    candidates = []
    for x in range(int(image.width * .34), int(image.width * .66)):
        if blank[x]:
            candidates.append(x)
    return min(candidates, key=lambda x: abs(x - image.width / 2)) if candidates else None


def fit_image(c, image, x, y, w, h):
    ratio = min(w / image.width, h / image.height)
    dw, dh = image.width * ratio, image.height * ratio
    c.drawImage(ImageReader(image), x + (w-dw)/2, y + (h-dh)/2, dw, dh)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    reader = PdfReader(args.source)
    pdf = canvas.Canvas(str(args.output), pagesize=(360, 500), pageCompression=1)
    pdf.setTitle("calvin & hobbes · duo reading edition")
    pdf.setAuthor("Bill Watterson; layout adapted from user-provided PDF")
    seen, months = {}, set()
    index, statistics = [], Counter()
    current_month = ""
    for page_number, page in enumerate(reader.pages):
        text = page.extract_text()
        match = re.search(r"Calvin\s*&\s*Hobbes\s*-\s*([A-Za-z]+)\s+(19\d\d)", text)
        if not match:
            continue
        month, year = match.group(1).lower(), match.group(2)
        current_month = month + " " + year
        resources = page["/Resources"].get("/XObject", {})
        order = [str(operands[0]) for operands, op in ContentStream(page.get_contents(), reader).operations if op == b"Do"]
        for name in order:
            ref = resources.get(name)
            if ref is None:
                continue
            ob = ref.get_object()
            if ob.get("/Subtype") != "/Image" or ob.get("/Width", 0) < 300 or ob.get("/Height", 0) < 100:
                continue
            key = ref.idnum
            # A tall strip can be clipped across adjacent print pages. Keep
            # one whole image there, but retain later intentional reprints.
            if key in seen and page_number - seen[key] <= 1:
                seen[key] = page_number
                statistics["repeated_image_placements_skipped"] += 1
                continue
            seen[key] = page_number
            image = page.images[name].image.copy()
            split = safe_split(image)
            if current_month not in months:
                if year not in months:
                    pdf.bookmarkPage(year)
                    pdf.addOutlineEntry(year, year, level=0)
                    months.add(year)
                pdf.bookmarkPage(current_month)
                pdf.addOutlineEntry(current_month, current_month, level=1)
                months.add(current_month)
            pdf.setFillColorRGB(.42, .42, .40)
            pdf.setFont("Courier", 9)
            pdf.drawString(14, 483, current_month)
            pdf.drawRightString(346, 483, str(len(index)+1))
            if split is not None:
                left = image.crop((0, 0, split, image.height))
                right = image.crop((split, 0, image.width, image.height))
                fit_image(pdf, left, 10, 246, 340, 223)
                fit_image(pdf, right, 10, 16, 340, 223)
                layout = "two-rows"
            else:
                fit_image(pdf, image, 10, 16, 340, 453)
                layout = "whole-strip"
            statistics[layout] += 1
            index.append({"pdfPage": len(index), "sourcePage": page_number+1, "sourceImage": name,
                          "year": year, "month": month, "layout": layout,
                          "originalSize": list(image.size), "splitX": split})
            pdf.showPage()
        if page_number % 100 == 0:
            print(f"source page {page_number+1}/{len(reader.pages)}; {len(index)} strips", flush=True)
    if not index:
        raise ValueError("No comic strip images found")
    pdf.save()
    result = {"sourcePages": len(reader.pages), "stripCount": len(index), "statistics": dict(statistics), "pages": index}
    args.output.with_suffix(".json").write_text(json.dumps(result, indent=2))
    check = PdfReader(args.output)
    assert len(check.pages) == len(index)
    print(json.dumps({k:v for k,v in result.items() if k != "pages"}), flush=True)

if __name__ == "__main__":
    main()
