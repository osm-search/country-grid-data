-- SPDX-License-Identifier: GPL-2.0-only
--
-- Copyright (C) 2024 by the Nominatim developer community.
-- For a full list of authors see the git log.

-- Script to build a calculated country grid from existing tables

-- Create a table with complete countries from the data in placex.
DROP TABLE IF EXISTS tmp_full_countries;
CREATE TABLE tmp_full_countries as select country_name.country_code,st_union(placex.geometry) as geometry from country_name,
  placex
  where (lower(placex.country_code) = country_name.country_code)
    and placex.rank_address between 4 and 15 and st_area(placex.geometry) > 0
    and type not in ('postcode', 'postal_code')
  group by country_name.country_code;
ALTER TABLE tmp_full_countries add column area double precision;
UPDATE tmp_full_countries set area = st_area(geometry::geography);

-- Load country_fills table.
\i country_fills.sql

-- Simplify boundaries by filling holes.
UPDATE tmp_full_countries c
  SET geometry = ST_Union(c.geometry, f.geometry)
  FROM (SELECT add_country, ST_Union(geometry) as geometry
        FROM country_fills GROUP BY add_country) f
  WHERE c.country_code = f.add_country;
UPDATE tmp_full_countries c
  SET geometry = ST_Difference(c.geometry, f.geometry)
  FROM (SELECT sub_country, ST_Union(geometry) as geometry
        FROM country_fills GROUP BY sub_country) f
  WHERE c.country_code = f.sub_country;


-- Create a single polygon that covers the whole world and simplify it.
DROP TABLE IF EXISTS full_world_poly;
DROP TABLE IF EXISTS simple_world_poly;
CREATE TABLE full_world_poly AS
  SELECT ST_Buffer(ST_Union(geometry), -0.01) as geometry FROM tmp_full_countries;
CREATE TABLE simple_world_poly AS
  SELECT ST_SimplifyPreserveTopology(geometry, 0.09) as geometry FROM full_world_poly;
UPDATE simple_world_poly c
  SET geometry = ST_Difference(c.geometry, ST_Difference(c.geometry, f.geometry))
  FROM full_world_poly f;
UPDATE simple_world_poly SET geometry = ST_SimplifyPreserveTopology(geometry, 0.05);
UPDATE simple_world_poly c
  SET geometry = ST_Difference(c.geometry, ST_Difference(c.geometry, f.geometry))
  FROM full_world_poly f;
UPDATE simple_world_poly SET geometry = ST_SimplifyPreserveTopology(geometry, 0.01);


-- Create the intersection of the simplified world and the countries.
UPDATE tmp_full_countries c
  SET geometry = ST_Intersection(c.geometry, f.geometry)
  FROM simple_world_poly f;

-- Now remove any overlaps. The country with the smaller area wins.
UPDATE tmp_full_countries c
 SET geometry = ST_Difference(c.geometry, src.geometry)
FROM
(SELECT country_code, ST_Union(geometry) as geometry
 FROM (SELECT c1.country_code, c2.geometry
         FROM tmp_full_countries c1, tmp_full_countries c2
        WHERE c1.area > c2.area
              AND c1.country_code != c2.country_code
              AND c1.geometry && c2.geometry) o
 GROUP BY country_code) as src
WHERE c.country_code = src.country_code;
-- Now do the same the other way around, to avoid artifacts from rounding.
UPDATE tmp_full_countries c
 SET geometry = ST_Difference(c.geometry, src.geometry)
FROM
(SELECT country_code, ST_Union(geometry) as geometry
 FROM (SELECT c1.country_code, c2.geometry
         FROM tmp_full_countries c1, tmp_full_countries c2
        WHERE c1.area < c2.area
              AND c1.country_code != c2.country_code
              AND c1.geometry && c2.geometry) o
 GROUP BY country_code) as src
WHERE c.country_code = src.country_code;

-- Split the table into simple polygons.
CREATE TABLE tmp_poly_countries AS
  SELECT country_code, area, (ST_Dump(geometry)).geom::geometry(Polygon, 4326) AS geometry
  FROM tmp_full_countries WHERE ST_GeometryType(geometry) in ('ST_Polygon', 'ST_MultiPolygon');

-- Simplify inner boundaries while keeping coverage. (Needs Postgis 3.4.)
CREATE TABLE tmp_simplified_countries AS
 (SELECT country_code, area, ST_CoverageSimplify(geometry, 0.0003) OVER () as geometry
    FROM tmp_poly_countries);

-- Split the countries into grids.
\i functions.sql

DROP TABLE IF EXISTS new_country_osm_grid;
CREATE TABLE new_country_osm_grid as
  SELECT country_code, area,
         ST_ReducePrecision(country_split_geometry(geometry, 0.4, 10), 0.0001) as geometry
    FROM tmp_simplified_countries;

DROP FUNCTION IF EXISTS country_split_geometry;

-- Flip the new table in.
BEGIN;
DROP TABLE IF EXISTS country_osm_grid;
ALTER TABLE new_country_osm_grid RENAME TO country_osm_grid;
CREATE INDEX idx_country_osm_grid_geometry ON country_osm_grid USING GIST (geometry);
COMMIT;

-- Clean up.
DROP TABLE IF EXISTS country_fills;
DROP TABLE IF EXISTS tmp_full_countries;
DROP TABLE IF EXISTS tmp_poly_countries;
DROP TABLE IF EXISTS tmp_simplified_countries;
DROP TABLE IF EXISTS full_world_poly;
DROP TABLE IF EXISTS simple_world_poly;
