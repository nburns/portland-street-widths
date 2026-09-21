#!/usr/bin/env python3
"""Check data/raw/ against the fingerprint the published results were built from.

Upstream ArcGIS re-exports are not byte-stable, so a changed hash means "these
are not the bytes behind the numbers in the README" - not necessarily "the data
is wrong". Missing files are a hard error; changed ones are reported and only
fail under --strict.
"""
import argparse
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "data", "raw")
EXPECTED = os.path.join(ROOT, "fetch", "expected.json")


def scan(raw_dir):
    found = {}
    for dirpath, dirnames, filenames in os.walk(raw_dir):
        dirnames.sort()
        for fn in sorted(filenames):
            if not fn.endswith(".geojson"):
                continue
            path = os.path.join(dirpath, fn)
            digest = hashlib.sha256()
            with open(path, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    digest.update(chunk)
            rel = os.path.relpath(path, raw_dir)
            found[rel] = {"bytes": os.path.getsize(path), "sha256": digest.hexdigest()}
    return found


def write_expected(found, path):
    doc = {
        "_comment": (
            "Fingerprint of the data/raw/ fetch the committed results were built "
            "from. Regenerate with fetch/verify.py --write."
        ),
        "files": found,
    }
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true",
                    help="regenerate fetch/expected.json from data/raw/ as it is now")
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero when a file's contents differ, not just when it is missing")
    args = ap.parse_args()

    if not os.path.isdir(RAW):
        sys.exit(f"no {os.path.relpath(RAW, ROOT)}/ - run ./setup.sh (or ./fetch/fetch.sh) first")

    found = scan(RAW)

    if args.write:
        if not found:
            sys.exit(f"refusing to write an empty fingerprint: no .geojson under {RAW}")
        write_expected(found, EXPECTED)
        total = sum(e["bytes"] for e in found.values())
        print(f"wrote {os.path.relpath(EXPECTED, ROOT)}: {len(found)} files, {total / 1e9:.2f} GB")
        return 0

    try:
        with open(EXPECTED, encoding="utf-8") as fh:
            expected = json.load(fh)["files"]
    except FileNotFoundError:
        sys.exit(f"{os.path.relpath(EXPECTED, ROOT)} not found; generate it with --write")

    missing = sorted(set(expected) - set(found))
    extra = sorted(set(found) - set(expected))
    changed = sorted(
        rel for rel in set(expected) & set(found)
        if found[rel]["sha256"] != expected[rel]["sha256"]
    )
    ok = len(expected) - len(missing) - len(changed)

    for rel in missing:
        print(f"MISSING  {rel}")
    for rel in changed:
        print(f"CHANGED  {rel}  ({expected[rel]['bytes']} -> {found[rel]['bytes']} bytes)")
    for rel in extra:
        print(f"EXTRA    {rel}  (not in the fingerprint; harmless, nothing reads it)")

    print(f"\n{ok}/{len(expected)} files match the published fetch.")

    if missing:
        print("Missing files: re-run ./fetch/fetch.sh", file=sys.stderr)
        return 1
    if changed:
        print(
            "Upstream has re-exported or revised these layers since the fingerprint "
            "was taken. The pipeline will still run; results may differ from the "
            "README. Run fetch/verify.py --write to adopt the new data as the "
            "baseline.",
            file=sys.stderr,
        )
        return 1 if args.strict else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
