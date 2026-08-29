#!/usr/bin/env bash
# A delete removes the post on the other side.
#
# The one that matters most when it fails: a post somebody deleted and that is
# still readable elsewhere is the worst kind of protocol drift.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account. Set up
# here rather than assumed from an earlier scenario, which is how nine of
# these came to fail with "the post never arrived".
peer_follows_abuuba

marker="interop-delete-$(date +%s%N)"

posted="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public")"
status_id="$(echo "$posted" | json_field . id)"

await "the post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post never arrived"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" DELETE "/api/v1/statuses/$status_id" >/dev/null

await "the delete to arrive" \
  "! api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post is still readable on the peer after being deleted"

pass
