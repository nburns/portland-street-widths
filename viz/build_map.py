#!/usr/bin/env python3
"""Compact the exported geometry and inline it into a single self-contained
HTML file. No build step, no server, no external requests beyond Google Fonts:
open it locally, host it anywhere, or publish it."""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
OUT = os.path.join(ROOT, "out", "map.html")
TEMPLATE = os.path.join(ROOT, "viz", "template.html")


def rings(geom):
    """GeoJSON geometry -> list of coordinate rings, whatever the type."""
    o = json.loads(geom) if isinstance(geom, str) else geom
    t = o["type"]
    if t == "LineString":
        return [o["coordinates"]]
    if t in ("MultiLineString", "Polygon"):
        return o["coordinates"]
    if t == "MultiPolygon":
        return [r for poly in o["coordinates"] for r in poly]
    raise ValueError(f"unexpected geometry type {t}")


def flatten(parts, precision=5):
    """Rings -> flat [x,y,x,y,...] arrays. 5 decimals is ~1 m, which is finer
    than the 3 ft simplification already applied in SQL."""
    return [
        [v for xy in ring for v in (round(xy[0], precision), round(xy[1], precision))]
        for ring in parts
    ]


def load(name):
    path = os.path.join(BUILD, f"{name}.json")
    if not os.path.exists(path):
        sys.exit(f"missing {path} - run sql/07_map_export.sql first (make map)")
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    blocks = {}
    for r in load("segs"):
        blk = blocks.setdefault(
            r["block_id"],
            {
                "n": r["full_name"] or "(unnamed)",
                "bm": r["block_max"],
                "bn": r["block_min"],
                "bl": int(r["block_len"]),
                "s": [],
            },
        )
        blk["s"].append(
            {
                "m": r["seg_max"],
                "l": int(r["seg_len"]),
                "r": None if r["row_w"] is None else round(r["row_w"], 1),
                "p": flatten(rings(r["g"])),
            }
        )

    # Narrowings: parallel arrays rather than a list of objects, because the
    # coordinates are projected in place by the same routine that projects the
    # line layers and the attributes never need to move with them.
    pinch = load("pinch")
    data = {
        "blocks": list(blocks.values()),
        # Context layers carry less precision; they are never measured against.
        "major": [p for r in load("major") for p in flatten(rings(r["g"]), 4)],
        "boundary": [p for r in load("boundary") for p in flatten(rings(r["g"]), 4)],
        "pinch": {
            "p": [v for r in pinch for v in (r["lon"], r["lat"])],
            "w": [r["w"] for r in pinch],
            "l": [r["l"] for r in pinch],
            "d": [r["d"] for r in pinch],
            "s": [r["s"] for r in pinch],
            "n": [r["n"] for r in pinch],
        },
    }

    with open(TEMPLATE, encoding="utf-8") as f:
        html = f.read()
    if "__DATA__" not in html:
        sys.exit(f"{TEMPLATE} has no __DATA__ placeholder")

    payload = json.dumps(data, separators=(",", ":"))
    if "</script" in payload:
        sys.exit("payload would close the host script tag")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(html.replace("__DATA__", payload))

    miles = {}
    for t in (14, 16, 18, 20, 22, 24):
        qualifying = [b for b in data["blocks"] if b["bm"] <= t]
        miles[t] = (len(qualifying), sum(b["bl"] for b in qualifying) / 5280)

    print(f"wrote {OUT} ({os.path.getsize(OUT):,} bytes)")
    print(f"  {len(data['blocks']):,} blocks, {len(data['major']):,} context lines")
    print(f"  {len(pinch):,} narrowings ({len(json.dumps(data['pinch'])):,} bytes inlined)")
    for t, (n, mi) in miles.items():
        print(f"  <= {t} ft: {n:5,} blocks {mi:7.1f} mi")


if __name__ == "__main__":
    main()
