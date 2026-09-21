-- ORS 801.368 "narrow residential roadway"
--
--   "'Narrow residential roadway' means a two-way roadway that is:
--    (1) Located in a residence district; and
--    (2) Not more than 18 feet wide at any point between two intersections or
--        between an intersection and the end of the roadway."
--
-- Three conditions, and the width one is not the whole test.
--
-- What "roadway" means here is set by ORS 801.450: "the portion of a highway
-- that is improved, designed or ordinarily used for vehicular travel,
-- EXCLUSIVE OF THE SHOULDER." So:
--   * shoulders come out      -> PaveWidth, not RoadWidth, is the right field;
--                                RoadWidth is PBOT's graded roadway and on
--                                unimproved streets it includes gravel shoulder
--   * parking lanes stay in   -> a parking lane is part of the roadway, so
--                                nothing is subtracted for on-street parking
-- PBOT's own speed-limit guidance agrees and goes further: pavement markings
-- that narrow the travel way to 18 ft do not make a narrow residential street.
-- Actual pavement width is what counts.
LOAD spatial;

-- Pavement width per centerline segment, as a maximum over its pavement
-- sections - the finest resolution the source supports for "at any point".
CREATE OR REPLACE TABLE seg_pavement AS
SELECT
  s.street_oid,
  max(p.pave_width_ft) AS pave_max_ft,
  min(p.pave_width_ft) AS pave_min_ft,
  max(p.road_width_ft) AS road_max_ft
FROM street_segment s
JOIN pms_portland p ON p.localid = s.localid
GROUP BY s.street_oid;

-- Residence district, approximated by residential base zoning. Zoning polygons
-- do not reliably cover the right of way, so the test is proximity: a block is
-- treated as residential when residential zoning lies within 60 ft of its
-- centerline, which is a lot's frontage rather than its far boundary.
CREATE OR REPLACE TABLE seg_residential AS
WITH zbox AS (
  SELECT ST_XMin(geom) AS xmin, ST_XMax(geom) AS xmax,
         ST_YMin(geom) AS ymin, ST_YMax(geom) AS ymax, geom
  FROM zoning WHERE is_residential
), sbox AS (
  SELECT street_oid, geom,
         ST_XMin(geom) AS xmin, ST_XMax(geom) AS xmax,
         ST_YMin(geom) AS ymin, ST_YMax(geom) AS ymax
  FROM street_segment
)
SELECT s.street_oid, count(z.geom) > 0 AS is_residential
FROM sbox s
LEFT JOIN zbox z
  ON s.xmax + 60 >= z.xmin AND s.xmin - 60 <= z.xmax
 AND s.ymax + 60 >= z.ymin AND s.ymin - 60 <= z.ymax
 AND ST_DWithin(s.geom, z.geom, 60.0)
GROUP BY s.street_oid;

-- Block-level test. Every condition is evaluated over the whole block, because
-- the statute measures between intersections, and a block only counts as
-- testable when every one of its segments has a pavement width on record.
CREATE OR REPLACE TABLE narrow_residential AS
SELECT
  m.block_id,
  mode(sg.full_name)                                    AS full_name,
  count(*)                                              AS n_segments,
  round(sum(s.len_ft), 1)                               AS len_ft,
  max(sp.pave_max_ft)                                   AS pave_max_ft,
  min(sp.pave_min_ft)                                   AS pave_min_ft,
  max(sp.road_max_ft)                                   AS road_max_ft,
  count(*) FILTER (WHERE sp.pave_max_ft IS NULL)        AS n_missing_pave,
  bool_and(sg.direction = 1)                            AS all_two_way,
  bool_or(sr.is_residential)                            AS any_residential,
  bool_and(sr.is_residential)                           AS all_residential,
  -- the three statutory conditions
  count(*) FILTER (WHERE sp.pave_max_ft IS NULL) = 0
    AND max(sp.pave_max_ft) <= 18                       AS cond_width,
  bool_and(sg.direction = 1)                            AS cond_two_way,
  bool_or(sr.is_residential)                            AS cond_residence
FROM block_member m
JOIN street_segment s  ON s.street_oid  = m.street_oid
JOIN seg            sg ON sg.street_oid = m.street_oid
LEFT JOIN seg_pavement   sp ON sp.street_oid = m.street_oid
LEFT JOIN seg_residential sr ON sr.street_oid = m.street_oid
GROUP BY m.block_id;

