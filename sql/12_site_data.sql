-- GeoJSON for the static site (site/), as MapLibre sources.
--
-- Differs from sql/07_map_export.sql, which feeds the single-file canvas map:
-- that one emits a bespoke shape that viz/build_map.py compacts and inlines.
-- MapLibre wants plain FeatureCollections it can fetch, and it does its own
-- filtering and styling from feature properties, so the geometry ships once
-- with every quantity the UI needs attached to it.
--
-- Property names are short because they are repeated on every feature:
--   bm  block maximum roadway width, ft   - the "never wider than" test
--   bn  block minimum roadway width, ft   - the "narrow somewhere" test
--   sm  this segment's own maximum, ft    - for the block-widens layer
--   bl  block length, ft                  - for the mileage readout
--   rw  right of way width, ft
LOAD spatial;
SET geometry_always_xy = true;

-- The arterial context layer that sql/07 exports is not repeated here: the
-- basemap draws roads, so redrawing them would be duplicate ink.
COPY (
  SELECT
    b.block_id,
    coalesce(b.full_name, '(unnamed)') AS street,
    b.road_width_max_ft                AS bm,
    b.road_width_min_ft                AS bn,
    round(b.portland_len_ft)           AS bl,
    b.n_segments                       AS nseg,
    s.road_width_max_ft                AS sm,
    round(s.row_width_ft, 1)           AS rw,
    ST_Transform(ST_Simplify(s.geom, 3.0),
                 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM narrow_block b
  JOIN block_member m USING (block_id)
  JOIN street_segment s USING (street_oid)
  WHERE s.road_width_max_ft <= 24
     OR b.road_width_max_ft <= 24
     OR b.road_width_min_ft <= 24
) TO 'site/public/data/blocks.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326');

-- Narrowings from the curb profile (sql/11): one point per run, at its
-- narrowest station. Nothing in PBOT's pavement records can see these.
COPY (
  SELECT
    pinch_id         AS pid,
    coalesce(full_name, '(unnamed)') AS street,
    block_id,
    functional_class AS fclass,
    min_gap_ft       AS w,
    seg_median_ft    AS s,
    narrowing_ft     AS d,
    run_len_ft       AS l,
    left_curb_style  AS lstyle,
    right_curb_style AS rstyle,
    ST_Transform(geom, 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM curb_pinch
) TO 'site/public/data/narrowings.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326');

COPY (
  SELECT ST_Transform(ST_Simplify(geom, 50.0),
                      'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM city_boundary
) TO 'site/public/data/boundary.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326');

-- Totals the site quotes, computed here rather than summed in the browser so
-- the page cannot drift from the pipeline. testable_miles is the denominator
-- for "x% of Portland's testable miles": blocks where every segment has a
-- pavement width on record, which is the set the width test can be run on.
COPY (
  SELECT
    (SELECT count(*) FROM narrow_block)                                AS testable_blocks,
    (SELECT round(sum(portland_len_ft) / 5280.0, 1) FROM narrow_block) AS testable_miles,
    (SELECT count(*) FROM curb_pinch)                                  AS narrowings,
    (SELECT count(*) FROM curb_pinch WHERE min_gap_ft <= 18)           AS narrowings_under_18,
    (SELECT count(*) FROM block WHERE n_missing_road_width > 0)        AS untestable_blocks,
    (SELECT round(sum(portland_len_ft) / 5280.0, 1) FROM block
      WHERE n_missing_road_width > 0)                                  AS untestable_miles
) TO 'site/public/data/totals.json' (FORMAT JSON, ARRAY false);
