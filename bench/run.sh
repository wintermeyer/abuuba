#!/usr/bin/env bash
# The whole benchmark, one command.
#
#   bench/run.sh [small|medium|large]
#
# Brings up Mastodon and abuuba side by side, seeds both with the same generated
# dataset, warms them, measures, tears everything down and writes a Markdown
# report. Needs Docker and nothing else.
#
# Every stage prints what it is doing, because a benchmark that goes quiet for
# twenty minutes is one people kill.
set -euo pipefail

# Numbers are parsed and printed in the C locale, always. On a machine whose
# locale uses a comma for the decimal point, awk reads "0.000312" as 0 and
# prints "0,000" — which is both the wrong number and invalid JSON, and it
# happens silently on every machine outside the English-speaking world.
export LC_ALL=C

profile="small"
only="both"
keep="no"
startup_only="no"

while [ $# -gt 0 ]; do
  case "$1" in
    # One side only. The comparison needs both, but iterating an abuuba change
    # does not, and waiting twenty minutes for Mastodon's queue to drain to
    # learn what abuuba did is the wrong loop to work in.
    --only) only="$2"; shift 2 ;;
    --keep) keep="yes"; shift ;;
    # Cold start alone, on a migrated but unseeded database. Boot time is code
    # loading and a supervision tree coming up, not a function of row count,
    # so there is nothing for twenty-five minutes of seeding to tell us about
    # it. Five minutes against twenty-five is the difference between measuring
    # this and not bothering.
    --startup-only) startup_only="yes"; shift ;;
    small | medium | large | huge) profile="$1"; shift ;;
    # A size is a follower count too, so a curve through 5000, 50000 and
    # 100000 needs no name invented for each point.
    *[!0-9]*) 
      echo "Usage: run.sh [<followers>|small|medium|large|huge] [--only abuuba|mastodon] [--keep] [--startup-only]" >&2
      exit 1
      ;;
    *) profile="$1"; shift ;;
    *)
  esac
done

case "$only" in
  both | abuuba | mastodon) ;;
  *)
    echo "--only takes abuuba or mastodon, not $only." >&2
    exit 1
    ;;
esac

with_abuuba() { [ "$only" != "mastodon" ]; }
with_mastodon() { [ "$only" != "abuuba" ]; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The repository root, whatever directory this was started from. The report is
# rendered by `mix abuuba.bench`, which resolves its paths against the working
# directory and refuses to run anywhere else.
cd "$here/.."
results="$here/results"
raw="$results/$profile"

# Published host ports. Overridable because a machine that already has
# something on 3000 or 4000 otherwise fails partway through the run, with a
# container that cannot bind rather than an error anybody can act on.
abuuba_port="${BENCH_ABUUBA_PORT:-4000}"
mastodon_port="${BENCH_MASTODON_PORT:-3000}"
export BENCH_ABUUBA_PORT="$abuuba_port"
export BENCH_MASTODON_PORT="$mastodon_port"
export BENCH_MASTODON_STREAMING_PORT="${BENCH_MASTODON_STREAMING_PORT:-4001}"

abuuba_url="http://localhost:$abuuba_port"
mastodon_url="http://localhost:$mastodon_port"

port_free() {
  ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "This needs $1 and cannot find it." >&2
    exit 1
  }
}

say "Checking what is here"
require docker
require curl
# The ids are pulled out with a JSON parser rather than a regular expression,
# and that is not fastidiousness. `grep -o '"id":"[0-9]*"' | head -1` returns
# whichever id the server happened to serialise first: Mastodon puts the
# status id at the top of the object, abuuba nests `account` above it, so the
# same line took the status id from one server and the *author's account id*
# from the other. That account id then appears in every entry of the home
# timeline, so the fan-out probe matched on the first poll and reported abuuba
# delivering to a thousand followers in about a millisecond.
require jq
docker compose version >/dev/null 2>&1 || {
  echo "This needs Docker Compose v2 (docker compose, not docker-compose)." >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "The Docker daemon is not reachable. On Linux you may need to be in the docker group." >&2
  exit 1
}

