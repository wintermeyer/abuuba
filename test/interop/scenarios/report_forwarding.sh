#!/usr/bin/env bash
# A report forwarded to the reported account's own server arrives there.
#
# Moderation is the part of the protocol where silence is worst. A report that
# does not arrive leaves the reporter believing they have told somebody, and
# the server that could act on it never hearing -- and unlike a post that
# fails to arrive, nobody is looking at a timeline wondering where it went.
#
# Only asked of servers whose moderation can be read from outside. Checking
# that we sent something is not the same as checking it was received, and this
# scenario exists for the second one.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Two markers, because one would not tell two things apart. The admin API
# returns a report together with the statuses attached to it, so a single
# marker used for both the post and the comment matches whether or not the
# comment travelled -- and the comment is the part somebody on the other
# server actually reads.
stamp="$(date +%s%N)"
post_marker="interop-reported-post-$stamp"
comment_marker="interop-report-says-$stamp"

# Something to report: a post from the peer, which abuuba has to have seen.
peer_follows_abuuba
abuuba_follows_peer

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$post_marker" --data-urlencode "visibility=public" >/dev/null

await "the post to report to arrive" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$post_marker'" ||
  fail "the post never arrived, so there is nothing to report"

peer_account_id="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" \
  GET "/api/v2/search?q=$PEER_ACCOUNT@$PEER_DOMAIN&resolve=true&type=accounts&limit=1" |
  json_first_account_id)"

[ -n "$peer_account_id" ] || fail "abuuba could not resolve $PEER_ACCOUNT@$PEER_DOMAIN"

reported="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/reports" \
  --data-urlencode "account_id=$peer_account_id" \
  --data-urlencode "comment=$comment_marker" \
  --data-urlencode "forward=true")"

# abuuba's own half first, so a report it refused to file and one that did not
# travel are told apart.
[ -n "$(echo "$reported" | json_field . id)" ] ||
  fail "abuuba would not file the report: $(echo "$reported" | head -c 200)"

await "the report to reach the other server" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/admin/reports?limit=40' | grep -q '$comment_marker'" ||
  fail "the report was forwarded and never arrived"

pass
