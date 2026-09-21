-- Curb-to-curb width at 5 ft resolution, measured from the curb lines.
--
-- Every other width in this pipeline comes from PBOT's Pavement Management
-- System, which carries one PaveWidth per pavement section. ORS 801.368 asks
-- whether a roadway is "not more than 18 feet wide at any point between two
-- intersections", and a pavement section is not a point: a stormwater planter,
-- a curb extension or a parking-lane island is invisible to PMS. SE Taylor at
-- SE 50th is on record as a flat 30 ft; a pair of bioswales pinches it to 20.
--
-- The curbs table has been loaded since the beginning and nothing read it. It
-- is the only source here with the resolution to answer "at any point".
--
-- Method is stage 02's, with points instead of intervals: walk the centerline
-- every 5 ft, take the local perpendicular, intersect it with nearby curb
-- lines, project each crossing onto the transect axis as a signed distance
-- from the centerline, and take the nearest crossing on each side. Their
-- separation is the roadway at that station.
--
-- This stage measures; it does not decide the statute. curb_max_ft and
-- curb_min_ft are both exported so either reading of "at any point" is a
-- downstream filter, and the PMS-based answer in 08/09 is left untouched.
LOAD spatial;

SET VARIABLE spacing = 5.0;   -- station interval, ft. A planter is 15-25 ft long.
SET VARIABLE chord   = 10.0;  -- half-chord for the local bearing, ft (as stage 02)
SET VARIABLE margin  = 20.0;  -- transect reach beyond the expected roadway edge, ft
SET VARIABLE minhalf = 25.0;  -- floor on transect half-length, ft
SET VARIABLE assumed = 40.0;  -- roadway width assumed where PMS has no record, ft
SET VARIABLE tile    = 100.0; -- spatial grid cell, ft. Only affects speed.
SET VARIABLE corner  = 30.0;  -- curb-return exclusion radius at intersections, ft
SET VARIABLE thresh  = 18.0;  -- the ORS 801.368 figure
SET VARIABLE pinch   = 24.0;  -- widest station that can count as a narrowing, ft
SET VARIABLE drop    = 3.0;   -- how much narrower than its own street a station must be, ft
SET VARIABLE minrun  = 10.0;  -- shortest narrowing worth recording, ft (3 stations)

-- ===========================================================================
-- Which segment ends are real intersections
--
-- Curb returns flare the measured gap to 36-42 ft over the last ~15 ft of a
-- segment that ends at an intersection, and that flare is intersection
-- geometry rather than the block's roadway. Ends at a degree-2 node are
-- mid-block continuations of the same block and get no exclusion - which is
-- what keeps this a block-level measure rather than a per-segment one.
--
-- Excluding corners LOWERS the block maximum and so makes blocks MORE likely
-- to pass an 18 ft test. The report prints the maximum both ways.
--
-- Segment geometry starts at f_node: ST_StartPoint matches the adjoining
-- segment's ST_EndPoint on 145,481 of 145,560 shared-node pairs.
-- ===========================================================================
CREATE OR REPLACE TABLE seg_end AS
SELECT
  s.street_oid,
  coalesce(df.degree, 1) <> 2 AS f_is_intersection,
  coalesce(dt.degree, 1) <> 2 AS t_is_intersection
FROM street_segment s
JOIN streets t ON t.street_oid = s.street_oid
LEFT JOIN node_degree df ON df.node = t.f_node
LEFT JOIN node_degree dt ON dt.node = t.t_node;