mkdir -p "$raw"

# Posts through the API both projects publish, and prints the id.
#
# Both spellings of the text are sent. Mastodon's parameter is `status`; abuuba
# reads `text` and ignores `status`, which is a compatibility bug on abuuba's
# side rather than a benchmark decision — but sending both is what lets one
# script drive both servers, and Rails ignores the parameter it was not
# expecting. See the report: a stock Mastodon client posting `status=` gets a
# 422 from abuuba today.
post_to() {
  local body="Benchmark fan-out probe $(date +%s%N)"
  curl -s -X POST "$1/api/v1/statuses" \
    -H "X-Forwarded-Proto: https" \
    -H "Authorization: Bearer $2" \
    --data-urlencode "status=$body" \
    --data-urlencode "text=$body" \
    --data-urlencode "visibility=public" |
    jq -r '.id // empty'
}

# Exits 0 once that post is in the last follower's own home timeline, read with
# that follower's own token. Asking the subject would answer instantly and
# measure nothing: an author sees their own post the moment it is written.
# Matched against the entries' own top-level ids, not against the whole
# response body: an author's account id occurs in every entry, so a substring
# search answers "yes" before the post has gone anywhere.
#
# Exit 3 on 429 so the caller can tell "the server would not answer" from "the
# post is not there yet". Both look like an absent post in the body.
seen_by() {
  local response code body
  response="$(curl -s -w '\n%{http_code}' "$1/api/v1/timelines/home?limit=40" \
    -H "X-Forwarded-Proto: https" -H "Authorization: Bearer $2")"
  code="$(printf '%s' "$response" | tail -1)"
  body="$(printf '%s' "$response" | sed '$d')"

  [ "$code" = "429" ] && return 3
  [ "$code" = "200" ] || return 1

  printf '%s' "$body" | jq -e --arg id "$3" 'any(.[]?; .id == $id)' >/dev/null
}

export -f post_to seen_by

compose_abuuba() { docker compose -f "$here/compose/abuuba.yml" "$@"; }
compose_mastodon() { docker compose -f "$here/compose/mastodon.yml" "$@"; }

