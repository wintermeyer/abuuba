#!/usr/bin/env bash
# A locked abuuba account turns a Follow into a request, and the later Accept
# turns the request into a follow.
#
# Worth its own scenario because the two-step version is where implementations
# disagree: some treat an unanswered request as a follow, which is exactly the
# thing locking an account is for.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Unlocked again however this ends. Locking is the one thing here that outlives
# the scenario, and leaving it set turns every later follow into a request that
# nobody answers -- which is five scenarios failing to establish a follow they
# only needed as scaffolding.
unlock() {
  api "$ABUUBA_URL" "$ABUUBA_TOKEN" PATCH "/api/v1/accounts/update_credentials" \
    --data-urlencode "locked=false" >/dev/null 2>&1 || true
}
trap unlock EXIT

abuuba_handle="$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"
# Search with `resolve`, for the same reason as follow_in.
lookup="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v2/search?q=$abuuba_handle&resolve=true&type=accounts&limit=1")"
account_id="$(echo "$lookup" | json_first_account_id)"

[ -n "$account_id" ] || fail "the peer could not resolve $abuuba_handle"

# Starting from not following, because an existing follow is not turned into a
# request by locking the account afterwards -- and `follow_in` runs first and
# leaves one. Without this the scenario asserts nothing about locking.
api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$account_id/unfollow" >/dev/null

await "the follow to be withdrawn" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/relationships?id[]=$account_id' | grep -q '\"following\":false'" ||
  fail "the peer would not stop following before the locked test"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" PATCH "/api/v1/accounts/update_credentials" \
  --data-urlencode "locked=true" >/dev/null

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$account_id/follow" >/dev/null

# Requested, and specifically not following.
await "the request to be pending" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/relationships?id[]=$account_id' | grep -q '\"requested\":true'" ||
  fail "the follow was not held as a request"

if api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/accounts/relationships?id[]=$account_id" |
  grep -q '"following":true'; then
  fail "a locked account was followed without accepting"
fi

# Now accept it on the abuuba side.
request="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/follow_requests")"
requester_id="$(echo "$request" | json_field . id)"

[ -n "$requester_id" ] || fail "abuuba has no follow request to accept"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/follow_requests/$requester_id/authorize" >/dev/null

await "the Accept to reach the peer" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/relationships?id[]=$account_id' | grep -q '\"following\":true'" ||
  fail "the Accept never arrived"

pass
