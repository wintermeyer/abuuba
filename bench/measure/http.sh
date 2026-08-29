#!/usr/bin/env bash
# Times HTTP requests and prints the percentiles, as JSON.
#
# Deliberately curl and sort rather than a load generator: the numbers this
# produces are single-request latencies under a stated concurrency, and a tool
# that also does connection pooling, keep-alive and its own retries would be
# measuring itself as much as the server.
#
# Usage: http.sh <label> <url> <requests> [concurrency] [bearer-token]
#
# The token, when given, is sent as an `Authorization: Bearer` header rather
# than an `?access_token=` query parameter. Mastodon's Doorkeeper accepts both;
# abuuba accepts only the header, so the query-parameter form silently measured
# the latency of a 422 on one side and a real timeline on the other — which
# looks like abuuba being fast rather than abuuba not answering the question.
set -euo pipefail

# Numbers are parsed and printed in the C locale, always. On a machine whose
# locale uses a comma for the decimal point, awk reads "0.000312" as 0 and
# prints "0,000" — which is both the wrong number and invalid JSON, and it
# happens silently on every machine outside the English-speaking world.
export LC_ALL=C

label="$1"
url="$2"
requests="${3:-200}"
concurrency="${4:-1}"
token="${5:-}"

raw="$(mktemp)"
samples="$(mktemp)"
trap 'rm -f "$raw" "$samples"' EXIT

time_one() {
  # Total time and the status code, so that a run which measured nothing but
  # error pages says so instead of reporting an impressively low latency.
  # `%{time_total}` is seconds with microsecond resolution.
  #
  # `X-Forwarded-Proto: https` because Mastodon sets `config.force_ssl = true`
  # in production with no environment variable to turn it off, and answers
  # plain HTTP with a 301 to the https URL. A 301 is served in well under a
  # millisecond, so timing it would have handed Mastodon a spectacular win for
  # refusing to do the work. The header is what the TLS-terminating proxy every
  # real Mastodon runs behind puts there, and it goes to both servers so the
  # request is the same request on each side.
  if [ -n "${BENCH_TOKEN:-}" ]; then
    curl -s -o /dev/null -w '%{time_total} %{http_code}\n' --max-time 30 \
      -H "X-Forwarded-Proto: https" -H "Authorization: Bearer $BENCH_TOKEN" "$1"
  else
    curl -s -o /dev/null -w '%{time_total} %{http_code}\n' --max-time 30 \
      -H "X-Forwarded-Proto: https" "$1"
  fi | awk '{ printf "%.3f %s\n", $1 * 1000, $2 }'
}

export -f time_one
export BENCH_URL="$url"
export BENCH_TOKEN="$token"

if [ "$concurrency" -gt 1 ]; then
  # No `-I`: its placeholder is replaced everywhere it appears, including
  # inside the name of the function being called, which turns `time_one` into
  # `time7one` and fails once per request.
  seq "$requests" | xargs -P "$concurrency" -n 1 bash -c 'time_one "$BENCH_URL"' _ >"$raw"
else
  for _ in $(seq "$requests"); do time_one "$url" >>"$raw"; done
fi

# Only successful responses are timed. A 422 is served far faster than the
# timeline it refused to render, so mixing the two in one percentile is how a
# broken measurement reads as a fast one.
awk '$2 ~ /^2/ { print $1 }' "$raw" >"$samples"

ok="$(wc -l <"$samples" | tr -d ' ')"
failed="$(awk '$2 !~ /^2/' "$raw" | wc -l | tr -d ' ')"
codes="$(awk '{ print $2 }' "$raw" | sort | uniq -c | sort -rn |
  awk '{ printf "%s%s:%s", (NR > 1 ? "," : ""), $2, $1 }')"

percentile() {
  local p="$1"
  sort -n "$samples" | awk -v p="$p" '
    { values[NR] = $1 }
    END {
      if (NR == 0) { print "null"; exit }
      index_at = int((p / 100) * NR + 0.5)
      if (index_at < 1) index_at = 1
      if (index_at > NR) index_at = NR
      printf "%.3f", values[index_at]
    }'
}

printf '{"label":"%s","requests":%s,"concurrency":%s,"ok":%s,"failed":%s,"codes":"%s","p50":%s,"p95":%s,"p99":%s}\n' \
  "$label" "$requests" "$concurrency" "$ok" "$failed" "$codes" \
  "$(percentile 50)" "$(percentile 95)" "$(percentile 99)"