-- ===========================================================================
-- Transects
--
-- Half-length is adaptive rather than the fixed 250 ft of stage 02. A long
-- reach would let a transect crossing a driveway curb-cut find the curb on the
-- far side of the street and report a roadway twice as wide as it is. Sizing
-- the window from the PMS width plus 20 ft means a missing curb yields NULL -
-- excluded from the aggregate - instead of a wrong number.
--
-- Geometry is rebuilt from cx/cy/ux/uy where it is needed rather than stored:
-- 2.8M persisted linestrings would cost more disk than the rest of the
-- database, and the tile join only needs the bounding box as plain numbers.
-- ===========================================================================
CREATE OR REPLACE TABLE curb_transect AS
WITH s AS (
  SELECT
    s.street_oid, s.geom, s.len_ft,
    greatest(getvariable('minhalf')::DOUBLE,
             coalesce(greatest(s.road_width_ft, s.pave_width_ft),
                      s.road_width_ft, s.pave_width_ft,
                      getvariable('assumed')::DOUBLE) / 2.0
             + getvariable('margin')::DOUBLE) AS half,
    e.f_is_intersection, e.t_is_intersection
  FROM street_segment s
  JOIN seg_end e USING (street_oid)
  WHERE s.len_ft > 2 * getvariable('spacing')::DOUBLE
), pts AS (
  SELECT
    z.street_oid, z.geom, z.len_ft, z.half,
    z.f_is_intersection, z.t_is_intersection,
    i.v AS sample_no,
    i.v * getvariable('spacing')::DOUBLE AS ft_along
  FROM s z,
       unnest(range(0, (z.len_ft / getvariable('spacing')::DOUBLE)::INT + 1)) AS i(v)
), geo AS (
  SELECT
    p.street_oid, p.sample_no, p.ft_along, p.len_ft, p.half,
    (p.ft_along < getvariable('corner')::DOUBLE AND p.f_is_intersection)
      OR (p.len_ft - p.ft_along < getvariable('corner')::DOUBLE AND p.t_is_intersection)
      AS in_corner,
    ST_LineInterpolatePoint(p.geom, p.ft_along / p.len_ft) AS c,
    ST_LineInterpolatePoint(p.geom,
      greatest(p.ft_along - getvariable('chord')::DOUBLE, 0.0) / p.len_ft) AS a,
    ST_LineInterpolatePoint(p.geom,
      least(p.ft_along + getvariable('chord')::DOUBLE, p.len_ft) / p.len_ft) AS b
  FROM pts p WHERE p.ft_along <= p.len_ft
), dirs AS (
  SELECT
    street_oid, sample_no, ft_along, len_ft, half, in_corner,
    ST_X(c) AS cx, ST_Y(c) AS cy,
    ST_X(b) - ST_X(a) AS dx,
    ST_Y(b) - ST_Y(a) AS dy
  FROM geo
), unit AS (
  SELECT *, sqrt(dx * dx + dy * dy) AS m FROM dirs
)
SELECT
  row_number() OVER (ORDER BY street_oid, sample_no) AS transect_id,
  street_oid, sample_no, ft_along, len_ft, half, in_corner,
  cx, cy, -dy / m AS ux, dx / m AS uy,
  cx - abs(half * dy / m) AS xmin,
  cx + abs(half * dy / m) AS xmax,
  cy - abs(half * dx / m) AS ymin,
  cy + abs(half * dx / m) AS ymax
FROM unit WHERE m > 0;

-- ===========================================================================
-- Crossings
--
-- Same explicit tile join as stage 02: DuckDB will not reliably choose a
-- spatial join at this scale. The grid is tighter (100 ft, not 300) because
-- these transects are an order of magnitude shorter than the ROW ones.
-- ===========================================================================
CREATE OR REPLACE TABLE curb_box AS
SELECT oid, curb_type, curb_style,
       ST_XMin(geom) AS xmin, ST_XMax(geom) AS xmax,
       ST_YMin(geom) AS ymin, ST_YMax(geom) AS ymax
FROM curbs;

CREATE OR REPLACE TABLE curb_tile AS
SELECT c.oid, gx.v AS gx, gy.v AS gy
FROM curb_box c,
     unnest(range((c.xmin / getvariable('tile')::DOUBLE)::BIGINT,
                  (c.xmax / getvariable('tile')::DOUBLE)::BIGINT + 1)) AS gx(v),
     unnest(range((c.ymin / getvariable('tile')::DOUBLE)::BIGINT,
                  (c.ymax / getvariable('tile')::DOUBLE)::BIGINT + 1)) AS gy(v);

CREATE OR REPLACE TABLE curb_transect_tile AS
SELECT t.transect_id, gx.v AS gx, gy.v AS gy
FROM curb_transect t,
     unnest(range((t.xmin / getvariable('tile')::DOUBLE)::BIGINT,
                  (t.xmax / getvariable('tile')::DOUBLE)::BIGINT + 1)) AS gx(v),
     unnest(range((t.ymin / getvariable('tile')::DOUBLE)::BIGINT,
                  (t.ymax / getvariable('tile')::DOUBLE)::BIGINT + 1)) AS gy(v);

-- A curb line collinear with a transect would intersect in a LINESTRING rather
-- than a POINT; only POINT parts are kept, so such a crossing is dropped
-- rather than mismeasured. It needs a curb running perpendicular to its own
-- street and is not observed here.
CREATE OR REPLACE TABLE curb_crossing AS
WITH cand AS (
  SELECT DISTINCT tt.transect_id, ct.oid
  FROM curb_transect_tile tt JOIN curb_tile ct USING (gx, gy)
), near AS (
  -- exact bounding-box overlap first: plain arithmetic that discards most of
  -- what the tile join let through, before any geometry work happens
  SELECT c.transect_id, c.oid,
         t.cx, t.cy, t.ux, t.uy,
         ST_MakeLine(ST_Point(t.cx - t.half * t.ux, t.cy - t.half * t.uy),
                     ST_Point(t.cx + t.half * t.ux, t.cy + t.half * t.uy)) AS tr
  FROM cand c
  JOIN curb_transect t ON t.transect_id = c.transect_id
  JOIN curb_box      b ON b.oid         = c.oid
  WHERE t.xmax >= b.xmin AND t.xmin <= b.xmax
    AND t.ymax >= b.ymin AND t.ymin <= b.ymax
), hit AS (
  SELECT n.transect_id, n.oid, b.curb_type, b.curb_style,
         n.cx, n.cy, n.ux, n.uy,
         ST_Intersection(n.tr, c.geom) AS x
  FROM near n
  JOIN curbs    c ON c.oid = n.oid
  JOIN curb_box b ON b.oid = n.oid
  WHERE ST_Intersects(n.tr, c.geom)
)
SELECT DISTINCT
  h.transect_id, h.oid, h.curb_type, h.curb_style,
  (ST_X(d.rec.geom) - h.cx) * h.ux + (ST_Y(d.rec.geom) - h.cy) * h.uy AS sdist
