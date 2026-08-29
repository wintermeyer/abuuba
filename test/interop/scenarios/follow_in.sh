#!/usr/bin/env bash
# The other server follows an abuuba account, and abuuba accepts.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

abuuba_handle="$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"

# Search with `resolve`: lookup answers only from what that server already
# knows, so asking it about a stranger fetches nothing.
lookup="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v2/search?q=$abuuba_handle&resolve=true&type=accounts&limit=1")"
account_id="$(echo "$lookup" | json_first_account_id)"

[ -n "$account_id" ] || fail "the peer could not resolve $abuuba_handle"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$account_id/follow" >/dev/null

await "abuuba to accept" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/relationships?id[]=$account_id' | grep -q '\"following\":true'" ||
  fail "abuuba never accepted the follow"

pass
