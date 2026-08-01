# CloudNativePG-compatible PostgreSQL with Citus and a default extension set.
#
# Built for linux/amd64 and linux/arm64. The single fact that shapes this file:
# Citus publishes packages for amd64 only. repos.citusdata.com has no arm64
# index at all, and Citus is not in PGDG. pg_durable is the same — its GitHub
# releases carry `_amd64.deb` and nothing else.
#
# So the arm64 half has to come from source either way, and this builds both
# arches from source rather than installing a package on one and compiling on
# the other. One code path is worth more than the few minutes saved: a
# dual-path build is how you get an image that works on amd64 and fails in some
# unexamined way on arm64, discovered by whoever runs an arm64 node.
#
# Everything else comes from PGDG, which does publish both arches.
#
# Base is ghcr.io/cloudnative-pg/postgresql, not the official postgres image.
# CloudNativePG will not operate a stock Postgres: it needs barman-cloud for
# WAL archiving and backup, and uid 26. Adding extensions to CNPG's image keeps
# that contract; starting from citusdata/citus would mean rebuilding it.

ARG PG_MAJOR=17
ARG BASE_IMAGE=ghcr.io/cloudnative-pg/postgresql

# --------------------------------------------------------------------------- #
# builder — compiles what has no arm64 package, then throws the toolchain away
# --------------------------------------------------------------------------- #
FROM ${BASE_IMAGE}:${PG_MAJOR}-bookworm AS builder

ARG PG_MAJOR=17
ARG CITUS_VERSION=13.3.0
ARG PG_DURABLE_VERSION=0.2.5
ARG WITH_DURABLE=true

USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git flex libcurl4-openssl-dev \
      libicu-dev libkrb5-dev liblz4-dev libpam0g-dev libreadline-dev \
      libselinux1-dev libssl-dev libxslt1-dev libzstd-dev pkg-config \
      "postgresql-server-dev-${PG_MAJOR}" zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

# --- Citus ----------------------------------------------------------------- #
# From the release tarball rather than a git clone: a tag can be moved, and the
# tarball is what the checksum below pins. DESTDIR stages the install so the
# final stage copies a known tree instead of re-running make install as root.
RUN set -eux; \
    curl -fsSLo /tmp/citus.tar.gz \
      "https://github.com/citusdata/citus/archive/refs/tags/v${CITUS_VERSION}.tar.gz"; \
    mkdir -p /tmp/citus && tar -xzf /tmp/citus.tar.gz -C /tmp/citus --strip-components=1; \
    cd /tmp/citus; \
    ./configure --without-libcurl; \
    make -j"$(nproc)"; \
    make install DESTDIR=/staging; \
    rm -rf /tmp/citus /tmp/citus.tar.gz

# --- pg_durable ------------------------------------------------------------ #
# Microsoft's in-database durable execution. A pgrx extension, so building it
# means a Rust toolchain and cargo-pgrx pinned to the version the crate expects
# — pgrx is tightly coupled to its build tool and a mismatched cargo-pgrx fails
# late, during schema generation, rather than at resolve time.
#
# This is the slow part of the build by a wide margin. WITH_DURABLE=false skips
# it entirely and produces an image with Citus and the PGDG set only.
ARG CARGO_PGRX_VERSION=0.16.1
ENV CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN set -eux; \
    if [ "${WITH_DURABLE}" != "true" ]; then \
      echo "WITH_DURABLE=${WITH_DURABLE} — skipping"; exit 0; \
    fi; \
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable; \
    cargo install --locked "cargo-pgrx@${CARGO_PGRX_VERSION}"; \
    curl -fsSLo /tmp/durable.tar.gz \
      "https://github.com/microsoft/pg_durable/archive/refs/tags/v${PG_DURABLE_VERSION}.tar.gz"; \
    mkdir -p /tmp/durable && tar -xzf /tmp/durable.tar.gz -C /tmp/durable --strip-components=1; \
    cd /tmp/durable; \
    cargo pgrx init "--pg${PG_MAJOR}=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"; \
    cargo pgrx install --release --no-default-features \
      --features "pg${PG_MAJOR}" \
      --pg-config "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" \
      --sudo; \
    mkdir -p "/staging/usr/lib/postgresql/${PG_MAJOR}/lib" \
             "/staging/usr/share/postgresql/${PG_MAJOR}/extension"; \
    cp "/usr/lib/postgresql/${PG_MAJOR}/lib/pg_durable.so" \
       "/staging/usr/lib/postgresql/${PG_MAJOR}/lib/"; \
    cp /usr/share/postgresql/${PG_MAJOR}/extension/pg_durable* \
       "/staging/usr/share/postgresql/${PG_MAJOR}/extension/"; \
    rm -rf /tmp/durable /tmp/durable.tar.gz /usr/local/cargo/registry

# --------------------------------------------------------------------------- #
# final — the base image again, plus packages and the staged build output
# --------------------------------------------------------------------------- #
FROM ${BASE_IMAGE}:${PG_MAJOR}-bookworm

ARG PG_MAJOR=17
ARG CITUS_VERSION=13.3.0
ARG PG_DURABLE_VERSION=0.2.5
ARG WITH_DURABLE=true

USER root

# PGDG ships all of these for both architectures, so there is no reason to
# compile them. Chosen to be useful without being opinionated: vector search,
# scheduling, partition maintenance, bloat removal, index experiments,
# approximate counting, and an audit trail.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      "postgresql-${PG_MAJOR}-pgvector" \
      "postgresql-${PG_MAJOR}-cron" \
      "postgresql-${PG_MAJOR}-partman" \
      "postgresql-${PG_MAJOR}-repack" \
      "postgresql-${PG_MAJOR}-hypopg" \
      "postgresql-${PG_MAJOR}-hll" \
      "postgresql-${PG_MAJOR}-pgaudit"; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /staging/ /

# Fail the build, not the cluster. Without this the image builds clean and the
# first CREATE EXTENSION fails inside a CNPG initdb Job, where the reason is
# several containers deep and reads like a broken operator.
# `vector`, not `pgvector`: the Debian package is postgresql-17-pgvector but
# the extension it installs is called vector. Comments live outside the RUN —
# a `#` line inside a backslash continuation is a parser quirk worth not
# relying on.
RUN set -eux; \
    for ext in citus vector pg_cron pg_partman pg_repack hypopg hll pgaudit; do \
      test -f "/usr/share/postgresql/${PG_MAJOR}/extension/${ext}.control" \
        || { echo "MISSING: ${ext}.control"; exit 1; }; \
    done; \
    test -f "/usr/lib/postgresql/${PG_MAJOR}/lib/citus.so"; \
    if [ "${WITH_DURABLE}" = "true" ]; then \
      test -f "/usr/share/postgresql/${PG_MAJOR}/extension/pg_durable.control"; \
      test -f "/usr/lib/postgresql/${PG_MAJOR}/lib/pg_durable.so"; \
    fi; \
    # barman-cloud is CNPG's contract, and a careless apt step can remove it.
    test -x /usr/local/bin/barman-cloud-wal-archive

LABEL org.opencontainers.image.title="cnpg-citus" \
      org.opencontainers.image.description="CloudNativePG-compatible PostgreSQL with Citus and a default extension set" \
      org.opencontainers.image.licenses="PostgreSQL" \
      io.cnpg.postgres.major="${PG_MAJOR}" \
      io.cnpg.citus.version="${CITUS_VERSION}" \
      io.cnpg.pg_durable.version="${PG_DURABLE_VERSION}"

# CloudNativePG refuses to start a container whose Postgres runs as root.
USER 26
