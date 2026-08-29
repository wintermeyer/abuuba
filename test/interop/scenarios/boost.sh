#!/usr/bin/env bash
# A boost on the peer shows on abuuba as a boost of the original, not as a new
# post with the same words.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account. Set up
# here rather than assumed from an earlier scenario, which is how nine of
# these came to fail with "the post never arrived".
peer_follows_abuuba

# And abuuba follows back: what the peer does to our post reaches us because
# we follow the account doing it, rather than because its server chose to
# tell the author.
abuuba_follows_peer

marker="interop-boost-$(date +%s%N)"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public" >/dev/null

await "the post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post never arrived, so there is nothing to boost"

remote_id="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/timelines/home?limit=40" | json_id_containing "$marker")"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses/$remote_id/reblog" >/dev/null

# On abuuba the boost has to point at the original rather than repeat it: the
# count going up is the part that proves it.
await "the boost to be counted" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -A5 '$marker' | grep -q '\"reblogs_count\":1'" ||
  fail "the Announce did not register as a boost of the original"

# And taking it back, which is the half nothing was asking about. An Undo that
# does not arrive leaves a count that can only go up: the author is told their
# post was boosted while the person who boosted it has already changed their
# mind, and no amount of looking at either screen explains the difference.
api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses/$remote_id/unreblog" >/dev/null

await "the boost to be taken back" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -A5 '$marker' | grep -q '\"reblogs_count\":0'" ||
  fail "the boost was withdrawn on the peer and still counts here"

pass
