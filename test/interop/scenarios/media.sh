#!/usr/bin/env bash
# An attachment is fetched by the other side and its description survives.
#
# The description is the part worth asserting: it is the accessibility text
# somebody wrote, it travels in a different field from the file, and it is
# quietly dropped by more implementations than drop the picture.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Everything below needs the peer to be following the abuuba account. Set up
# here rather than assumed from an earlier scenario, which is how nine of
# these came to fail with "the post never arrived".
peer_follows_abuuba

marker="interop-media-$(date +%s%N)"
description="a one pixel image, described"

png="$(mktemp --suffix=.png)"
trap 'rm -f "$png"' EXIT
base64 -d >"$png" <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
B64

uploaded="$(curl -s -X POST "$ABUUBA_URL/api/v2/media" \
  -H "Authorization: Bearer $ABUUBA_TOKEN" \
  -F "file=@$png" -F "description=$description")"
media_id="$(echo "$uploaded" | json_field . id)"

[ -n "$media_id" ] || fail "abuuba would not accept the upload"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" \
  --data-urlencode "media_ids[]=$media_id" >/dev/null

await "the post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the post never arrived"

remote="$(api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/timelines/home?limit=40")"

echo "$remote" | grep -q "$description" ||
  fail "the picture arrived without the description somebody wrote for it"

pass
