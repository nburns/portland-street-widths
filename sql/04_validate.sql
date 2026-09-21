-- Validation, right of way first. Everything here is a report, not a
-- transformation; the point is to know where the numbers are weak before
-- anyone uses them.
LOAD spatial;

.print
.print ========== ROW coverage and confidence ==========
SELECT
  row_confidence,
  count(*)                                           AS segments,
  round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct,
  round(sum(len_ft) / 5280.0, 1)                     AS miles,
  round(median(row_width_ft), 1)                     AS median_row_ft,
  round(median(row_width_spread_ft), 1)              AS median_spread_ft
FROM street_segment GROUP BY row_confidence ORDER BY segments DESC;

SELECT
  count(*)                                        AS segments,
  count(row_width_ft)                             AS measured_both_edges,
  count(row_width_any_ft)                         AS measured_or_estimated,
  count(*) FILTER (WHERE row_confidence IN ('high','medium')) AS confident,
  round(median(row_width_ft), 1)                   AS median_row_ft
FROM street_segment;

.print
.print ========== why a ROW measurement is missing, by transect ==========
SELECT status, count(*) AS transects,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM transect_width GROUP BY status ORDER BY transects DESC;

.print
.print ========== independent check: do sidewalks fall inside the measured ROW? ==========
-- A sidewalk polygon lies within the right of way by definition. Project every
-- sidewalk crossing onto the transect axis and see whether it sits between the
-- two ROW edges derived from taxlots. Sampled rather than exhaustive: the
-- answer is a rate, and 25k transects pins it down.
CREATE OR REPLACE TEMP TABLE sw_box AS
SELECT oid, geom,
       ST_XMin(geom) AS xmin, ST_XMax(geom) AS xmax,
       ST_YMin(geom) AS ymin, ST_YMax(geom) AS ymax
FROM sidewalks;

CREATE OR REPLACE TEMP TABLE sw_tile AS
SELECT s.oid, gx.v AS gx, gy.v AS gy
FROM sw_box s,
     unnest(range((s.xmin / 300.0)::BIGINT, (s.xmax / 300.0)::BIGINT + 1)) AS gx(v),
     unnest(range((s.ymin / 300.0)::BIGINT, (s.ymax / 300.0)::BIGINT + 1)) AS gy(v);

CREATE OR REPLACE TEMP TABLE sw_sample AS
SELECT tw.transect_id, tw.left_ft, tw.right_ft,
       t.tr, t.cx, t.cy, t.ux, t.uy, t.xmin, t.xmax, t.ymin, t.ymax
FROM transect_width tw JOIN transect t USING (transect_id)
WHERE tw.status = 'ok'
USING SAMPLE 25000 ROWS (reservoir, 42);

CREATE OR REPLACE TEMP TABLE sw_cross AS
WITH cand AS (
  SELECT DISTINCT s.transect_id, w.oid
  FROM sw_sample s,
       unnest(range((s.xmin / 300.0)::BIGINT, (s.xmax / 300.0)::BIGINT + 1)) AS gx(v),
       unnest(range((s.ymin / 300.0)::BIGINT, (s.ymax / 300.0)::BIGINT + 1)) AS gy(v)
  JOIN sw_tile w ON w.gx = gx.v AND w.gy = gy.v
), hit AS (
  SELECT c.transect_id, c.oid, ST_Intersection(s.tr, b.geom) AS x,
         s.cx, s.cy, s.ux, s.uy, s.left_ft, s.right_ft
  FROM cand c
  JOIN sw_sample s ON s.transect_id = c.transect_id
  JOIN sw_box    b ON b.oid         = c.oid
  WHERE s.xmax >= b.xmin AND s.xmin <= b.xmax
    AND s.ymax >= b.ymin AND s.ymin <= b.ymax
    AND ST_Intersects(s.tr, b.geom)
), part AS (
  SELECT h.*, d.rec.geom AS seg_x
  FROM hit h, unnest(ST_Dump(h.x)) AS d(rec)
  WHERE ST_GeometryType(d.rec.geom) = 'LINESTRING'
)
SELECT
  transect_id, left_ft, right_ft,
  least(   (ST_X(ST_StartPoint(seg_x)) - cx) * ux + (ST_Y(ST_StartPoint(seg_x)) - cy) * uy,
           (ST_X(ST_EndPoint(seg_x))   - cx) * ux + (ST_Y(ST_EndPoint(seg_x))   - cy) * uy) AS s_lo,
  greatest((ST_X(ST_StartPoint(seg_x)) - cx) * ux + (ST_Y(ST_StartPoint(seg_x)) - cy) * uy,
           (ST_X(ST_EndPoint(seg_x))   - cx) * ux + (ST_Y(ST_EndPoint(seg_x))   - cy) * uy) AS s_hi
FROM part;