FROM hit h, unnest(ST_Dump(h.x)) AS d(rec)
WHERE ST_GeometryType(d.rec.geom) = 'POINT';

-- ===========================================================================
-- Per-station width
--
-- The nearest crossing either side of the centerline. The 0.5 ft dead band
-- stops a curb drawn on the centerline itself - a traffic circle, a median
-- nose - from pairing with itself and reporting a near-zero roadway.
--
-- curb_type has no published domain, the same situation as TYPE on the
-- centerlines and LineType on the markings inventory. Inferred from the data,
-- with the evidence printed in the report:
--
--   3110  street curb, the roadway edge. 56,183 features, 2,982 mi, median
--         200 ft long, median 15.9 ft from the centerline.
--   3120  corner return. 41,068 features, median 24 ft long, 89% of them
--         within 60 ft of a degree-3 node (90.3%, median 31 ft).
--   3130  median or raised island curb, NOT a roadway edge. 2,843 features;
--         10th-percentile offset 3.4 ft from the centerline against 12.0 ft
--         for 3110, and the stations with 3130 on both sides are on NE MLK,
--         SE Powell, SW Naito and S Macadam, reporting 9-11 ft against PMS
--         roadways of 58-76 ft. That is the median being measured, not a lane.
--   3140  shoulder line (curb_style SHOULDER). ORS 801.450 defines the
--         roadway "exclusive of the shoulder", so this is not a roadway edge
--         either.
--   3150  flexcurb, 378 features averaging 11 ft: in-roadway separators.
--
-- Nothing is dropped on the strength of that inference. Every station keeps
-- its width and carries flags, and `is_outer_curb` marks the stations bounded
-- by street curb on both sides - the ones that are unambiguously a roadway.
-- ===========================================================================
CREATE OR REPLACE TABLE curb_gap AS
WITH pos AS (
  SELECT transect_id, sdist, curb_type, curb_style,
         row_number() OVER (PARTITION BY transect_id ORDER BY sdist) AS rn
  FROM curb_crossing WHERE sdist > 0.5
), neg AS (
  SELECT transect_id, sdist, curb_type, curb_style,
         row_number() OVER (PARTITION BY transect_id ORDER BY sdist DESC) AS rn
  FROM curb_crossing WHERE sdist < -0.5
)
SELECT
  t.transect_id, t.street_oid, t.sample_no, t.ft_along, t.len_ft,
  t.in_corner, t.half, t.cx, t.cy,
  p.sdist              AS right_ft,
  n.sdist              AS left_ft,
  p.sdist - n.sdist    AS gap_ft,
  -- A transect meeting the median curb on both sides has measured the median,
  -- not a roadway: on N Hayden Bay Dr it reports 4.7 ft from -2.6 to +2.1 of
  -- the centerline. That is the same class of error as a curb return, so it is
  -- excluded from every statistic rather than flagged and carried. gap_ft
  -- keeps the raw number for inspection; roadway_ft is what aggregates.
  CASE WHEN coalesce(p.curb_type = 3130 AND n.curb_type = 3130, false)
       THEN NULL ELSE p.sdist - n.sdist END AS roadway_ft,
  p.curb_type          AS right_curb_type,
  n.curb_type          AS left_curb_type,
  p.curb_style         AS right_curb_style,
  n.curb_style         AS left_curb_style,
  coalesce(p.sdist >= t.half - 1.0, false)
    OR coalesce(-n.sdist >= t.half - 1.0, false)            AS flag_at_window,
  p.sdist IS NULL AND n.sdist IS NULL                       AS flag_no_curb,
  (p.sdist IS NULL) <> (n.sdist IS NULL)                    AS flag_one_side,
  coalesce(p.curb_type = 3140 OR n.curb_type = 3140, false) AS flag_shoulder_edge,
  coalesce(p.curb_type = 3130 OR n.curb_type = 3130, false) AS flag_median_edge,
  coalesce(p.curb_type = 3130 AND n.curb_type = 3130, false) AS flag_median_span,
  coalesce(p.curb_type = 3150 OR n.curb_type = 3150, false) AS flag_flexcurb,
  coalesce(p.curb_type IN (3110, 3120)
       AND n.curb_type IN (3110, 3120), false)              AS is_outer_curb
FROM curb_transect t
LEFT JOIN pos p ON p.transect_id = t.transect_id AND p.rn = 1
LEFT JOIN neg n ON n.transect_id = t.transect_id AND n.rn = 1;

