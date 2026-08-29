#!/usr/bin/env bash
# A favourite from the other server counts here, and taking it back takes the
# count with it.
#
# The commonest activity on the network and the last one this suite got round
# to. A `Like` that never arrives costs nobody a post, which is exactly why it
# could be broken for a long time without anybody saying so: the author simply
# sees a number that is lower than the truth.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account.
peer_follows_abuuba

marker="interop-fav-$(date +%s%N)"

posted="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public")"
abuuba_status_id="$(echo "$posted" | json_field . id)"

[ -n "$abuuba_status_id" ] || fail "abuuba would not make the post"

await "the post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post never arrived, so there is nothing to favourite"

remote_id="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/timelines/home?limit=40" | json_id_containing "$marker")"

[ -n "$remote_id" ] || fail "the post is on the peer's timeline but its id could not be read"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses/$remote_id/favourite" >/dev/null

await "the favourite to be counted" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/statuses/$abuuba_status_id' | grep -q '\"favourites_count\":1'" ||
  fail "the favourite never reached the post it was for"

# And taking it back. An Undo that does not arrive leaves a count that can only
# go up, which is worse than one that never moved: the author is told somebody
# liked their post and the peer's own screen says otherwise.
api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses/$remote_id/unfavourite" >/dev/null

await "the favourite to be taken back" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/statuses/$abuuba_status_id' | grep -q '\"favourites_count\":0'" ||
  fail "the favourite was withdrawn on the peer and still counts here"

pass
