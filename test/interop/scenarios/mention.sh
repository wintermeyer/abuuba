#!/usr/bin/env bash
# Being mentioned by somebody on the other server is heard about here.
#
# A mention is the one activity that reaches somebody who follows nobody and
# is followed by nobody, so it is the only way two strangers ever meet. If it
# does not arrive, the person mentioned has no way to know they were talked
# to, and the person talking has no way to find out they were not heard.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

marker="interop-mention-$(date +%s%N)"
handle="@$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"

# Deliberately no follow in either direction. A mention that only works
# between accounts that already follow each other is not a mention.
account_id="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v2/search?q=$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN&resolve=true&type=accounts&limit=1" |
  json_first_account_id)"

[ -n "$account_id" ] || fail "the peer could not resolve $ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"

posted="$(api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$handle $marker" --data-urlencode "visibility=public")"

# The peer's own half first. A post it refused to make and a post that never
# arrived are the same silence otherwise, and only one of them is about abuuba.
[ -n "$(echo "$posted" | json_field . id)" ] ||
  fail "the peer would not make the post: $(echo "$posted" | head -c 160)"

await "the mention to arrive as a notification" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/notifications?limit=40' | grep -q '$marker'" ||
  fail "being mentioned produced no notification here"

# And it is a mention rather than something else that happens to carry the
# text: a reader is told a different thing by each, and a post arriving as a
# notification of the wrong kind is worse than one arriving as none.
api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/notifications?limit=40" |
  grep -q '"type":"mention"' ||
  fail "the notification arrived but not as a mention"

pass
