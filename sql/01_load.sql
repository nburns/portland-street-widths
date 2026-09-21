-- Raw GeoJSON -> DuckDB tables. Everything lands in EPSG:2913 (Oregon North,
-- international feet) so lengths and widths are in feet with no unit juggling.
INSTALL spatial;
LOAD spatial;

CREATE OR REPLACE MACRO to_2913(g) AS
  ST_Transform(g, 'EPSG:4326', 'EPSG:2913', always_xy := true);

-- PBOT Pavement Management System: the curb-to-curb width source.
CREATE OR REPLACE TABLE pms AS
SELECT
  OBJECTID                                     AS pms_oid,
  AssetID                                      AS asset_id,
  LocationID                                   AS location_id,
  TRY_CAST(regexp_extract(LocationID, 'SEG(\d+)$', 1) AS INTEGER) AS localid,
  SectionID                                    AS section_id,
  Streetname                                   AS street_name,
  BegLocation                                  AS beg_location,
  EndLocation                                  AS end_location,
  Direction                                    AS direction,
  RoadWidth                                    AS road_width_ft,
  PaveWidth                                    AS pave_width_ft,
  NumberOfLanes                                AS lanes,
  Curb                                         AS curb,
  SurfaceType                                  AS surface_type,
  PaveType                                     AS pave_type,
  SealType                                     AS seal_type,
  FunctionalClass                              AS functional_class,
  PCI                                          AS pci,
  InspectionYear                               AS inspection_year,
  SqYards                                      AS sq_yards,
  Owner                                        AS owner,
  MaintResp                                    AS maint_resp,
  JurisdictionFlag                             AS jurisdiction_flag,
  to_2913(geom)                                AS geom,
  ST_Length(to_2913(geom))                     AS geom_len_ft
FROM ST_Read('data/raw/pavement_management.geojson');

-- Street centerline network (4 counties). The canonical segment geometry, and
-- what the ROW transects are measured against.
CREATE OR REPLACE TABLE streets AS
SELECT
  OBJECTID        AS street_oid,
  LOCALID         AS localid,
  FULL_NAME       AS full_name,
  PREFIX          AS prefix,
  STREETNAME      AS street_name,
  FTYPE           AS ftype,
  SUFFIX          AS suffix,
  TYPE            AS type_code,
  STRUC_TYPE      AS struc_type,
  DIRECTION       AS direction,
  LEFTADD1        AS left_from,
  LEFTADD2        AS left_to,
  RGTADD1         AS right_from,
  RGTADD2         AS right_to,
  LCITY           AS left_city,
  RCITY           AS right_city,
  LCOUNTY         AS left_county,
  RCOUNTY         AS right_county,
  LEFT_JUR        AS left_jur,
  RIGHT_JUR       AS right_jur,
  -- Network topology, needed to reassemble segments into blocks: the source
  -- splits many blocks mid-run, so a segment is not the same thing as a
  -- stretch between two intersections.
  PDX_F_NODE      AS f_node,
  PDX_T_NODE      AS t_node,
  to_2913(geom)   AS geom,
  ST_Length(to_2913(geom)) AS len_ft
FROM ST_Read('data/raw/streets.geojson');

-- PBOT curb extension policy: an independent roadway-width figure per TSP
-- segment, used to cross-check PMS rather than as a primary source.
CREATE OR REPLACE TABLE curb_extension AS
SELECT
  f.properties.TSP_ID                 AS tsp_id,
  f.properties.TSP_StreetName         AS street_name,
  f.properties.TSP_Traffic            AS tsp_traffic,
  f.properties.TSP_Design             AS tsp_design,
  f.properties.Pavement_RoadWidthFt   AS road_width_ft,
  f.properties.CurbExtensionPolicy    AS policy,
  ST_GeomFromGeoJSON(f.geometry)      AS geom
FROM (SELECT unnest(features) AS f
      FROM read_json('data/raw/curb_extension/page_*.geojson',
                     maximum_object_size = 200000000));

-- Platted but unbuilt right of way: streets that exist on paper only.
CREATE OR REPLACE TABLE unimproved_row AS
SELECT
  OBJECTID      AS oid,
  LOCALID       AS localid,
  FULL_NAME     AS full_name,
  TYPE          AS type_code,
  to_2913(geom) AS geom
FROM ST_Read('data/raw/unimproved_row.geojson');

-- Curb and shoulder lines. Not used for the headline numbers; kept so a
-- curb-to-curb width can be measured geometrically where PMS has no record.
CREATE OR REPLACE TABLE curbs AS
SELECT
  OBJECTID      AS oid,
  AssetID       AS asset_id,
  LocationID    AS location_id,
  CurbType      AS curb_type,
  CurbStyle     AS curb_style,
  Owner         AS owner,
  MaintResp     AS maint_resp,
  to_2913(geom) AS geom
FROM ST_Read('data/raw/curbs.geojson');

