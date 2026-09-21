-- GeoJSON for publishing, styled per feature.
--
-- GitHub renders GeoJSON in gists and repos as an interactive map and honors
-- simplestyle-spec properties, so stroke colour can encode how much shoulder a
-- block would need. Colours are validated against a light basemap (#f2f1ee):
-- the three-step ramp is monotonic in OKLab lightness with even steps and
-- adjacent separation dE 18-20, and "already qualifies" gets a status hue
-- because it is a state rather than a magnitude.
LOAD spatial;
SET geometry_always_xy = true;

CREATE OR REPLACE MACRO nrr_class(sh) AS
  CASE WHEN sh <= 0 THEN 'already a narrow residential roadway'
       WHEN sh <= 3 THEN 'convertible: up to 3 ft shoulder each side'
       WHEN sh <= 5 THEN 'convertible: 4-5 ft shoulder each side'
       ELSE 'convertible: more than 5 ft shoulder each side' END;

CREATE OR REPLACE MACRO nrr_stroke(sh) AS
  CASE WHEN sh <= 0 THEN '#1c7c54'
       WHEN sh <= 3 THEN '#0d2b47'
       WHEN sh <= 5 THEN '#26648f'
       ELSE '#4a8cb8' END;

-- Geometry dissolved to one feature per block, simplified to 15 ft. Local
-- streets are near-straight, so this costs almost nothing visually and keeps
-- the file inside GitHub's 10 MB map-rendering ceiling.
CREATE OR REPLACE TABLE nrr_block_geom AS
SELECT c.block_id,
       ST_CollectionExtract(ST_Simplify(ST_Collect(list(s.geom)), 25.0), 2) AS geom
FROM nrr_candidate c
JOIN block_member m USING (block_id)
JOIN street_segment s USING (street_oid)
GROUP BY c.block_id;

COPY (
  SELECT
    -- Property names repeat in every feature, so the set is kept to what a
    -- map popup needs; the full column set lives in out/nrr_convertible.csv.
    coalesce(c.full_name, '(unnamed)')      AS street,
    nrr_class(c.shoulder_each_side_ft)      AS status,
    c.shoulder_each_side_ft                 AS shoulder_ft,
    c.pave_max_ft                           AS pavement_ft,
    round(c.len_ft)::INT                    AS length_ft,
    nrr_stroke(c.shoulder_each_side_ft)     AS stroke,
    CASE WHEN c.shoulder_each_side_ft <= 0 THEN 4 ELSE 3 END AS "stroke-width",
    0.9                                     AS "stroke-opacity",
    ST_Transform(g.geom, 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM nrr_candidate c JOIN nrr_block_geom g USING (block_id)
  -- Block granularity is limited to the decision-relevant set: blocks that
  -- already qualify plus those within 3 ft of shoulder either side. All 13,632
  -- eligible blocks at 25 ft simplification come to 2.5 MB of geometry alone
  -- before properties, which renders too slowly to be usable on a map, and the
  -- by-street file below already covers the full universe. The complete block
  -- table is out/nrr_convertible.csv.
  WHERE c.shoulder_each_side_ft <= 3
  ORDER BY c.shoulder_each_side_ft DESC, c.block_id  -- qualifying blocks drawn last, on top
) TO 'out/nrr_blocks.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326',
        LAYER_CREATION_OPTIONS 'COORDINATE_PRECISION=5');

-- Rolled up to street names. The binding figure for a street is the widest
-- shoulder any of its blocks needs, since the statute must hold at every point.
COPY (
  SELECT
    c.full_name                                    AS street,
    nrr_class(max(c.shoulder_each_side_ft))        AS status,
    max(c.shoulder_each_side_ft)                   AS shoulder_each_side_ft_worst,
    min(c.pave_max_ft)                             AS pavement_min_ft,
    max(c.pave_max_ft)                             AS pavement_max_ft,
    count(*)                                       AS blocks,
    round(sum(c.len_ft::DECIMAL(18,4)) / 5280.0, 3) AS miles,
    count(*) FILTER (WHERE c.already_nrr)          AS blocks_already_nrr,
    nrr_stroke(max(c.shoulder_each_side_ft))       AS stroke,
    CASE WHEN max(c.shoulder_each_side_ft) <= 0 THEN 4 ELSE 3 END AS "stroke-width",
    0.9                                            AS "stroke-opacity",
    -- ST_Collect over already-multipart geometries nests into a
    -- GeometryCollection, which renderers handle inconsistently; extracting
    -- type 2 forces a clean MultiLineString.
    -- list() collects in whatever order the aggregate finished, so the parts
    -- of a street's MultiLineString were shuffled between runs even though the
    -- set of parts never changed. Ordering by block_id fixes the sequence.
    ST_Transform(ST_CollectionExtract(ST_Collect(list(g.geom ORDER BY g.block_id)), 2),
                 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM nrr_candidate c JOIN nrr_block_geom g USING (block_id)
  WHERE c.full_name IS NOT NULL AND trim(c.full_name) <> ''
  GROUP BY c.full_name
  ORDER BY max(c.shoulder_each_side_ft) DESC, street
) TO 'out/nrr_by_street.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326',
        LAYER_CREATION_OPTIONS 'COORDINATE_PRECISION=5');
