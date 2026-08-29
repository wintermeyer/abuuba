#!/usr/bin/env bash
# A Move from the peer is honoured: the follower here follows the new account.
#
# The origin and target are throwaway accounts made for this scenario, the way
# account_closure makes its own, so the peer's main account is never moved and
# nothing later inherits a migrated peer. It still runs in LAST_SCENARIOS:
# a Move sends real deliveries whose timing is the peer's business, and
# keeping it at the end costs nothing.
#
# The implementation has to provide `peer_prepare_move` (create both accounts,
# print their usernames) and `peer_trigger_move` (alias, then move), because
# the two servers differ in kind here: GoToSocial has an API for a migration,
# Mastodon keeps it behind a web form with no API at all. A peer that cannot
# be scripted is a skip, not a failure -- nothing about abuuba can be learned
# from a migration nobody can start.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# The implementation's own driver functions. A scenario runs in its own
# process, so the config's functions are not inherited -- only its exported
# variables are. Sourced whole rather than exported piecemeal from run.sh,
# because which helpers a driver leans on is the implementation's business.
source "$(dirname "$0")/../implementations/$PEER_ID.sh"

declare -f peer_prepare_move >/dev/null || {
  printf '{"outcome":"skip","reason":"this implementation has no scripted way to trigger a Move"}\n'
  exit 0
}

# In this process, not a subshell: the tokens it sets have to survive until
# `peer_trigger_move` uses them.
peer_prepare_move ||
  fail "the peer could not make the two accounts a migration needs"

origin="$MOVE_ORIGIN"
target="$MOVE_TARGET"

# abuuba resolves and follows the origin. The follow has to exist before the
# Move: a Move only carries the followers it finds.
resolve_on_abuuba() {
  local handle="$1@$PEER_DOMAIN"
  local answer

  answer="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" \
    GET "/api/v2/search?q=$handle&resolve=true&type=accounts&limit=1")"

  echo "$answer" | json_first_account_id
}

origin_id="$(resolve_on_abuuba "$origin")"
[ -n "$origin_id" ] || fail "abuuba could not resolve $origin@$PEER_DOMAIN"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$origin_id/follow" >/dev/null

await "abuuba to be following the origin" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$origin_id' | grep -q '\"following\":true'" ||
  fail "abuuba could not follow the origin, so there is nothing for a Move to move"

peer_trigger_move || fail "the peer refused to migrate; its answer is in the raw log"

target_id="$(resolve_on_abuuba "$target")"
[ -n "$target_id" ] || fail "abuuba could not resolve $target@$PEER_DOMAIN"

# The whole point, both halves: following the new account, and no longer
# following the old one. Asserting only the first would pass on a server that
# follows every Move target it hears about without moving anybody.
await "the follower to arrive at the new account" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$target_id' | grep -q '\"following\":true'" ||
  fail "the Move did not move the follower"

await "the old follow to be gone" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$origin_id' | grep -q '\"following\":false'" ||
  fail "abuuba follows both ends of a migration"

pass
