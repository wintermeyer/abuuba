#!/usr/bin/env bash
# How long a post takes to reach every follower's timeline, as JSON.
#
# The number people mean by "fan-out latency" is not how long the API call
# takes — both servers answer that in milliseconds by queueing the work. It is
# how long until the post is actually in the last follower's home timeline,
# which is what somebody refreshing their feed experiences.
#
# So this posts, then polls the last follower's home timeline until the post
# appears, and reports the wall-clock difference. Polling rather than watching
# the queue, because the queue is an implementation detail and the timeline is
# the promise.
#
# Usage: fanout.sh <label> <post-command> <check-command> <timeout-seconds> [poll-seconds]
#   post-command   prints the id of the post it made
#   check-command  takes that id, exits 0 once the last follower can see it,
#                  and exits 3 if the server refused to answer (HTTP 429)
#
# The exit-3 case matters more than it looks. Polling a timeline ten times a
# second exhausts the API budget both servers ship with, and a throttled poll
# comes back without the post in it — which is indistinguishable from the post
# not having arrived. Read that way, a server that delivered in one millisecond
# is reported as never having delivered at all. A refusal is therefore a
# separate outcome and stops the measurement, rather than being counted as
# evidence about fan-out.
set -euo pipefail

# Numbers are parsed and printed in the C locale, always. On a machine whose
# locale uses a comma for the decimal point, awk reads "0.000312" as 0 and
# prints "0,000" — which is both the wrong number and invalid JSON, and it
# happens silently on every machine outside the English-speaking world.
export LC_ALL=C

label="$1"
post_command="$2"
check_command="$3"
timeout_seconds="${4:-300}"
# Slow enough to stay inside the budget both servers ship with over the length
# of a probe, fast enough that the number still means something.
# 0.02 s, not the 0.2 it used to be. A cycle costs the sleep plus an HTTP round
# trip, so 0.2 measured out at ~250 ms per poll, and the fast side finished in
# two or three of them: 755.9 ms at ten thousand followers carried ~250 ms of
# uncertainty, a third of the figure, while the slow side took 202 polls and
# was resolved to half a percent. A row whose two halves are measured to
# wildly different precision reads as though they are not.
#
# Do not go below this without making the check cheaper than the thing being
# timed. At 0.02 s the prober already makes about fifty requests a second
# against a server whose latency is what the run exists to measure, so the poll
# stops being free and starts being load. That is the same trap as the API
# budget note above, one layer down: there, polling too fast tripped the rate
# limiter and produced an error the measurement could not tell from slowness;
# here it would produce real slowness of the prober's own making.
poll_seconds="${5:-0.02}"

started="$(date +%s.%N)"

post_id="$(eval "$post_command")"

if [ -z "$post_id" ]; then
  printf '{"label":"%s","ms":null,"note":"the post was not made"}\n' "$label"
  exit 0
fi

# awk rather than bc: bc is not installed by default on a Debian container
# host or a stock macOS, and a benchmark that needs a package installed before
# it runs is one people do not run. awk is in every base system and is already
# what the other measurements use.
elapsed_ms() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) * 1000 }'
}

past_deadline() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

deadline="$(awk -v s="$started" -v t="$timeout_seconds" 'BEGIN { printf "%.6f", s + t }')"

polls=0

while true; do
  set +e
  eval "$check_command $post_id" >/dev/null 2>&1
  outcome=$?
  set -e
  polls=$((polls + 1))

  if [ "$outcome" -eq 0 ]; then
    finished="$(date +%s.%N)"
    printf '{"label":"%s","ms":%s,"polls":%s,"post_id":"%s"}\n' \
      "$label" "$(elapsed_ms "$started" "$finished")" "$polls" "$post_id"
    exit 0
  fi

  if [ "$outcome" -eq 3 ]; then
    printf '{"label":"%s","ms":null,"polls":%s,"post_id":"%s","note":"the server throttled the poll (HTTP 429), so this says nothing about fan-out"}\n' \
      "$label" "$polls" "$post_id"
    exit 0
  fi

  now="$(date +%s.%N)"

  if past_deadline "$now" "$deadline"; then
    # A timeout is a result, not an error: "it had not arrived after five
    # minutes" is exactly the sort of thing this benchmark exists to find.
    printf '{"label":"%s","ms":null,"polls":%s,"note":"did not arrive within %ss"}\n' \
      "$label" "$polls" "$timeout_seconds"
    exit 0
  fi

  sleep "$poll_seconds"
done
