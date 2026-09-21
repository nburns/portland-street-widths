-- Right-of-way width, measured rather than looked up: no Portland dataset
-- publishes platted ROW width, so it is derived from the gap between the
-- taxlots on either side of each street centerline.
--
-- For each street segment, cast perpendicular transects along it, intersect
-- them with nearby taxlots, and project every crossing onto the transect axis
-- as a signed distance from the centerline. The nearest blocked interval on
-- each side gives the two ROW edges; their separation is the width. Projection
-- arithmetic (rather than polygon differencing) keeps this a pure aggregation,
-- which is what makes a quarter-million transects take seconds.
LOAD spatial;

SET VARIABLE half    = 250.0;  -- transect half-length, ft. Caps the widest ROW measurable.
SET VARIABLE chord   = 10.0;   -- half-chord used to estimate the local bearing, ft
SET VARIABLE tile    = 300.0;  -- spatial grid cell, ft. Only affects speed.
SET VARIABLE inset   = 40.0;   -- keep-out distance from each segment end, ft
SET VARIABLE spacing = 25.0;   -- target distance between transects, ft
SET VARIABLE max_n   = 40;     -- transects per segment ceiling

CREATE OR REPLACE TABLE transect AS
WITH s AS (
  -- Sample by absolute inset, not by fraction of length. Portland is full of
  -- 137 ft half-block segments, and on those a 20%-of-length inset lands the
  -- transect inside the cross-street intersection, where there are no taxlots
  -- to measure against. Segments too short to inset 40 ft get as much as they
  -- can afford.
  SELECT street_oid, geom, len_ft,
         least(getvariable('inset')::DOUBLE, 0.35 * len_ft) AS inset_ft
  FROM seg WHERE len_ft > 8.0
), sized AS (
  -- One transect every 25 ft of usable length, at least 5 and at most 40. The
  -- median over many transects is what makes a platted width fall out cleanly;
  -- five samples is enough to be wrong on an irregular block.
  SELECT *,
         len_ft - 2 * inset_ft AS usable_ft,
         least(getvariable('max_n')::INT,
               greatest(5, ((len_ft - 2 * inset_ft) / getvariable('spacing')::DOUBLE + 1)::INT)) AS n
  FROM s
), pts AS (
  SELECT
    z.street_oid, z.len_ft, z.n, i.v AS sample_no,
    (z.inset_ft + z.usable_ft * i.v / (z.n - 1)) / z.len_ft AS frac
  FROM sized z, unnest(range(0, z.n)) AS i(v)
), geo AS (
  SELECT
    p.street_oid, p.sample_no, p.frac, p.len_ft,
    ST_LineInterpolatePoint(s.geom, p.frac) AS c,
    ST_LineInterpolatePoint(s.geom,
      greatest(p.frac - getvariable('chord')::DOUBLE / p.len_ft, 0.0)) AS a,
    ST_LineInterpolatePoint(s.geom,
      least(p.frac + getvariable('chord')::DOUBLE / p.len_ft, 1.0)) AS b
  FROM pts p JOIN seg s ON s.street_oid = p.street_oid
), dirs AS (
  SELECT
    street_oid, sample_no, frac, len_ft, c,
    ST_X(c) AS cx, ST_Y(c) AS cy,
    ST_X(b) - ST_X(a) AS dx,
    ST_Y(b) - ST_Y(a) AS dy
  FROM geo
), unit AS (
  SELECT *, sqrt(dx * dx + dy * dy) AS m FROM dirs
), ends AS (
  -- Unit normal to the local bearing: the transect direction.
  SELECT
    street_oid, sample_no, frac, len_ft, c, cx, cy,
    -dy / m AS ux,
     dx / m AS uy
  FROM unit WHERE m > 0
)
SELECT
  row_number() OVER (ORDER BY street_oid, sample_no) AS transect_id,
  street_oid, sample_no, frac, len_ft, c, cx, cy, ux, uy,
  ST_MakeLine(
    ST_Point(cx - getvariable('half')::DOUBLE * ux, cy - getvariable('half')::DOUBLE * uy),
    ST_Point(cx + getvariable('half')::DOUBLE * ux, cy + getvariable('half')::DOUBLE * uy)
  ) AS tr,
  -- Bounding box kept as plain columns so the candidate prefilter is plain
  -- arithmetic rather than a geometry call per candidate pair.
  cx - abs(getvariable('half')::DOUBLE * ux) AS xmin,
  cx + abs(getvariable('half')::DOUBLE * ux) AS xmax,
  cy - abs(getvariable('half')::DOUBLE * uy) AS ymin,
  cy + abs(getvariable('half')::DOUBLE * uy) AS ymax
