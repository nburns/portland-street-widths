#!/usr/bin/env bash
# Build the basemap: a Portland-shaped slice of the Protomaps daily planet
# build, as a single PMTiles archive the browser reads with range requests.
#
# No tile server and no API key, which is what makes "static site" and
# "basemap" both true at once. The archive is a build artifact rather than a
# repository blob - 19 MB that anyone can regenerate - so .gitignore keeps it
# out and this script puts it back.
#
# Used by `make basemap` and by .github/workflows/pages.yml, so the two cannot
# drift.
set -euo pipefail

cd "$(dirname "$0")/.."

PMTILES_VERSION="${PMTILES_VERSION:-1.31.2}"
OUT="${OUT:-public/basemap.pmtiles}"
# Portland's city boundary is -122.837,45.433 to -122.472,45.653; padded so the
# edge of the frame is not the edge of the data.
BBOX="${BBOX:--122.90,45.40,-122.40,45.68}"
MAXZOOM="${MAXZOOM:-14}"

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)  ASSET="go-pmtiles-${PMTILES_VERSION}_Darwin_arm64.zip" ;;
  Darwin/x86_64) ASSET="go-pmtiles-${PMTILES_VERSION}_Darwin_x86_64.zip" ;;
  Linux/aarch64) ASSET="go-pmtiles_${PMTILES_VERSION}_Linux_arm64.tar.gz" ;;
  Linux/x86_64)  ASSET="go-pmtiles_${PMTILES_VERSION}_Linux_x86_64.tar.gz" ;;
  *) echo "no pmtiles build for $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

BIN_DIR="$(mktemp -d)"
trap 'rm -rf -- "$BIN_DIR"' EXIT

echo "fetching pmtiles ${PMTILES_VERSION}"
URL="https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/${ASSET}"
curl -fsSL --retry 3 --retry-delay 2 -o "$BIN_DIR/dl" -- "$URL"
case "$ASSET" in
  *.zip)    unzip -oq "$BIN_DIR/dl" -d "$BIN_DIR" ;;
  *.tar.gz) tar -xzf "$BIN_DIR/dl" -C "$BIN_DIR" ;;
esac
chmod +x "$BIN_DIR/pmtiles"

# Protomaps keeps roughly two weeks of daily builds, so the date cannot be
# pinned: an old one 404s and a hardcoded date would break CI on a schedule
# nobody is watching. Walk back until one answers a range request.
BUILD=""
for i in $(seq 0 20); do
  if date -v-1d >/dev/null 2>&1; then
    d="$(date -u -v-"${i}"d +%Y%m%d)"            # BSD date (macOS)
  else
    d="$(date -u -d "-${i} days" +%Y%m%d)"       # GNU date (CI)
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
            -r 0-6 "https://build.protomaps.com/${d}.pmtiles" || true)"
  if [[ "$code" == "206" || "$code" == "200" ]]; then BUILD="$d"; break; fi
done
if [[ -z "$BUILD" ]]; then
  echo "no Protomaps planet build found in the last 20 days" >&2
  exit 1
fi
echo "using planet build ${BUILD}"

mkdir -p -- "$(dirname -- "$OUT")"
"$BIN_DIR/pmtiles" extract "https://build.protomaps.com/${BUILD}.pmtiles" "$OUT" \
  --bbox="$BBOX" --maxzoom="$MAXZOOM"

# An extract that silently produced nothing usable would show up as a blank
# basemap much later, so check the archive before calling this a success.
"$BIN_DIR/pmtiles" show "$OUT" > /dev/null
echo "wrote $OUT ($(du -h -- "$OUT" | cut -f1)) from planet build ${BUILD}"
