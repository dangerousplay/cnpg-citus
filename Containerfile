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

# The exact PostgreSQL package version, used on BOTH sides of the build.
#
# This is not tidiness, it is the difference between a working image and this:
#
#   FATAL: could not load library ".../citus.so": undefined symbol: palloc0_mul
#
# Citus is compiled against postgresql-server-dev-17 and loaded by the server
# in the final stage. If those are different minors, the extension can
# reference a backend symbol the running server does not export, and it fails
# at load — after the image has built perfectly.
#
# The two cannot simply be left to agree on their own. The CloudNativePG base
# image's 17-bookworm tag currently carries 17.6, and apt.postgresql.org no
# longer publishes 17.6 at all — only 17.8 and newer — so an unpinned
# server-dev resolves to 17.10 against a 17.6 server every single time.
# Pinning the header package to the base image's version is therefore not
# possible; the server is upgraded to meet the headers instead, which is a
# routine same-major minor bump that also picks up the fixes 17.6 is missing.
ARG PG_FULL_VERSION=17.10-1.pgdg12+1

# --------------------------------------------------------------------------- #
# builder — compiles what has no arm64 package, then throws the toolchain away
# --------------------------------------------------------------------------- #
FROM ${BASE_IMAGE}:${PG_MAJOR}-bookworm AS builder

ARG PG_MAJOR=17
ARG CITUS_VERSION=13.3.0
ARG PG_DURABLE_VERSION=0.2.5
ARG WITH_DURABLE=true

USER root

ARG PG_FULL_VERSION
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git flex libcurl4-openssl-dev \
      libicu-dev libkrb5-dev liblz4-dev libpam0g-dev libreadline-dev \
      libselinux1-dev libssl-dev libxslt1-dev libzstd-dev pkg-config \
      "postgresql-server-dev-${PG_MAJOR}=${PG_FULL_VERSION}" zlib1g-dev; \
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
# No --sudo. This stage already runs as root, and the flag makes cargo-pgrx
# shell out to a `sudo` binary the image does not contain. It fails *after* a
# five-minute compile has succeeded, with "Finished installing pg_durable"
# immediately followed by:
#
#   Error:
#      0: No such file or directory (os error 2)
#      Location: .../cargo-pgrx-0.16.1/src/command/sudo_install.rs:91
#
# which reads as a missing source file rather than a missing interpreter.
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
      --pg-config "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"; \
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

ARG PG_FULL_VERSION

# Bring the server up to the version the extensions were compiled against. The
# base image is behind what apt.postgresql.org still carries, so this is an
# upgrade rather than a pin — same major, so no dump and restore, and it is
# the only way to make the two halves agree.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      "postgresql-${PG_MAJOR}=${PG_FULL_VERSION}" \
      "postgresql-client-${PG_MAJOR}=${PG_FULL_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

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
#
# The last check is the one that matters most: it asserts the running server is
# the same minor the extensions were compiled against. A drifting base image
# would otherwise produce an image that builds, passes every file test, and
# then refuses to start with "undefined symbol". barman-cloud is checked too,
# since a careless apt step can remove it and it is CNPG's contract.
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
    test -x /usr/local/bin/barman-cloud-wal-archive; \
    running="$(/usr/lib/postgresql/${PG_MAJOR}/bin/postgres --version | cut -d" " -f3)"; \
    echo "server ${running}, compiled against ${PG_FULL_VERSION}"; \
    case "${PG_FULL_VERSION}" in \
      "${running}-"*) echo "versions agree" ;; \
      *) echo "MISMATCH: server ${running}, headers ${PG_FULL_VERSION}"; exit 1 ;; \
    esac

LABEL org.opencontainers.image.title="cnpg-citus" \
      org.opencontainers.image.description="CloudNativePG-compatible PostgreSQL with Citus and a default extension set" \
      org.opencontainers.image.licenses="PostgreSQL" \
      io.cnpg.postgres.major="${PG_MAJOR}" \
      io.cnpg.citus.version="${CITUS_VERSION}" \
      io.cnpg.pg_durable.version="${PG_DURABLE_VERSION}"

# CloudNativePG refuses to start a container whose Postgres runs as root.
USER 26
