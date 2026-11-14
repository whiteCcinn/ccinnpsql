#!/usr/bin/env bash
# Starts PgBouncer (transaction pooling) and Pgpool-II in front of ccinnpsql-it-pg17 (start it first with
# scripts/pg-up.sh 17). Containers: ccinnpsql-it-pgbouncer (127.0.0.1:15430, admin console database "pgbouncer"),
# ccinnpsql-it-pgpool (127.0.0.1:15431). Both are capped at 256 MB and joined to the network ccinnpsql-it-net.
set -euo pipefail
BACKEND="${CCINNPSQL_IT_BACKEND:-ccinnpsql-it-pg17}"
docker network inspect ccinnpsql-it-net >/dev/null 2>&1 || docker network create ccinnpsql-it-net >/dev/null
docker network connect ccinnpsql-it-net "$BACKEND" 2>/dev/null || true

docker rm -f ccinnpsql-it-pgbouncer ccinnpsql-it-pgpool >/dev/null 2>&1 || true
docker run -d --name ccinnpsql-it-pgbouncer --memory 256m --network ccinnpsql-it-net -p 127.0.0.1:15430:5432 \
  -e DB_HOST="$BACKEND" -e DB_USER=ccinn -e DB_PASSWORD=ccinn -e DB_NAME=ccinn -e POOL_MODE=transaction \
  -e AUTH_TYPE=scram-sha-256 -e ADMIN_USERS=ccinn -e LISTEN_PORT=5432 -e DEFAULT_POOL_SIZE=4 -e MAX_CLIENT_CONN=100 \
  edoburu/pgbouncer:v1.24.1-p1 >/dev/null
echo "started ccinnpsql-it-pgbouncer on 127.0.0.1:15430 (transaction pooling)"

docker run -d --name ccinnpsql-it-pgpool --memory 256m --network ccinnpsql-it-net -p 127.0.0.1:15431:5432 \
  -e PGPOOL_BACKEND_NODES="0:$BACKEND:5432" -e PGPOOL_SR_CHECK_USER=ccinn -e PGPOOL_SR_CHECK_PASSWORD=ccinn \
  -e PGPOOL_SR_CHECK_PERIOD=0 -e PGPOOL_HEALTH_CHECK_PERIOD=0 -e PGPOOL_ENABLE_LDAP=no \
  -e PGPOOL_POSTGRES_USERNAME=ccinn -e PGPOOL_POSTGRES_PASSWORD=ccinn -e PGPOOL_ADMIN_USERNAME=admin -e PGPOOL_ADMIN_PASSWORD=adminpass \
  -e PGPOOL_NUM_INIT_CHILDREN=8 -e PGPOOL_MAX_POOL=2 -e PGPOOL_AUTHENTICATION_METHOD=scram-sha-256 \
  bitnamilegacy/pgpool:4.6.2 >/dev/null
echo "started ccinnpsql-it-pgpool on 127.0.0.1:15431"

for _ in $(seq 1 60); do
  if docker exec "$BACKEND" sh -c 'PGPASSWORD=ccinn psql -h ccinnpsql-it-pgbouncer -U ccinn -d ccinn -tAc "select 1"' >/dev/null 2>&1; then
    echo "ready   ccinnpsql-it-pgbouncer"; break
  fi
  sleep 1
done
for _ in $(seq 1 90); do
  if docker exec "$BACKEND" sh -c 'PGPASSWORD=ccinn psql -h ccinnpsql-it-pgpool -U ccinn -d ccinn -tAc "show pool_version"' >/dev/null 2>&1; then
    echo "ready   ccinnpsql-it-pgpool"; break
  fi
  sleep 1
done
