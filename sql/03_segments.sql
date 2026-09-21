-- One row per Portland street segment, right of way first. Curb-to-curb comes
-- along because PBOT records it and it makes the ROW figure interpretable, but
-- the ROW columns are the product.
LOAD spatial;

-- PMS covers three counties; keep only pavement whose midpoint falls inside the
-- city limits. Midpoint rather than intersection, so a segment that merely
-- clips the boundary is attributed to whichever side it actually sits on.
-- ST_Centroid rather than ST_LineInterpolatePoint because 89 PMS records are
-- multipart and interpolation only accepts a single LINESTRING.
CREATE OR REPLACE TABLE pms_portland AS
SELECT p.*
FROM pms p, city_boundary b
WHERE ST_Intersects(ST_Centroid(p.geom), b.geom);

-- PMS subdivides a centerline segment into pavement sections that can differ in
-- width, so collapse to one row per centerline with the variation preserved.
CREATE OR REPLACE TABLE pms_by_localid AS
SELECT
  localid,
  count(*)                                  AS n_pms_sections,
  sum(geom_len_ft)                          AS pms_len_ft,
  round(sum(road_width_ft * geom_len_ft)
        / nullif(sum(geom_len_ft) FILTER (WHERE road_width_ft IS NOT NULL), 0), 1)
                                            AS road_width_ft,
  min(road_width_ft)                        AS road_width_min_ft,
  max(road_width_ft)                        AS road_width_max_ft,
  round(sum(pave_width_ft * geom_len_ft)
        / nullif(sum(geom_len_ft) FILTER (WHERE pave_width_ft IS NOT NULL), 0), 1)
                                            AS pave_width_ft,
  max(lanes)                                AS lanes,
  bool_or(curb = 'Y')                       AS has_curb,
  mode(surface_type)                        AS surface_type,
  mode(functional_class)                    AS functional_class,
  mode(owner)                               AS owner,
  mode(maint_resp)                          AS maint_resp,
  round(avg(pci), 1)                        AS pci,
  max(inspection_year)                      AS inspection_year
FROM pms_portland
WHERE localid IS NOT NULL
GROUP BY localid;

CREATE OR REPLACE TABLE street_segment AS
SELECT
  s.street_oid,
  s.localid,
  s.full_name,
  s.type_code,
  round(s.len_ft, 1)                        AS len_ft,

  -- ==== right of way, derived from the taxlot gap ====
  r.row_width_ft,
  -- Mode of the per-transect widths rounded to the foot. Where a few transects
  -- clip a driveway apron or a corner, this lands on the platted figure more
  -- often than the median does.
  r.row_width_mode_ft,
  r.row_width_min_ft,
  r.row_width_max_ft,
  r.row_width_spread_ft,
  -- Best-effort width including one-sided estimates. Equals row_width_ft
  -- wherever both ROW edges were actually found.
  r.row_width_any_ft,
  -- Distance from the centerline to each ROW edge. Platted ROW is often not
  -- centred on the built centerline, and for anything frontage-related the two
  -- halves matter more than the total.
  r.row_left_ft,
  r.row_right_ft,
  r.row_offcenter_ft,
  CASE
    WHEN r.n_measured >= 5 AND r.row_width_spread_ft <= 1.0 THEN 'high'
    WHEN r.n_measured >= 3 AND r.row_width_spread_ft <= 5.0 THEN 'medium'
    WHEN r.n_measured >= 1                                  THEN 'low'
    WHEN r.n_any      >= 1                                  THEN 'estimated'
    ELSE 'none'
  END                                       AS row_confidence,
  r.n_transects                             AS row_n_transects,
  r.n_measured                              AS row_n_measured,

  -- ==== curb-to-curb, straight from PBOT's pavement records ====
  p.road_width_ft,
  p.pave_width_ft,
  p.road_width_min_ft,
  p.road_width_max_ft,
  p.lanes,
  p.has_curb,
  p.surface_type,
  p.functional_class,
  p.owner,
  p.maint_resp,
  p.pci,
  p.n_pms_sections,

  -- What is left over: sidewalks, planting strips and setbacks on both sides
  -- combined. Negative means the pavement is wider than the platted ROW, which
  -- is a real thing on some arterials but more often a data disagreement.
  CASE WHEN r.row_width_ft IS NOT NULL AND p.road_width_ft IS NOT NULL
       THEN round(r.row_width_ft - p.road_width_ft, 1) END AS non_roadway_ft,

  u.localid IS NOT NULL                     AS is_unimproved_row,
  r.n_in_taxlot > 0                         AS row_flag_centerline_in_taxlot,
  r.n_no_lots + r.n_one_side > 0            AS row_flag_missing_lots,
  r.n_at_cap > 0                            AS row_flag_at_transect_cap,
  s.len_ft < 60.0                           AS flag_short_segment,

  s.left_from, s.left_to, s.right_from, s.right_to,
  s.left_jur, s.right_jur,
  s.geom
FROM seg s
LEFT JOIN pms_by_localid p USING (localid)
LEFT JOIN row_width      r USING (street_oid)
LEFT JOIN (SELECT DISTINCT localid FROM unimproved_row) u USING (localid);

-- Street-level rollup, length-weighted. A street whose segments disagree shows
-- it in the min/max rather than being averaged flat.
CREATE OR REPLACE TABLE street_summary AS
SELECT
  full_name,
  count(*)                                   AS n_segments,
  round(sum(len_ft), 1)                      AS len_ft,
  round(sum(len_ft) / 5280.0, 3)             AS len_mi,
  round(sum(row_width_ft * len_ft)
        / nullif(sum(len_ft) FILTER (WHERE row_width_ft IS NOT NULL), 0), 1)
                                             AS row_width_ft,
  mode(row_width_mode_ft)                    AS row_width_mode_ft,
  min(row_width_ft)                          AS row_width_min_ft,
  max(row_width_ft)                          AS row_width_max_ft,
  count(row_width_ft)                        AS n_with_row_width,
  count(*) FILTER (WHERE row_confidence IN ('high', 'medium')) AS n_row_confident,
  round(sum(road_width_ft * len_ft)
        / nullif(sum(len_ft) FILTER (WHERE road_width_ft IS NOT NULL), 0), 1)
                                             AS road_width_ft,
  min(road_width_ft)                         AS road_width_min_ft,
  max(road_width_ft)                         AS road_width_max_ft,
  count(road_width_ft)                       AS n_with_road_width,
  mode(functional_class)                     AS functional_class,
  mode(maint_resp)                           AS maint_resp
FROM street_segment
-- Unnamed segments (NULL or blank in the source) roll up to nothing useful;
-- they stay in street_segment, just not in the per-street summary.
WHERE full_name IS NOT NULL AND trim(full_name) <> ''
GROUP BY full_name;

SELECT
  row_confidence,
  count(*)                                           AS segments,
  round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct,
  round(sum(len_ft) / 5280.0, 1)                     AS miles,
  round(median(row_width_ft), 1)                     AS median_row_ft
FROM street_segment
GROUP BY row_confidence
ORDER BY segments DESC;
