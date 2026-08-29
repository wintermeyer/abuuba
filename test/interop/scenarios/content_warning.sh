#!/usr/bin/env bash
# A content warning arrives as a warning rather than as body text.
#
# Getting this wrong is not a rendering detail: it puts the thing somebody
# warned about in front of the people who asked not to see it.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account. Set up
# here rather than assumed from an earlier scenario, which is how nine of
# these came to fail with "the post never arrived".
peer_follows_abuuba

marker="interop-cw-$(date +%s%N)"
warning="spoilers ahead"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" \
  --data-urlencode "spoiler_text=$warning" >/dev/null

await "the post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post never arrived"

remote="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/timelines/home?limit=40")"

echo "$remote" | grep -q "\"spoiler_text\":\"$warning\"" ||
  fail "the warning did not arrive as a warning"

pass