-- Sidewalk polygons. Used only to validate the derived ROW: a sidewalk lies
-- inside the right of way by definition, so any sidewalk crossing that falls
-- outside the measured ROW edges means the measurement is too narrow.
CREATE OR REPLACE TABLE sidewalks AS
SELECT
  OBJECTID      AS oid,
  SidewalkType  AS sidewalk_type,
  Owner         AS owner,
  MaintResp     AS maint_resp,
  to_2913(geom) AS geom
FROM ST_Read('data/raw/sidewalks.geojson');

-- Base zoning, used to approximate the ORS "residence district" test.
CREATE OR REPLACE TABLE zoning AS
SELECT
  ZONE          AS zone,
  ZONE_DESC     AS zone_desc,
  -- ORS 801.430 defines a residence district by actual dwelling frontage, not
  -- by zoning; residential base zones are a proxy, flagged as such downstream.
  ZONE LIKE 'R%' AS is_residential,
  to_2913(geom) AS geom
FROM ST_Read('data/raw/zoning.geojson');

CREATE OR REPLACE TABLE city_boundary AS
SELECT
  CITYNAME      AS city_name,
  to_2913(geom) AS geom
FROM ST_Read('data/raw/city_boundaries.geojson')
WHERE upper(CITYNAME) = 'PORTLAND';

-- Metro RLIS taxlots, already EPSG:2913 from the fetch. Multnomah County lots
-- stop at the property line, so the gap between opposing lots is the platted
-- right of way - that gap is what the ROW width is measured from.
-- A handful of lots have self-touching rings that make GEOS throw a side
-- location conflict mid-intersection, which would abort the whole measurement.
-- Repair those at load time and keep a flag so the count stays visible.
CREATE OR REPLACE TABLE taxlots AS
WITH src AS (
  SELECT
    row_number() OVER ()           AS lot_id,
    f.properties.TLID              AS tlid,
    f.properties.COUNTY            AS county,
    f.properties.JURIS_CITY        AS juris_city,
    ST_GeomFromGeoJSON(f.geometry) AS geom
  FROM (SELECT unnest(features) AS f
        FROM read_json('data/raw/taxlots/page_*.geojson',
                       maximum_object_size = 200000000))
)
SELECT
  lot_id, tlid, county, juris_city,
  NOT ST_IsValid(geom)                                             AS was_repaired,
  CASE WHEN ST_IsValid(geom) THEN geom ELSE ST_MakeValid(geom) END  AS geom
FROM src;

-- Portland street segments, defined spatially. LCITY/RCITY on the centerline
-- dataset is the POSTAL city, not the jurisdiction: filtering on it pulls in
-- ~16k Washington and Clackamas County segments that merely have a "Portland,
-- OR" mailing address, and those have no taxlots in this extract to measure
-- against. Midpoint-inside-the-boundary agrees with LEFT_JUR='PORT' on 38,979
-- of 39,103 segments, and uses the city's own boundary polygon as the arbiter.
CREATE OR REPLACE TABLE seg AS
WITH bbox AS (
  SELECT ST_XMin(geom) AS xmin, ST_XMax(geom) AS xmax,
         ST_YMin(geom) AS ymin, ST_YMax(geom) AS ymax
  FROM city_boundary
), near AS (
  SELECT s.* FROM streets s, bbox x
  WHERE ST_XMax(s.geom) >= x.xmin AND ST_XMin(s.geom) <= x.xmax
    AND ST_YMax(s.geom) >= x.ymin AND ST_YMin(s.geom) <= x.ymax
)
SELECT n.*
FROM near n, city_boundary b
WHERE ST_Intersects(ST_LineInterpolatePoint(n.geom, 0.5), b.geom);

CREATE OR REPLACE TABLE load_summary AS
SELECT 'pms' AS tbl, count(*) AS rows FROM pms
UNION ALL SELECT 'streets', count(*) FROM streets
UNION ALL SELECT 'seg (Portland, spatial)', count(*) FROM seg
UNION ALL SELECT 'curb_extension', count(*) FROM curb_extension
UNION ALL SELECT 'unimproved_row', count(*) FROM unimproved_row
UNION ALL SELECT 'curbs', count(*) FROM curbs
UNION ALL SELECT 'sidewalks', count(*) FROM sidewalks
UNION ALL SELECT 'taxlots', count(*) FROM taxlots
UNION ALL SELECT 'taxlots repaired', count(*) FROM taxlots WHERE was_repaired
UNION ALL SELECT 'taxlots still invalid', count(*) FROM taxlots WHERE NOT ST_IsValid(geom)
UNION ALL SELECT 'zoning', count(*) FROM zoning
UNION ALL SELECT 'zoning residential', count(*) FROM zoning WHERE is_residential
UNION ALL SELECT 'city_boundary', count(*) FROM city_boundary;

SELECT * FROM load_summary ORDER BY tbl;