.print
.print ========== ORS 801.368 conditions applied in sequence ==========
SELECT
  'all testable blocks'                        AS step,
  count(*)                                     AS blocks,
  round(sum(len_ft) / 5280.0, 1)               AS miles
FROM narrow_residential WHERE n_missing_pave = 0
UNION ALL SELECT '+ pavement <= 18 ft at every point',
  count(*), round(sum(len_ft) / 5280.0, 1)
FROM narrow_residential WHERE n_missing_pave = 0 AND cond_width
UNION ALL SELECT '+ two-way',
  count(*), round(sum(len_ft) / 5280.0, 1)
FROM narrow_residential WHERE n_missing_pave = 0 AND cond_width AND cond_two_way
UNION ALL SELECT '+ in a residence district  = ORS 801.368',
  count(*), round(sum(len_ft) / 5280.0, 1)
FROM narrow_residential
WHERE n_missing_pave = 0 AND cond_width AND cond_two_way AND cond_residence;

.print
.print ========== which width field: RoadWidth includes the shoulder ==========
SELECT
  'PaveWidth <= 18 (roadway, exclusive of shoulder)' AS field,
  count(*) AS blocks, round(sum(len_ft) / 5280.0, 1) AS miles
FROM narrow_residential WHERE n_missing_pave = 0 AND pave_max_ft <= 18
UNION ALL SELECT 'RoadWidth <= 18 (graded roadway, includes shoulder)',
  count(*), round(sum(len_ft) / 5280.0, 1)
FROM narrow_residential WHERE n_missing_pave = 0 AND road_max_ft <= 18;

.print
.print ========== what each condition removes, on its own ==========
SELECT
  count(*) FILTER (WHERE NOT cond_two_way)   AS fails_two_way,
  round(sum(len_ft) FILTER (WHERE NOT cond_two_way) / 5280.0, 1)   AS miles_one_way,
  count(*) FILTER (WHERE NOT cond_residence) AS fails_residence,
  round(sum(len_ft) FILTER (WHERE NOT cond_residence) / 5280.0, 1) AS miles_non_residential
FROM narrow_residential WHERE n_missing_pave = 0 AND cond_width;

.print
.print ========== pavement width distribution of qualifying blocks ==========
SELECT pave_max_ft, count(*) AS blocks, round(sum(len_ft) / 5280.0, 1) AS miles
FROM narrow_residential
WHERE n_missing_pave = 0 AND cond_width AND cond_two_way AND cond_residence
GROUP BY pave_max_ft ORDER BY pave_max_ft;

.print
.print ========== longest qualifying blocks ==========
SELECT full_name, round(len_ft) AS len_ft, n_segments, pave_min_ft, pave_max_ft, road_max_ft
FROM narrow_residential
WHERE n_missing_pave = 0 AND cond_width AND cond_two_way AND cond_residence
ORDER BY len_ft DESC LIMIT 12;

-- Export. The unpaved placeholders are dropped: 53 blocks carry PaveWidth = 1,
-- which is PBOT's marker for "not paved", not a one-foot road - their graded
-- RoadWidth averages 28 ft, so they are unpaved streets rather than narrow ones.
CREATE OR REPLACE TABLE narrow_residential_final AS
SELECT * FROM narrow_residential
WHERE n_missing_pave = 0 AND cond_width AND cond_two_way AND cond_residence
  AND pave_max_ft > 1;

COPY (
  SELECT
    n.full_name              AS street,
    n.pave_max_ft            AS pavement_max_ft,
    n.pave_min_ft            AS pavement_min_ft,
    n.road_max_ft            AS graded_roadway_max_ft,
    round(n.len_ft)          AS block_len_ft,
    n.n_segments,
    s.row_width_ft           AS row_width_ft,
    ST_Transform(s.geom, 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM narrow_residential_final n
  JOIN block_member m USING (block_id)
  JOIN street_segment s USING (street_oid)
) TO 'out/narrow_residential_roadways.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326');

SELECT count(*) AS blocks, round(sum(len_ft) / 5280.0, 1) AS miles
FROM narrow_residential_final;