cleanup() {
  [ "$keep" = "yes" ] && {
    say "Left running (--keep)"
    return
  }

  say "Tearing down"
  compose_abuuba down -v --remove-orphans >/dev/null 2>&1 || true
  compose_mastodon down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

say "Clearing anything left from a previous run"
compose_abuuba down -v --remove-orphans >/dev/null 2>&1 || true
compose_mastodon down -v --remove-orphans >/dev/null 2>&1 || true

# Checked here rather than discovered twenty minutes in, when a container fails
# to bind and the run dies with half its measurements taken.
require_free_port() {
  port_free "$1" || {
    echo "Port $1 is already in use by something else on this machine." >&2
    echo "Set $2 to a free port and run this again." >&2
    exit 1
  }
}

with_abuuba && require_free_port "$abuuba_port" BENCH_ABUUBA_PORT
with_mastodon && require_free_port "$mastodon_port" BENCH_MASTODON_PORT
with_mastodon && require_free_port "$BENCH_MASTODON_STREAMING_PORT" BENCH_MASTODON_STREAMING_PORT

if with_abuuba; then
  say "Starting abuuba"
  # One at a time. Building two images and booting two databases at once on a
  # laptop makes the first measurement a measurement of the build.
  compose_abuuba up -d --build --wait
fi

if with_mastodon; then
  say "Starting Mastodon"
  # Staged, because Mastodon's web process refuses to boot against a database
  # that has no schema: `up --wait` on the whole file waits for a health check
  # that cannot pass until migrations it is blocking have run. Database and
  # Redis first, then the schema, then the three application containers.
  compose_mastodon up -d --wait db redis
  compose_mastodon run --rm --no-deps -T web bin/rails db:prepare >"$raw/migrate-mastodon.txt" 2>&1
  compose_mastodon up -d --wait web sidekiq streaming
fi

say "Recording the Postgres both sides were given"
# Both stacks are given the same image, so either one answers the question.
if with_abuuba; then
  compose_abuuba exec -T db postgres --version
else
  compose_mastodon exec -T db postgres --version
fi | awk '{print $NF}' >"$raw/postgres-version.txt"

# Before the seed, because the seed is the expensive part and cold start does
# not need it. Everything below this point is skipped when it is all you want.
if [ "$startup_only" = "yes" ]; then
  say "Measuring how long each stack takes to answer again after a restart"
  with_abuuba && "$here/measure/startup.sh" "abuuba startup" \
    "$here/compose/abuuba.yml" "abuuba" \
    "$abuuba_url/health" >"$raw/startup-abuuba.json"
  with_mastodon &&
    "$here/measure/startup.sh" "mastodon startup" \
      "$here/compose/mastodon.yml" "web sidekiq streaming" \
      "$mastodon_url/health" >"$raw/startup-mastodon.json"

  with_abuuba && cat "$raw/startup-abuuba.json"
  with_mastodon && cat "$raw/startup-mastodon.json"
  say "Done: $raw"
  exit 0
fi

say "Seeding both with the same data ($profile)"
# `rpc`, not `eval`: the seeder needs the Repo, Oban and PubSub, and `eval`
# starts a bare node with none of them. The profile travels in the environment
# of the node the code actually runs on, because `rpc` does not forward argv.
abuuba_token=""
mastodon_token=""
abuuba_follower_token=""
mastodon_follower_token=""
expected_tokens=""

if with_abuuba; then
  compose_abuuba exec -T abuuba /app/bin/abuuba rpc \
    "System.put_env(\"BENCH_PROFILE\", \"$profile\"); Code.eval_file(\"/app/bench/seed/abuuba.exs\")" \
    >"$raw/seed-abuuba.txt"

  abuuba_token="$(grep '^TOKEN ' "$raw/seed-abuuba.txt" | awk '{print $2}')"
  abuuba_follower_token="$(grep '^FOLLOWER_TOKEN ' "$raw/seed-abuuba.txt" | awk '{print $2}')"
  expected_tokens="$expected_tokens abuuba_token abuuba_follower_token"
fi

if with_mastodon; then
  compose_mastodon exec -T web bin/rails runner /bench/seed/mastodon.rb "$profile" \
    >"$raw/seed-mastodon.txt"

  mastodon_token="$(grep '^TOKEN ' "$raw/seed-mastodon.txt" | awk '{print $2}')"
  mastodon_follower_token="$(grep '^FOLLOWER_TOKEN ' "$raw/seed-mastodon.txt" | awk '{print $2}')"
  expected_tokens="$expected_tokens mastodon_token mastodon_follower_token"
fi

for name in $expected_tokens; do
  [ -n "${!name}" ] || {
    echo "Seeding did not produce $name; see $raw/seed-*.txt." >&2
    exit 1
  }
done

say "Checking both servers answer the questions before timing them"
# A positive control, and it runs here rather than after the drain on purpose:
# waiting for a couple of hundred thousand queued jobs to clear and only then
# discovering that one server answers 301 to every request is twenty minutes
# spent to learn something visible in six requests.
#
# Every measurement below is a latency, and a latency is just as happily
# produced by an error page as by the thing being measured — the authenticated
# reads were once timed against a 422 on one side and a real timeline on the
# other. If a probe does not come back 200, the run stops rather than
# publishing a number for it.
probe() {
  local label="$1" url="$2" token="${3:-}" code body

  if [ -n "$token" ]; then
    body="$(curl -s -w '\n%{http_code}' -H "X-Forwarded-Proto: https" \
      -H "Authorization: Bearer $token" "$url")"
  else
    body="$(curl -s -w '\n%{http_code}' -H "X-Forwarded-Proto: https" "$url")"
  fi

  code="$(printf '%s' "$body" | tail -1)"
  printf '%s %s %s\n' "$label" "$code" "$(printf '%s' "$body" | head -c 120 | tr -d '\n')" \
    >>"$raw/probes.txt"

  [ "$code" = "200" ] || {
    echo "$label answered $code, not 200. See $raw/probes.txt." >&2
    exit 1
  }
}

: >"$raw/probes.txt"
if with_abuuba; then
  probe "abuuba public" "$abuuba_url/api/v1/timelines/public?limit=20"
  probe "abuuba home" "$abuuba_url/api/v1/timelines/home?limit=20" "$abuuba_token"
  probe "abuuba profile" "$abuuba_url/@benchsubject"
fi

if with_mastodon; then
  probe "mastodon public" "$mastodon_url/api/v1/timelines/public?limit=20"
  probe "mastodon home" "$mastodon_url/api/v1/timelines/home?limit=20" "$mastodon_token"
  probe "mastodon profile" "$mastodon_url/@benchsubject"
fi

say "Waiting for the seed fan-out to finish on both sides"
# Seeding writes 200 posts to every follower's feed on both sides, and both
# servers do part of that in the background. Measuring before the backlog has
# drained times the queue rather than the server, and the side that queues more
# work looks slower for the length of its own seeding.
abuuba_pending() {
  compose_abuuba exec -T db psql -U abuuba -d abuuba_bench -tAc \
    "select count(*) from oban_jobs where state in ('available','scheduled','executing','retryable')" \
    2>/dev/null | tr -d '[:space:]'
}

mastodon_pending() {
  compose_mastodon exec -T redis sh -c '
    total=0
    for q in $(redis-cli --raw keys "queue:*"); do
      case "$q" in *_scheduled|*_retry) continue ;; esac
      n=$(redis-cli --raw llen "$q" 2>/dev/null || echo 0)
      total=$((total + n))
    done
    for w in $(redis-cli --raw keys "*:work"); do
      n=$(redis-cli --raw hlen "$w" 2>/dev/null || echo 0)
      total=$((total + n))
    done
    n=$(redis-cli --raw zcard schedule 2>/dev/null || echo 0); total=$((total + n))
    n=$(redis-cli --raw zcard retry 2>/dev/null || echo 0); total=$((total + n))
    echo $total
  ' 2>/dev/null | tr -d '[:space:]'
}

