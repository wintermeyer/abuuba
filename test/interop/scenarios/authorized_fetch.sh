#!/usr/bin/env bash
# Authorized fetch: a peer that insists on a signed GET is answered with one,
# and abuuba's own actor is served to a signed request.
#
# Servers running in this mode are a large and growing part of the network, and
# the failure is total rather than partial: nothing is fetchable at all.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# What an unsigned fetch of the peer's actor gets. Either answer is legitimate
# — it depends on whether that server requires a signature — and the point is
# what abuuba does next.
# With the Host and forwarded-proto headers every other request here sends:
# without them Rails answers 403 from `config.hosts` before a controller sees
# the request, so this read 403 whatever the peer's setting was and the answer
# it is checking for could never appear.
unsigned="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Host: $PEER_DOMAIN" -H "X-Forwarded-Proto: https" \
  -H 'Accept: application/activity+json' "$PEER_URL/users/$PEER_ACCOUNT")"

say "an unsigned fetch of the peer's actor answered $unsigned"

# A peer that answers an unsigned fetch is not in authorized-fetch mode, and
# nothing done here would say whether abuuba can talk to one that is. Reported as
# a skip rather than a pass: this scenario used to run against exactly such a
# peer and report that signed fetches worked, which was true of nothing.
case "$unsigned" in
  200)
    printf '{"outcome":"skip","reason":"the peer answers unsigned fetches, so this proves nothing"}\n'
    exit 0
    ;;
esac

# abuuba resolving the account is the signed fetch: if the peer requires one and
# abuuba did not send it, this fails.
#
# Asked through search with `resolve=true`, not through `accounts/lookup`.
# Lookup answers from what the server already knows and deliberately never
# fetches -- Mastodon passes `skip_webfinger` and abuuba matches it -- so the
# scenario used to report an unreachable peer whenever it happened to run
# before anything else had resolved that account, which as the alphabetically
# first scenario was every time.
resolved="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET \
  "/api/v2/search?q=$PEER_ACCOUNT@$PEER_DOMAIN&resolve=true&type=accounts&limit=1")"

[ -n "$(echo "$resolved" | json_first_account_id)" ] ||
  fail "abuuba could not fetch the actor; a peer in authorized-fetch mode is unreachable"

# And the other direction: abuuba's actor, fetched by the peer.
peer_resolved="$(api "$PEER_URL" "$PEER_TOKEN" GET \
  "/api/v2/search?q=$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN&resolve=true&type=accounts&limit=1")"

[ -n "$(echo "$peer_resolved" | json_first_account_id)" ] ||
  fail "the peer could not fetch abuuba's actor"

pass
