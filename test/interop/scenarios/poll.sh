#!/usr/bin/env bash
# A poll federates and a vote from the other side is counted.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account. Set up
# here rather than assumed from an earlier scenario, which is how nine of
# these came to fail with "the post never arrived".
peer_follows_abuuba

marker="interop-poll-$(date +%s%N)"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" \
  --data-urlencode "poll[options][]=yes" \
  --data-urlencode "poll[options][]=no" \
  --data-urlencode "poll[expires_in]=3600" >/dev/null

await "the poll to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the poll never arrived"

remote="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/timelines/home?limit=40")"

# Read out of the JSON rather than scraped out of the text. The scrape was a
# pipeline of greps under `pipefail`, so the case it was written for -- a post
# that arrived without its poll -- killed the script on the grep that found
# nothing, before the line that would have said so. The scenario reported no
# reason at all for its own central failure.
poll_id="$(echo "$remote" | json_poll_id "$marker")"

[ -n "$poll_id" ] || fail "the post arrived without its poll"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/polls/$poll_id/votes" \
  --data-urlencode "choices[]=0" >/dev/null

await "the vote to be counted on abuuba" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -A20 '$marker' | grep -q '\"votes_count\":1'" ||
  fail "the vote never reached the server that owns the poll"

pass
