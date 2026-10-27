#!/usr/bin/env python3
"""Build the demo catalog (venues, cafes, menus, photos).

Reads supabase/catalog/catalog.json + images.json and:

  --images   download the pinned Wikimedia Commons photos (1024px JPEG) and record
             author / licence in supabase/catalog/images.lock.json
  --upload   upload those photos to the public Supabase Storage bucket `catalog`
             (needs SUPABASE_PROJECT_URL and SUPABASE_SERVICE_ROLE_KEY in the environment)
  --sql      write supabase/migrations/20261026140000_catalog.sql

IDs are uuid5-derived, so re-running produces identical SQL (safe to re-apply).
Run with the venv that has Pillow + requests:  /tmp/toolsvenv/bin/python scripts/build_catalog.py --images
"""
import argparse
import io
import json
import os
import re
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "supabase/catalog/catalog.json"
IMAGES = ROOT / "supabase/catalog/images.json"
LOCK = ROOT / "supabase/catalog/images.lock.json"
IMG_DIR = ROOT / "supabase/catalog/images"
MIGRATION = ROOT / "supabase/migrations/20261026140000_catalog.sql"
LEGACY_SQL = ROOT / "supabase/migrations/20261024210000_fan_features.sql"
NS = uuid.UUID("5b1b7e0e-8f55-4c8a-9d0e-5c1a7d0c4a11")
AVIVA = "d9d44e67-c936-4f45-8ec5-cfc0fd22cd11"
HEADERS = {"User-Agent": "SkippioDemoCatalog/1.0 (https://www.skippio.io/; mohammad@skippio.io) requests/2"}
API = "https://commons.wikimedia.org/w/api.php"


def uid(*parts: str) -> str:
    return str(uuid.uuid5(NS, "|".join(parts)))


