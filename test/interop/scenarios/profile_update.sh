#!/usr/bin/env bash
# A change to a profile here reaches the other server.
#
# The `Update` of an actor, which nothing else in this suite sends. A profile
# that never updates elsewhere is the kind of failure people notice slowly and
# blame on caching: somebody renames themselves, everybody they follow keeps
# seeing the old name, and there is nothing to report because nothing broke.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# The peer has to be following, or it has no reason to be told anything about
# this account at all.
peer_follows_abuuba

handle="$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"
# Short enough to be accepted: a display name is capped at 30 characters, and
# the first version of this used a nanosecond timestamp that came to 32. The
# PATCH answered 422, nothing changed, and the scenario would have reported
# that profile changes do not federate -- which was true of nothing.
name="interop $(date +%s)"

# Whatever it was called before, put back however this ends. A display name
# left behind would be harmless, but a scenario that changes an account and
# does not say so is how the last round of these went wrong.
previous="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/accounts/verify_credentials" |
  json_field . display_name)"

restore() {
  api "$ABUUBA_URL" "$ABUUBA_TOKEN" PATCH "/api/v1/accounts/update_credentials" \
    --data-urlencode "display_name=$previous" >/dev/null 2>&1 || true
}
trap restore EXIT

account_id="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v2/search?q=$handle&resolve=true&type=accounts&limit=1" | json_first_account_id)"

[ -n "$account_id" ] || fail "the peer could not resolve $handle"

changed="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" PATCH "/api/v1/accounts/update_credentials" \
  --data-urlencode "display_name=$name")"

# That it took effect here, before asking whether it travelled. Otherwise a
# change abuuba never applied and a change abuuba never sent are the same silence,
# and the scenario would name the wrong one.
here="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/accounts/verify_credentials" |
  json_field . display_name)"

[ "$here" = "$name" ] ||
  fail "abuuba did not apply the change itself: $(echo "$changed" | head -c 160)"

await "the new name to reach the peer" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/$account_id' | grep -q '$name'" ||
  fail "the profile change never reached the other server"

pass
