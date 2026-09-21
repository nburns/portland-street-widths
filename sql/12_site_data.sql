-- GeoJSON for the static site (site/), as MapLibre sources.
--
-- MapLibre wants plain FeatureCollections it can fetch, and does its own
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

-- Every block that could become a narrow residential roadway, with the
-- narrowest and widest width known for it and where that width came from.
--
-- Three decisions, all of which move the answer:
--
-- PaveWidth, not RoadWidth. ORS 801.450 defines the roadway "exclusive of the
-- shoulder"; RoadWidth is PBOT's graded roadway, which on an unimproved street
-- includes gravel shoulder. Drawing RoadWidth put the answer at 51.4 miles
-- against 74.1 for the field the statute points at.
--
-- Blocks PBOT has no pavement record for are included when the curb lines can
-- measure them. 13,974 blocks - 1,067 miles - have no PaveWidth, and the gap
-- is concentrated in exactly the local and unimproved streets where narrow
-- ones live. The 5 ft curb profile reaches 7,981 of them, 542 miles, and finds
-- 583 blocks narrow somewhere. Leaving them out answered a different question
-- than the one being asked.
--
-- The whole eligible universe ships, not just what is already narrow. A block
-- needing 2 ft of edge line is the subject of this map as much as one needing
-- none.
--
--   wn/wx  narrowest and widest width known for the block, ft
--   src    'pms' where PBOT records a pavement width, 'curb' where the width
--          is measured off the curb lines instead
--   sh     shoulder needed each side to bring the travel way to 18 ft
--   nrr    passes the whole ORS 801.368 test today, on the strict reading
COPY (
  WITH eligible AS (
    -- has a pavement record: eligibility already decided in sql/09
    SELECT c.block_id, c.full_name, c.len_ft, c.n_segments,
           c.pave_min_ft AS wn, c.pave_max_ft AS wx, 'pms' AS src,
           c.shoulder_each_side_ft AS sh,
           (n.cond_width AND n.cond_two_way AND n.cond_residence) AS nrr
    FROM nrr_candidate c
    JOIN narrow_residential n USING (block_id)
    UNION ALL
    -- no pavement record, but the curb lines can measure it. Same three
    -- statutory conditions, evaluated here because sql/09 requires a
    -- pavement width before it will consider a block at all.
    SELECT
      b.block_id, b.full_name, b.portland_len_ft, b.n_segments,
      w.curb_min_ft, w.curb_max_ft, 'curb',
      round((w.curb_max_ft - 18) / 2.0, 1),
      w.curb_max_ft <= 18
    FROM block b
    JOIN block_curb_width w USING (block_id)
    JOIN block_attr a USING (block_id)
    WHERE b.n_missing_road_width > 0
      AND w.curb_testable
      AND a.functional_class = 'UL'
      AND EXISTS (SELECT 1 FROM block_member m JOIN seg sg USING (street_oid)
                  WHERE m.block_id = b.block_id AND sg.direction = 1)
      AND EXISTS (SELECT 1 FROM block_member m JOIN seg_residential r USING (street_oid)
                  WHERE m.block_id = b.block_id AND r.is_residential)
  )
  SELECT
    e.block_id,
    coalesce(e.full_name, '(unnamed)') AS street,
    e.wn, e.wx, e.src, e.sh, e.nrr,
    round(e.len_ft)                    AS bl,
    e.n_segments                       AS nseg,
    round(s.row_width_ft, 1)           AS rw,
    ST_Transform(ST_Simplify(s.geom, 4.0),
                 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM eligible e
  JOIN block_member m USING (block_id)
  JOIN street_segment s USING (street_oid)
  ORDER BY e.block_id, s.street_oid
) TO 'site/public/data/blocks.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326',
        LAYER_CREATION_OPTIONS 'COORDINATE_PRECISION=5');

-- Narrowings from the curb profile (sql/11): the stretch of street each one
-- occupies, not a marker beside it. Nothing in PBOT's pavement records can
-- see these at all.
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
    (SELECT count(*) FROM nrr_candidate)                       AS eligible_blocks,
    (SELECT round(sum(len_ft) / 5280.0, 1) FROM nrr_candidate) AS eligible_miles,
    (SELECT count(*) FROM narrow_residential
      WHERE n_missing_pave = 0 AND cond_width AND cond_two_way AND cond_residence)
                                                               AS strict_blocks,
    (SELECT round(sum(len_ft) / 5280.0, 1) FROM narrow_residential
      WHERE n_missing_pave = 0 AND cond_width AND cond_two_way AND cond_residence)
                                                               AS strict_miles,
    (SELECT count(*) FROM curb_pinch)                          AS narrowings,
    (SELECT count(*) FROM curb_pinch WHERE min_gap_ft <= 18)   AS narrowings_under_18,
    (SELECT count(*) FROM block WHERE n_missing_road_width > 0) AS untestable_blocks,
    (SELECT round(sum(portland_len_ft) / 5280.0, 1) FROM block
      WHERE n_missing_road_width > 0)                          AS untestable_miles
) TO 'site/public/data/totals.json' (FORMAT JSON, ARRAY false);
