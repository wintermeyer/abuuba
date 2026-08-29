#!/usr/bin/env bash
# Total CPU time a stack has consumed since it started, in milliseconds.
#
# Read before and after a measured load, the difference is how much CPU that
# load actually cost — which is the resource question worth asking and the one
# `docker stats` cannot answer here.
#
# `docker stats` reports a percentage over a ~1s window, so it only describes a
# load that lasts longer than the window. abuuba answers 150 timeline reads in
# about a third of a second, and the shipped rate limit (300 requests per five
# minutes per token) forbids simply asking for more of them. Sampling a
# percentage against that is measuring an idle stack and calling it load.
#
# Cumulative CPU time has neither problem: it does not care how long the work
# took, and two servers doing the same work are directly comparable per
# request.
#
# Usage: cputime.sh <compose-project-name>
set -euo pipefail

export LC_ALL=C

project="$1"

containers="$(docker ps --filter "label=com.docker.compose.project=$project" --format '{{.ID}}')"

[ -n "$containers" ] || {
  echo "0"
  exit 0
}

total=0

for id in $containers; do
  # cgroup v2 first, then v1. A container that reports neither contributes
  # nothing and is counted as zero rather than failing the run — but it is the
  # reason a total can read low, so it is worth knowing about.
  usec="$(docker exec "$id" sh -c '
    if [ -r /sys/fs/cgroup/cpu.stat ]; then
      awk "/^usage_usec/ { print \$2 }" /sys/fs/cgroup/cpu.stat
    elif [ -r /sys/fs/cgroup/cpuacct/cpuacct.usage ]; then
      awk "{ printf \"%d\", \$1 / 1000 }" /sys/fs/cgroup/cpuacct/cpuacct.usage
    else
      echo 0
    fi
  ' 2>/dev/null | tr -d '[:space:]')"

  [ -n "$usec" ] || usec=0
  total=$((total + usec))
done

# Milliseconds, as a plain number so the caller can subtract two of them.
awk -v total="$total" 'BEGIN { printf "%.1f", total / 1000 }'
