#!/usr/bin/env bash
# A post on abuuba reaches a follower on the other server.
#
# The thing the whole protocol exists for. Everything after it is a variation
# on the same shape: post, wait, look.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account. Set up
# here rather than assumed from an earlier scenario, which is how nine of
# these came to fail with "the post never arrived".
peer_follows_abuuba

marker="interop-$(date +%s%N)"

posted="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public")"

[ -n "$(echo "$posted" | json_field . id)" ] || fail "abuuba would not make the post"

await "the post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post never reached the follower's timeline"

pass
