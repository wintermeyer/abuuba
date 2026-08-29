#!/usr/bin/env bash
# Signatures verify in both directions.
#
# The one scenario where "it worked" is not enough, because a server that
# accepted an unsigned request would also pass. So this asks three questions:
# does a signed request from the peer get in, does an unsigned one get refused,
# and does the peer accept ours.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account. Set up
# here rather than assumed from an earlier scenario, which is how nine of
# these came to fail with "the post never arrived".
peer_follows_abuuba

# A delivery from the peer arrived earlier in the suite, which is the inbound
# direction working. Here it is asserted directly: an unsigned POST to the
# inbox must not be accepted.
unsigned="$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "$ABUUBA_URL/users/$ABUUBA_ACCOUNT/inbox" \
  -H 'Content-Type: application/activity+json' \
  --data '{"type":"Create","actor":"https://nowhere.example/users/nobody"}')"

case "$unsigned" in
  40*) : ;;
  *) fail "an unsigned delivery was answered with $unsigned rather than refused" ;;
esac

# Outbound: the peer accepted our signature if anything we sent has arrived.
marker="interop-sig-$(date +%s%N)"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public" >/dev/null

await "the peer to accept a signed delivery from abuuba" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the peer did not accept a delivery signed by abuuba"

pass
