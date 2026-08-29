#!/usr/bin/env bash
# abuuba follows an account on the other server, and the Accept comes back.
#
# The first scenario for a reason: everything after it assumes a follow exists,
# and a suite that fails sixteen things because this one broke is harder to
# read than one that stops here.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

peer_handle="$PEER_ACCOUNT@$PEER_DOMAIN"

# Search with `resolve`, which is what a client uses to find somebody it has
# never met. `/api/v1/accounts/lookup` is the wrong question: it answers from
# what this server already knows — Mastodon's passes `skip_webfinger: true` —
# so asking it about a stranger answers nothing and fetches nothing.
found="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v2/search?q=$peer_handle&resolve=true&type=accounts&limit=1")"
account_id="$(echo "$found" | json_first_account_id)"

[ -n "$account_id" ] || fail "abuuba could not resolve $peer_handle"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$account_id/follow" >/dev/null

# Following is not the same as being followed back: the Accept is what turns
# the request into a follow, and it arrives asynchronously.
await "the Accept" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$account_id' | grep -q '\"following\":true'" ||
  fail "the follow was never accepted"

# And the other side has to agree it happened -- named, not counted.
#
# This used to fetch the peer's followers collection unsigned and grep it for
# `totalItems`, which asserted that the collection answered at all and nothing
# about who was in it: it passed just as happily with an empty one. It also
# could not work against a peer in authorized-fetch mode, which refuses an
# unsigned fetch and is exactly the peer this most needs to hold for.
#
# Asked through the peer's own API with the peer's token, which works in either
# mode and can say the thing worth saying.
peer_account_id="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/accounts/verify_credentials" |
  json_field . id)"

await "abuuba to appear among the peer's followers" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/$peer_account_id/followers?limit=80' | grep -q '\"acct\":\"$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN\"'" ||
  fail "abuuba never appeared in the peer's follower list"

pass
