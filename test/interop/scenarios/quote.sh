#!/usr/bin/env bash
# A quote request is answered and the quote renders with what it quotes.
#
# Newer than the rest of the protocol and implemented by fewer servers, which
# is why the suite only asks the ones that have it.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account. Set up
# here rather than assumed from an earlier scenario, which is how nine of
# these came to fail with "the post never arrived".
peer_follows_abuuba

marker="interop-quote-$(date +%s%N)"

posted="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public")"
abuuba_status_id="$(echo "$posted" | json_field . id)"

await "the post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post never arrived, so there is nothing to quote"

remote_id="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/timelines/home?limit=40" | json_id_containing "$marker")"

# An empty id here is not an error to the peer: `quoted_status_id=` reads as no
# quote at all, so it makes an ordinary post, answers 200, and the scenario
# waits sixty seconds for a quote nobody was ever asked for.
[ -n "$remote_id" ] || fail "the post is on the peer's timeline but its id could not be read"

quoting="$(api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker-quoting" \
  --data-urlencode "quoted_status_id=$remote_id")"

# Kept, because the peer refusing to make the quote at all and the peer making
# it and never asking us are the same silence otherwise. A server decides
# whether to ask from the `interactionPolicy` on the quoted post, so a refusal
# here is about what abuuba published rather than about how it answers.
[ -n "$(echo "$quoting" | json_field . id)" ] ||
  fail "the peer would not make the quote: $(echo "$quoting" | head -c 200)"

# A post came back with no quote on it, which means this peer took
# `quoted_status_id` and ignored it: quoting is newer than it is. Mastodon
# 4.4.7 has no such parameter in its statuses controller at all, so it answers
# 200 and makes an ordinary post, and the sixty seconds spent waiting
# afterwards were spent waiting for a request nobody was ever going to send.
#
# Reported as a skip. This scenario can only say something about abuuba when the
# other end can ask in the first place.
if [ -z "$(echo "$quoting" | json_subfield quote id)" ]; then
  printf '{"outcome":"skip","reason":"this peer cannot make a quote post"}\n'
  exit 0
fi

await "the quote to arrive with what it quotes" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/statuses/$abuuba_status_id' | grep -q '\"quotes_count\":1'" ||
  fail "the quote did not register against the post it quotes"

pass