-- ===========================================================================
-- Per segment and per block
--
-- Statistics run over non-corner stations. curb_max_ft is the statutory
-- figure; curb_p95_ft is the outlier-resistant one, and the pair plays the
-- same role as row_width_ft against row_width_mode_ft - when they diverge, a
-- handful of stations are doing the work.
-- ===========================================================================
CREATE OR REPLACE TABLE seg_curb_width AS
SELECT
  street_oid,
  count(*)                                        AS n_transects,
  count(roadway_ft)                               AS n_measured,
  round(min(roadway_ft), 1)                       AS curb_min_ft,
  round(quantile_cont(roadway_ft, 0.05), 1)       AS curb_p05_ft,
  round(median(roadway_ft), 1)                    AS curb_median_ft,
  round(median(roadway_ft) FILTER (WHERE is_outer_curb), 1) AS curb_median_outer_ft,
  round(quantile_cont(roadway_ft, 0.95), 1)       AS curb_p95_ft,
  round(max(roadway_ft), 1)                       AS curb_max_ft,
  round(min(roadway_ft) FILTER (WHERE is_outer_curb), 1) AS curb_min_outer_ft,
  round(max(roadway_ft) FILTER (WHERE is_outer_curb), 1) AS curb_max_outer_ft,
  count(*) FILTER (WHERE is_outer_curb)           AS n_outer_curb,
  count(*) FILTER (WHERE flag_shoulder_edge)      AS n_shoulder_edge,
  count(*) FILTER (WHERE flag_median_edge)        AS n_median_edge,
  count(*) FILTER (WHERE flag_flexcurb)           AS n_flexcurb,
  count(*) FILTER (WHERE flag_at_window)          AS n_at_window,
  count(*) FILTER (WHERE roadway_ft <= getvariable('thresh')::DOUBLE) AS n_under_thresh
FROM curb_gap
WHERE NOT in_corner
GROUP BY street_oid;

-- Same over the whole block, plus the corner-inclusive maximum so the effect
-- of the exclusion is visible rather than assumed. The coverage gate is a
-- judgement call: a maximum computed from two fifths of a block is not a
-- maximum, and 0.8 is where the line is drawn.
CREATE OR REPLACE TABLE block_curb_width AS
WITH agg AS (
  SELECT
    b.block_id, b.full_name, b.n_segments, b.portland_len_ft,
    count(*) FILTER (WHERE NOT g.in_corner)                              AS n_transects,
    count(g.roadway_ft) FILTER (WHERE NOT g.in_corner)                   AS n_measured,
    min(g.roadway_ft) FILTER (WHERE NOT g.in_corner)                     AS curb_min_ft,
    median(g.roadway_ft) FILTER (WHERE NOT g.in_corner)                  AS curb_median_ft,
    quantile_cont(g.roadway_ft, 0.95) FILTER (WHERE NOT g.in_corner)     AS curb_p95_ft,
    max(g.roadway_ft) FILTER (WHERE NOT g.in_corner)                     AS curb_max_ft,
    max(g.roadway_ft)                                                    AS curb_max_with_corners_ft,
    min(g.roadway_ft) FILTER (WHERE NOT g.in_corner AND g.is_outer_curb) AS curb_min_outer_ft,
    max(g.roadway_ft) FILTER (WHERE NOT g.in_corner AND g.is_outer_curb) AS curb_max_outer_ft,
    count(*) FILTER (WHERE NOT g.in_corner AND g.is_outer_curb)          AS n_outer_curb,
    count(*) FILTER (WHERE NOT g.in_corner AND g.flag_shoulder_edge)     AS n_shoulder_edge,
    count(*) FILTER (WHERE NOT g.in_corner AND g.flag_median_edge)       AS n_median_edge,
    count(*) FILTER (WHERE NOT g.in_corner AND g.flag_flexcurb)          AS n_flexcurb,
    count(*) FILTER (WHERE NOT g.in_corner AND g.flag_at_window)         AS n_at_window,
    count(*) FILTER (WHERE NOT g.in_corner
                 AND g.roadway_ft <= getvariable('thresh')::DOUBLE)      AS n_under_thresh
  FROM block b
  JOIN block_member m USING (block_id)
  JOIN curb_gap     g USING (street_oid)
  GROUP BY b.block_id, b.full_name, b.n_segments, b.portland_len_ft
)
SELECT
  block_id, full_name, n_segments,
  round(portland_len_ft, 1)                  AS portland_len_ft,
  n_transects, n_measured,
  round(n_measured / nullif(n_transects, 0)::DOUBLE, 3) AS coverage,
  round(curb_min_ft, 1)                      AS curb_min_ft,
  round(curb_median_ft, 1)                   AS curb_median_ft,
  round(curb_p95_ft, 1)                      AS curb_p95_ft,
  round(curb_max_ft, 1)                      AS curb_max_ft,
  round(curb_max_with_corners_ft, 1)         AS curb_max_with_corners_ft,
  round(curb_min_outer_ft, 1)                AS curb_min_outer_ft,
  round(curb_max_outer_ft, 1)                AS curb_max_outer_ft,
  n_outer_curb, n_shoulder_edge, n_median_edge, n_flexcurb, n_at_window,
  n_under_thresh,
  round(n_under_thresh * getvariable('spacing')::DOUBLE, 1) AS under_thresh_ft,
  n_measured >= 0.8 * n_transects            AS curb_testable,
  -- How much the width can be trusted, and the reason it has to be said out
  -- loud. Only 3110/3120 is unambiguously the roadway edge. Where the nearest
  -- curb feature is something else the measurement is whatever that feature
  -- is: SE Clinton at SE 77th comes out at a flat 8.0 ft from a
  -- pair of shoulder lines at +/-4.0 ft of the centerline, on a street PBOT
  -- records as 22 ft and uncurbed. No threshold separates that from a real
  -- narrow street - the centerline is off-centre by more than 10 ft on 12.7%
  -- of segments, so an edge 4 ft away is normal on a genuinely narrow road -
  -- so it is labelled rather than guessed at.
  CASE WHEN n_measured = 0            THEN 'none'
       WHEN n_outer_curb = n_measured THEN 'street curb'
       WHEN n_outer_curb > 0          THEN 'mixed'
       ELSE                                'no street curb' END AS edge_quality
