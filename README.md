
Country grid data for Nominatim
===============================

The number of countries in the world can change (South Sudan created 2011, Germany reunification), so can their boundaries. This document explain how the pre-generated files can be updated.


Overview
--------

Nominatim imports two pre-generated files

   * `data/country_name.sql` (country code, name, default language, partition)
   * `data/country_osm_grid.sql` (country code, geometry)

before creating places in the database. This helps with fast lookups and missing data (e.g. if the data the user wants to import doesn't contain any country places).

Thus the country grid is mainly **Fallback Country Boundaries**.

Each place is assigned a `country_code` and partition. Partitions derive from `country_code`.


Country codes
-------------

Each place is assigned a two letter country_code based on its location, e.g. `gb` for Great Britain. Or `NULL` if no suitable country is found (usually it's in open water then).

In `sql/functions.sql: get_country_code(geometry)` the place's center is checked against

   1. country places already imported from the user's data file. Places are imported by rank low-to-high. Lowest rank 2 is countries so most places should be matched. Still the data file might be incomplete.
   2. if unmatched: OSM grid boundaries
   3. if still unmatched: OSM grid boundaries, but allow a small distance




Partitions
----------

Each place is assigned partition, which is a number 0..250. 0 is fallback/other.

During place indexing (`sql/functions.sql: placex_insert()`) a place is assigned the partition based on its country code (`sql/functions.sql: get_partition(country_code)`). It checks in the `country_name` table.

Most countries have their own partition, some share a partition. Thus partition counts vary greatly.

Several database tables are split by partition to allow queries to run against less indices and improve caching.

   * `location_area_large_<partition>`
   * `search_name_<partition>`
   * `location_road_<partition>`





Data files
----------

### data/country_name.sql

Export from existing database table plus manual changes. `country_default_language_code` most taken from [https://wiki.openstreetmap.org/wiki/Nominatim/Country_Codes](), see `utils/country_languages.php`.



### data/country_osm_grid.sql

`country_grid.sql` creates a base table with simplified country polygons from a
global Nominatim database. The polygons are split by rectilinear lines for
faster point-in-polygon lookup.

The simplification of the polygons is guided by Nominatim's requirement that
it should minimize the error that a OSM object is placed in the wrong country.
This means simplification can be greater on water areas where there are
fewer OSM object and needs to remain quite close to the original in
inhabited areas. For example, the boundaries around
[Baarle-Nassau](https://www.openstreetmap.org/#map=15/51.4414/4.9339)
need to be kept precise, while the boundary of Northern Canada will only
need a few vertex points.

`country_fills.sql` contains manual simplifications around some areas that
are known to cause issues with the subsequent automatic simplification and
deduplication.

Where OSM countries overlap because an area is disputed, the same strategy
as within Nominatim itself is used and the country with the smaller area wins.
Exceptions can be added by editing `country_fills.sql` and declaring the
owner country for the area.

The script can be run in a fully automatic fashion to create a new table
`country_osm_grid`. However, it is advisable to carefully check the result
because the countries in the Nominatim database are not necessarily in a
clean state. PostGIS version 3.4 or higher is required for the
ST_CoverageSimplify function.

To visualize one country as geojson feature collection,
e.g. for loading into [geojson.io](http://geojson.io/):

```
-- http://www.postgresonline.com/journal/archives/267-Creating-GeoJSON-Feature-Collections-with-JSON-and-PostGIS-functions.html

SELECT row_to_json(fc)
FROM (
  SELECT 'FeatureCollection' As type, array_to_json(array_agg(f)) As features
  FROM (
    SELECT 'Feature' As type,
    ST_AsGeoJSON(lg.geometry)::json As geometry,
    row_to_json((country_code, area)) As properties
    FROM country_osm_grid As lg where country_code='mx'
  ) As f
) As fc;
```

`cat /tmp/query.sql | psql -At nominatim > /tmp/mexico.quad.geojson`

![mexico](mexico.quad.png)

#### Publishing `country_osm_grid.sql`

To create a new `country_grid.sql.gz`, run the following:

```
pg_dump  -Ox -t country_osm_grid <DATABASE NAME> | grep -v '^SET.*;' | grep -v '^SELECT.*;' | grep -v '^--' > country_grid.sql
```

Now add the following license header:

```
-- SPDX-License-Identifier:  ODbL-1.0
--
-- Copyright OpenStreetMap contributors
--
-- Simplified OSM country grid (data as of <DATE OF NOMINATIM DATABASE>)
```

and pack using `gzip -9`.

License
=======

The source code is available under a GPLv2 license.
