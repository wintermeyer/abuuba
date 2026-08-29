#!/usr/bin/env bash
# A direct message reaches the person it names and nobody else.
#
# The one scenario here whose point is a negative, and a negative on its own
# proves nothing: a suite that only checks "the stranger cannot see it" passes
# just as happily when nothing arrived at all, when the timeline is broken, or
# when the request was never authenticated. So the same run checks that an
# ordinary post from the same account on the same server does appear where the
# direct one must not.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

stamp="$(date +%s%N)"
public_marker="interop-open-$stamp"
direct_marker="interop-private-$stamp"
handle="@$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"

# Resolved first so the peer can address the account at all.
account_id="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v2/search?q=$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN&resolve=true&type=accounts&limit=1" |
  json_first_account_id)"

[ -n "$account_id" ] || fail "the peer could not resolve $ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"

# The control. An ordinary public post from the same account, which has to
# turn up on the federated timeline -- otherwise the check below is measuring
# a timeline that shows nothing rather than a post that is being kept out.
open_post="$(api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$handle $public_marker" --data-urlencode "visibility=public")"

[ -n "$(echo "$open_post" | json_field . id)" ] ||
  fail "the peer would not make the public post: $(echo "$open_post" | head -c 160)"

private_post="$(api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$handle $direct_marker" --data-urlencode "visibility=direct")"

[ -n "$(echo "$private_post" | json_field . id)" ] ||
  fail "the peer would not make the direct post: $(echo "$private_post" | head -c 160)"

await "the public post to reach the federated timeline" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/public?limit=40' | grep -q '$public_marker'" ||
  fail "even a public post from the peer did not reach the timeline, so this scenario can say nothing"

# Asked of the conversations list rather than of notifications. A private
# mention from somebody you do not follow is held back from the main
# notification list on purpose -- it is the requests inbox, and that policy is
# the reference implementation's default and ours -- so looking there would
# report a message as lost when it had arrived and been filed exactly as
# intended.
await "the direct message to reach the person it names" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/conversations?limit=40' | grep -q '$direct_marker'" ||
  fail "the direct message never reached the account it was addressed to"

# Now the negative, with both halves of the control already established: the
# timeline works, and this post arrived.
if api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/timelines/public?limit=40" | grep -q "$direct_marker"; then
  fail "a direct message appeared on the federated timeline"
fi

# And to somebody with no credentials at all, which is the reader this most
# has to hold against.
if curl -s -H "Host: $ABUUBA_DOMAIN" -H "X-Forwarded-Proto: https" \
  "$ABUUBA_URL/api/v1/timelines/public?limit=40" | grep -q "$direct_marker"; then
  fail "a direct message was served to a request carrying no token"
fi

pass
