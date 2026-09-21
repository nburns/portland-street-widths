-- Which streets could be made narrow residential roadways by striping.
--
-- ORS 801.450 measures the roadway "exclusive of the shoulder", so a street
-- whose pavement is wider than 18 ft can be brought inside ORS 801.368 by
-- striping an edge line and designating the pavement outside it as shoulder.
-- The width that matters is then the distance between edge lines, not the
-- pavement width.
--
-- The published marking inventory cannot answer "is there an edge line here":
-- its LineType codes (3611-3623) have no domain in any PBOT metadata or service
-- renderer, and the renderer keys on LineStyle, which names the physical marking
-- (Solid Single White 4) rather than its role. An 8 inch solid white is a bike
-- lane line on one street and an edge line on another. So this file does not
-- claim to find existing edge lines; it computes how much shoulder each block
-- would need for its travel way to reach 18 ft.
--
-- Eligibility follows the statute plus the ordinance's non-arterial limit:
-- two-way, residence district, and locally classified.
LOAD spatial;

CREATE OR REPLACE TABLE nrr_candidate AS
WITH fc AS (
  -- resolved once in sql/06 so it cannot tie-break differently here
  SELECT block_id, functional_class AS fclass FROM block_attr
)
SELECT
  n.block_id, n.full_name, n.len_ft, n.n_segments,
  n.pave_max_ft, n.pave_min_ft, n.road_max_ft,
  fc.fclass,
  -- Shoulder needed on EACH side for an 18 ft travel way, and the one-sided
  -- alternative. Negative or zero means the block already qualifies.
  round((n.pave_max_ft - 18) / 2.0, 1) AS shoulder_each_side_ft,
  n.pave_max_ft - 18                   AS shoulder_one_side_ft,
  n.pave_max_ft <= 18                  AS already_nrr
FROM narrow_residential n
JOIN fc USING (block_id)
WHERE n.n_missing_pave = 0
  AND n.cond_two_way            -- ORS 801.368: two-way
  AND n.cond_residence          -- ORS 801.368: residence district (zoning proxy)
  AND fc.fclass = 'UL'          -- Ordinance 188774: non-arterial
  AND n.pave_max_ft > 1;        -- drop PaveWidth=1, PBOT's "unpaved" placeholder

.print
.print ========== eligible universe: two-way, residential, locally classified ==========
SELECT
  count(*)                                              AS blocks,
  round(sum(len_ft) / 5280.0, 1)                        AS miles,
  count(*) FILTER (WHERE already_nrr)                   AS already_nrr_blocks,
  round(sum(len_ft) FILTER (WHERE already_nrr) / 5280.0, 1) AS already_nrr_miles
FROM nrr_candidate;

.print
.print ========== convertible by striping, by shoulder needed per side ==========
SELECT
  CASE
    WHEN shoulder_each_side_ft <= 0 THEN 'a. already 18 ft or less'
    WHEN shoulder_each_side_ft <= 1 THEN 'b. 1 ft each side'
    WHEN shoulder_each_side_ft <= 2 THEN 'c. 2 ft each side'
    WHEN shoulder_each_side_ft <= 3 THEN 'd. 3 ft each side'
    WHEN shoulder_each_side_ft <= 5 THEN 'e. 4-5 ft each side'
    WHEN shoulder_each_side_ft <= 7 THEN 'f. 6-7 ft each side'
    WHEN shoulder_each_side_ft <= 9 THEN 'g. 8-9 ft each side'
    ELSE 'h. more than 9 ft each side'
  END AS shoulder_needed,
  count(*)                        AS blocks,
  round(sum(len_ft) / 5280.0, 1)  AS miles
FROM nrr_candidate
GROUP BY shoulder_needed ORDER BY shoulder_needed;

.print
.print ========== the same by pavement width, which is what gets striped ==========
SELECT pave_max_ft AS pavement_ft,
       count(*) AS blocks,
       round(sum(len_ft) / 5280.0, 1) AS miles,
       round((pave_max_ft - 18) / 2.0, 1) AS shoulder_each_side_ft
