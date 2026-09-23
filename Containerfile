# mcl-rag
#
# The mesh shared memory: retrieval over a realm-bound corpus, and the deposits agents remember into it
#
# ⚠ THE SHARED MEMORY LIVES ON A VOLUME, /var/lib/mcl-rag: one barrel database
# (documents, attachments, vectors) plus the corpus checkouts. Declared here and
# in the compose file together; the eunit suite holds the two to each other.

# ⚠ THE RUNTIME IS PINNED IN TWO PLACES AND THEY MUST AGREE: here and `lint.yml'
# beside it. A generated service that builds on one release and tests on another
# only ever proves "the tests pass on the CI release".
#
# This template said 27 from the beginning and nothing revisited it, so every
# service scaffolded from it inherited 27 while development machines moved on.
# In a sibling service that cost three commits of red CI on a crash that does not
# occur on the development release at all, and because `build-push.yml' is a
# separate workflow the image shipped to the fleet regardless.
# ⚠ PINNED BY TAG AND DIGEST. `erlang:28-alpine' floats, and when Docker Hub
# moved it on 2026-09-22 mcl-echo's next deploy shipped OTP 28.5 while lint
# tested something else. 28.4.3 is the team standard; the digest is the
# multi-arch index, so a re-pushed tag cannot change what builds. hexpm's
# image, because Docker's own `erlang' publishes no 28.4.3; Alpine 3.22.6, the
# same release as the runtime stage below, whose OpenSSL 3.5 carries ML-DSA.
# Move both on purpose, never by drift.
FROM docker.io/hexpm/erlang:28.4.3-alpine-3.22.6@sha256:3815b99f486c2509baf556045bca0c5fc1c3ee50fb50a80590534f22cb48736c AS builder
WORKDIR /build

# macula ships a QUIC NIF. MACULA_FORCE_SOURCE_BUILD makes it build here rather
# than fetch a prebuilt binary linked against a different libc, which is the
# recorded glibc trap: the fetched artifact loads on the build host and fails on
# alpine at runtime.
#
# openssl-dev/zstd-dev/snappy-dev/lz4-dev: mcl_om pulls in rocksdb (via
# barrel_docdb) and khepri/ra transitively, UNCONDITIONALLY -- confirmed on a
# storeless, producer-only service (no store_id/0 or data_dir/0 exported),
# which still failed to build without these. Not specific to a service that
# owns its own reckon-db store.
RUN apk add --no-cache git curl bash build-base cmake perl linux-headers \
        openssl-dev zstd-dev snappy-dev lz4-dev
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTFLAGS="-C target-feature=-crt-static"
ENV MACULA_FORCE_SOURCE_BUILD=1

RUN curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/ and the Rust toolchain is not re-run per commit.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps

# THE CORPUS-SYNC NIF IS BUILT HERE, against musl, and never copied in. It was
# once committed as a workstation build, which links glibc: it loaded in every
# local test and would never have loaded on this image, so the corpus would
# silently have stopped syncing. It is built AFTER `COPY apps' so a stale local
# priv/lib cannot overwrite it (.dockerignore keeps it out too). zlib-dev: the
# vendored libgit2 links the system zlib.
RUN apk add --no-cache zlib-dev
COPY native ./native
COPY scripts ./scripts
RUN bash scripts/build-corpus-sync-nif.sh

RUN rebar3 as prod release

FROM docker.io/alpine:3.22
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-rag"
# zstd-libs/snappy/lz4-libs: the RUNTIME shared libraries for rocksdb's
# compression backends, compiled against in the builder stage above via
# their -dev packages. Missing here crashes the release outright on
# boot -- rocksdb's on_load NIF init fails with "Failed to load NIF
# library: Error loading shared library liblz4.so.1: No such file or
# directory" and the whole node exits, since kernel can't start.
# Confirmed live: this stage shipped without them once already.
# zlib: the corpus-sync NIF's libgit2 links it dynamically.
RUN apk add --no-cache ncurses-libs libstdc++ libgcc openssl ca-certificates curl \
        zstd-libs snappy lz4-libs zlib
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/mcl_rag ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV MCL_NODE_NAME=mcl_rag
ENV MCL_NODE_HOST=127.0.0.1
ENV MCL_COOKIE=mcl_rag
ENV MCL_HEALTH_PORT=8450
# The local HTTP API: loopback only, because it has writes and no
# authentication. The mesh procedures are the public surface.
ENV MCL_RAG_HTTP_PORT=8470
ENV MCL_RAG_HTTP_IP=127.0.0.1
ENV MCL_DATA_DIR=/var/lib/mcl-rag

VOLUME ["/etc/mcl/secrets", "/var/lib/mcl-rag"]

EXPOSE 8450
# THE START PERIOD OUTLASTS THE STORE OPEN. Opening rebuilds the vector index:
# 190-227 s on the workstation for the production corpus, longer on a Celeron,
# and /health is honestly `degraded, store_opening' throughout. A shorter start
# period lets an orchestrator kill a healthy open and loop it forever.
HEALTHCHECK --interval=30s --timeout=5s --start-period=900s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MCL_HEALTH_PORT}/health" || exit 1

CMD ["/app/bin/mcl_rag", "foreground"]