def q(value) -> str:
    """SQL literal."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def env(name: str) -> str:
    value = os.environ.get(name)
    if value:
        return value
    dotenv = ROOT / ".env"
    if dotenv.exists():
        for line in dotenv.read_text().splitlines():
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit(f"{name} is not set")


# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
def fetch_images() -> None:
    import requests
    from PIL import Image

    config = json.loads(IMAGES.read_text())["images"]
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    lock = json.loads(LOCK.read_text()) if LOCK.exists() else {}

    by_file: dict[str, list[str]] = {}
    for key, spec in config.items():
        by_file.setdefault(spec["file"], []).append(key)

    for title, keys in by_file.items():
        reuse = next((k for k in keys if k in lock and (IMG_DIR / f"{k}.jpg").exists() and lock[k]["title"] == title), None)
        if reuse and all(k in lock and lock[k]["title"] == title and (IMG_DIR / f"{k}.jpg").exists() for k in keys):
            continue
        pages = None
        for attempt in range(8):
            resp = requests.get(
                API,
                params={
                    "action": "query", "format": "json", "titles": title, "prop": "imageinfo",
                    "iiprop": "url|extmetadata|size|mime", "iiurlwidth": 1024,
                },
                headers=HEADERS, timeout=30,
            )
            try:
                pages = resp.json()["query"]["pages"]
                break
            except Exception:
                time.sleep(5 + attempt * 5)
        if pages is None:
            raise SystemExit(f"Commons API did not answer for {title}")
        page = next(iter(pages.values()))
        ii = page["imageinfo"][0]
        meta = ii["extmetadata"]
        license_name = meta.get("LicenseShortName", {}).get("value", "")
        if re.search(r"(nc|nd)\b", license_name, re.I) or not license_name:
            raise SystemExit(f"Refusing {title}: licence '{license_name}'")
        author = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", meta.get("Artist", {}).get("value", ""))).strip() or "Unknown"
        data = None
        for attempt in range(8):
            r = requests.get(ii["thumburl"], headers=HEADERS, timeout=60)
            if r.status_code == 200:
                data = r.content
                break
            time.sleep(5 + attempt * 5)
        if data is None:
            raise SystemExit(f"Could not download {title}")
        image = Image.open(io.BytesIO(data)).convert("RGB")
        image.thumbnail((1024, 1024))
        for key in keys:
            image.save(IMG_DIR / f"{key}.jpg", "JPEG", quality=82, optimize=True)
            lock[key] = {
                "title": title,
                "author": author,
                "license": license_name,
                "license_url": meta.get("LicenseUrl", {}).get("value", ""),
                "source_url": ii["descriptionurl"],
            }
        print("ok", title, "->", ", ".join(keys), f"({license_name})", flush=True)
        LOCK.write_text(json.dumps(lock, indent=1, ensure_ascii=False, sort_keys=True))
        time.sleep(1.5)

    LOCK.write_text(json.dumps(lock, indent=1, ensure_ascii=False, sort_keys=True))


def upload_images() -> None:
    import requests

    base = env("SUPABASE_PROJECT_URL").rstrip("/")
    key = env("SUPABASE_SERVICE_ROLE_KEY")
    headers = {"Authorization": f"Bearer {key}", "apikey": key}
    # The bucket is created by the migration; this is a harmless fallback.
    requests.post(f"{base}/storage/v1/bucket", headers=headers, json={"id": "catalog", "name": "catalog", "public": True}, timeout=30)
    for path in sorted(IMG_DIR.glob("*.jpg")):
        r = requests.post(
            f"{base}/storage/v1/object/catalog/{path.name}",
            headers={**headers, "Content-Type": "image/jpeg", "x-upsert": "true", "cache-control": "max-age=31536000"},
            data=path.read_bytes(),
            timeout=60,
        )
        if r.status_code not in (200, 201):
            raise SystemExit(f"Upload failed for {path.name}: {r.status_code} {r.text[:200]}")
        print("uploaded", path.name)


# ---------------------------------------------------------------------------
# SQL
# ---------------------------------------------------------------------------
def legacy_aviva() -> tuple[dict, dict]:
    """Ids of the Aviva menu created by an earlier migration, keyed by title."""
    sql = LEGACY_SQL.read_text()
    cats = {}
    for m in re.finditer(r"\('([0-9a-f-]{36})', '" + AVIVA + r"', '([^']+)', (\d+)\)", sql):
        cats[m.group(2)] = m.group(1)
    items = {}
    for m in re.finditer(
        r"\('([0-9a-f-]{36})', '" + AVIVA + r"', '([0-9a-f-]{36})', '([^']+)', '([^']*)', '([^']*)', (\d+),", sql
    ):
        items[m.group(3)] = m.group(1)
    return cats, items


def build_sql() -> None:
    catalog = json.loads(CATALOG.read_text())
    lock = json.loads(LOCK.read_text())
    base = env("SUPABASE_PROJECT_URL").rstrip("/")
    public = f"{base}/storage/v1/object/public/catalog"
    legacy_cats, legacy_items = legacy_aviva()

    def image_url(key: str | None) -> str | None:
        return f"{public}/{key}.jpg" if key else None

    used_images: set[str] = set()
    out: list[str] = []
    w = out.append

    w("-- GENERATED by scripts/build_catalog.py from supabase/catalog/catalog.json. Do not edit by hand.")
    w("-- Demo venues, cafes, menus and photo credits. Invented content is listed in the README.\n")

    # ---- venues + cafes
    rows = []
    entries = (
        [("venue", v) for v in catalog["venues"]]
        + [("cafe", c) for c in catalog["cafes"]]
        + [("restaurant", r) for r in catalog.get("restaurants", [])]
    )
    for kind, e in entries:
        vid = e.get("id") or uid("venue", e["key"])
        e["_id"] = vid
        e["_kind"] = kind
        used_images.add(e["cover"])
        rows.append(
            "  ("
            + ", ".join(
                q(x)
                for x in (
                    vid, e["name"], e["address"], e["city"], e.get("country", "Ireland"),
                    image_url(e["cover"]), None, e["subtitle"], kind, e["open"], True,
                    e["lat"], e["lon"], e["group"],
                )
            )
            + ")"
        )
    w("insert into public.venues\n  (id, name, address, city, country, cover_image_url, logo_url, subtitle, kind, is_open, is_active, latitude, longitude, group_name)\nvalues")
    w(",\n".join(rows))
    w(
        "on conflict (id) do update set\n  name = excluded.name, address = excluded.address, city = excluded.city, country = excluded.country,\n"
        "  cover_image_url = excluded.cover_image_url, logo_url = excluded.logo_url, subtitle = excluded.subtitle,\n"
        "  kind = excluded.kind, is_open = excluded.is_open, is_active = excluded.is_active,\n"
        "  latitude = excluded.latitude, longitude = excluded.longitude, group_name = excluded.group_name;\n"
    )

    # ---- collection points
    rows = []
    for kind, e in entries:
        if e.get("points"):
            points = e["points"]
        elif kind == "restaurant":
            points = [catalog.get("restaurant_point", catalog["cafe_point"])]
        else:
            points = [catalog["cafe_point"]]
        for i, p in enumerate(points):
            pid = p.get("id") or uid("point", e["key"], str(i))
            rows.append("  (" + ", ".join(q(x) for x in (pid, e["_id"], p["name"], p["floor"], p["block"], p["wait"], True)) + ")")
    w("insert into public.collection_points\n  (id, venue_id, name, floor_label, block_label, average_wait_seconds, is_open)\nvalues")
    w(",\n".join(rows))
    w(
        "on conflict (id) do update set\n  name = excluded.name, floor_label = excluded.floor_label, block_label = excluded.block_label,\n"
        "  average_wait_seconds = excluded.average_wait_seconds, is_open = excluded.is_open;\n"
    )

    # ---- menus
    cat_rows, item_rows, allergen_rows = [], [], []
    group_rows, option_rows, link_rows = [], [], []
    for kind, e in entries:
        if kind == "cafe":
            template = catalog["cafe_menu"]
        elif kind == "restaurant":
            cuisine = e.get("cuisine", "italian")
            template = catalog.get(f"menu_{cuisine}", catalog.get("menu_italian", []))
        else:
            template = catalog["venue_menu"]
        offset = e.get("price_offset", 0)
        is_aviva = e["_id"] == AVIVA

        # option groups: one set per cafe, linked to the coffee items that carry "options"
        group_ids = []
        if kind == "cafe":
            for gi, g in enumerate(catalog["option_groups"]["coffee_options"]):
                gid = uid("group", e["key"], g["title"])
                group_ids.append(gid)
                group_rows.append("  (" + ", ".join(q(x) for x in (gid, e["_id"], g["title"], g["required"], g["multi"], gi + 1)) + ")")
                for oi, o in enumerate(g["options"]):
                    option_rows.append("  (" + ", ".join(q(x) for x in (uid("option", e["key"], g["title"], o["title"]), gid, o["title"], o["price"], oi + 1)) + ")")

        for ci, cat in enumerate(template):
            cid = legacy_cats.get(cat["title"]) if is_aviva and cat["title"] in legacy_cats else uid("cat", e["key"], cat["title"])
            cat_rows.append("  (" + ", ".join(q(x) for x in (cid, e["_id"], cat["title"], ci + 1)) + ")")
            for ii, item in enumerate(cat["items"]):
                iid = legacy_items.get(item["title"]) if is_aviva and item["title"] in legacy_items else uid("item", e["key"], cat["title"], item["title"])
                price = max(100, item["price"] + (0 if is_aviva else offset))
                used_images.add(item["image"])
                item_rows.append(
                    "  ("
                    + ", ".join(
                        q(x)
                        for x in (
                            iid, e["_id"], cid, item["title"], item.get("sub"), item.get("volume"), image_url(item["image"]),
                            price, "EUR", item.get("available", True), ii + 1,
                        )
                    )
                    + ")"
                )
                for allergen in item["allergens"]:
                    allergen_rows.append(f"  ({q(iid)}, {q(allergen)})")
                if item.get("options"):
                    for gid in group_ids:
                        link_rows.append(f"  ({q(iid)}, {q(gid)})")

    def block(table: str, columns: str, rows: list[str], conflict: str) -> None:
        w(f"insert into public.{table}\n  ({columns})\nvalues")
        w(",\n".join(rows))
        w(conflict + ";\n")

    block("menu_categories", "id, venue_id, title, sort_order", cat_rows,
          "on conflict (id) do update set title = excluded.title, sort_order = excluded.sort_order")
    block("menu_items", "id, venue_id, category_id, title, subtitle, volume_label, image_url, price_cents, currency, is_available, sort_order", item_rows,
          "on conflict (id) do update set\n  category_id = excluded.category_id, title = excluded.title, subtitle = excluded.subtitle,\n"
          "  volume_label = excluded.volume_label, image_url = excluded.image_url, price_cents = excluded.price_cents,\n"
          "  is_available = excluded.is_available, sort_order = excluded.sort_order")
    block("menu_item_allergens", "menu_item_id, allergen", allergen_rows, "on conflict (menu_item_id, allergen) do nothing")
    block("menu_option_groups", "id, venue_id, title, is_required, allows_multiple, sort_order", group_rows,
          "on conflict (id) do update set title = excluded.title, is_required = excluded.is_required,\n  allows_multiple = excluded.allows_multiple, sort_order = excluded.sort_order")
    block("menu_options", "id, group_id, title, price_delta_cents, sort_order", option_rows,
          "on conflict (id) do update set title = excluded.title, price_delta_cents = excluded.price_delta_cents, sort_order = excluded.sort_order")
    block("menu_item_option_groups", "menu_item_id, group_id", link_rows, "on conflict do nothing")

    # ---- credits (only for photos that are actually used)
    credit_rows = []
    for key in sorted(used_images):
        c = lock[key]
        credit_rows.append("  (" + ", ".join(q(x) for x in (key, c["title"].removeprefix("File:"), c["author"], c["license"], c["license_url"], c["source_url"])) + ")")
    block("image_credits", "image_key, title, author, license, license_url, source_url", credit_rows,
          "on conflict (image_key) do update set title = excluded.title, author = excluded.author,\n  license = excluded.license, license_url = excluded.license_url, source_url = excluded.source_url")

    MIGRATION.write_text("\n".join(out))
    print(f"wrote {MIGRATION.relative_to(ROOT)}: {len(entries)} venues/cafes, {len(item_rows)} items, {len(credit_rows)} credits")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--images", action="store_true")
    parser.add_argument("--upload", action="store_true")
    parser.add_argument("--sql", action="store_true")
    args = parser.parse_args()
    if not (args.images or args.upload or args.sql):
        parser.print_help()
        sys.exit(1)
    if args.images:
        fetch_images()
    if args.upload:
        upload_images()
    if args.sql:
        build_sql()


if __name__ == "__main__":
    main()
