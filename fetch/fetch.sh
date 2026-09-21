#!/usr/bin/env bash
# Download raw source data into data/raw/. Idempotent: skips files already present.
set -euo pipefail

cd "$(dirname "$0")/.."
RAW="data/raw"
mkdir -p "$RAW"

# ArcGIS Hub keeps a pre-built bulk export per dataset, but only in EPSG:4326 and
# only where someone has generated one; reprojection happens in SQL, and layers
# with no export fall back to paging the REST endpoint.
HUB="https://opendata.arcgis.com/api/v3/datasets"
OD="https://www.portlandmaps.com/od/rest/services"

json_ok() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if "error" in d:
    sys.exit(f"service error: {d['error']}")
if not d.get("features"):
    sys.exit("no features in response")
PY
}

# hub_get <name> <hub-dataset-id> <service-path> <layer-id>
hub_get() {
  local name="$1"
  local dataset="$2"
  local service="$3"
  local layer="$4"
  local out="$RAW/$name.geojson"
  if [[ -s "$out" ]]; then
    echo "skip   $name ($(du -h "$out" | cut -f1))"
    return
  fi
  echo "fetch  $name"
  if curl -fsSL --retry 3 --retry-delay 2 --max-time 900 \
       -o "$out.part" "$HUB/$dataset/downloads/data?format=geojson&spatialRefId=4326"; then
    json_ok "$out.part"
    mv -- "$out.part" "$out"
    echo "done   $name ($(du -h "$out" | cut -f1)) via hub export"
  else
    rm -f -- "$out.part"
    echo "       no hub export, paging REST instead"
    # Page in EPSG:4326 to match what the bulk export would have returned, so
    # the SQL sees one shape and one CRS per layer whichever path ran. 7 decimal
    # places is ~1 cm; the 0.01 ft precision used for 2913 would be ~1 km here.
    page_layer "$name" "$OD/$service/MapServer/$layer/query" "1=1" 200 "*" OBJECTID 4326 7
    python3 fetch/merge_pages.py "$RAW/$name" "$out"
    rm -rf -- "${RAW:?}/${name:?}"
    echo "done   $name ($(du -h "$out" | cut -f1)) via REST paging"
  fi
}

# page_layer <name> <query-url> <where> <page-size> <out-fields> <oid-field> <out-sr> <precision>
# Writes data/raw/<name>/page_NNNN.geojson. Resumable: existing pages are kept.
# out-sr and precision travel together and must agree: 2913 (Oregon North, feet)
# wants 2 decimals for 0.01 ft, while 4326 needs 7 or degrees truncate into
# uselessness.
page_layer() {
  local name="$1"
  local url="$2"
  local where="$3"
  local page="$4"
  local fields="$5"
  local oidfield="$6"
  local outsr="$7"
  local precision="$8"
  local dir="$RAW/$name"
  mkdir -p "$dir"

  local total
  total=$(curl -fsS --get "$url" \
    --data-urlencode "where=$where" \
    --data-urlencode "returnCountOnly=true" \
    --data-urlencode "f=json" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')
  local pages=$(( (total + page - 1) / page ))
  echo "       $name: $total features, $pages pages of $page"

  local offset=0
  local page_no=0
  while (( offset < total )); do
    local out
    out=$(printf '%s/page_%04d.geojson' "$dir" "$page_no")
    if [[ ! -s "$out" ]]; then
      curl -fsS --retry 3 --retry-delay 2 --max-time 300 --get "$url" \
        --data-urlencode "where=$where" \
        --data-urlencode "outFields=$fields" \
        --data-urlencode "returnGeometry=true" \
        --data-urlencode "outSR=$outsr" \
        --data-urlencode "geometryPrecision=$precision" \
        --data-urlencode "orderByFields=$oidfield" \
        --data-urlencode "resultOffset=$offset" \
        --data-urlencode "resultRecordCount=$page" \
        --data-urlencode "f=geojson" \
        -o "$out.part"
      json_ok "$out.part"
      mv -- "$out.part" "$out"
      if [[ -t 1 ]]; then
        printf '       page %d/%d\r' "$(( page_no + 1 ))" "$pages"
      elif (( (page_no + 1) % 25 == 0 )); then
        printf '       page %d/%d\n' "$(( page_no + 1 ))" "$pages"
      fi
    fi
    offset=$(( offset + page ))
    page_no=$(( page_no + 1 ))
  done
  echo ""
  echo "done   $name ($(du -sh "$dir" | cut -f1))"
}

# City of Portland open data (PBOT / BPS)
hub_get pavement_management 147735d763274812882bdbb099776237_71   COP_OpenData_Transportation 71
hub_get streets             9248407180c94efb9ddc675b0cc53826_68   COP_OpenData_Transportation 68
hub_get curb_extension      9646a2e182b14202ac86c37c59a99b13_1432 COP_OpenData_Transportation 1432
hub_get unimproved_row      7c180f7fdb744b7d8292e6f044f1e01c_208  COP_OpenData_Transportation 208
hub_get curbs               4b7461cc94f94c46a49d6585116d978d_74   COP_OpenData_Transportation 74
hub_get city_boundaries     951488174bfe4275bbbd04421d7820f5_10   COP_OpenData_Boundary       10
# Sidewalk polygons sit inside the right of way by definition, which makes them
# an independent geometric check on the derived ROW edges.
hub_get sidewalks           a3c2d531f53b428e9b9084f5e7ed4b52_77   COP_OpenData_Transportation 77
# Base zoning, to approximate the ORS "residence district" test.
hub_get zoning              9e97018d1efd424aa52cb6ad031486a6_16   COP_OpenData_ZoningCode     16

# Metro RLIS taxlots. No bulk export exists, and the geometry is the whole point,
# so page the feature service asking only for the join key. Requested in
# COUNTY='M' picks up lots across the city line so boundary streets still have
# taxlots on both sides; JURIS_CITY adds the Washington/Clackamas County slivers.
TAXLOT_URL="https://services2.arcgis.com/McQ0OlIABe29rJJy/arcgis/rest/services/Taxlots_(Public)/FeatureServer/3/query"
page_layer taxlots "$TAXLOT_URL" "COUNTY='M' OR JURIS_CITY='PORTLAND'" 2000 "TLID,COUNTY,JURIS_CITY" FID 2913 2

{
  echo "fetched_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  find "$RAW" -name '*.geojson' -print0 | xargs -0 du -ch | tail -1
  find "$RAW" -maxdepth 1 -print0 | xargs -0 du -sh | sort -k2
} > "$RAW/MANIFEST.txt"
echo "wrote  $RAW/MANIFEST.txt"
