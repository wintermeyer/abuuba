#!/usr/bin/env bash
# A delete arriving from the other server removes the post here.
#
# The mirror of `delete`, and the half nobody was checking. That scenario says
# it best: a post somebody deleted and that is still readable elsewhere is the
# worst kind of protocol drift. It only ever checked the direction where abuuba
# is the one deleting, which is the direction abuuba controls -- the one that
# depends on abuuba reading somebody else's activity correctly had no scenario
# at all.
#
# The post arriving first is the positive control. "It is not on the timeline"
# passes just as well on two servers that never connected, or on a timeline
# that is broken, so the same run has to show the post there and then gone.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# abuuba follows the peer, so their posts have a reason to be on this timeline.
abuuba_follows_peer

marker="interop-delete-in-$(date +%s%N)"

posted="$(api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public")"

peer_status_id="$(echo "$posted" | json_field . id)"

[ -n "$peer_status_id" ] ||
  fail "the peer would not post: $(echo "$posted" | head -c 160)"

await "the post to arrive before it is deleted" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "nothing arrived even before the delete, so this scenario can say nothing"

api "$PEER_URL" "$PEER_TOKEN" DELETE "/api/v1/statuses/$peer_status_id" >/dev/null

await "the post to go" \
  "! api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post is still on the timeline after the peer deleted it"

pass
