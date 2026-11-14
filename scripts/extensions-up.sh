#!/usr/bin/env bash
# Starts single-node TimescaleDB, Citus and PostGIS servers for the extension-awareness checks
# (CCINNPSQL_IT=1 CCINNPSQL_IT_EXTENSIONS=1). Ports: TimescaleDB 15440, Citus 15441, PostGIS 15442; 256 MB each.
# PostGIS uses imresamu/postgis (multi-arch build of the official postgis/postgis image).
set -euo pipefail
start() { # name port image extra-args...
  local name="$1" port="$2" image="$3"; shift 3
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --memory 256m -p "127.0.0.1:$port:5432" \
    -e POSTGRES_USER=ccinn -e POSTGRES_PASSWORD=ccinn -e POSTGRES_DB=ccinn -e NO_TS_TUNE=true "$image" "$@" >/dev/null
  echo "started $name on 127.0.0.1:$port"
}
start ccinnpsql-it-timescale 15440 timescale/timescaledb:latest-pg17 postgres -c shared_buffers=32MB -c max_connections=40
start ccinnpsql-it-citus 15441 citusdata/citus:13.0 postgres -c shared_buffers=32MB -c max_connections=40 -c shared_preload_libraries=citus
start ccinnpsql-it-postgis 15442 imresamu/postgis:17-3.5-alpine postgres -c shared_buffers=32MB -c max_connections=40
for name in ccinnpsql-it-timescale ccinnpsql-it-citus ccinnpsql-it-postgis; do
  for _ in $(seq 1 120); do
    if docker exec "$name" sh -c 'PGPASSWORD=ccinn psql -h 127.0.0.1 -U ccinn -d ccinn -tAc "select 1"' >/dev/null 2>&1; then
      echo "ready   $name"; break
    fi
    sleep 1
  done
done
docker exec -i ccinnpsql-it-timescale psql -q -U ccinn -d ccinn -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS timescaledb;
DROP TABLE IF EXISTS conditions;
CREATE TABLE conditions (time timestamptz NOT NULL, device text NOT NULL, temperature double precision);
SELECT create_hypertable('conditions', 'time', chunk_time_interval => interval '1 day');
INSERT INTO conditions SELECT now() - (g || ' hours')::interval, 'dev-' || (g % 3), random() * 30 FROM generate_series(1, 200) g;
ALTER TABLE conditions SET (timescaledb.compress, timescaledb.compress_segmentby = 'device');
SQL
docker exec -i ccinnpsql-it-citus psql -q -U ccinn -d ccinn -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS citus;
DROP TABLE IF EXISTS events, countries;
CREATE TABLE events (tenant_id int NOT NULL, id bigserial, payload text, PRIMARY KEY (tenant_id, id));
SELECT create_distributed_table('events', 'tenant_id');
CREATE TABLE countries (code char(2) PRIMARY KEY, name text);
SELECT create_reference_table('countries');
INSERT INTO events (tenant_id, payload) SELECT g % 10, 'e' || g FROM generate_series(1, 100) g;
SQL
docker exec -i ccinnpsql-it-postgis psql -q -U ccinn -d ccinn -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
DROP TABLE IF EXISTS places;
CREATE TABLE places (id serial PRIMARY KEY, name text, location geometry(Point, 4326), area geography(Polygon, 4326));
INSERT INTO places (name, location) VALUES ('KLCC', ST_SetSRID(ST_MakePoint(101.7119, 3.1579), 4326));
SQL
echo "extensions seeded"