-- Only the sidewalk immediately beside this street counts. A 250 ft reach
-- crosses the sidewalks of neighbouring streets too, and those are correctly
-- outside this segment's ROW - counting them would invent a 36% failure rate.
CREATE OR REPLACE TEMP TABLE sw_nearest AS
SELECT transect_id, 'left' AS side, left_ft AS edge_ft,
       -- nearest crossing on the left: the one whose inner edge is closest to 0
       max_by(s_lo, s_hi) AS far_ft
FROM sw_cross WHERE s_hi <= 0.0 GROUP BY transect_id, left_ft
UNION ALL
SELECT transect_id, 'right' AS side, right_ft AS edge_ft,
       min_by(s_hi, s_lo) AS far_ft
FROM sw_cross WHERE s_lo >= 0.0 GROUP BY transect_id, right_ft;

SELECT
  count(*)                                                     AS nearest_sidewalks_checked,
  count(DISTINCT transect_id)                                  AS transects,
  count(*) FILTER (WHERE abs(far_ft) <= edge_ft + 1.0)         AS inside_row,
  round(100.0 * count(*) FILTER (WHERE abs(far_ft) <= edge_ft + 1.0)
        / nullif(count(*), 0), 1)                              AS pct_inside_row,
  round(median(greatest(0.0, abs(far_ft) - edge_ft)), 2)        AS median_overshoot_ft
FROM sw_nearest;

SELECT
  CASE
    WHEN abs(far_ft) - edge_ft <= 1.0  THEN 'inside ROW (<= 1 ft slack)'
    WHEN abs(far_ft) - edge_ft <= 3.0  THEN 'over by 1-3 ft'
    WHEN abs(far_ft) - edge_ft <= 10.0 THEN 'over by 3-10 ft'
    ELSE 'over by more than 10 ft'
  END AS containment,
  count(*) AS sidewalks,
  round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM sw_nearest GROUP BY containment ORDER BY sidewalks DESC;

.print
.print ========== ROW width distribution, 2 ft bins (top 15) ==========
SELECT (round(row_width_ft / 2.0) * 2)::INT AS row_width_bin_ft,
       count(*) AS segments, round(sum(len_ft) / 5280.0, 1) AS miles
FROM street_segment WHERE row_width_ft IS NOT NULL
GROUP BY row_width_bin_ft ORDER BY segments DESC LIMIT 15;

.print
.print ========== modal ROW width, high-confidence segments only ==========
SELECT row_width_mode_ft, count(*) AS segments, round(sum(len_ft) / 5280.0, 1) AS miles
FROM street_segment WHERE row_confidence = 'high'
GROUP BY row_width_mode_ft ORDER BY segments DESC LIMIT 12;

.print
.print ========== is the centerline centred in the ROW? ==========
SELECT
  CASE
    WHEN abs(row_offcenter_ft) <= 1.0  THEN 'centred (<= 1 ft)'
    WHEN abs(row_offcenter_ft) <= 3.0  THEN 'off by 1-3 ft'
    WHEN abs(row_offcenter_ft) <= 10.0 THEN 'off by 3-10 ft'
    ELSE 'off by more than 10 ft'
  END AS centring,
  count(*) AS segments,
  round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM street_segment WHERE row_offcenter_ft IS NOT NULL
GROUP BY centring ORDER BY segments DESC;

.print
.print ========== ROW coverage by street type ==========
SELECT type_code,
       count(*) AS segments,
       count(row_width_ft) AS measured,
       round(100.0 * count(row_width_ft) / count(*), 1) AS pct_measured,
       round(median(row_width_ft), 1) AS median_row_ft,
       round(sum(len_ft) / 5280.0, 1) AS miles
FROM street_segment GROUP BY type_code ORDER BY segments DESC LIMIT 12;

.print
.print ========== ROW minus roadway: is the leftover space plausible? ==========
SELECT
  CASE
    WHEN non_roadway_ft <  0   THEN 'negative (pavement wider than ROW)'
    WHEN non_roadway_ft <  6   THEN '0-6 ft'
    WHEN non_roadway_ft < 16   THEN '6-16 ft'
    WHEN non_roadway_ft < 30   THEN '16-30 ft'
    ELSE '30+ ft'
  END AS leftover,
  count(*) AS segments,
  round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM street_segment WHERE non_roadway_ft IS NOT NULL
GROUP BY leftover ORDER BY segments DESC;

.print
.print ========== outliers to quarantine ==========
SELECT 'ROW edge hit the 250 ft transect reach (width is a lower bound)' AS check,
       count(*) AS segments FROM street_segment WHERE row_flag_at_transect_cap