FROM agg;

-- ===========================================================================
-- Edge-line arithmetic, ORS 801.450
--
-- "Roadway" is the travelled portion "exclusive of the shoulder", so a block
-- wider than 18 ft can be brought inside ORS 801.368 by striping an edge line
-- and designating the pavement outside it as shoulder. sql/09 computes this
-- from one pavement-section figure per segment; here it comes from the widest
-- measured station, which is the constraint that actually binds.
--
-- The split between already-narrow and needs-a-line is the point of the table.
-- PBOT's Sept 23 2022 speed-limit memo accepts pavement that is physically no
-- wider than 18 ft and rejects "pavement markings that create an 18 foot or
-- narrower travel way"; PBOT's own Pedestrian Design Guide (May 2022, B.5.4.3)
-- says the opposite and allows paint, wands and planters. Only the
-- already-narrow share is safe from that objection either way.
-- ===========================================================================
CREATE OR REPLACE TABLE block_edge_line AS
SELECT
  block_id, full_name, portland_len_ft, curb_max_ft, curb_min_ft, coverage,
  edge_quality,
  round((curb_max_ft - getvariable('thresh')::DOUBLE) / 2.0, 1) AS edge_line_each_side_ft,
  round(curb_max_ft - getvariable('thresh')::DOUBLE, 1)         AS edge_line_one_side_ft,
  -- Both measured in station footage, so they add up to the measured part of
  -- the block. The rest is corner exclusion and unmeasured stations, which is
  -- neither already narrow nor in need of a line.
  under_thresh_ft                                               AS already_18_ft,
  round((n_measured - n_under_thresh) * getvariable('spacing')::DOUBLE, 1)
                                                                AS needs_line_ft,
  round(portland_len_ft - n_measured * getvariable('spacing')::DOUBLE, 1)
                                                                AS unmeasured_ft,
  -- the width test on its own, and the width test on a measurement that is
  -- unambiguously of a roadway. The second is the one to quote.
  curb_max_ft <= getvariable('thresh')::DOUBLE                  AS width_test_18ft,
  curb_max_ft <= getvariable('thresh')::DOUBLE
    AND edge_quality = 'street curb'                            AS confident_18ft
FROM block_curb_width
WHERE curb_testable;

-- ===========================================================================
-- Narrowings: runs of stations materially narrower than their own street
--
-- A narrowing is relative, not absolute. An absolute cut misses the case this
-- stage was built for - the bioswale pair on SE Taylor bottoms out at 20.3 ft,
-- so a 20 ft rule excludes the very thing it is looking for - while admitting
-- freeway ramps that drop from 60 ft to 8 ft at a gore curb. A station counts
-- when it is at least `drop` ft narrower than its own segment's median AND no
-- wider than `pinch` ft, and a run counts when it is at least `minrun` long.
--
-- Restricted to stations bounded by street curb on both sides. Without that
-- the inventory fills with medians: a transect across NE MLK meeting the
-- median curb either side reports 9 ft and looks like the narrowest street in
-- Portland. Non-outer stations stay in the sequence and count as not narrow,
-- so a run never bridges across one.
-- ===========================================================================
CREATE OR REPLACE TABLE curb_pinch AS
WITH f AS (
  SELECT g.*,
         g.is_outer_curb
           AND g.roadway_ft <= getvariable('pinch')::DOUBLE
           AND g.roadway_ft <= w.curb_median_outer_ft - getvariable('drop')::DOUBLE
           AS narrow
  FROM curb_gap g
  JOIN seg_curb_width w USING (street_oid)
  WHERE NOT g.in_corner
), marked AS (
  SELECT *,
         row_number() OVER (PARTITION BY street_oid ORDER BY ft_along)
       - row_number() OVER (PARTITION BY street_oid, narrow ORDER BY ft_along) AS grp
  FROM f
), runs AS (
  SELECT
    street_oid, grp,
    min(ft_along)                                                 AS start_ft,
    max(ft_along)                                                 AS end_ft,
    max(ft_along) - min(ft_along) + getvariable('spacing')::DOUBLE AS run_len_ft,
    min(roadway_ft)                                               AS min_gap_ft,
    arg_min(cx, roadway_ft)                                       AS cx,
    arg_min(cy, roadway_ft)                                       AS cy,
    arg_min(left_curb_style, roadway_ft)                          AS left_curb_style,
    arg_min(right_curb_style, roadway_ft)                         AS right_curb_style,
    bool_or(flag_shoulder_edge)                                   AS any_shoulder_edge
  FROM marked WHERE narrow GROUP BY street_oid, grp
  HAVING max(ft_along) - min(ft_along) + getvariable('spacing')::DOUBLE
         >= getvariable('minrun')::DOUBLE
)
SELECT
  row_number() OVER (ORDER BY r.street_oid, r.start_ft) AS pinch_id,
  r.street_oid, m.block_id, s.full_name,
  round(r.start_ft, 1)                                  AS start_ft,
  round(r.end_ft, 1)                                    AS end_ft,
  round(r.run_len_ft, 1)                                AS run_len_ft,
  round(r.min_gap_ft, 1)                                AS min_gap_ft,
  round(w.curb_median_outer_ft, 1)                      AS seg_median_ft,
  round(w.curb_median_outer_ft - r.min_gap_ft, 1)       AS narrowing_ft,
  s.functional_class, s.type_code,
  r.left_curb_style, r.right_curb_style, r.any_shoulder_edge,
  ST_Point(r.cx, r.cy)                                  AS geom