FROM ends;

-- Grid index. DuckDB will not reliably pick a spatial join for this many
-- geometries, so candidate pairs come from an explicit integer tile join and
-- ST_Intersects only ever sees pairs that are already close.
CREATE OR REPLACE TABLE lot_box AS
SELECT lot_id,
       ST_XMin(geom) AS xmin, ST_XMax(geom) AS xmax,
       ST_YMin(geom) AS ymin, ST_YMax(geom) AS ymax
FROM taxlots;

CREATE OR REPLACE TABLE lot_tile AS
SELECT l.lot_id, gx.v AS gx, gy.v AS gy
FROM lot_box l,
     unnest(range((l.xmin / getvariable('tile')::DOUBLE)::BIGINT,
                  (l.xmax / getvariable('tile')::DOUBLE)::BIGINT + 1)) AS gx(v),
     unnest(range((l.ymin / getvariable('tile')::DOUBLE)::BIGINT,
                  (l.ymax / getvariable('tile')::DOUBLE)::BIGINT + 1)) AS gy(v);

CREATE OR REPLACE TABLE transect_tile AS
SELECT t.transect_id, gx.v AS gx, gy.v AS gy
FROM transect t,
     unnest(range((t.xmin / getvariable('tile')::DOUBLE)::BIGINT,
                  (t.xmax / getvariable('tile')::DOUBLE)::BIGINT + 1)) AS gx(v),
     unnest(range((t.ymin / getvariable('tile')::DOUBLE)::BIGINT,
                  (t.ymax / getvariable('tile')::DOUBLE)::BIGINT + 1)) AS gy(v);

CREATE OR REPLACE TABLE crossing AS
WITH cand AS (
  SELECT DISTINCT tt.transect_id, lt.lot_id
  FROM transect_tile tt JOIN lot_tile lt USING (gx, gy)
), near AS (
  -- Exact bounding-box overlap first: cheap arithmetic that discards most of
  -- what the tile join let through, before any geometry work happens.
  SELECT c.transect_id, c.lot_id
  FROM cand c
  JOIN transect t ON t.transect_id = c.transect_id
  JOIN lot_box  b ON b.lot_id      = c.lot_id
  WHERE t.xmax >= b.xmin AND t.xmin <= b.xmax
    AND t.ymax >= b.ymin AND t.ymin <= b.ymax
), hit AS (
  SELECT n.transect_id, n.lot_id,
         ST_Intersection(t.tr, l.geom) AS x,
         t.cx, t.cy, t.ux, t.uy
  FROM near n
  JOIN transect t ON t.transect_id = n.transect_id
  JOIN taxlots  l ON l.lot_id      = n.lot_id
  WHERE ST_Intersects(t.tr, l.geom)
), part AS (
  -- One interval per crossing, so a concave lot that the transect enters twice
  -- contributes two blocked intervals rather than one spanning the street.
  SELECT h.transect_id, h.lot_id, h.cx, h.cy, h.ux, h.uy, d.rec.geom AS seg_x
  FROM hit h, unnest(ST_Dump(h.x)) AS d(rec)
  WHERE ST_GeometryType(d.rec.geom) = 'LINESTRING'
), proj AS (
  SELECT
    transect_id, lot_id,
    (ST_X(ST_StartPoint(seg_x)) - cx) * ux + (ST_Y(ST_StartPoint(seg_x)) - cy) * uy AS s1,
    (ST_X(ST_EndPoint(seg_x))   - cx) * ux + (ST_Y(ST_EndPoint(seg_x))   - cy) * uy AS s2
  FROM part
)
SELECT
  transect_id, lot_id,
  least(s1, s2)    AS s_lo,
  greatest(s1, s2) AS s_hi
FROM proj;

