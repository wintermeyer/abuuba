#!/usr/bin/env bash
# A report forwarded from the other server reaches this one's moderators.
#
# The mirror of `report_forwarding`, which checks the report abuuba sends. This
# is the one it receives, and moderation is the part of the protocol where
# silence is worst: a Flag that abuuba drops means somebody on another server
# reported abuse here, was told it had been passed on, and no moderator here
# ever saw it. Nobody finds that out by using the software.
#
# Asked of abuuba's database over rpc rather than through the admin API: the
# account this suite makes has ordinary scopes, and widening them for one
# scenario would change what every other scenario is running as.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

marker="interop-reported-$(date +%s%N)"

# Something to report. The report names the account and the post, which is
# what a real one carries.
posted="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/statuses" \
  --data-urlencode "status=$marker" --data-urlencode "visibility=public")"

status_uri="$(echo "$posted" | json_field . uri)"

[ -n "$status_uri" ] || fail "abuuba would not make the post to be reported"

abuuba_handle="$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"

await "the peer to see the post" \
  "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v2/search?q=$status_uri&resolve=true&type=statuses&limit=1' | grep -q '$marker'" ||
  fail "the peer never saw the post, so it has nothing to report"

abuuba_on_peer="$(api "$PEER_URL" "$PEER_TOKEN" \
  GET "/api/v2/search?q=$abuuba_handle&resolve=true&type=accounts&limit=1" | json_first_account_id)"

[ -n "$abuuba_on_peer" ] || fail "the peer could not resolve $abuuba_handle"

# `forward=true` is the part that makes this federate at all: without it the
# report stays on the peer and is nobody else's business.
filed="$(api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/reports" \
  --data-urlencode "account_id=$abuuba_on_peer" \
  --data-urlencode "comment=$marker" \
  --data-urlencode "forward=true")"

echo "$filed" | grep -q '"id"' ||
  fail "the peer would not file the report: $(echo "$filed" | head -c 200)"

# Asked of abuuba itself. A report that arrived is a row a moderator can read;
# the comment is what ties it to this run rather than to any other report the
# suite may have left behind.
reported() {
  docker compose -f "$COMPOSE" exec -T abuuba /app/bin/abuuba rpc "
    import Ecto.Query

    count =
      Abuuba.Repo.aggregate(
        from(r in \"reports\", where: r.comment == \"$marker\"),
        :count
      )

    IO.puts(\"REPORTS=\" <> to_string(count))
  " 2>/dev/null | grep -q "REPORTS=[1-9]"
}

await "the report to reach abuuba's moderators" reported ||
  fail "the Flag never arrived, so a report from another server was lost here"

pass