# Quiet for three consecutive samples, not one: a queue can read empty for an
# instant between a job finishing and the jobs it enqueued becoming visible.
wait_quiet() {
  # 2400s suits a thousand followers and a ten thousand. It does not suit a
  # hundred thousand: two million feed rows at the ~180 jobs a second measured
  # live on 2026-08-28 is over three hours, and that rate falls as the feed
  # table grows. The wait would expire and everything below would be timed
  # against a queue still draining. Raise it for the big profiles rather than
  # publishing a number measured on top of a backlog.
  local label="$1" probe="$2" quiet=0 pending
  local limit="${BENCH_DRAIN_TIMEOUT:-2400}"
  local deadline=$((SECONDS + limit))

  while [ "$SECONDS" -lt "$deadline" ]; do
    pending="$($probe)"
    [ -n "$pending" ] || pending=0

    if [ "$pending" -eq 0 ]; then
      quiet=$((quiet + 1))
      [ "$quiet" -ge 3 ] && {
        echo "    $label: drained"
        return 0
      }
    else
      quiet=0
      echo "    $label: $pending queued"
    fi

    sleep 2
  done

  # Reported, not swallowed. A run measured on top of a backlog is still a
  # result, but the reader has to be told which one it was.
  echo "    $label: STILL BUSY after ${limit}s — measurements below include a backlog"
  echo "$label did not drain within ${limit}s" >>"$raw/warnings.txt"
}