FROM runs r
JOIN street_segment s USING (street_oid)
LEFT JOIN block_member   m USING (street_oid)
LEFT JOIN seg_curb_width w USING (street_oid);

-- curb_type domain evidence, tiled rather than cross-joined so it stays cheap.
CREATE OR REPLACE TABLE curb_type_offset AS
WITH samp AS (
  SELECT oid, curb_type, ST_Centroid(geom) AS c FROM curbs USING SAMPLE 4000 ROWS
), sb AS (
  SELECT oid, curb_type, c, ST_X(c) AS x, ST_Y(c) AS y FROM samp
), st AS (
  SELECT s.oid, gx.v AS gx, gy.v AS gy
  FROM sb s,
       unnest(range(((s.x - 200) / 300.0)::BIGINT, ((s.x + 200) / 300.0)::BIGINT + 1)) AS gx(v),
       unnest(range(((s.y - 200) / 300.0)::BIGINT, ((s.y + 200) / 300.0)::BIGINT + 1)) AS gy(v)
), gt AS (
  SELECT g.street_oid, gx.v AS gx, gy.v AS gy
  FROM (SELECT street_oid, ST_XMin(geom) x0, ST_XMax(geom) x1,
               ST_YMin(geom) y0, ST_YMax(geom) y1 FROM seg) g,
       unnest(range((g.x0 / 300.0)::BIGINT, (g.x1 / 300.0)::BIGINT + 1)) AS gx(v),
       unnest(range((g.y0 / 300.0)::BIGINT, (g.y1 / 300.0)::BIGINT + 1)) AS gy(v)
), pairs AS (
  SELECT DISTINCT st.oid, gt.street_oid FROM st JOIN gt USING (gx, gy)
)
SELECT s.curb_type, s.oid, min(ST_Distance(s.c, g.geom)) AS offset_ft
FROM pairs p
JOIN sb  s ON s.oid        = p.oid
JOIN seg g ON g.street_oid = p.street_oid
GROUP BY s.curb_type, s.oid;

-- ===========================================================================
-- Report
-- ===========================================================================
.print
.print ========== what was measured ==========
SELECT
  (SELECT count(*) FROM curb_transect)                      AS transects_cast,
  (SELECT count(*) FROM curb_transect WHERE in_corner)      AS in_corner_excluded,
  (SELECT count(*) FROM curb_gap WHERE NOT in_corner)       AS considered,
  (SELECT count(roadway_ft) FROM curb_gap WHERE NOT in_corner) AS measured,
  (SELECT round(100.0 * count(roadway_ft) / count(*), 1) FROM curb_gap WHERE NOT in_corner)
                                                            AS pct_measured;

.print
.print ========== why a station produced no width ==========
SELECT
  count(*) FILTER (WHERE flag_no_curb)     AS no_curb_either_side,
  count(*) FILTER (WHERE flag_one_side)    AS curb_on_one_side_only,
  count(*) FILTER (WHERE flag_median_span) AS measured_across_a_median,
  count(*) FILTER (WHERE flag_at_window)   AS edge_at_reach_limit_lower_bound
FROM curb_gap WHERE NOT in_corner;

.print
.print ========== agreement with PBOT pavement records, mid-block stations ==========
.print The check that makes this credible, and the one that says it is not a
.print drop-in replacement for the pavement management system.
SELECT
  'PaveWidth' AS pbot_field,
  count(*)    AS stations,
  round(median(abs(g.roadway_ft - s.pave_width_ft)), 2) AS median_abs_diff_ft,
  round(100.0 * count(*) FILTER (WHERE abs(g.roadway_ft - s.pave_width_ft) <= 2)
        / count(*), 1)                              AS pct_within_2ft
