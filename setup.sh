#!/usr/bin/env bash
# One-shot setup: check tools, download the source data, verify it, build everything.
# Safe to re-run - every stage skips work that is already done.
set -euo pipefail

cd "$(dirname "$0")"

missing=0
for tool in duckdb curl python3 make; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    missing=1
  fi
done
if (( missing )); then
  cat >&2 <<'HELP'

On macOS:   brew install duckdb
            curl, python3 and make ship with the Xcode command line tools
            (xcode-select --install)
On Debian:  apt install duckdb curl python3 make
HELP
  exit 1
fi

echo "==> downloading source data (about 860 MB; ~20 min on a first run)"
./fetch/fetch.sh

echo
echo "==> verifying against the published fetch"
# Lenient: upstream re-exports are not byte-stable, and drift is worth knowing
# about but not worth refusing to build over.
python3 fetch/verify.py || true

echo
echo "==> building (about 80 seconds)"
make
make map

cat <<'DONE'

Done.

  out/portland_street_widths.parquet   39,103 segments, one row each
  out/portland_street_widths.csv       the same, as text
  out/portland_street_widths.gpkg      with geometry, for QGIS
  out/map.html                         open this one
  out/validation.txt                   what the pipeline checked

  make shell                           poke at the database directly
DONE
