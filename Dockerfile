# The production image. One binary and Postgres is the whole deployment.
#
# Two stages: a builder with Elixir and the toolchain, and a runtime with
# neither. The release carries its own ERTS, so the runtime image needs no
# Erlang installed — which is what keeps it small and what keeps a compiler out
# of production.
#
# Multi-arch (amd64 and arm64) is a property of how it is built rather than of
# this file: every base image here is published for both, and nothing below
# hard-codes an architecture. See `.github/workflows/release.yml`.

# The versions in .tool-versions, so the image builds what CI builds.
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.4
# The date matters: hexpm publishes one Debian snapshot per Elixir/OTP pair,
# so the combination is what has to exist rather than the Debian release on its
# own. Not every snapshot is built for both architectures either — the trixie
# one for this pair is arm64 only, which a multi-arch build discovers halfway
# through. CI resolves both tags and both architectures on every pull request,
# because nothing else does until `docker build` runs.
ARG DEBIAN_VERSION=bookworm-20260713-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first and alone, so that editing a source file does not
# re-fetch and re-compile every dependency. This one ordering is most of the
# difference between a ten-second rebuild and a five-minute one.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# The tailwind and esbuild binaries, fetched from GitHub releases. In their
# own layer up here, before the source COPYs, for two reasons. Cached: this
# layer only changes when the lockfile or the pinned versions do, so an
# ordinary push builds without touching github.com at all -- inside
# `assets.deploy` the download re-ran on every build, and one closed socket
# was a red Release run on main. Retried: the first build after a version
# bump still fetches, and a transient refusal deserves a second try before
# it fails a workflow. When all three tries fail, the step that dies is
# named after the download, not after the CSS build that never got to run.
RUN mix assets.setup || (sleep 5 && mix assets.setup) || (sleep 25 && mix assets.setup)

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix compile
RUN mix assets.deploy

# runtime.exs last: it is read when the release *starts*, not when it is built,
# and copying it here rather than above keeps a change to it from invalidating
# the compile cache.
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE}

# libstdc++ and openssl for the ERTS, locales for a UTF-8 default, ca-certificates
# so outbound federation can verify TLS, and ffmpeg because media processing
# shells out to it.
RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates ffmpeg \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Not root. A remote-content processor running as uid 0 is one file-write bug
# away from being somebody else's server.
RUN useradd --create-home --uid 10001 abuuba
RUN chown abuuba /app
USER abuuba:abuuba

COPY --from=builder --chown=abuuba:abuuba /app/_build/prod/rel/abuuba ./

# The upload directory has to exist in the image, owned by the user that will
# write to it. Docker seeds a fresh named volume from whatever is at the mount
# point, ownership included — and creates it root-owned when there is nothing
# there, which the non-root release then cannot write to.
RUN mkdir -p /app/uploads
ENV MEDIA_ROOT=/app/uploads

# The container's own opinion of its health, for `docker compose` and for any
# orchestrator that reads it. Readiness rather than liveness, because the
# question a scheduler is asking is whether to send this container traffic.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
  CMD ["/app/bin/abuuba", "rpc", "if Abuuba.Health.ready?(), do: :ok, else: System.halt(1)"]

ENV PHX_SERVER=true

# No migrations here. They are a separate command on purpose: see the
# zero-downtime section of docs/deploy.md — a container that migrates on start
# migrates once per replica, concurrently, during a rolling deploy.
CMD ["/app/bin/abuuba", "start"]