FROM nrr_candidate
WHERE pave_max_ft BETWEEN 19 AND 40
GROUP BY pave_max_ft ORDER BY pave_max_ft;

.print
.print ========== headline: cumulative eligible mileage at each shoulder width ==========
SELECT w AS shoulder_each_side_ft,
       count(*) FILTER (WHERE shoulder_each_side_ft <= w) AS blocks,
       round(sum(len_ft) FILTER (WHERE shoulder_each_side_ft <= w) / 5280.0, 1) AS miles
FROM nrr_candidate, (SELECT unnest([0, 1, 2, 3, 4, 5, 6, 7, 9]) AS w)
GROUP BY w ORDER BY w;

.print
.print ========== what the non-arterial limit removes ==========
SELECT
  count(*) FILTER (WHERE fclass = 'UL')  AS local_blocks,
  count(*) FILTER (WHERE fclass <> 'UL') AS non_local_blocks,
  round(sum(len_ft) FILTER (WHERE fclass <> 'UL') / 5280.0, 1) AS non_local_miles
FROM (
  SELECT n.len_ft, fc.fclass
  FROM narrow_residential n
  JOIN (SELECT block_id, functional_class AS fclass FROM block_attr) fc
    USING (block_id)
  WHERE n.n_missing_pave = 0 AND n.cond_two_way AND n.cond_residence
    AND n.pave_max_ft <= 18 AND n.pave_max_ft > 1
);

-- Exports. Geometry only for the blocks that already qualify - the convertible
-- universe is ~1,050 miles of local street, too much geometry to publish as a
-- single rendered file, so it goes out as a table keyed by street and block.
COPY (
  SELECT
    c.full_name           AS street,
    c.pave_max_ft         AS pavement_max_ft,
    c.pave_min_ft         AS pavement_min_ft,
    c.road_max_ft         AS graded_roadway_max_ft,
    round(c.len_ft)       AS block_len_ft,
    c.n_segments,
    s.row_width_ft        AS row_width_ft,
    ST_Transform(s.geom, 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM nrr_candidate c
  JOIN block_member m USING (block_id)
  JOIN street_segment s USING (street_oid)
  WHERE c.already_nrr
) TO 'out/nrr_existing.geojson' WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326');

-- Lean column set: GitHub stops rendering a CSV as a searchable table above
-- 512 KB, and every dropped column is derivable. shoulder_one_side_ft is twice
-- shoulder_each_side_ft; already_nrr is shoulder_each_side_ft <= 0; block miles
-- are block_len_ft / 5280.
COPY (
  SELECT
    full_name             AS street,
    round(len_ft)::INT    AS block_len_ft,
    n_segments,
    pave_max_ft           AS pavement_max_ft,
    pave_min_ft           AS pavement_min_ft,
    shoulder_each_side_ft
  FROM nrr_candidate
  ORDER BY shoulder_each_side_ft, street, len_ft DESC, block_id
) TO 'out/nrr_convertible.csv' (HEADER, DELIMITER ',');

-- Per street name, for scanning: where the convertible mileage is concentrated.
COPY (
  SELECT
    full_name                                   AS street,
    count(*)                                    AS blocks,
    round(sum(len_ft::DECIMAL(18,4)) / 5280.0, 3) AS miles,
    min(pave_max_ft)                            AS pavement_min_ft,
    max(pave_max_ft)                            AS pavement_max_ft,
    max(shoulder_each_side_ft)                  AS shoulder_each_side_ft_worst,
    count(*) FILTER (WHERE already_nrr)         AS blocks_already_nrr,
    round(coalesce(sum(len_ft::DECIMAL(18,4)) FILTER (WHERE already_nrr), 0) / 5280.0, 3)
                                                AS miles_already_nrr
  FROM nrr_candidate
  WHERE full_name IS NOT NULL AND trim(full_name) <> ''
  GROUP BY full_name
  ORDER BY sum(len_ft::DECIMAL(18,4)) DESC, street
) TO 'out/nrr_by_street.csv' (HEADER, DELIMITER ',');
