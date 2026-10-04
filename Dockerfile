# Build the release, then ship it on a base image with no Elixir and no Node.
# The database is Postgres and runs in its own container, so this image holds
# only the app; uploads and generated secrets live on a volume.
#
# This image is not meant to be run on its own — it needs a Postgres to talk
# to. `docker compose up -d` brings up both and is the documented way (see
# compose.yaml). To run it by hand you have to supply DATABASE_URL:
#
#   docker build -t slipdock .
#   docker run -p 4000:4000 -v slipdock-data:/data \
#     -e DATABASE_URL=postgres://user:pass@host:5432/slipdock slipdock

# Elixir 1.20: config/runtime.exs uses the `E` regex modifier, which older
# versions cannot compile — the release would build and then die on boot.
ARG ELIXIR_IMAGE="hexpm/elixir:1.20.4-erlang-27.3.4.18-debian-bookworm-20260918-slim"
# Must be the same Debian release as the builder: the release carries Erlang's
# own shared libraries and expects that one's libc and OpenSSL.
ARG RUNNER_IMAGE="debian:bookworm-20260918-slim"

# ── build ───────────────────────────────────────────────────────────────────
FROM ${ELIXIR_IMAGE} AS builder

# git for a dependency fetched from git; build-essential for the NIFs (mdex
# ships a precompiled Rust NIF but wants a toolchain if it has to fall back).
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"
# Build with the https redirect off: see config/prod.exs. Pass
# --build-arg SLIPDOCK_FORCE_SSL=true if the app itself terminates TLS.
ARG SLIPDOCK_FORCE_SSL="false"
ENV SLIPDOCK_FORCE_SSL=${SLIPDOCK_FORCE_SSL}

# Dependencies first, so editing application code does not refetch them.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Which commit this image was built from. There is no .git in here to ask, so
# the build has to be told: --build-arg SLIPDOCK_GIT_SHA=$(git rev-parse HEAD).
# Left out, Configuration shows the commit as "unknown" rather than wrong.
# It changes on every commit, so it sits after the dependency layers (which
# would otherwise be rebuilt every time) and before `mix compile`, which is
# where Slipdock.Build reads it.
ARG SLIPDOCK_GIT_SHA=""
ENV SLIPDOCK_GIT_SHA=${SLIPDOCK_GIT_SHA}

COPY priv priv
COPY lib lib
COPY assets assets

# Compile before the assets: LiveView's colocated hooks are generated into
# _build during compilation and the stylesheet imports them, so Tailwind cannot
# resolve them until this has run.
RUN mix compile

# Tailwind and esbuild are downloaded by their own mix tasks — no Node needed.
RUN mix assets.setup
RUN mix assets.deploy

COPY config/runtime.exs config/
RUN mix release

# ── run ─────────────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

# libstdc++ and libncurses for the Erlang runtime, locales so the app's UTF-8
# is honoured, curl for the health check, util-linux for setpriv (the
# entrypoint drops privileges with it after fixing the volume), netcat so the
# entrypoint can wait for Postgres to start accepting connections.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates curl util-linux \
       netcat-openbsd \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Everything that must survive a new image lives under /data: uploaded files,
# each person's OpenRouter key, and the secret the entrypoint generates on
# first run. The database is Postgres' own volume, not this one.
ENV MIX_ENV="prod" \
    PHX_SERVER="true" \
    PORT="4000" \
    SLIPDOCK_UPLOADS_DIR="/data/uploads" \
    SLIPDOCK_AI_KEY_FILE="/data/ai_keys.json" \
    SLIPDOCK_DATA_DIR="/data"

WORKDIR /app
RUN groupadd -r slipdock && useradd -r -g slipdock -d /app slipdock

COPY --from=builder --chown=slipdock:slipdock /app/_build/prod/rel/slipdock ./
COPY --chown=slipdock:slipdock deploy/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME /data
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/login" > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["start"]
