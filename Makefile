# Without pipefail a stage piped into `tee` reports tee's status, so a SQL
# error printed to stderr still looked like a successful build - stage 11 once
# failed mid-script and left a stale table behind while make exited 0.
SHELL      := /bin/bash
.SHELLFLAGS := -o pipefail -c

DB     := data/street_widths.duckdb
DUCKDB := duckdb
STAMP  := .stamps

RAW_INPUTS := data/raw/pavement_management.geojson \
              data/raw/streets.geojson \
              data/raw/unimproved_row.geojson \
              data/raw/curbs.geojson \
              data/raw/city_boundaries.geojson \
              data/raw/sidewalks.geojson \
              data/raw/zoning.geojson

.PHONY: all fetch verify load row segments blocks ors nrr nrr-geojson curb validate export \
        site-data site-dev site basemap shell clean clean-db
.DELETE_ON_ERROR:

all: export

# fetch is idempotent and skips anything already downloaded
fetch:
	./fetch/fetch.sh

# Checks data/raw/ against the fetch the published numbers came from.
verify:
	python3 fetch/verify.py

$(RAW_INPUTS):
	./fetch/fetch.sh

$(STAMP):
	@mkdir -p "$(STAMP)"

out:
	@mkdir -p out

$(STAMP)/load: sql/01_load.sql $(RAW_INPUTS) | $(STAMP)
	$(DUCKDB) "$(DB)" < sql/01_load.sql
	@touch "$@"

$(STAMP)/row: sql/02_row_width.sql $(STAMP)/load
	$(DUCKDB) "$(DB)" < sql/02_row_width.sql
	@touch "$@"

$(STAMP)/segments: sql/03_segments.sql $(STAMP)/row
	$(DUCKDB) "$(DB)" < sql/03_segments.sql
	@touch "$@"

$(STAMP)/blocks: sql/06_blocks.sql $(STAMP)/segments
	$(DUCKDB) "$(DB)" < sql/06_blocks.sql > /dev/null
	@touch "$@"

out/narrow_blocks.txt out/narrow_blocks_18ft.geojson: sql/06_blocks.sql $(STAMP)/segments | out
	$(DUCKDB) "$(DB)" < sql/06_blocks.sql | tee out/narrow_blocks.txt

out/ors_narrow_residential.txt: sql/08_narrow_residential.sql $(STAMP)/blocks | out
	$(DUCKDB) "$(DB)" < sql/08_narrow_residential.sql | tee "$@"

out/nrr_convertible.txt out/nrr_convertible.csv out/nrr_by_street.csv: sql/09_nrr_convertible.sql out/ors_narrow_residential.txt | out
	$(DUCKDB) "$(DB)" < sql/09_nrr_convertible.sql | tee "$@"

# One stamp rather than three targets: this stage writes a report and two data
# exports, and a multi-target rule would tee the report over them.
$(STAMP)/curb: sql/11_curb_profile.sql out/ors_narrow_residential.txt | $(STAMP) out
	$(DUCKDB) "$(DB)" < sql/11_curb_profile.sql | tee out/curb_profile.txt
	@touch "$@"

# sql/10 writes four GeoJSON files that were in out/ with no rule to rebuild
# them: they had only ever been produced by hand.
out/nrr_blocks.geojson out/nrr_by_street.geojson out/nrr_existing.geojson out/narrow_residential_roadways.geojson: \
  sql/10_nrr_geojson.sql out/nrr_convertible.txt | out
	$(DUCKDB) "$(DB)" < sql/10_nrr_geojson.sql

nrr-geojson: out/nrr_blocks.geojson

out/validation.txt: sql/04_validate.sql $(STAMP)/segments | out
	$(DUCKDB) "$(DB)" < sql/04_validate.sql | tee "$@"

out/portland_street_widths.csv out/portland_row_confident.csv: sql/05_export.sql $(STAMP)/segments | out
	$(DUCKDB) "$(DB)" < sql/05_export.sql

load:     $(STAMP)/load
row:      $(STAMP)/row
segments: $(STAMP)/segments
blocks:   out/narrow_blocks.txt
ors:      out/ors_narrow_residential.txt
nrr:      out/nrr_convertible.txt out/nrr_blocks.geojson
curb:     $(STAMP)/curb
validate: out/validation.txt
export:   out/validation.txt out/narrow_blocks.txt out/ors_narrow_residential.txt out/nrr_convertible.txt out/nrr_blocks.geojson $(STAMP)/curb out/portland_street_widths.csv out/portland_row_confident.csv

# ---------------------------------------------------------------------------
# site/ - the Vite build. Its GeoJSON is committed, because GitHub Actions
# cannot rebuild the DuckDB pipeline: that needs 863 MB of source data and 20
# minutes. CI runs `npm ci && vite build` against data that is already there.
# ---------------------------------------------------------------------------
SITE_DATA := site/public/data/blocks.geojson site/public/data/narrowings.geojson \
             site/public/data/boundary.geojson site/public/data/totals.json

$(SITE_DATA): sql/12_site_data.sql $(STAMP)/curb
	@mkdir -p site/public/data
	$(DUCKDB) "$(DB)" < sql/12_site_data.sql

site-data: $(SITE_DATA)

site/node_modules: site/package.json site/package-lock.json
	cd site && npm ci
	@touch site/node_modules

# Regenerable, 19 MB, and gitignored - so it is a target rather than a file in
# the tree. The site works without it, on a flat ground with the city boundary.
basemap:
	./site/scripts/basemap.sh

site-dev: site/node_modules $(SITE_DATA)
	cd site && npm run dev

site: site/node_modules $(SITE_DATA)
	cd site && npm run build

shell:
	$(DUCKDB) "$(DB)"

# Drops derived data but keeps the downloads, which are the slow part.
clean-db:
	rm -rf -- "$(DB)" "$(DB).wal" "$(STAMP)" out

clean: clean-db
	rm -rf -- data/raw