with_abuuba && wait_quiet abuuba abuuba_pending
with_mastodon && wait_quiet mastodon mastodon_pending

say "Settling both databases before anything is timed"
# Deterministically, not by luck. Seeding writes hundreds of thousands of rows
# and leaves Postgres with unvacuumed pages, stale planner statistics and an
# unfinished checkpoint; how much of that has settled when the measurements
# start depends on how long the drain above happened to take. That dependence
# once manufactured a phantom regression: a bug stranded one unrunnable job on
# the old side, its drain-wait ran the full 2400s, and its 40 rested minutes
# of autovacuum measured 0.5ms faster than the fixed code whose queue drained
# in seconds -- a fifth of the whole request. VACUUM ANALYZE plus CHECKPOINT
# puts both sides in the same settled state in seconds, whatever the queues
# did.
if with_abuuba; then
  compose_abuuba exec -T db psql -U abuuba -d abuuba_bench -q -c "VACUUM (ANALYZE)" -c "CHECKPOINT"
fi

if with_mastodon; then
  compose_mastodon exec -T db psql -U mastodon -d mastodon_bench -q -c "VACUUM (ANALYZE)" -c "CHECKPOINT"
fi

say "Measuring what each stack costs at idle"
# Before the load, not after: "idle" means idle. The same measurement is taken
# again under load further down.
with_abuuba && "$here/measure/resources.sh" abuuba-bench "abuuba" >"$raw/resources-idle-abuuba.json"
with_mastodon &&
  "$here/measure/resources.sh" mastodon-bench "mastodon" >"$raw/resources-idle-mastodon.json"

# Every count below is chosen to fit inside the API budget both servers ship
# with, because neither side is retuned for the benchmark. The tightest bucket
# in play is 300 requests per five minutes: per IP for anonymous reads on both
# servers, and additionally per token on abuuba, which Mastodon does not have.
# Exceeding it does not produce a slower number, it produces a 429 — and a 429
# is served much faster than a timeline, so an over-budget run reports a
# spectacular latency for a server that answered nothing.
requests=150
warmups=10

say "Warming up"
# Both sides get the same warm-up: a cold run measures module loading, an empty
# query plan cache and a JIT that has not seen the code yet, on whichever side
# happens to be measured first.
warm() { curl -s -o /dev/null -H "X-Forwarded-Proto: https" "$@" || true; }

for _ in $(seq "$warmups"); do
  if with_abuuba; then
    warm "$abuuba_url/api/v1/timelines/public?limit=20"
    warm -H "Authorization: Bearer $abuuba_token" "$abuuba_url/api/v1/timelines/home?limit=20"
    warm "$abuuba_url/@benchsubject"
  fi

  if with_mastodon; then
    warm "$mastodon_url/api/v1/timelines/public?limit=20"
    warm -H "Authorization: Bearer $mastodon_token" "$mastodon_url/api/v1/timelines/home?limit=20"
    warm "$mastodon_url/@benchsubject"
  fi
done

say "Measuring public timeline reads"
with_abuuba && "$here/measure/http.sh" "abuuba public timeline" \
  "$abuuba_url/api/v1/timelines/public?limit=20" "$requests" 4 >"$raw/public-abuuba.json"
with_mastodon && "$here/measure/http.sh" "mastodon public timeline" \
  "$mastodon_url/api/v1/timelines/public?limit=20" "$requests" 4 >"$raw/public-mastodon.json"

say "Measuring home timeline reads, and what the stack costs while serving them"
# The read every client makes on every refresh, and the one both projects have
# built their storage around. Authenticated with a header: abuuba's REST API does
# not read `?access_token=`, so the query-parameter form measured a refusal.
#
# The resource sample is taken during this measurement rather than from a
# second, separate load phase — which would double the number of authenticated
# requests and put the run over the budget the servers ship with.
cpu_cost() {
  local label="$1" before="$2" after="$3" count="$4"

  awk -v b="$before" -v a="$after" -v n="$count" -v l="$label" 'BEGIN {
    printf "{\"label\":\"%s\",\"cpu_ms_total\":%.1f,\"requests\":%d,\"cpu_ms_per_request\":%.3f}\n",
      l, a - b, n, (a - b) / n
  }'
}

