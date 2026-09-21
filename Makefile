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

.PHONY: all fetch verify load row segments blocks ors nrr curb validate export map shell clean clean-db
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

out/narrow_blocks.txt: sql/06_blocks.sql $(STAMP)/segments | out
	$(DUCKDB) "$(DB)" < sql/06_blocks.sql | tee "$@"

out/ors_narrow_residential.txt: sql/08_narrow_residential.sql $(STAMP)/blocks | out
	$(DUCKDB) "$(DB)" < sql/08_narrow_residential.sql | tee "$@"

out/nrr_convertible.txt out/nrr_convertible.csv out/nrr_by_street.csv: sql/09_nrr_convertible.sql out/ors_narrow_residential.txt | out
	$(DUCKDB) "$(DB)" < sql/09_nrr_convertible.sql | tee "$@"

# One stamp rather than three targets: this stage writes a report and two data
# exports, and a multi-target rule would tee the report over them.
$(STAMP)/curb: sql/11_curb_profile.sql out/ors_narrow_residential.txt | $(STAMP) out
	$(DUCKDB) "$(DB)" < sql/11_curb_profile.sql | tee out/curb_profile.txt
	@touch "$@"

out/validation.txt: sql/04_validate.sql $(STAMP)/segments | out
	$(DUCKDB) "$(DB)" < sql/04_validate.sql | tee "$@"

out/portland_street_widths.csv out/portland_row_confident.csv: sql/05_export.sql $(STAMP)/segments | out
	$(DUCKDB) "$(DB)" < sql/05_export.sql

load:     $(STAMP)/load
row:      $(STAMP)/row
segments: $(STAMP)/segments
blocks:   out/narrow_blocks.txt
ors:      out/ors_narrow_residential.txt
nrr:      out/nrr_convertible.txt
curb:     $(STAMP)/curb
validate: out/validation.txt
export:   out/validation.txt out/narrow_blocks.txt out/ors_narrow_residential.txt out/nrr_convertible.txt $(STAMP)/curb out/portland_street_widths.csv out/portland_row_confident.csv

build:
	@mkdir -p build

out/map.html: sql/07_map_export.sql viz/template.html viz/build_map.py $(STAMP)/blocks $(STAMP)/curb | out build
	$(DUCKDB) "$(DB)" < sql/07_map_export.sql
	python3 viz/build_map.py

map: out/map.html

shell:
	$(DUCKDB) "$(DB)"

# Drops derived data but keeps the downloads, which are the slow part.
clean-db:
	rm -rf -- "$(DB)" "$(DB).wal" "$(STAMP)" out

clean: clean-db
	rm -rf -- data/raw build