FROM curb_gap g JOIN street_segment s USING (street_oid)
WHERE NOT g.in_corner AND g.roadway_ft IS NOT NULL AND s.pave_width_ft IS NOT NULL
UNION ALL
SELECT
  'RoadWidth', count(*),
  round(median(abs(g.roadway_ft - s.road_width_ft)), 2),
  round(100.0 * count(*) FILTER (WHERE abs(g.roadway_ft - s.road_width_ft) <= 2)
        / count(*), 1)
FROM curb_gap g JOIN street_segment s USING (street_oid)
WHERE NOT g.in_corner AND g.roadway_ft IS NOT NULL AND s.road_width_ft IS NOT NULL;

.print
.print ========== curb_type has no published domain: what the data says ==========
.print offset_from_centerline is the median distance from a curb feature's
.print centroid to the nearest street centerline, over a 4,000 feature sample.
SELECT
  c.curb_type,
  mode(c.curb_style)                        AS commonest_style,
  count(*)                                  AS features,
  round(sum(ST_Length(c.geom)) / 5280.0, 0) AS miles,
  round(median(ST_Length(c.geom)), 0)       AS median_len_ft,
  o.median_offset_ft,
  o.sampled
FROM curbs c
LEFT JOIN (
  SELECT curb_type, round(median(offset_ft), 1) AS median_offset_ft,
         count(*) AS sampled
  FROM curb_type_offset GROUP BY curb_type
) o ON o.curb_type = c.curb_type
GROUP BY c.curb_type, o.median_offset_ft, o.sampled
ORDER BY c.curb_type;

.print
.print ========== measured width distribution, non-corner stations ==========
SELECT
  3 * (roadway_ft / 3)::INT                         AS width_bucket_ft,
  count(*)                                          AS stations,
  round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM curb_gap
WHERE NOT in_corner AND roadway_ft IS NOT NULL AND roadway_ft < 60
GROUP BY 1 ORDER BY 1;

.print
.print ========== what the under-18 stations are made of ==========
.print Raw gap, before the median-span exclusion, so what was thrown out is
.print visible. 3130 on both sides is a median and does not count. 3140 is
.print SHOULDER, and ORS 801.450 excludes the shoulder from the roadway, so a
.print shoulder-to-shoulder measurement overstates the roadway; that one is
.print flagged and kept rather than dropped.
SELECT
  left_curb_type, right_curb_type,
  mode(left_curb_style)    AS left_style,
  mode(right_curb_style)   AS right_style,
  count(*)                 AS stations,
  round(median(gap_ft), 1) AS median_gap_ft,
  count(roadway_ft) > 0    AS counts_as_roadway
FROM curb_gap
WHERE NOT in_corner AND gap_ft <= getvariable('thresh')::DOUBLE
GROUP BY 1, 2 ORDER BY stations DESC LIMIT 10;

.print
.print ========== what excluding curb returns is worth ==========
.print The exclusion lowers the block maximum, so it makes blocks MORE likely
.print to qualify. This is how much.
SELECT
  count(*)                                                      AS testable_blocks,
  count(*) FILTER (WHERE curb_max_ft <= getvariable('thresh')::DOUBLE)
                                                                AS pass_without_corners,
  count(*) FILTER (WHERE curb_max_with_corners_ft <= getvariable('thresh')::DOUBLE)
                                                                AS pass_with_corners,
  round(median(curb_max_with_corners_ft - curb_max_ft), 1)      AS median_corner_inflation_ft
FROM block_curb_width WHERE curb_testable;

.print
.print ========== ORS 801.368 clause 2, both readings ==========
.print The statute reads: not more than 18 feet wide at any point between two
.print intersections. Stages 06 and 08 read that as a maximum. No Oregon
.print appellate decision, AG opinion or ODOT guidance construing it was found,
.print so both populations are reported and neither is baked into the export.
SELECT
  'testable blocks, coverage >= 0.8'                  AS population,
  count(*)                                            AS blocks,
  round(sum(portland_len_ft) / 5280.0, 1)             AS miles
FROM block_curb_width WHERE curb_testable
UNION ALL SELECT 'maximum <= 18 ft: never wider, the reading in 06 and 08',
  count(*), round(sum(portland_len_ft) / 5280.0, 1)
FROM block_curb_width
WHERE curb_testable AND curb_max_ft <= getvariable('thresh')::DOUBLE
UNION ALL SELECT '  of those, street curb on both sides at every station',
  count(*), round(sum(portland_len_ft) / 5280.0, 1)
FROM block_curb_width
WHERE curb_testable AND curb_max_ft <= getvariable('thresh')::DOUBLE
  AND edge_quality = 'street curb'
UNION ALL SELECT 'minimum <= 18 ft: narrow somewhere, the alternative reading',
  count(*), round(sum(portland_len_ft) / 5280.0, 1)
FROM block_curb_width
WHERE curb_testable AND curb_min_ft <= getvariable('thresh')::DOUBLE;

