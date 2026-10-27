#!/usr/bin/env python3
"""Search Wikimedia Commons for licence-safe candidate photos.

Reads supabase/catalog/images.json, searches Commons for every key that has no pinned
`file`, keeps only CC0 / public domain / CC BY / CC BY-SA results, downloads small
thumbnails to /tmp/catalog_thumbs for review and writes
supabase/catalog/images.candidates.json.

    python3 scripts/commons_search.py [key ...]
"""
import json
import re
import sys
import time
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
IMAGES = ROOT / "supabase/catalog/images.json"
OUT = ROOT / "supabase/catalog/images.candidates.json"
THUMBS = Path("/tmp/catalog_thumbs")
API = "https://commons.wikimedia.org/w/api.php"
HEADERS = {"User-Agent": "SkippioDemoCatalog/1.0 (demo project; contact: demo@example.com)"}

ALLOWED = re.compile(r"^(cc0|public domain|pd|cc[ -]by(-sa)?[ -]\d(\.\d)?|cc[ -]by(-sa)?[ -]\d\.\d( \w+)?)", re.I)
BLOCKED = re.compile(r"(-nc|-nd|\bnc\b|\bnd\b|fair use|non-?commercial|no derivatives)", re.I)


def license_ok(short: str) -> bool:
    short = (short or "").strip()
    if not short or BLOCKED.search(short):
        return False
    return bool(ALLOWED.match(short))


def strip_html(value: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", value or "")).strip()


def api(params: dict) -> dict:
    for attempt in range(4):
        r = requests.get(API, params={**params, "format": "json"}, headers=HEADERS, timeout=30)
        if r.status_code == 200:
            return r.json()
        time.sleep(2 + attempt * 2)
    r.raise_for_status()
    return {}


def info_for_pages(pages: dict) -> list[dict]:
    out = []
    for page in pages.values():
        ii = (page.get("imageinfo") or [{}])[0]
        meta = ii.get("extmetadata", {})
        short = meta.get("LicenseShortName", {}).get("value", "")
        if ii.get("mime") not in ("image/jpeg", "image/png"):
            continue
        if not license_ok(short):
            continue
        if ii.get("width", 0) < 700 or ii.get("height", 0) < 500:
            continue
        out.append(
            {
                "title": page["title"],
                "width": ii.get("width"),
                "height": ii.get("height"),
                "thumb": ii.get("thumburl"),
                "page": ii.get("descriptionurl"),
                "license": short,
                "license_url": meta.get("LicenseUrl", {}).get("value", ""),
                "author": strip_html(meta.get("Artist", {}).get("value", "")) or "Unknown",
                "index": page.get("index", 999),
            }
        )
    return sorted(out, key=lambda x: x["index"])


def search(query: str, limit: int = 25) -> list[dict]:
    data = api(
        {
            "action": "query",
            "generator": "search",
            "gsrnamespace": 6,
            "gsrsearch": f"{query} filetype:bitmap",
            "gsrlimit": limit,
            "prop": "imageinfo",
            "iiprop": "url|extmetadata|size|mime",
            "iiurlwidth": 400,
        }
    )
    return info_for_pages(data.get("query", {}).get("pages", {}))


def main() -> None:
    config = json.loads(IMAGES.read_text())["images"]
    only = set(sys.argv[1:])
    existing = json.loads(OUT.read_text()) if OUT.exists() else {}
    THUMBS.mkdir(exist_ok=True)

    for key, spec in config.items():
        if only and key not in only:
            continue
        if spec.get("file") and not only:
            continue
        candidates = search(spec["query"])[:6]
        existing[key] = {"query": spec["query"], "candidates": candidates}
        for i, cand in enumerate(candidates):
            if cand["thumb"]:
                path = THUMBS / f"{key}__{i}.jpg"
                if not path.exists():
                    resp = requests.get(cand["thumb"], headers=HEADERS, timeout=30)
                    if resp.status_code == 200:
                        path.write_bytes(resp.content)
                    time.sleep(0.15)
        print(f"{key}: {len(candidates)} candidates")
        time.sleep(0.2)

    OUT.write_text(json.dumps(existing, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
