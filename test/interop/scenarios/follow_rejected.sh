#!/usr/bin/env bash
# A follow abuuba sent is declined, and abuuba takes it back.
#
# The mirror of `follow_locked`, which covers the request abuuba receives and
# accepts. Nothing covered the answer nobody wants to get. A `Reject` that
# abuuba ignores leaves somebody here following an account that has refused
# them: a state only the other server can clear, and one the person cannot
# even see is wrong.
#
# Deliberately does not wait for abuuba to learn that the peer locked its
# account. It does not need to: the peer holds the Follow as a request
# whatever abuuba believes, so abuuba sends one believing the account is open and
# is then corrected by the Reject. That is the more interesting case anyway --
# it is what happens to anybody whose copy of a profile is a few minutes old.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

peer_handle="$PEER_ACCOUNT@$PEER_DOMAIN"

peer_on_abuuba="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" \
  GET "/api/v2/search?q=$peer_handle&resolve=true&type=accounts&limit=1" | json_first_account_id)"

[ -n "$peer_on_abuuba" ] || fail "abuuba could not resolve $peer_handle"

# Unlocked again however this ends, and the follows put back. Locking outlives
# the scenario, and leaving it set turns every later follow into a request that
# nobody answers.
lift() {
  api "$PEER_URL" "$PEER_TOKEN" PATCH "/api/v1/accounts/update_credentials" \
    --data-urlencode "locked=false" >/dev/null 2>&1 || true

  (abuuba_follows_peer) >/dev/null 2>&1 || true
  (peer_follows_abuuba) >/dev/null 2>&1 || true
}
trap lift EXIT

# From not following, because an existing follow is not turned back into
# anything by locking the account afterwards -- and `follow_out` runs first and
# leaves one.
api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$peer_on_abuuba/unfollow" >/dev/null

await "abuuba to stop following before the test" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$peer_on_abuuba' | grep -q '\"following\":false'" ||
  fail "abuuba would not stop following, so there would be nothing to decline"

api "$PEER_URL" "$PEER_TOKEN" PATCH "/api/v1/accounts/update_credentials" \
  --data-urlencode "locked=true" >/dev/null

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$peer_on_abuuba/follow" >/dev/null

# The positive control: abuuba believes it is following, because as far as it
# knows the account is open. Without this the assertion after the Reject would
# pass on a follow that never happened.
await "abuuba to think it is following" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$peer_on_abuuba' | grep -qE '\"(following|requested)\":true'" ||
  fail "abuuba neither followed nor asked, so nothing reached the peer"

# The peer holds it as a request, because its account is locked, and declines.
await "the request to reach the peer" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/follow_requests' | grep -q '$ABUUBA_ACCOUNT'" ||
  fail "the Follow never arrived, so there was nothing for the peer to decline"

# `json_field . id`, not `json_first_account_id`: this endpoint answers with a
# bare array of accounts rather than the search result's `{"accounts": [...]}`,
# and the helper for one shape dies on the other.
requester="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/follow_requests" | json_field . id)"

[ -n "$requester" ] || fail "the peer lists no follow request from $ABUUBA_ACCOUNT"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/follow_requests/$requester/reject" >/dev/null

# What abuuba has to do with it: stop claiming a relationship the other server
# has refused. Both halves, because clearing one and leaving the other is the
# shape that leaves a client showing a button that does nothing.
await "abuuba to take the follow back" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$peer_on_abuuba' | grep -q '\"following\":false'" ||
  fail "the Reject arrived and abuuba still believes it follows the account"

if api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/accounts/relationships?id[]=$peer_on_abuuba" |
  grep -q '"requested":true'; then
  fail "a declined follow is still shown as a pending request"
fi

pass
