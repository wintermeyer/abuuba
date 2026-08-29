#!/usr/bin/env bash
# Withdrawing a follow travels, in both directions.
#
# Three scenarios establish a follow and none took it back. The Undo is the
# interesting half, the same as it was for favourites and boosts: one that
# never arrives leaves a relationship that can only be created. The person who
# unfollowed sees they are no longer following; the other server goes on
# delivering to them and goes on counting them as a follower. Neither screen
# explains the difference, and nothing errors.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

abuuba_handle="$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"
peer_handle="$PEER_ACCOUNT@$PEER_DOMAIN"

# --- them unfollowing us -------------------------------------------------

peer_follows_abuuba

abuuba_id_on_peer="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v2/search?q=$abuuba_handle&resolve=true&type=accounts&limit=1" | json_first_account_id)"

[ -n "$abuuba_id_on_peer" ] || fail "the peer could not resolve $abuuba_handle"

# Named rather than counted, on both sides. A counter is a denormalised
# number each server keeps in its own way and refreshes when it chooses --
# GoToSocial's still read 1 after it had logged "Follow undone" -- so a
# scenario built on one measures their bookkeeping rather than the follow.
#
# The control first: they are a follower here before they stop being one.
# Without it, "they are not a follower" passes on a server that never
# recorded them.
abuuba_account_id="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" \
  GET "/api/v1/accounts/verify_credentials" | json_field . id)"

await "the peer to be among our followers" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/$abuuba_account_id/followers?limit=80' | grep -q '\"acct\":\"$PEER_ACCOUNT@$PEER_DOMAIN\"'" ||
  fail "the peer never appeared among our followers, so withdrawing it proves nothing"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$abuuba_id_on_peer/unfollow" >/dev/null

await "the follower to be taken back" \
  "! api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/$abuuba_account_id/followers?limit=80' | grep -q '\"acct\":\"$PEER_ACCOUNT@$PEER_DOMAIN\"'" ||
  fail "they unfollowed and this server still lists them as a follower"

# --- us unfollowing them -------------------------------------------------

abuuba_follows_peer

peer_id_on_abuuba="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" \
  GET "/api/v2/search?q=$peer_handle&resolve=true&type=accounts&limit=1" | json_first_account_id)"

[ -n "$peer_id_on_abuuba" ] || fail "abuuba could not resolve $peer_handle"

peer_account_id="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v1/accounts/verify_credentials" | json_field . id)"

await "us to appear among their followers" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/$peer_account_id/followers?limit=80' | grep -q '\"acct\":\"$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN\"'" ||
  fail "the peer never listed us as a follower, so withdrawing it proves nothing"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$peer_id_on_abuuba/unfollow" >/dev/null

await "the peer to stop listing us" \
  "! api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/$peer_account_id/followers?limit=80' | grep -q '\"acct\":\"$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN\"'" ||
  fail "we unfollowed and the other server still lists us as a follower"

pass
