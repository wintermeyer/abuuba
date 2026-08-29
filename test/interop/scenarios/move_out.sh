#!/usr/bin/env bash
# abuuba's own migration is honoured by the peer: its follower moves too.
#
# The mirror of `move`, and the half that needs no implementation driver --
# abuuba is the origin, and abuuba is ours to script. That is also what lets this
# run against Mastodon, whose own migrations cannot be triggered over an API:
# here Mastodon only has to *receive* a Move, which every implementation does
# automatically.
#
# The origin and target are throwaway abuuba accounts, so nothing that lives
# past this scenario has moved. The peer's main account ends up following the
# target, which is inert residue: later scenarios name their own accounts.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

stamp="$(date +%s)"
wanderer="wanderer$stamp"
settled="settled$stamp"

# Two local accounts, made the way account_closure makes its one.
make_abuuba_account() {
  docker compose -f "$COMPOSE" exec -T abuuba /app/bin/abuuba rpc "
    {:ok, %{user: user, account: _account}} =
      Abuuba.Accounts.Auth.register(
        %{
          \"username\" => \"$1\",
          \"email\" => \"$1@abuuba.interop\",
          \"password\" => \"interop password here\",
          \"agreement\" => \"true\"
        },
        rules_required: false
      )

    {:ok, _user} =
      user
      |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(), approved: true)
      |> Abuuba.Repo.update()

    IO.puts(\"made\")
  " | grep -q made
}

make_abuuba_account "$wanderer" || fail "could not make the origin account"
make_abuuba_account "$settled" || fail "could not make the target account"

# The peer follows the origin. A Move only carries the followers it finds.
answer="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v2/search?q=$wanderer@$ABUUBA_DOMAIN&resolve=true&type=accounts&limit=1")"
wanderer_on_peer="$(echo "$answer" | json_first_account_id)"

[ -n "$wanderer_on_peer" ] ||
  fail "the peer could not resolve $wanderer@$ABUUBA_DOMAIN; it answered $(echo "$answer" | head -c 200)"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$wanderer_on_peer/follow" >/dev/null

await "the peer to be following the origin" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/relationships?id[]=$wanderer_on_peer' | grep -q '\"following\":true'" ||
  fail "the peer could not follow the origin, so there is nothing for the Move to move"

# The consent half: the target names the origin as its former self. Through
# the same context the settings page uses, because that is the path a person
# takes.
docker compose -f "$COMPOSE" exec -T abuuba /app/bin/abuuba rpc "
  target = Abuuba.Accounts.get_account_by_handle(\"$settled\", nil)

  {:ok, _} =
    target
    |> Ecto.Changeset.change(also_known_as: [\"https://$ABUUBA_DOMAIN/users/$wanderer\"])
    |> Abuuba.Repo.update()

  origin = Abuuba.Accounts.get_account_by_handle(\"$wanderer\", nil)
  {:ok, _} = Abuuba.Accounts.Migration.move(origin, \"$settled@$ABUUBA_DOMAIN\")

  IO.puts(\"moved\")
" | grep -q moved || fail "abuuba refused its own migration; the raw log says why"

# The peer hears the Move, fetches the target, and moves its follower. The
# resolve is awaited rather than asked once: right after a Move the peer may
# still be mid-fetch of the target, and a search in that window truthfully
# answers nothing. It did exactly that once -- solo runs passed and the full
# run failed here, which is the signature of a race, not of a defect.
resolve_settled() {
  settled_answer="$(api "$PEER_URL" "$PEER_TOKEN" \
    GET "/api/v2/search?q=$settled@$ABUUBA_DOMAIN&resolve=true&type=accounts&limit=1")"
  settled_on_peer="$(echo "$settled_answer" | json_first_account_id)"

  [ -n "$settled_on_peer" ]
}

await "the peer to resolve the move target" resolve_settled ||
  fail "the peer could not resolve the move target; it last answered $(echo "${settled_answer:-nothing}" | head -c 200)"

# Both halves, because following the new account alone would also be true of
# a server that follows every Move target it hears about.

await "the peer's follower to arrive at the target" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/relationships?id[]=$settled_on_peer' | grep -q '\"following\":true'" ||
  fail "the peer did not honour abuuba's Move"

await "the old follow to be gone on the peer" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/relationships?id[]=$wanderer_on_peer' | grep -q '\"following\":false'" ||
  fail "the peer follows both ends of abuuba's migration"

pass
