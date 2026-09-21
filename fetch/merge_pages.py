#!/usr/bin/env python3
"""Concatenate page_*.geojson from a paged fetch into one FeatureCollection.

Lets a REST-paged fallback stand in for an ArcGIS bulk export, so downstream
SQL sees one shape per layer regardless of which path the download took.
Features are streamed a page at a time rather than held all at once.
"""
import glob
import json
import os
import sys


def merge(page_dir, out_path):
    pages = sorted(glob.glob(os.path.join(page_dir, "page_*.geojson")))
    if not pages:
        sys.exit(f"no page_*.geojson in {page_dir}")

    tmp = out_path + ".part"
    total = 0
    with open(tmp, "w", encoding="utf-8") as out:
        out.write('{"type":"FeatureCollection","features":[')
        for page in pages:
            with open(page, encoding="utf-8") as fh:
                features = json.load(fh).get("features")
            if not features:
                sys.exit(f"{page}: no features")
            for feat in features:
                if total:
                    out.write(",")
                json.dump(feat, out, separators=(",", ":"))
                total += 1
        out.write("]}")

    if total == 0:
        os.unlink(tmp)
        sys.exit(f"{page_dir}: merged to zero features")
    os.replace(tmp, out_path)
    print(f"merged {len(pages)} pages, {total} features -> {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: merge_pages.py <page-dir> <out.geojson>")
    merge(sys.argv[1], sys.argv[2])