.print
.print ========== the same blocks, by what bounded the measurement ==========
.print Only street curb is unambiguously the roadway edge. Where the nearest
.print curb feature is a shoulder line or an island, the number is whatever
.print that feature is, and the width test should not be quoted from it.
SELECT
  edge_quality,
  count(*)                                AS testable_blocks,
  round(sum(portland_len_ft) / 5280.0, 1) AS miles,
  count(*) FILTER (WHERE curb_max_ft <= getvariable('thresh')::DOUBLE)
                                          AS passing_18ft,
  round(median(curb_median_ft), 1)        AS median_width_ft
FROM block_curb_width WHERE curb_testable
GROUP BY 1 ORDER BY testable_blocks DESC;

.print
.print ========== curb-derived against the pavement record, per block ==========
SELECT
  count(*)                                                           AS testable_both,
  count(*) FILTER (WHERE c.curb_max_ft <= 18 AND n.pave_max_ft > 18) AS curb_yes_pms_no,
  count(*) FILTER (WHERE c.curb_max_ft > 18 AND n.pave_max_ft <= 18) AS pms_yes_curb_no,
  round(median(abs(c.curb_max_ft - n.pave_max_ft)), 1)               AS median_abs_diff_ft
FROM block_curb_width c
JOIN narrow_residential n USING (block_id)
WHERE c.curb_testable AND n.n_missing_pave = 0;

.print
.print ========== narrowings inventoried, by depth ==========
.print At least 3 ft narrower than the street's own median, no wider than
.print 24 ft, running at least 10 ft.
SELECT
  CASE WHEN narrowing_ft >= 10 THEN 'c. 10 ft or more narrower'
       WHEN narrowing_ft >= 6  THEN 'b. 6 to 10 ft narrower'
       ELSE                         'a. 3 to 6 ft narrower' END AS depth,
  count(*)                     AS runs,
  round(median(run_len_ft), 0) AS median_run_ft,
  round(median(min_gap_ft), 1) AS median_narrowest_ft,
  count(*) FILTER (WHERE min_gap_ft <= 18) AS reaching_18ft
FROM curb_pinch GROUP BY 1 ORDER BY 1;

.print
.print ========== narrowings by street class ==========
.print UL is the locally classified street, the population Ordinance 188774
.print leaves eligible. The rest is context.
SELECT
  coalesce(functional_class, '(none)') AS fclass,
  count(*)                             AS runs,
  round(median(run_len_ft), 0)         AS median_run_ft,
  round(median(seg_median_ft), 1)      AS median_street_ft,
  round(median(min_gap_ft), 1)         AS median_narrowest_ft
FROM curb_pinch GROUP BY 1 ORDER BY runs DESC;

.print
.print ========== the deepest narrowings on local streets ==========
SELECT full_name, run_len_ft, seg_median_ft, min_gap_ft, narrowing_ft,
       left_curb_style, right_curb_style
FROM curb_pinch
WHERE functional_class = 'UL' AND NOT any_shoulder_edge
ORDER BY narrowing_ft DESC LIMIT 12;

.print
.print ========== spot check: SE Taylor St at SE 50th, the bioswale pair ==========
.print PBOT records a flat 30 ft PaveWidth for this segment.
SELECT ft_along, round(gap_ft, 1) AS gap_ft, left_curb_style, right_curb_style
FROM curb_gap
WHERE street_oid = 10687 AND ft_along BETWEEN 20 AND 80
ORDER BY ft_along;

.print
.print ========== longest blocks never wider than 18 ft ==========
SELECT full_name, round(portland_len_ft, 0) AS len_ft, n_segments,
       curb_min_ft, curb_median_ft, curb_max_ft, coverage
FROM block_curb_width
WHERE curb_testable AND curb_max_ft <= getvariable('thresh')::DOUBLE
ORDER BY portland_len_ft DESC LIMIT 12;

-- ===========================================================================
-- Exports
-- ===========================================================================
SET geometry_always_xy = true;

COPY (
  SELECT e.block_id, e.full_name,
         e.portland_len_ft AS block_len_ft,
         w.n_transects, w.n_measured, w.coverage,
         w.curb_min_ft, w.curb_median_ft, w.curb_p95_ft, w.curb_max_ft,
         w.curb_max_with_corners_ft, w.curb_min_outer_ft, w.curb_max_outer_ft,
         w.n_outer_curb, w.n_shoulder_edge, w.n_median_edge, w.n_flexcurb,
         w.n_at_window,
         w.edge_quality,
         e.edge_line_each_side_ft, e.edge_line_one_side_ft,
         e.already_18_ft, e.needs_line_ft, e.unmeasured_ft,
         e.width_test_18ft, e.confident_18ft
  FROM block_edge_line e
  JOIN block_curb_width w USING (block_id)
  ORDER BY e.curb_max_ft, e.block_id
) TO 'out/curb_profile_by_block.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT full_name AS street, block_id, functional_class, start_ft, end_ft,
         run_len_ft, min_gap_ft, seg_median_ft, narrowing_ft,
         left_curb_style, right_curb_style, any_shoulder_edge,
         ST_Transform(geom, 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM curb_pinch ORDER BY narrowing_ft DESC
) TO 'out/curb_pinch_points.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326');

-- Large and rebuildable; the profile tables above are what downstream reads.
DROP TABLE curb_transect_tile;
DROP TABLE curb_tile;