UNION ALL SELECT 'row_width < 20 ft',       count(*) FROM street_segment WHERE row_width_ft < 20
UNION ALL SELECT 'row_width > 200 ft',      count(*) FROM street_segment WHERE row_width_ft > 200
UNION ALL SELECT 'pavement wider than ROW', count(*) FROM street_segment WHERE non_roadway_ft < 0
UNION ALL SELECT 'road_width > 100 ft',     count(*) FROM street_segment WHERE road_width_ft > 100
UNION ALL SELECT 'road_width < 8 ft',       count(*) FROM street_segment WHERE road_width_ft < 8;

.print
.print ========== join coverage: PMS -> street centerline ==========
SELECT
  count(*)                                       AS pms_rows_in_portland,
  count(*) FILTER (WHERE localid IS NULL)        AS localid_unparseable,
  count(DISTINCT localid)                        AS distinct_localids
FROM pms_portland;

SELECT count(*) AS pms_localids_absent_from_streets
FROM (SELECT DISTINCT localid FROM pms_portland WHERE localid IS NOT NULL) p
WHERE NOT EXISTS (SELECT 1 FROM streets s WHERE s.localid = p.localid);

.print
.print ========== independent check: PBOT curb-extension roadway width ==========
-- Curb Extension Policy carries its own Pavement_RoadWidthFt on TSP segments.
-- Match it to the nearest street segment geometrically, since it shares no key.
CREATE OR REPLACE TEMP TABLE ce_mid AS
SELECT row_number() OVER () AS ce_id, road_width_ft AS ce_width_ft,
       ST_Centroid(geom) AS mid
FROM curb_extension WHERE road_width_ft IS NOT NULL;

CREATE OR REPLACE TEMP TABLE ce_match AS
WITH ce_tile AS (
  SELECT ce_id, (ST_X(mid) / 300.0)::BIGINT AS gx, (ST_Y(mid) / 300.0)::BIGINT AS gy, mid, ce_width_ft
  FROM ce_mid
), seg_tile AS (
  SELECT s.street_oid, gx.v AS gx, gy.v AS gy, s.geom
  FROM street_segment s,
       unnest(range((ST_XMin(s.geom) / 300.0)::BIGINT - 1, (ST_XMax(s.geom) / 300.0)::BIGINT + 2)) AS gx(v),
       unnest(range((ST_YMin(s.geom) / 300.0)::BIGINT - 1, (ST_YMax(s.geom) / 300.0)::BIGINT + 2)) AS gy(v)
  WHERE s.road_width_ft IS NOT NULL
), pairs AS (
  -- DISTINCT because a segment spanning several tiles meets the same curb
  -- extension once per tile, and a duplicate at the same distance makes the
  -- nearest-match below depend on which copy the scheduler ranked first.
  SELECT DISTINCT c.ce_id, c.ce_width_ft, t.street_oid, ST_Distance(c.mid, t.geom) AS d
  FROM ce_tile c JOIN seg_tile t USING (gx, gy)
), ranked AS (
  -- street_oid breaks the tie: a curb extension beside an intersection is
  -- equidistant from two centerlines, and without it the winner alternated
  -- between runs and moved the published agreement rate.
  SELECT ce_id, ce_width_ft, street_oid, d,
         row_number() OVER (PARTITION BY ce_id ORDER BY d, street_oid) AS rn
  FROM pairs
)
SELECT ce_id, ce_width_ft, street_oid, d FROM ranked WHERE rn = 1 AND d < 30.0;

SELECT
  count(*)                                                           AS matched_segments,
  count(*) FILTER (WHERE ce_width_ft = road_width_ft)                AS exact_agreement,
  round(100.0 * count(*) FILTER (WHERE abs(ce_width_ft - road_width_ft) <= 2)
        / nullif(count(*), 0), 1)                                    AS pct_within_2_ft,
  round(median(abs(ce_width_ft - road_width_ft)), 1)                  AS median_abs_diff_ft
FROM ce_match m JOIN street_segment s USING (street_oid);

.print
.print ========== spot check: NE SISKIYOU ST, 7300 block ==========
SELECT street_oid, left_from, left_to, len_ft,
       row_width_ft, row_width_mode_ft, row_width_spread_ft,
       row_left_ft, row_right_ft, row_offcenter_ft, row_confidence,
       road_width_ft, non_roadway_ft
FROM street_segment
WHERE full_name = 'NE SISKIYOU ST' AND left_from BETWEEN 7200 AND 7500
ORDER BY left_from;

.print
.print ========== widest and narrowest ROW, high confidence, 500 ft or longer ==========
SELECT full_name, row_width_ft, road_width_ft, len_ft, functional_class
FROM street_segment
WHERE row_confidence = 'high' AND len_ft >= 500 AND NOT row_flag_at_transect_cap
ORDER BY row_width_ft DESC LIMIT 8;

SELECT full_name, row_width_ft, road_width_ft, len_ft, functional_class
FROM street_segment
WHERE row_confidence = 'high' AND len_ft >= 500
ORDER BY row_width_ft ASC LIMIT 8;
