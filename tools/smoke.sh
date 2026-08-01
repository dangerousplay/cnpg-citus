#!/usr/bin/env bash
# Start a real postmaster and exercise every extension the image claims.
#
# Checking that citus.so exists proves the file copied, not that it loads.
# Citus in particular cannot be created at all without being preloaded, and a
# .so built against the wrong PostgreSQL major fails at load time with a
# message nobody sees until a database bootstraps in anger. This runs the
# postmaster, creates each extension, and uses them.
#
# Runs as uid 26 inside the image. Not part of the image itself — mounted in.
set -euo pipefail

PG_MAJOR="${PG_MAJOR:-17}"
WITH_DURABLE="${WITH_DURABLE:-true}"
export PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"
export PGDATA=/tmp/smoke

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "arch:     $(uname -m)"
echo "postgres: $(postgres --version)"

initdb -U postgres >/dev/null 2>&1 || fail "initdb"

# Four of these refuse to be created unless they are preloaded, and each says
# so only at CREATE EXTENSION time: citus and pg_durable register background
# workers, pg_cron schedules one, and pgaudit hooks the executor
# ("pgaudit must be loaded via shared_preload_libraries").
#
# max_prepared_transactions is not optional for Citus either: cross-shard
# writes use two-phase commit and fail outright at the default of 0.
{
  echo "shared_preload_libraries = 'citus,pg_cron,pgaudit,pg_stat_statements${WITH_DURABLE:+,pg_durable}'"
  echo "max_prepared_transactions = 100"
  echo "cron.database_name = 'smoke'"
  [ "$WITH_DURABLE" = "true" ] && echo "pg_durable.database = 'smoke'"
} >> "$PGDATA/postgresql.conf"

pg_ctl -D "$PGDATA" -l /tmp/log -w start >/dev/null 2>&1 || {
  echo "--- postmaster log ---"; tail -40 /tmp/log; fail "postmaster did not start";
}

psql -U postgres -qc "CREATE DATABASE smoke;"

# `vector`, not `pgvector`: the Debian package is postgresql-17-pgvector
# but the extension it installs is called vector.
EXTS="citus vector pg_cron pg_partman pg_repack hypopg hll pgaudit pg_stat_statements"
[ "$WITH_DURABLE" = "true" ] && EXTS="$EXTS pg_durable"

for ext in $EXTS; do
  psql -U postgres -d smoke -qc "CREATE EXTENSION IF NOT EXISTS \"$ext\" CASCADE;" \
    || fail "CREATE EXTENSION $ext"
done

echo "--- extensions ---"
psql -U postgres -d smoke -Atc \
  "select '  '||extname||' '||extversion from pg_extension order by 1;"

# Creating an extension is not using it. These are the operations that would
# actually break if a library were subtly wrong for the architecture.
echo "--- exercising ---"

psql -U postgres -d smoke -q \
  -c "CREATE TABLE t (gid bigint, id bigserial, body text, PRIMARY KEY (gid, id));" \
  -c "CREATE TABLE r (k int PRIMARY KEY);"
psql -U postgres -d smoke -Atc "SELECT create_distributed_table('t','gid');" >/dev/null \
  || fail "create_distributed_table"
psql -U postgres -d smoke -Atc "SELECT create_reference_table('r');" >/dev/null \
  || fail "create_reference_table"
psql -U postgres -d smoke -qc \
  "INSERT INTO t(gid, body) SELECT i % 8, 'row '||i FROM generate_series(1,1000) i;"
rows=$(psql -U postgres -d smoke -Atc "SELECT count(*) FROM t;")
shards=$(psql -U postgres -d smoke -Atc \
  "SELECT count(*) FROM pg_dist_shard WHERE logicalrelid='t'::regclass;")
[ "$rows" = "1000" ] || fail "expected 1000 rows across shards, got $rows"
echo "  citus:    $rows rows across $shards shards"

# pgvector: an index build is where a bad build shows up, not the CREATE.
psql -U postgres -d smoke -q \
  -c "CREATE TABLE v (id int, e vector(3));" \
  -c "INSERT INTO v SELECT i, ('['||i||','||(i+1)||','||(i+2)||']')::vector FROM generate_series(1,100) i;" \
  -c "CREATE INDEX ON v USING hnsw (e vector_l2_ops);"
near=$(psql -U postgres -d smoke -Atc "SELECT id FROM v ORDER BY e <-> '[1,2,3]' LIMIT 1;")
[ "$near" = "1" ] || fail "pgvector nearest neighbour returned $near, expected 1"
echo "  pgvector: hnsw index built, nearest neighbour correct"

hll=$(psql -U postgres -d smoke -Atc \
  "SELECT hll_cardinality(hll_add_agg(hll_hash_integer(i))) FROM generate_series(1,1000) i;")
echo "  hll:      cardinality estimate $hll for 1000 distinct"

psql -U postgres -d smoke -Atc "SELECT cron.schedule('smoke','5 seconds','SELECT 1');" >/dev/null \
  || fail "pg_cron schedule"
echo "  pg_cron:  job scheduled"

psql -U postgres -d smoke -Atc \
  "SELECT count(*) FROM hypopg_create_index('CREATE INDEX ON t (body)');" >/dev/null \
  || fail "hypopg"
echo "  hypopg:   hypothetical index created"

if [ "$WITH_DURABLE" = "true" ]; then
  for _ in $(seq 1 30); do
    grep -q "duroxide runtime started" /tmp/log && break
    sleep 2
  done
  grep -q "duroxide runtime started" /tmp/log \
    || { tail -20 /tmp/log; fail "pg_durable worker never started"; }
  n=$(psql -U postgres -d smoke -Atc \
    "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='df';")
  [ "$n" -gt 0 ] || fail "pg_durable installed no functions in schema df"
  echo "  durable:  worker running, $n functions in schema df"
fi

# CloudNativePG's own requirements. An apt step that removes barman, or a
# forgotten USER directive, breaks the image for its only consumer.
command -v barman-cloud-wal-archive >/dev/null || fail "barman-cloud is missing"
[ "$(id -u)" = "26" ] || fail "expected to run as uid 26, got $(id -u)"
echo "  cnpg:     barman-cloud present, running as uid 26"

if grep -qE "FATAL|PANIC" /tmp/log; then
  echo "--- FATAL/PANIC in log ---"; grep -E "FATAL|PANIC" /tmp/log | head -5
  fail "postmaster logged FATAL or PANIC"
fi

echo "OK"
