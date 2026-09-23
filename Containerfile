# mcl-rag
#
# The mesh shared memory: retrieval over a realm-bound corpus, and the deposits agents remember into it
#
# ⚠ THE SHARED MEMORY LIVES ON A VOLUME, /var/lib/mcl-rag: one barrel database
# (documents, attachments, vectors) plus the corpus checkouts. Declared here and
# in the compose file together; the eunit suite holds the two to each other.

# ⚠ THE ROCKSDB PAIR, PINNED BY DIGEST. The store runs on barrel_docdb, whose
# rocksdb binding this repo links against the system librocksdb (the override
# in rebar.config) rather than compiling the copy it bundles.
# macula-ci-otp-rocksdb carries librocksdb 11.1.2, OTP 28.4.3 on an OpenSSL
# with ML-DSA, rebar3, Rust, cmake and the zlib headers; a release built in it
# needs librocksdb.so.11 at run time, which macula-pq-runtime-rocksdb carries.
# Both are Debian trixie, so the release's ERTS and NIFs match the runtime's
# glibc. Their tags move daily; the digests are what build. lint.yml pins the
# same build image, and mcl_rag_service_tests guards all three pins.
FROM ghcr.io/macula-io/macula-ci-otp-rocksdb@sha256:da4ea316b91f4f29efc8036fa9d95a3b1f3efde8b85cb5997780f140e0f2f6d8 AS builder

# ⚠ THE OTP RELEASE, ASSERTED HERE because the image tag names a date, not a
# release. The same check as lint.yml's toolchain step; the service tests read
# this line and compare it with .tool-versions and lint's.
RUN erl -noshell -eval ' \
    Otp = string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])))), \
    Mldsa = lists:member(mldsa87, crypto:supports(public_keys)), \
    io:format("OTP ~s, mldsa87 ~p~n", [Otp, Mldsa]), \
    case {Otp, Mldsa} of \
        {<<"28.4.3">>, true} -> halt(0); \
        _                    -> halt(1) \
    end.'

WORKDIR /build

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/ and the Rust toolchain is not re-run per commit.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps

# THE CORPUS-SYNC NIF IS BUILT HERE, against the runtime's own libc, and never
# copied in. It was once committed as a workstation build, which linked the
# workstation's libraries and would never have loaded on the image, so the
# corpus would silently have stopped syncing. It is built AFTER `COPY apps' so
# a stale local priv/lib cannot overwrite it (.dockerignore keeps it out too).
# The vendored libgit2 links the system zlib, whose headers the image carries.
COPY native ./native
COPY scripts ./scripts
RUN bash scripts/build-corpus-sync-nif.sh

RUN rebar3 as prod release

FROM ghcr.io/macula-io/macula-pq-runtime-rocksdb@sha256:ecb492cff20a84e88b197cf7d2c660ec1a51b26b3742def95f084499c1124c9f
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-rag"
# The runtime image carries everything the release loads: librocksdb.so.11 and
# the codec libraries it links, OpenSSL 3.5, ncurses, libstdc++, libz and
# libgcc_s for the corpus-sync NIF, and curl for the health check below.
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
ENV MCL_RAG_HTTP_PORT=8451
ENV MCL_RAG_HTTP_IP=127.0.0.1
ENV MCL_DATA_DIR=/var/lib/mcl-rag

VOLUME ["/etc/mcl/secrets", "/var/lib/mcl-rag"]

# Health and the loopback API, as registered in macula-fleet PORTS.md.
EXPOSE 8450 8451
# THE START PERIOD OUTLASTS THE STORE OPEN. Opening rebuilds the vector index:
# 190-227 s on the workstation for the production corpus, longer on a Celeron,
# and /health is honestly `degraded, store_opening' throughout. A shorter start
# period lets an orchestrator kill a healthy open and loop it forever.
HEALTHCHECK --interval=30s --timeout=5s --start-period=900s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MCL_HEALTH_PORT}/health" || exit 1

CMD ["/app/bin/mcl_rag", "foreground"]
