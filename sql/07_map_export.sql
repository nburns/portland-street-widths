-- Geometry for the map, simplified and reprojected to WGS84. Written to
-- build/ as JSON; viz/build_map.py compacts it and inlines it into one
-- self-contained HTML file.
LOAD spatial;
SET geometry_always_xy = true;

-- Every segment at or under 24 ft, carrying its block's maximum so the
-- threshold can be moved in the browser: a block qualifies at T when
-- block_max <= T. Restricted to blocks with no width gaps - the testable set.
COPY (
  SELECT
    b.block_id, b.full_name,
    b.road_width_max_ft   AS block_max,
    round(b.portland_len_ft) AS block_len,
    s.street_oid,
    round(s.len_ft)       AS seg_len,
    s.road_width_max_ft   AS seg_max,
    s.row_width_ft        AS row_w,
    s.lanes,
    ST_AsGeoJSON(ST_Transform(ST_Simplify(s.geom, 3.0),
                 'EPSG:2913', 'EPSG:4326', always_xy := true)) AS g
  FROM narrow_block b
  JOIN block_member m USING (block_id)
  JOIN street_segment s USING (street_oid)
  WHERE s.road_width_max_ft <= 24 OR b.road_width_max_ft <= 24
) TO 'build/segs.json' (FORMAT JSON, ARRAY true);

-- Context only: arterials, collectors, freeways and ramps.
COPY (
  SELECT ST_AsGeoJSON(ST_Transform(ST_Simplify(geom, 25.0),
                      'EPSG:2913', 'EPSG:4326', always_xy := true)) AS g
  FROM street_segment
  WHERE type_code IN (1110, 1120, 1121, 1122, 1200, 1300, 1400)
) TO 'build/major.json' (FORMAT JSON, ARRAY true);

COPY (
  SELECT ST_AsGeoJSON(ST_Transform(ST_Simplify(geom, 100.0),
                      'EPSG:2913', 'EPSG:4326', always_xy := true)) AS g
  FROM city_boundary
) TO 'build/boundary.json' (FORMAT JSON, ARRAY true);

-- A plain GeoJSON of the answer, for geojson.io, a gist, QGIS or a tile build.
COPY (
  SELECT b.full_name              AS street,
         b.road_width_max_ft      AS roadway_max_ft,
         b.road_width_min_ft      AS roadway_min_ft,
         round(b.portland_len_ft) AS block_len_ft,
         b.row_width_max_ft       AS row_max_ft,
         b.n_segments,
         ST_Transform(s.geom, 'EPSG:2913', 'EPSG:4326', always_xy := true) AS geom
  FROM narrow_block b
  JOIN block_member m USING (block_id)
  JOIN street_segment s USING (street_oid)
  WHERE b.qualifies_18ft
) TO 'out/narrow_blocks_18ft.geojson'
  WITH (FORMAT GDAL, DRIVER 'GeoJSON', SRS 'EPSG:4326');
