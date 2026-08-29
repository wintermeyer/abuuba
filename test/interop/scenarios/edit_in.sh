#!/usr/bin/env bash
# An edit arriving from the other server replaces the text here.
#
# The mirror of `edit`, and the direction that depends on abuuba reading
# somebody else's `Update` rather than on abuuba sending one. A correction that
# never lands is quieter than a delete that never lands and lands on the same
# person: they fixed what they said, everybody on their own server sees the
# fix, and the readers here go on quoting the sentence they took back.
#
# The post arriving first is the positive control. "The old words are not
# there" passes on two servers that never connected, so the same run has to
# show the old words, then the new ones, then the old ones gone.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# abuuba follows the peer, so their posts have a reason to be on this timeline.
abuuba_follows_peer

marker="interop-edit-in-$(date +%s%N)"

posted="$(api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker before" --data-urlencode "visibility=public")"

peer_status_id="$(echo "$posted" | json_field . id)"

[ -n "$peer_status_id" ] ||
  fail "the peer would not post: $(echo "$posted" | head -c 160)"

await "the post to arrive before it is edited" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker before'" ||
  fail "nothing arrived even before the edit, so this scenario can say nothing"

api "$PEER_URL" "$PEER_TOKEN" PUT "/api/v1/statuses/$peer_status_id" \
  --data-urlencode "status=$marker after" >/dev/null

await "the edit to arrive" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker after'" ||
  fail "the Update never arrived, so the correction is invisible here"

if api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/timelines/home?limit=40" | grep -q "$marker before"; then
  fail "the edit made a second post here instead of replacing the first"
fi

pass
