#!/usr/bin/env bash
# Removes every CcinnPsql test container (ccinnpsql-it-*) and nothing else.
set -euo pipefail
names=$(docker ps -a --format '{{.Names}}' | grep '^ccinnpsql-it-' || true)
[ -z "$names" ] && { echo "no ccinnpsql-it-* containers"; exit 0; }
echo "$names" | xargs docker rm -f
