# cnpg-citus

CloudNativePG-compatible PostgreSQL with Citus and a default extension set,
built for **linux/amd64 and linux/arm64**.

```
ghcr.io/OWNER/cnpg-citus:17-citus14.1.0
```

## What is in it

| | version | source |
|---|---|---|
| PostgreSQL | 17 | `ghcr.io/cloudnative-pg/postgresql` |
| Citus | 14.1.0 | compiled from the release tarball |
| pg_durable | 0.2.5 | compiled with cargo-pgrx |
| pgvector (as `vector`), pg_cron, pg_partman, pg_repack, hypopg, hll, pgaudit | PGDG | packages |

Base is `ghcr.io/cloudnative-pg/postgresql`, not the official `postgres` image.
CloudNativePG will not operate a stock PostgreSQL — it needs `barman-cloud` for
WAL archiving and backup, and uid 26. Adding extensions to CNPG's image keeps
that contract; starting from `citusdata/citus` would mean rebuilding it.

## Why both architectures are compiled

Citus publishes **amd64 packages only**. `repos.citusdata.com` has no arm64
index at all, and Citus is not in PGDG. pg_durable is the same — its releases
carry `_amd64.deb` and nothing else.

So the arm64 half has to be compiled either way, and this compiles both rather
than installing a package on one architecture and building on the other. One
code path is worth more than the few minutes saved: a dual-path build is how
you get an image that works on amd64 and fails in some unexamined way on
arm64, discovered by whoever runs an arm64 node.

Everything else comes from PGDG, which publishes both.

## Using it with CloudNativePG

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: db
spec:
  instances: 1
  imageName: ghcr.io/OWNER/cnpg-citus:17-citus14.1.0

  postgresql:
    # citus, pg_cron, pgaudit and pg_durable all refuse to be created unless
    # they are preloaded, and each only says so at CREATE EXTENSION time.
    shared_preload_libraries: [citus, pg_cron, pgaudit, pg_durable, pg_stat_statements]
    pg_hba:
      # Citus registers the coordinator as localhost:5432 and reaches its own
      # shards over TCP even when every shard is local. That connection has no
      # password and CNPG's pg_hba ends at scram-sha-256, so without this every
      # distributed write fails with "could not connect to shard".
      #
      # A plain initdb leaves loopback on trust, which is why this only bites
      # under CNPG. The scope is one pod's network namespace.
      - host all all 127.0.0.1/32 trust
      - host all all ::1/128 trust
    parameters:
      # Citus uses two-phase commit for cross-shard writes. At the default of
      # 0 they fail outright.
      max_prepared_transactions: "100"
      cron.database_name: app
      pg_durable.database: app
      pg_durable.worker_role: postgres

  bootstrap:
    initdb:
      database: app
      owner: app

  storage:
    size: 20Gi
---
# Extensions belong here, not in postInit SQL.
#
# postInitApplicationSQL runs as the application owner, and these extensions
# create objects in pg_catalog — it fails with "permission denied to create
# pg_catalog.pg_stat_statements". postInitTemplateSQL runs as a superuser but
# installing citus into template1 starts its maintenance daemon there, which
# blocks the CREATE DATABASE ... TEMPLATE template1 that CNPG does next.
#
# The operator applies this as a superuser, and re-applies on a spec change —
# postInit SQL runs once at bootstrap, so an extension added to it later is an
# edit that appears applied and does nothing.
#
# `applied: true` in the status is a record of a past action, not a live
# assertion: the controller acts on a generation change and does not re-verify
# afterwards. An extension dropped out of band stays dropped, and the status
# still says applied.
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: app-db
spec:
  cluster: {name: db}
  name: app
  owner: app
  ensure: present
  databaseReclaimPolicy: retain   # a prune must not drop the database
  extensions:
    - {name: citus, ensure: present}
    - {name: vector, ensure: present}   # the package is pgvector, the extension is vector
    - {name: pg_durable, ensure: present}
```

### If the tenant namespace has a default-deny network policy

CloudNativePG needs both directions and neither is obvious:

- **egress to the Kubernetes API** — the instance manager watches its own
  Cluster and cannot bootstrap without it. The Job retries forever on
  `dial tcp …:443: i/o timeout`, which reads as a broken API server.
- **ingress from the operator's namespace on port 8000** — CNPG polls each
  instance for status. Without it the database runs and the operator reports
  `Instance Status Extraction Error: HTTP communication issue`, and the Cluster
  never reaches a healthy phase.

Metrics are on **9187**, not 9090.

## Building

```sh
./tools/build.py                       # this host's architecture, no push
./tools/build.py --test                # build, then run the smoke test
./tools/build.py --arch amd64,arm64    # both; the foreign one runs under QEMU
./tools/build.py --no-durable          # skip the Rust build, much faster
./tools/build.py --push --registry ghcr.io/you
```

Nothing is pushed without `--push`, and `--push` implies `--test`: an image
that was not exercised is not published.

Cross-architecture builds go through QEMU and are slow — pg_durable is a Rust
compile. Prefer building each architecture on its own hardware, which is what
CI does.

## The smoke test

`tools/smoke.sh` starts a real postmaster and **uses** every extension rather
than checking that files exist. A `.so` can be present and fail to load, and
one built against the wrong PostgreSQL major only fails at load time.

It creates a distributed table and a reference table and inserts across shards,
builds an hnsw index and checks the nearest neighbour is the right row,
schedules a `pg_cron` job, creates a hypothetical index, runs an `hll`
cardinality estimate, waits for pg_durable's worker to report `duroxide runtime
started`, and confirms `barman-cloud` is present and the process is uid 26.
Then it fails if the postmaster logged any `FATAL` or `PANIC`.

## CI

`.github/workflows/build.yml` builds each architecture on a runner of that
architecture — `ubuntu-24.04` and `ubuntu-24.04-arm`, both free for public
repositories. Emulating a Rust build would take hours.

Each job pushes an untagged image and reports its digest; a final job assembles
the digests into a manifest list. Nothing gets a human-readable tag until every
architecture has built *and passed its smoke test*, so a half-published tag is
never reachable. The merge job then verifies the published list really
advertises both architectures — a manifest that claims an architecture it does
not contain fails on a user's node instead of in CI.

Each job also asserts the runner is the architecture it was asked for. A silent
fallback to amd64 would produce two identical images in a list advertising two.

### Tags

| tag | when |
|---|---|
| `17-citus14.1.0` | every build |
| `17` | default branch only |
| `v*` | git tags |
| `17-<sha>` | every build |

## Licence

The image contains PostgreSQL (PostgreSQL licence), Citus (AGPL-3.0),
pg_durable (MIT) and the PGDG extensions under their own terms. Citus being
AGPL is worth knowing before redistributing.
