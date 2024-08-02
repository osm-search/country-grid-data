-- SPDX-License-Identifier: GPL-2.0-only
--
-- Copyright (C) 2024 by the Nominatim developer community.
-- For a full list of authors see the git log.

CREATE OR REPLACE FUNCTION country_split_geometry(geometry GEOMETRY, maxarea FLOAT,
                                                  maxdepth INTEGER)
  RETURNS SETOF GEOMETRY
  AS $$
DECLARE
  xmin FLOAT;
  ymin FLOAT;
  xmax FLOAT;
  ymax FLOAT;
  mid FLOAT;
  secgeo GEOMETRY;
  secbox GEOMETRY;
  box1 GEOMETRY;
  box2 GEOMETRY;
  seg INTEGER;
  geo RECORD;
  area FLOAT;
  remainingdepth INTEGER;
BEGIN
  remainingdepth := maxdepth - 1;
  area := ST_AREA(geometry);
  IF remainingdepth < 1 OR area < maxarea OR ST_NPoints(geometry) < 10 THEN
    RETURN NEXT geometry;
    RETURN;
  END IF;

  xmin := st_xmin(geometry);
  xmax := st_xmax(geometry);
  ymin := st_ymin(geometry);
  ymax := st_ymax(geometry);
  secbox := ST_SetSRID(ST_MakeBox2D(ST_Point(ymin,xmin),ST_Point(ymax,xmax)),4326);

  -- if the geometry completely covers the box don't bother to slice any more
  IF ST_AREA(secbox) = area THEN
    RETURN NEXT geometry;
    RETURN;
  END IF;

  IF (xmax - xmin) > (ymax - ymin) THEN
    -- split vertically
    mid := (xmin+xmax)/2;
    box1 := ST_SetSRID(ST_MakeBox2D(ST_Point(xmin,ymin),ST_Point(mid,ymax)),4326);
    box2 := ST_SetSRID(ST_MakeBox2D(ST_Point(mid,ymin),ST_Point(xmax,ymax)),4326);
  ELSE
    -- split horizontally
    mid := (ymin+ymax)/2;
    box1 := ST_SetSRID(ST_MakeBox2D(ST_Point(xmin,ymin),ST_Point(xmax,mid)),4326);
    box2 := ST_SetSRID(ST_MakeBox2D(ST_Point(xmin,mid),ST_Point(xmax,ymax)),4326);
  END IF;

  FOR seg IN 1..2 LOOP
    IF seg = 1 THEN
      secbox := box1;
    END IF;
    IF seg = 2 THEN
      secbox := box2;
    END IF;

    IF st_intersects(geometry, secbox) THEN
      secgeo := st_intersection(geometry, secbox);
      IF NOT ST_IsEmpty(secgeo) AND ST_GeometryType(secgeo) in ('ST_Polygon','ST_MultiPolygon') THEN
        FOR geo IN select country_split_geometry(secgeo, maxarea, remainingdepth) as geom LOOP
          IF NOT ST_IsEmpty(geo.geom) AND ST_GeometryType(geo.geom) in ('ST_Polygon','ST_MultiPolygon') THEN
            RETURN NEXT geo.geom;
          END IF;
        END LOOP;
      END IF;
    END IF;
  END LOOP;

  RETURN;
END;
$$
LANGUAGE plpgsql IMMUTABLE;

