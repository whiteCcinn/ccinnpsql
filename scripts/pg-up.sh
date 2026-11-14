#!/usr/bin/env bash
# Starts PostgreSQL test containers for the integration tests (CCINNPSQL_IT=1).
#
#   scripts/pg-up.sh [version …]      # default: 17
#   scripts/pg-up.sh 9.6 13 16 17 18
#
# Every container is named ccinnpsql-it-pg<version>, listens on 127.0.0.1:154<NN> (9.6 → 15496,
# 10 → 15410 … 18 → 15418), is capped at 256 MB and has TLS (self-signed test CA), pg_stat_statements,
# and users for each authentication method:
#   ccinn / ccinn          scram-sha-256 (md5 on 9.6)      md5_user / md5pass     md5
#   trust_user             trust                           clear_user / clearpass password (clear text)
#   tls_user / tlspass     scram-sha-256, hostssl only
# Images come from the public ECR mirror of the Docker official images (no Docker Hub rate limit).
set -euo pipefail

STATE_DIR="${CCINNPSQL_IT_DIR:-${TMPDIR:-/tmp}/ccinnpsql-it}"
REGISTRY="${CCINNPSQL_IT_REGISTRY:-public.ecr.aws/docker/library}"
versions=("$@")
[ ${#versions[@]} -eq 0 ] && versions=(17)

port_for() {
  case "$1" in
    9.6) echo 15496 ;;
    *) echo $((15400 + ${1%%.*})) ;;
  esac
}

mkdir -p "$STATE_DIR/certs" "$STATE_DIR/init"
if [ ! -f "$STATE_DIR/certs/server.crt" ]; then
  (
    cd "$STATE_DIR/certs"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 3650 -subj "/CN=CcinnPsql Test CA" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
    printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > ext.cnf
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -extfile ext.cnf 2>/dev/null
    chmod 644 server.key
  )
fi

write_init() { # <dir> <scram|md5>
  local dir="$1" method="$2"
  mkdir -p "$dir"
  cat > "$dir/pg_hba.conf" <<HBA
local   all  all                       trust
hostssl all  tls_user    all           $method
host    all  tls_user    all           reject
host    all  trust_user  all           trust
host    all  md5_user    all           md5
host    all  clear_user  all           password
host    all  all         all           $method
HBA
  if [ "$method" = "md5" ]; then
    # PostgreSQL 9.6: no SCRAM; password_encryption is a boolean.
    cat > "$dir/10-users.sh" <<'INIT'
#!/bin/sh
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE md5_user LOGIN PASSWORD 'md5pass';
CREATE ROLE trust_user LOGIN;
CREATE ROLE clear_user LOGIN PASSWORD 'clearpass';
CREATE ROLE tls_user LOGIN PASSWORD 'tlspass';
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
INIT
  else
    cat > "$dir/10-users.sh" <<'INIT'
#!/bin/sh
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
SET password_encryption = 'md5';
CREATE ROLE md5_user LOGIN PASSWORD 'md5pass';
SET password_encryption = 'scram-sha-256';
CREATE ROLE trust_user LOGIN;
CREATE ROLE clear_user LOGIN PASSWORD 'clearpass';
CREATE ROLE tls_user LOGIN PASSWORD 'tlspass';
GRANT pg_monitor TO md5_user, trust_user, clear_user, tls_user;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
INIT
  fi
  chmod 755 "$dir/10-users.sh"
}
write_init "$STATE_DIR/init" scram-sha-256
write_init "$STATE_DIR/init-md5" md5

for version in "${versions[@]}"; do
  name="ccinnpsql-it-pg${version//./}"
  port=$(port_for "$version")
  init_dir="$STATE_DIR/init"; auth=scram-sha-256
  if [ "$version" = "9.6" ]; then init_dir="$STATE_DIR/init-md5"; auth=md5; fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --memory 256m -p "127.0.0.1:${port}:5432" \
    -e POSTGRES_USER=ccinn -e POSTGRES_PASSWORD=ccinn -e POSTGRES_DB=ccinn \
    -e POSTGRES_INITDB_ARGS="--auth-host=$auth" \
    -v "$STATE_DIR/certs:/certs:ro" -v "$init_dir:/docker-entrypoint-initdb.d:ro" \
    --entrypoint sh "$REGISTRY/postgres:${version}-alpine" -c '
      cp /certs/server.crt /certs/server.key /certs/ca.crt /tmp/ && chown postgres /tmp/server.* /tmp/ca.crt && chmod 600 /tmp/server.key
      cp /docker-entrypoint-initdb.d/pg_hba.conf /tmp/pg_hba.conf && chown postgres /tmp/pg_hba.conf
      exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/server.crt -c ssl_key_file=/tmp/server.key \
        -c hba_file=/tmp/pg_hba.conf -c shared_preload_libraries=pg_stat_statements -c track_io_timing=on \
        -c max_connections=60 -c shared_buffers=32MB -c wal_level=logical -c max_replication_slots=4' >/dev/null
  echo "started $name on 127.0.0.1:$port"
done

for version in "${versions[@]}"; do
  name="ccinnpsql-it-pg${version//./}"
  for _ in $(seq 1 90); do
    if docker exec "$name" pg_isready -h 127.0.0.1 -U ccinn -d ccinn >/dev/null 2>&1 \
       && docker exec "$name" psql -h 127.0.0.1 -U trust_user -d ccinn -tAc 'select 1' >/dev/null 2>&1; then
      echo "ready   $name"
      break
    fi
    sleep 1
  done
done
# Demo data for the integration tests and screenshots.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for version in "${versions[@]}"; do
  name="ccinnpsql-it-pg${version//./}"
  docker exec -i "$name" psql -q -U ccinn -d ccinn -v ON_ERROR_STOP=1 < "$SCRIPT_DIR/seed-demo.sql" >/dev/null 2>&1 \
    && docker exec -i "$name" psql -q -U ccinn -d ccinn -v ON_ERROR_STOP=1 < "$SCRIPT_DIR/seed-modern.sql" >/dev/null 2>&1 \
    && echo "seeded  $name" || echo "SEED FAILED for $name"
done
echo "CA certificate: $STATE_DIR/certs/ca.crt"
