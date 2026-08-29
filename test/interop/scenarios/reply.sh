#!/usr/bin/env bash
# A reply from the peer threads under an abuuba post, and abuuba's reply threads
# under theirs.
#
# Both directions, because inReplyTo is read by one side and written by the
# other and a server can get one right while getting the other wrong.
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

marker="interop-thread-$(date +%s%N)"

posted="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public")"
abuuba_status_id="$(echo "$posted" | json_field . id)"

[ -n "$abuuba_status_id" ] || fail "abuuba would not make the post"

await "the post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post never arrived, so there is nothing to reply to"

remote_id="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/timelines/home?limit=40" | json_id_containing "$marker")"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker-reply" \
  --data-urlencode "in_reply_to_id=$remote_id" >/dev/null

await "the reply to thread on abuuba" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/statuses/$abuuba_status_id/context' | grep -q '$marker-reply'" ||
  fail "the reply did not thread under the original"

pass
