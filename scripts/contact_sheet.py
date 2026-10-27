#!/usr/bin/env python3
"""Build review contact sheets from the thumbnails commons_search.py downloaded.

    python3 scripts/contact_sheet.py            # all keys, 6 keys per sheet
Sheets are written to /tmp/catalog_sheets/sheet_N.jpg (one row per key, one column
per candidate, each labelled key:index).
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
CAND = json.loads((ROOT / "supabase/catalog/images.candidates.json").read_text())
PINNED = {k for k, v in json.loads((ROOT / "supabase/catalog/images.json").read_text())["images"].items() if v.get("file")}
THUMBS = Path("/tmp/catalog_thumbs")
OUT = Path("/tmp/catalog_sheets")
OUT.mkdir(exist_ok=True)

CELL = 230
ROWS_PER_SHEET = 6
COLS = 6

import sys
keys = sys.argv[1:] or [k for k in CAND if k not in PINNED]
for sheet_index in range(0, len(keys), ROWS_PER_SHEET):
    chunk = keys[sheet_index : sheet_index + ROWS_PER_SHEET]
    sheet = Image.new("RGB", (COLS * CELL, len(chunk) * (CELL + 18)), "white")
    draw = ImageDraw.Draw(sheet)
    for row, key in enumerate(chunk):
        y = row * (CELL + 18)
        draw.text((4, y + 2), f"{key}  ({CAND[key]['query']})", fill="black")
        for col in range(COLS):
            path = THUMBS / f"{key}__{col}.jpg"
            if not path.exists():
                continue
            img = Image.open(path).convert("RGB")
            img.thumbnail((CELL - 6, CELL - 24))
            x = col * CELL
            sheet.paste(img, (x + 3, y + 16))
            draw.rectangle((x + 3, y + 16, x + 22, y + 30), fill="black")
            draw.text((x + 8, y + 17), str(col), fill="white")
    sheet.save(OUT / (f"sheet_{sheet_index // ROWS_PER_SHEET}.jpg" if len(sys.argv) == 1 else "extra.jpg"), quality=80)
print(len(keys), "keys ->", len(list(OUT.glob("sheet_*.jpg"))), "sheets")