# Timed with the stack's own cumulative CPU either side of the load, because a
# `docker stats` percentage needs a load that outlasts its sampling window and
# abuuba answers this one in about a third of a second.
measure_home() {
  local side="$1" project="$2" url="$3" token="$4" before after

  before="$("$here/measure/cputime.sh" "$project")"
  "$here/measure/http.sh" "$side home timeline" \
    "$url/api/v1/timelines/home?limit=20" "$requests" 4 "$token" \
    >"$raw/home-$side.json"
  after="$("$here/measure/cputime.sh" "$project")"

  cpu_cost "$side" "$before" "$after" "$requests" >"$raw/cpu-$side.json"
}

with_abuuba && measure_home abuuba abuuba-bench "$abuuba_url" "$abuuba_token"
with_mastodon && measure_home mastodon mastodon-bench "$mastodon_url" "$mastodon_token"

say "Measuring memory while each stack holds the seeded data"
with_abuuba && "$here/measure/resources.sh" abuuba-bench "abuuba" >"$raw/resources-loaded-abuuba.json"
with_mastodon &&
  "$here/measure/resources.sh" mastodon-bench "mastodon" >"$raw/resources-loaded-mastodon.json"

say "Measuring fan-out to every follower"
# Not how long the API call takes — both servers answer that in milliseconds by
# queueing the work — but how long until the last follower can actually see the
# post, which is what somebody refreshing their feed experiences.
# Polled with the last follower's own token, which has a budget of its own and
# is not the one the home-timeline measurement just spent.
with_abuuba && "$here/measure/fanout.sh" "abuuba fan-out" \
  "post_to '$abuuba_url' '$abuuba_token'" \
  "seen_by '$abuuba_url' '$abuuba_follower_token'" 300 0.2 >"$raw/fanout-abuuba.json"

with_mastodon && "$here/measure/fanout.sh" "mastodon fan-out" \
  "post_to '$mastodon_url' '$mastodon_token'" \
  "seen_by '$mastodon_url' '$mastodon_follower_token'" 300 0.2 \
  >"$raw/fanout-mastodon.json"

say "Measuring a logged-out profile page"
# Not an API route on either side, so this one is not under the API budget.
with_abuuba && "$here/measure/http.sh" "abuuba profile page" "$abuuba_url/@benchsubject" 100 4 \
  >"$raw/page-abuuba.json"
with_mastodon &&
  "$here/measure/http.sh" "mastodon profile page" "$mastodon_url/@benchsubject" 100 4 \
    >"$raw/page-mastodon.json"

# Last, because it restarts the application tier and every measurement above
# wants a warm one. Restarting the database is deliberately left out: that cost
# is the same on both sides and would only add a constant to each.
say "Measuring how long each stack takes to answer again after a restart"
with_abuuba && "$here/measure/startup.sh" "abuuba startup" \
  "$here/compose/abuuba.yml" "abuuba" \
  "$abuuba_url/health" >"$raw/startup-abuuba.json"
with_mastodon &&
  "$here/measure/startup.sh" "mastodon startup" \
    "$here/compose/mastodon.yml" "web sidekiq streaming" \
    "$mastodon_url/health" >"$raw/startup-mastodon.json"

# The report is a comparison, so there is nothing to render from one side. The
# raw JSON is still there, which is what a one-sided run was for.
if [ "$only" != "both" ]; then
  say "Done: $raw (one side only, no report rendered)"
  exit 0
fi

say "Writing the report"
mix abuuba.bench --report-only --profile "$profile" --raw "$raw" --out "$results/$profile.md"

say "Done: $results/$profile.md"
