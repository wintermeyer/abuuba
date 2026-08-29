#!/usr/bin/env bash
# What a stack costs to have running, as JSON.
#
# Every container in the project, added up. Mastodon's total includes Redis and
# Sidekiq and abuuba's does not, because abuuba does not need them — that is a
# difference in what the two servers require rather than an accounting trick,
# and hiding it by measuring only the web process would be the trick.
#
# Usage: resources.sh <compose-project-name> <label>
set -euo pipefail

# Numbers are parsed and printed in the C locale, always. On a machine whose
# locale uses a comma for the decimal point, awk reads "0.000312" as 0 and
# prints "0,000" — which is both the wrong number and invalid JSON, and it
# happens silently on every machine outside the English-speaking world.
export LC_ALL=C

project="$1"
label="$2"

containers="$(docker ps --filter "label=com.docker.compose.project=$project" --format '{{.ID}}')"

if [ -z "$containers" ]; then
  printf '{"label":"%s","containers":0,"memory_mb":null,"cpu_percent":null}\n' "$label"
  exit 0
fi

# Several samples and the median, not one.
#
# A single `--no-stream` sample is one ~1s window, and whatever happens to run
# inside it becomes the whole answer. That is not hypothetical: an "idle"
# reading of an abuuba stack came back at 505% while the *loaded* reading of the
# same stack came back at 1.2%, because a periodic feed-trimming job happened
# to fire inside the idle window. A run whose idle CPU is four hundred times
# its loaded CPU is not a measurement, and it is the sort of number a reader
# would quote.
#
# Memory is a gauge and one reading of it is honest, so the last sample is
# used for that; CPU is a rate over a window, so it gets the median.
samples=5
cpu_samples="$(mktemp)"
stats=""
trap 'rm -f "$cpu_samples"' EXIT

for _ in $(seq "$samples"); do
  stats="$(docker stats --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' $containers)"

  echo "$stats" | awk -F'\t' '
    { value = $2; gsub(/%/, "", value); total += value }
    END { printf "%.1f\n", total }' >>"$cpu_samples"
done

memory="$(echo "$stats" | awk -F'\t' '
  {
    split($1, parts, " / ")
    value = parts[1]
    unit = value
    gsub(/[0-9.]/, "", unit)
    gsub(/[^0-9.]/, "", value)
    if (unit == "GiB") value = value * 1024
    else if (unit == "KiB") value = value / 1024
    else if (unit == "B") value = value / 1048576
    total += value
  }
  END { printf "%.1f", total }')"

cpu="$(sort -n "$cpu_samples" | awk '
  { values[NR] = $1 }
  END {
    if (NR == 0) { print "null"; exit }
    middle = int((NR + 1) / 2)
    printf "%.1f", values[middle]
  }')"

# The spread is reported alongside, because a median hides how much the
# samples disagreed and that disagreement is the reader's warning that the
# stack was doing something other than what the label says.
cpu_low="$(sort -n "$cpu_samples" | head -1)"
cpu_high="$(sort -n "$cpu_samples" | tail -1)"

count="$(echo "$containers" | wc -l | tr -d ' ')"

printf '{"label":"%s","containers":%s,"samples":%s,"memory_mb":%s,"cpu_percent":%s,"cpu_min":%s,"cpu_max":%s}\n' \
  "$label" "$count" "$samples" "$memory" "$cpu" "$cpu_low" "$cpu_high"
