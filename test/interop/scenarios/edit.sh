#!/usr/bin/env bash
# An edit replaces the text on the other side rather than making a second post.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account. Set up
# here rather than assumed from an earlier scenario, which is how nine of
# these came to fail with "the post never arrived".
peer_follows_abuuba

marker="interop-edit-$(date +%s%N)"

posted="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker before" --data-urlencode "visibility=public")"
status_id="$(echo "$posted" | json_field . id)"

await "the post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker before'" ||
  fail "the post never arrived"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" PUT "/api/v1/statuses/$status_id" \
  --data-urlencode "status=$marker after" >/dev/null

await "the edit to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker after'" ||
  fail "the Update never arrived"

if api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/timelines/home?limit=40" | grep -q "$marker before"; then
  fail "the edit made a second post instead of replacing the first"
fi

pass
