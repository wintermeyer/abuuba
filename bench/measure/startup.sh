#!/usr/bin/env bash
#
# How long a stack takes to answer after it is stopped and started again.
#
# This is the number an operator feels on every deploy, and it is where "one
# BEAM application" against "a Rails app, a job runner and a streaming sidecar"
# shows up as wall-clock time rather than as memory.
#
# ## Restart, not cold start
#
# The image is already pulled, the container already created, the page cache
# already warm. A real first deploy is slower than this on both sides. The
# measurement is symmetric so the comparison holds, but what it measures is
# restart to first response, and the report says that rather than claiming more.
#
# ## What is restarted, and why the asymmetry favours Mastodon
#
# The application tier on both sides, never the database: starting Postgres
# costs the same for both and would only add a constant to each.
#
# abuuba's tier is one container and Mastodon's is three, and the objection to
# that is "you simply bundled more into one process". The supervision order is
# the answer. `AbuubaWeb.Endpoint` is the last child in `Abuuba.Application`,
# and children start in order, so nothing can reach /health until Telemetry,
# Vault, Repo, Oban, RateLimit, CircuitBreaker, DNSCluster, PubSub, Cache and
# Timelines.Broadcast are already up. abuuba's clock therefore stops only once
# its job runner is running.
#
# Mastodon's stops earlier by construction. Its HealthController subclasses
# ActionController::Base rather than ApplicationController, so it skips the
# application filters and answers as early as Rails can serve anything at all,
# with Sidekiq still booting in a container beside it.
#
# Two things push the other way and are stated rather than hidden. abuuba's
# `ensure_instance_actor()` runs after the supervisor returns, so that database
# write is in flight while the endpoint is already accepting connections, and it
# is excluded from the number. And the clock starts before `docker compose
# start`, so Docker's own per-container start work is inside the measurement and
# Mastodon pays it for three containers rather than one. They roughly cancel,
# and neither is near the size of the effect being measured.
#
# ## Why it polls HTTP rather than reading the health check
#
# Both compose files probe every three seconds, so a health-check-gated
# measurement is quantised to three seconds, and abuuba's answer is smaller than
# that quantum. Polling directly at 100 ms measures the thing rather than the
# probe interval.
#
# Usage: startup.sh <label> <compose-file> "<services>" <url> [timeout] [poll]

set -euo pipefail

# As in every other measurement here: awk's printf honours LC_NUMERIC, and a
# comma decimal separator turns this script's output into JSON nothing can
# parse. run.sh exports this too, but a script that is only correct when its
# caller remembers is one that breaks the first time somebody runs it directly.
export LC_ALL=C

label="$1"
compose_file="$2"
services="$3"
url="$4"
timeout_seconds="${5:-180}"
poll_seconds="${6:-0.1}"

# The caller redirects our stdout into a file, so that file exists from the
# moment this script starts. Dying without printing would leave a zero-byte
# JSON that a reader cannot tell apart from a measurement nobody ran. Every
# exit from here on says something.
give_up() {
  printf '{"label":"%s","ms":null,"note":"%s"}\n' "$label" "$1"
  exit 0
}
trap 'give_up "the measurement failed"' ERR

# awk rather than bc, for the reason `fanout.sh` already wrote down: bc is not
# installed by default on a Debian container host or a stock macOS, and a
# benchmark that needs a package installed before it runs is one people do not
# run. These two helpers are that file's, unchanged.
elapsed_ms() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) * 1000 }'
}

past_deadline() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

# Stop first and let the teardown finish, then start the clock, then start the
# tier. `restart` would not do: it returns once the containers are running
# rather than serving, so any boot that happened inside it would be invisible
# to a clock started afterwards, and invisible by different amounts on a
# one-container stack and a three-container one.
#
# shellcheck disable=SC2086 -- $services is a deliberate word split.
docker compose -f "$compose_file" stop $services >/dev/null 2>&1 ||
  give_up "the stack would not stop"

started="$(date +%s.%N)"
deadline="$(awk -v s="$started" -v t="$timeout_seconds" 'BEGIN { printf "%.6f", s + t }')"

# shellcheck disable=SC2086
docker compose -f "$compose_file" start $services >/dev/null 2>&1 ||
  give_up "the stack would not start"

poll_ms="$(awk -v p="$poll_seconds" 'BEGIN { printf "%d", p * 1000 }')"

while :; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"

  if [ "$code" = "200" ]; then
    printf '{"label":"%s","ms":%s,"poll_ms":%s}\n' \
      "$label" "$(elapsed_ms "$started" "$(date +%s.%N)")" "$poll_ms"
    exit 0
  fi

  if past_deadline "$(date +%s.%N)" "$deadline"; then
    give_up "did not answer within ${timeout_seconds}s"
  fi

  sleep "$poll_seconds"
done
