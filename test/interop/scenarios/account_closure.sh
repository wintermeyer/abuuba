#!/usr/bin/env bash
# Somebody closes their account here, and the other server stops showing them.
#
# The one scenario whose failure matters outside the software. Closing an
# account promises the posts and the profile go; a `Delete` that never travels
# leaves them on servers the person has no account on and no way to reach.
#
# It runs as its own account rather than the suite's, because closing that one
# would end the run.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

stamp="$(date +%s)"
leaver="leaver$stamp"
marker="interop-closing-$stamp"

# A second local account, made the way the suite makes its first.
# The name is written into the code rather than passed as an environment
# variable. `docker compose exec -e` sets it for the process it starts, and
# `bin/abuuba rpc` evaluates in the node that is already running -- which never
# saw it. The first version read `System.get_env("USERNAME")`, got nil, and
# died on a string concatenation inside the node, where the scenario could not
# see it.
leaver_token="$(docker compose -f "$COMPOSE" exec -T abuuba /app/bin/abuuba rpc "
  {:ok, %{user: user, account: _account}} =
    Abuuba.Accounts.Auth.register(
      %{
        \"username\" => \"$leaver\",
        \"email\" => \"$leaver@abuuba.interop\",
        \"password\" => \"interop password here\",
        \"agreement\" => \"true\"
      },
      rules_required: false
    )

  {:ok, user} =
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(), approved: true)
    |> Abuuba.Repo.update()

  {:ok, application, _secret} =
    Abuuba.OAuth.create_application(%{
      \"name\" => \"closing $leaver\",
      \"redirect_uris\" => \"urn:ietf:wg:oauth:2.0:oob\",
      \"scopes\" => \"read write follow\"
    })

  {:ok, _token, raw} = Abuuba.OAuth.issue_token(application, user, [\"read\", \"write\", \"follow\"])

  IO.puts(\"LEAVER_TOKEN=\" <> raw)
" 2>>/tmp/leaver-rpc.log | grep -o 'LEAVER_TOKEN=.*' | cut -d= -f2 || true)"

# `|| true` because the grep finding nothing is a pipeline failure, and under
# `pipefail` that kills the assignment and the script with it -- before the
# check below can say what went wrong. That is how this reported "no reason
# given" the first time it ran, which is the failure this suite keeps having
# to be taught not to have.
[ -n "$leaver_token" ] ||
  fail "could not make a second account to close: $(tail -c 200 /tmp/leaver-rpc.log 2>/dev/null)"

# The peer follows them, so it has a reason to be told anything at all.
account_id="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v2/search?q=$leaver@$ABUUBA_DOMAIN&resolve=true&type=accounts&limit=1" |
  json_first_account_id)"

[ -n "$account_id" ] || fail "the peer could not resolve $leaver@$ABUUBA_DOMAIN"

api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$account_id/follow" >/dev/null

await "the peer to follow them" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/relationships?id[]=$account_id' | grep -q '\"following\":true'" ||
  fail "the peer could not follow the account that is about to close"

api "$ABUUBA_URL" "$leaver_token" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public" >/dev/null

# The control. Their post is on the other server before it is supposed to go,
# otherwise "it is not there" says nothing at all.
await "their post to arrive" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "their post never arrived, so its going away proves nothing"

docker compose -f "$COMPOSE" exec -T abuuba /app/bin/abuuba rpc "
  account = Abuuba.Accounts.lookup(\"$leaver\")
  _ = Abuuba.Accounts.Deletion.close(account)
  IO.puts(\"CLOSED\")
" >&2 || fail "abuuba would not close the account"

await "the post to go from the other server" \
  "! api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/timelines/home?limit=40' | grep -q '$marker'" ||
  fail "the account closed here and its posts are still on the other server"

pass