-- One measurement per transect: the two ROW edges as distances from the
-- centerline, kept separately so asymmetry survives instead of being averaged
-- into a width.
CREATE OR REPLACE TABLE transect_width AS
WITH edges AS (
  SELECT
    transect_id,
    max(s_hi) FILTER (WHERE s_hi <= 0.0) AS left_edge,
    min(s_lo) FILTER (WHERE s_lo >= 0.0) AS right_edge,
    count(*)  FILTER (WHERE s_lo < 0.0 AND s_hi > 0.0) AS straddling_lots
  FROM crossing
  GROUP BY transect_id
), m AS (
  SELECT
    t.transect_id, t.street_oid, t.sample_no, t.frac, t.len_ft,
    -- A lot straddling the centerline means the centerline is inside private
    -- property; there is no ROW to measure, so both offsets go null.
    CASE WHEN coalesce(e.straddling_lots, 0) = 0 THEN abs(e.left_edge) END AS left_ft,
    CASE WHEN coalesce(e.straddling_lots, 0) = 0 THEN e.right_edge     END AS right_ft,
    coalesce(e.straddling_lots, 0) AS straddling_lots
  FROM transect t
  LEFT JOIN edges e USING (transect_id)
)
SELECT
  transect_id, street_oid, sample_no, frac, len_ft,
  left_ft, right_ft, straddling_lots,
  CASE WHEN left_ft IS NOT NULL AND right_ft IS NOT NULL
       THEN left_ft + right_ft END AS width_ft,
  -- One edge found only: assume the centerline is centred in the right of way
  -- and double what was measured. Separate column because that is an
  -- assumption, and on an off-centre centerline it is wrong by twice the offset.
  CASE WHEN left_ft IS NOT NULL AND right_ft IS NOT NULL THEN left_ft + right_ft
       WHEN left_ft  IS NOT NULL THEN 2 * left_ft
       WHEN right_ft IS NOT NULL THEN 2 * right_ft END AS width_any_ft,
  CASE
    WHEN straddling_lots > 0                  THEN 'centerline_in_taxlot'
    WHEN left_ft IS NULL AND right_ft IS NULL THEN 'no_lots_either_side'
    WHEN left_ft IS NULL OR  right_ft IS NULL THEN 'no_lot_one_side'
    ELSE 'ok'
  END AS status,
  -- An edge at the far end of the transect means the nearest lot was only found
  -- at the reach limit, so the true width may be larger still.
  coalesce(left_ft      >= getvariable('half')::DOUBLE - 5.0, false)
    OR coalesce(right_ft >= getvariable('half')::DOUBLE - 5.0, false) AS edge_at_cap
FROM m;

-- Roll transects up to the segment. The median resists a transect landing on a
-- driveway apron, a corner clip or a missing lot; the spread across transects
-- is the confidence signal, and the mode of the rounded widths recovers the
-- platted figure when a minority of transects are noisy.
CREATE OR REPLACE TABLE row_width AS
SELECT
  street_oid,
  count(*)                                     AS n_transects,
  count(width_ft)                              AS n_measured,
  count(width_any_ft)                          AS n_any,
  round(median(width_ft), 1)                   AS row_width_ft,
  mode(round(width_ft))                        AS row_width_mode_ft,
  round(min(width_ft), 1)                      AS row_width_min_ft,
  round(max(width_ft), 1)                      AS row_width_max_ft,
  round(max(width_ft) - min(width_ft), 1)      AS row_width_spread_ft,
  round(median(width_any_ft), 1)               AS row_width_any_ft,
  round(median(left_ft), 1)                    AS row_left_ft,
  round(median(right_ft), 1)                   AS row_right_ft,
  round(median(right_ft) - median(left_ft), 1) AS row_offcenter_ft,
  any_value(len_ft)                            AS len_ft,
  count(*) FILTER (WHERE status = 'centerline_in_taxlot') AS n_in_taxlot,
  count(*) FILTER (WHERE status = 'no_lots_either_side')  AS n_no_lots,
  count(*) FILTER (WHERE status = 'no_lot_one_side')      AS n_one_side,
  count(*) FILTER (WHERE edge_at_cap)                     AS n_at_cap
FROM transect_width
GROUP BY street_oid;

SELECT status, count(*) AS transects,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM transect_width GROUP BY status ORDER BY transects DESC;
