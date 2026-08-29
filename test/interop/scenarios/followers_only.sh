#!/usr/bin/env bash
# A followers-only post reaches a follower on the other server and nobody else.
#
# The second of the two scenarios whose point is a negative, and the same rule
# applies: "the stranger cannot see it" passes just as happily when nothing
# arrived at all. So the run shows the same post reaching the follower first.
#
# Worth its own scenario rather than trusting `direct_message`: a direct post
# names its reader, and a followers-only one names a collection, which is a
# different decision made in a different place on both sides.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

peer_follows_abuuba

marker="interop-followers-$(date +%s%N)"

posted="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=private")"

[ -n "$(echo "$posted" | json_field . id)" ] || fail "abuuba would not make the post"

await "the post to reach the follower" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "a followers-only post did not reach somebody who follows"

# And to nobody else. The federated timeline carries public posts from servers
# this one has heard of, and a followers-only post must not be among them --
# on the peer, where the reader is a stranger to the author.
if curl -s -H "Host: $PEER_DOMAIN" -H "X-Forwarded-Proto: https" \
  "$PEER_URL/api/v1/timelines/public?limit=40" | grep -q "$marker"; then
  fail "a followers-only post was served on the peer's public timeline"
fi

# And it is not readable as an ordinary document by anybody who asks for it
# unsigned, which is the reader with no account anywhere.
#
# Asked of the published port with a Host header, the way everything else here
# reaches a server. The first version used the status's own URL --
# `https://abuuba.interop/...` -- which nothing outside the docker network can
# resolve: curl answered 000, the assignment failed, and `set -e` killed the
# scenario before it could say anything at all. It reported "no reason given",
# which is what this whole suite is trying to stop doing.
status_path="/users/$ABUUBA_ACCOUNT/statuses/$(echo "$posted" | json_field . id)"

code="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Host: $ABUUBA_DOMAIN" -H "X-Forwarded-Proto: https" \
  -H 'Accept: application/activity+json' "$ABUUBA_URL$status_path" || echo 000)"

case "$code" in
  200) fail "a followers-only post was served to an unsigned fetch" ;;
  000) fail "the unsigned fetch could not be made at all, so it proves nothing" ;;
  *) : ;;
esac

pass
