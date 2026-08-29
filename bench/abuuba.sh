#!/usr/bin/env bash
# abuuba on its own, brought up, seeded and measured. About two minutes.
#
#   bench/abuuba.sh [small|medium|large]
#   bench/abuuba.sh small --keep     # leave the stack running afterwards
#
# The two-server comparison takes twenty-five minutes, nearly all of it waiting
# for Mastodon's queue to drain, and that is the wrong loop to iterate an abuuba
# change in: the number that has to move is abuuba's, and Mastodon will not have
# changed between two runs an hour apart.
#
# This is `run.sh --only abuuba` and nothing else. It was a second script once,
# with its own bring-up, seeding, drain wait and warm-up copied across — and
# every copy was the weaker one. The drain wait had no timeout, so a stuck
# queue hung forever, and there was no positive control, so the one script
# people would iterate in was the one that could not tell a fast redirect from
# a fast timeline.
#
# It measures one side and is not a comparison. Use the numbers only against
# other numbers from here; use run.sh for abuuba against Mastodon.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$here/run.sh" --only abuuba "$@"
