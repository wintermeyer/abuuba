#!/usr/bin/env bash
# Blocking an account on the other server stops their posts arriving.
#
# The whole point of a block is a negative, and a negative alone proves
# nothing: "their posts do not arrive" passes just as well on a server where
# nothing arrives, where the timeline is broken, or where the two were never
# connected. So the same run shows a post from the same account arriving
# before the block and not after it.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# abuuba follows the peer, so their posts have a reason to be on this timeline
# at all.
abuuba_follows_peer

stamp="$(date +%s%N)"
before_marker="interop-before-block-$stamp"
after_marker="interop-after-block-$stamp"
handle="$PEER_ACCOUNT@$PEER_DOMAIN"

account_id="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" \
  GET "/api/v2/search?q=$handle&resolve=true&type=accounts&limit=1" | json_first_account_id)"

[ -n "$account_id" ] || fail "abuuba could not resolve $handle"

# Unblocked however this ends. A block left in place would hide the peer from
# every scenario that runs afterwards, and they would each report their own
# feature as broken.
unblock() {
  api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$account_id/unblock" >/dev/null 2>&1 || true
}
trap unblock EXIT

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$before_marker" --data-urlencode "visibility=public" >/dev/null

await "a post from them to arrive before the block" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$before_marker'" ||
  fail "nothing from them arrived even before the block, so this scenario can say nothing"

blocked="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$account_id/block")"

echo "$blocked" | grep -q '"blocking":true' ||
  fail "abuuba would not block the account: $(echo "$blocked" | head -c 160)"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$after_marker" --data-urlencode "visibility=public" >/dev/null

# Proving a negative needs a deadline rather than a poll: wait the window out
# and then look, the same way `domain_block` does.
sleep "$DEADLINE_SECONDS"

if api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/timelines/home?limit=40" | grep -q "$after_marker"; then
  fail "a post from a blocked account arrived anyway"
fi

# And the older one goes too: a block is not only about what comes next.
if api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/timelines/home?limit=40" | grep -q "$before_marker"; then
  fail "posts from before the block are still on the timeline"
fi

pass
