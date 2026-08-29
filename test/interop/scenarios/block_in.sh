#!/usr/bin/env bash
# A block arriving from the other server is honoured here.
#
# The mirror of `block`, and the half nobody was checking. abuuba sends `Block`
# and it handles one; only the sending had a scenario. What arrives has real
# consequences on this side -- the follows between the two come down, in both
# directions -- and a server that filed the activity and did nothing would look
# exactly the same from outside until somebody noticed they were still reading
# an account that had blocked them.
#
# Nothing is asserted about the blocked person being told. They are not told,
# deliberately: the reference implementation does not say who blocked you, and
# abuuba is not going to be the server that leaks it.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# A relationship for the block to undo, in both directions, and the positive
# control for everything below: if these do not hold, the assertions after the
# block would pass on two servers that had never heard of each other.
peer_follows_abuuba
abuuba_follows_peer

handle="$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"
peer_handle="$PEER_ACCOUNT@$PEER_DOMAIN"

abuuba_on_peer="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v2/search?q=$handle&resolve=true&type=accounts&limit=1" | json_first_account_id)"

[ -n "$abuuba_on_peer" ] || fail "the peer could not resolve $handle"

peer_on_abuuba="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" \
  GET "/api/v2/search?q=$peer_handle&resolve=true&type=accounts&limit=1" | json_first_account_id)"

[ -n "$peer_on_abuuba" ] || fail "abuuba could not resolve $peer_handle"

# Lifted however this ends, and the follows re-made with it. A block left
# standing on the peer would take the following scenarios with it, and they
# would each report their own feature as broken.
lift() {
  api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$abuuba_on_peer/unblock" >/dev/null 2>&1 || true

  (peer_follows_abuuba) >/dev/null 2>&1 || true
  (abuuba_follows_peer) >/dev/null 2>&1 || true
}
trap lift EXIT

blocked="$(api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$abuuba_on_peer/block")"

echo "$blocked" | grep -q '"blocking":true' ||
  fail "the peer would not block $handle: $(echo "$blocked" | head -c 160)"

# What abuuba has to do with it: record that this account has blocked ours, and
# take the follows down both ways. Asked of abuuba rather than of the peer,
# because the peer's own bookkeeping proves nothing about what crossed.
await "abuuba to know it has been blocked" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$peer_on_abuuba' | grep -q '\"blocked_by\":true'" ||
  fail "the Block arrived and abuuba carried on as though nothing had happened"

await "the follow from here to be gone" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$peer_on_abuuba' | grep -q '\"following\":false'" ||
  fail "abuuba still follows an account that has blocked it"

await "the follow from there to be gone" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$peer_on_abuuba' | grep -q '\"followed_by\":false'" ||
  fail "abuuba still counts a follower who has blocked it"

# And taking it back, which is the last kind of Undo abuuba handles with nothing
# asking about it: Follow, Like and Announce each have their undo checked by
# the scenario that makes them, and Block had none. An Undo that never lands
# leaves abuuba refusing somebody who has changed their mind, with nothing the
# person on this side could do about it.
#
# The follows do not come back and are not expected to: a block deletes the
# edges, and no unblock resurrects a deleted one. The trap re-makes them.
api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$abuuba_on_peer/unblock" >/dev/null

await "abuuba to hear that the block was lifted" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$peer_on_abuuba' | grep -q '\"blocked_by\":false'" ||
  fail "the Undo of the Block never arrived, so abuuba still believes it is blocked"

pass
