#!/usr/bin/env bash
# A domain block holds in both directions: nothing new from that domain
# arrives, and nothing goes to it.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

control="interop-unblocked-$(date +%s%N)"
control_out="interop-unblockedout-$(date +%s%N)"
marker="interop-blocked-$(date +%s%N)"
outbound="interop-blockedout-$(date +%s%N)"

# The follows the block is meant to cut, one for each direction this checks.
# Without them the scenario proves nothing whatever: a post that was never
# going to arrive does not arrive, and both assertions below pass just as
# happily on two servers that have never heard of each other.
abuuba_follows_peer
peer_follows_abuuba

# And the positive controls, taken before anything is blocked. They are what
# make the silence afterwards evidence rather than a coincidence: the same
# accounts, the same follows, the same timelines, one post earlier.
api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$control" --data-urlencode "visibility=public" >/dev/null

await "a post from the peer to arrive while nothing is blocked" \
  "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$control'" ||
  fail "nothing from the peer arrives unblocked either, so a block here would prove nothing"

api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$control_out" --data-urlencode "visibility=public" >/dev/null

await "a post from abuuba to reach the peer while nothing is blocked" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$control_out'" ||
  fail "nothing from abuuba reaches the peer unblocked either, so a block here would prove nothing"

# Blocked at the server level, which is the admin's tool rather than a user's.
# A block is a moderator's decision and is recorded as one, so it is made
# through the same function the admin area calls rather than by writing a row.
# The output is kept: an rpc that raises says why, and discarding it left
# "the domain could not be blocked" standing in for a call whose signature had
# simply never existed.
moderator="Abuuba.Accounts.lookup(\"$ABUUBA_ACCOUNT\")"

docker compose -f "$(dirname "$0")/../compose.yml" exec -T abuuba \
  /app/bin/abuuba rpc \
  "{:ok, _} = Abuuba.Moderation.Domains.block($moderator, %{\"domain\" => \"$PEER_DOMAIN\", \"severity\" => \"suspend\"})" \
  >&2 || fail "the domain could not be blocked"

# Lifted however this ends, and the follows re-made with it. A suspension left
# standing would silence the peer for everything that runs afterwards, and the
# failure would look like the network rather than like this scenario.
#
# The follows need saying separately because lifting the block cannot bring
# them back: suspending a domain severs them in both directions, deliberately,
# and no unblock resurrects a deleted edge. That is what used to poison every
# scenario after this one -- each reported that a post never arrived, and the
# truth was that nobody was following anybody any more (#243). Re-made here
# rather than left to the ordering, so this scenario can run anywhere.
#
# In subshells because these helpers end the scenario when they fail, which is
# right in the body and wrong in a trap that runs after the verdict is in.
lift() {
  docker compose -f "$(dirname "$0")/../compose.yml" exec -T abuuba \
    /app/bin/abuuba rpc \
    "block = Abuuba.Moderation.Domains.block_for(\"$PEER_DOMAIN\"); block && Abuuba.Moderation.Domains.unblock($moderator, block)" \
    >/dev/null 2>&1 || true

  (abuuba_follows_peer) >/dev/null 2>&1 || true
  (peer_follows_abuuba) >/dev/null 2>&1 || true
}
trap lift EXIT

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public" >/dev/null

# And the other direction, which this scenario has claimed in its first line
# since it was written and never once checked. Two things stop it: the block
# severs the follows, so the fan-out has nobody there to reach, and
# `Delivery.deliver_to/4` drops a refused host for anything that names an
# inbox directly. Both are the point -- a moderator who suspends a domain
# means it either way.
api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$outbound" --data-urlencode "visibility=public" >/dev/null

# Nothing should arrive, either way. Proving a negative needs a deadline rather
# than a poll: wait out the window once, for both.
sleep "$DEADLINE_SECONDS"

if api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/timelines/home?limit=40" | grep -q "$marker"; then
  fail "a post from a suspended domain arrived anyway"
fi

if api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/timelines/home?limit=40" | grep -q "$outbound"; then
  fail "a post went out to a suspended domain anyway"
fi

pass
