-- Exports. Geometry-bearing formats go out in EPSG:4326 for portability; the
-- width columns stay in feet, which is the unit PBOT records them in.
LOAD spatial;

-- Be explicit about axis order: DuckDB geometry is [easting, northing], and
-- GDAL will otherwise apply the authority-defined order for EPSG:4326.
SET geometry_always_xy = true;

CREATE OR REPLACE TEMP VIEW export_segment AS
SELECT * EXCLUDE (geom),
       ST_Transform(geom, 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
FROM street_segment;

COPY (SELECT * FROM export_segment)
  TO 'out/portland_street_widths.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326');

COPY (SELECT * FROM export_segment)
  TO 'out/portland_street_widths.gpkg'
  WITH (FORMAT GDAL, DRIVER 'GPKG', SRS 'EPSG:4326',
        LAYER_CREATION_OPTIONS 'GEOMETRY_NAME=geom');

COPY (SELECT * EXCLUDE (geom) FROM street_segment)
  TO 'out/portland_street_widths.csv' (HEADER, DELIMITER ',');

COPY (SELECT * EXCLUDE (geom) FROM street_segment)
  TO 'out/portland_street_widths.parquet' (FORMAT PARQUET);

COPY (SELECT * FROM street_summary ORDER BY full_name)
  TO 'out/portland_street_summary.csv' (HEADER, DELIMITER ',');

-- The subset to use for aggregate claims about Portland's right of way: both
-- edges measured, transects in agreement, nothing clipped by the transect reach.
COPY (
  SELECT street_oid, localid, full_name, type_code, len_ft,
         row_width_ft, row_width_mode_ft, row_width_spread_ft,
         row_left_ft, row_right_ft, row_offcenter_ft, row_confidence,
         road_width_ft, non_roadway_ft, functional_class, maint_resp
  FROM street_segment
  WHERE row_confidence IN ('high', 'medium') AND NOT row_flag_at_transect_cap
  ORDER BY full_name, left_from
) TO 'out/portland_row_confident.csv' (HEADER, DELIMITER ',');

SELECT 'out/' || f AS file FROM (SELECT unnest([
  'portland_street_widths.geojson',
  'portland_street_widths.gpkg',
  'portland_street_widths.csv',
  'portland_street_widths.parquet',
  'portland_street_summary.csv',
  'portland_row_confident.csv']) AS f);
