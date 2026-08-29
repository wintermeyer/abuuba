#!/usr/bin/env bash
# A pinned post shows on the profile the other server draws, and leaves again
# when it is unpinned.
#
# The `Add` and `Remove` on the featured collection, which nothing else here
# sends. A pin that does not travel is a post somebody put at the top of their
# profile for everybody to see first, seen first by nobody.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# The peer has to be following. A pin arrives either way -- a server fetches
# the featured collection when it first resolves a profile, so the `Add` is
# not what puts it there -- but the `Remove` is pushed to followers, and
# without one it goes nowhere. The first version of this scenario had no
# follow and reported that unpinning does not federate, which was true only of
# a peer that had never asked to hear from us.
peer_follows_abuuba

marker="interop-pin-$(date +%s%N)"
handle="$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"

posted="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public")"
status_id="$(echo "$posted" | json_field . id)"

[ -n "$status_id" ] || fail "abuuba would not make the post"

# Unpinned again however this ends: a post left pinned would still be at the
# top of the profile for every scenario that runs afterwards.
unpin() {
  api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses/$status_id/unpin" >/dev/null 2>&1 || true
}
trap unpin EXIT

pinned="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses/$status_id/pin")"

# abuuba's own half first, so a pin it refused and a pin that did not travel are
# told apart.
echo "$pinned" | grep -q '"pinned":true' ||
  fail "abuuba would not pin the post: $(echo "$pinned" | head -c 160)"

account_id="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v2/search?q=$handle&resolve=true&type=accounts&limit=1" | json_first_account_id)"

[ -n "$account_id" ] || fail "the peer could not resolve $handle"

await "the pin to show on the peer's copy of the profile" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/$account_id/statuses?pinned=true&limit=40' | grep -q '$marker'" ||
  fail "the pinned post never appeared on the other server's profile"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses/$status_id/unpin" >/dev/null

# And taken back. A pin that arrives and never leaves is worse than one that
# never arrives: the author took it down and everybody else still sees it.
await "the pin to be taken back" \
  "! api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/$account_id/statuses?pinned=true&limit=40' | grep -q '$marker'" ||
  fail "the post was unpinned here and is still pinned there"

pass
