# Shared by every scenario.
#
# Each scenario is a small shell script that drives real HTTP between two real
# servers and exits 0 or 1. These are the parts every one of them needs: making
# an account somewhere, waiting for something to arrive, and saying what
# happened in a form the runner can collect.
#
# Waiting is polling with a deadline rather than a fixed sleep. Federation is
# asynchronous on every implementation and a sleep long enough to be reliable
# on a slow machine makes the suite take an hour on a fast one.

export LC_ALL=C

# How long anything is given to arrive. Generous: a cold Sidekiq on a laptop
# takes seconds to pick up its first job, and a scenario that fails because the
# machine was busy teaches nobody anything.
#
# Raised from 60 after two scenarios failed once each and passed on the next
# run -- `media` waiting for a post and `block` waiting for the one it sends
# before blocking. Nothing about either was wrong; the suite has grown, both
# servers are busier while it runs, and a delivery that is retried with a
# backoff can take longer than a minute to arrive on a machine doing other
# work. A flaky suite is worse than a slow one: it teaches people that a red
# line means nothing.
DEADLINE_SECONDS="${DEADLINE_SECONDS:-120}"

say() { printf '    %s\n' "$1" >&2; }

fail() {
  # The reason goes to stdout as JSON, because the runner collects it into the
  # report and "it failed" is not something anybody can act on.
  printf '{"outcome":"fail","reason":"%s"}\n' "$1"
  exit 1
}

pass() {
  printf '{"outcome":"pass"}\n'
  exit 0
}

# Polls until the command succeeds or the deadline passes.
#
#   await "the post to arrive" 'curl -s ... | grep -q hello'
await() {
  local what="$1"
  local command="$2"
  local waited=0

  while [ "$waited" -lt "$DEADLINE_SECONDS" ]; do
    if eval "$command" >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
    waited=$((waited + 1))
  done

  say "gave up waiting for $what after ${DEADLINE_SECONDS}s"
  delivery_state
  peer_state
  proxy_state "$command"

  return 1
}

# What the proxy in front of both servers saw, which is the only place that
# knows whether a request was made at all.
#
# The two queue reports say what each server believes it did. This says what
# crossed between them, which is the third answer neither of them can give: a
# delivery abuuba recorded as completed and the proxy never logged is a different
# bug from one the proxy logged and the peer did nothing with.
#
# Read live from the container rather than from `results/raw/proxy.log`, which
# is written during teardown and therefore either absent or left over from the
# run before.
proxy_state() {
  local command="$1"
  local marker

  # Every scenario's marker is `interop-<something>-<stamp>`, and it is in the
  # command the await was polling with. Naming it turns "some deliveries
  # happened" into "this post did or did not cross".
  marker="$(printf '%s' "$command" | grep -oE 'interop-[a-z_-]+-[0-9]+' | head -1)"

  if [ -n "$marker" ]; then
    say "proxy: requests carrying $marker"
    docker compose -f "$COMPOSE" logs --no-color --tail 2000 proxy 2>/dev/null |
      grep -F "$marker" | tail -5 | while read -r line; do
      say "  ${line:0:200}"
    done
  fi

  say "proxy: last deliveries either way"
  docker compose -f "$COMPOSE" logs --no-color --tail 2000 proxy 2>/dev/null |
    grep -E 'POST /(users/[^/ ]+/)?inbox' | tail -5 | while read -r line; do
    say "  ${line:0:200}"
  done

  return 0
}

# The other server's queues, where it can be asked.
#
# Whose slowness a red line is takes both halves. abuuba's side says whether its
# deliveries completed; when they have -- and on the one occurrence since this
# was instrumented, thirteen had, all on the first attempt -- the post was sent
# and the question is what the peer did with it.
#
# Implementations define `peer_queue_state` if they can answer. GoToSocial has
# no equivalent to ask, so it says so rather than printing nothing and leaving
# a reader to wonder whether the queue was empty.
peer_state() {
  if command -v peer_queue_state >/dev/null 2>&1 || declare -F peer_queue_state >/dev/null; then
    peer_queue_state 2>/dev/null | while read -r line; do
      say "$line"
    done
  else
    say "peer queues: $PEER_NAME cannot be asked"
  fi

  return 0
}

# What abuuba's delivery queue is doing, printed whenever an await gives up.
#
# "The post never arrived" has three quite different causes and one message:
# nothing was ever queued, something was queued and is still being retried, or
# it was delivered and the other server did nothing with it. Only the second
# is a matter of waiting, and the difference decides whether a red line is a
# defect or a deadline.
#
# It matters because the retry schedule is `attempt^4 + 15` seconds: a
# delivery that fails twice is roughly fifty seconds from its third attempt,
# and three failures put it past two minutes. A scenario that gives up at that
# point has found a slow retry rather than a lost post, and should say so.
delivery_state() {
  docker compose -f "$COMPOSE" exec -T abuuba /app/bin/abuuba rpc '
    import Ecto.Query

    rows =
      Abuuba.Repo.all(
        from j in "oban_jobs",
          where: j.queue == "push",
          group_by: [j.state],
          select: {j.state, count(j.id)}
      )

    IO.puts("delivery queue: " <> inspect(rows))

    last =
      Abuuba.Repo.one(
        from j in "oban_jobs",
          where: j.queue == "push" and j.attempt > 0,
          order_by: [desc: j.id],
          limit: 1,
          select: %{attempt: j.attempt, state: j.state, errors: fragment("array_length(?, 1)", j.errors)}
      )

    IO.puts("newest delivery: " <> inspect(last))
  ' 2>/dev/null | grep -E "delivery queue:|newest delivery:" | while read -r line; do
    say "$line"
  done

  return 0
}

# The peer following the abuuba account, which most of the scenarios need before
# anything they do is observable: a post reaches a home timeline because
# somebody follows its author, and a scenario that assumes an earlier one left
# that follow behind fails for a reason that has nothing to do with what it
# tests. Nine of them read "the post never arrived" for exactly that -- four
# because they run before `follow_in` alphabetically, and five because `move`
# migrates the peer account out from under them.
#
# Idempotent, and cheap when the follow is already there: the follow endpoint
# answers the current relationship either way.
# abuuba following the peer, which some scenarios need in the other direction.
#
# What reaches an account is what its server was told about, and servers differ
# on who that is. Mastodon delivers a reply and a boost to the author of the
# post being replied to or boosted, whether or not they follow; GoToSocial
# delivers to followers, so a scenario asserting on abuuba's side saw nothing
# arrive and read it as abuuba failing to understand what never came.
#
# A mutual follow is what two accounts talking to each other look like anyway,
# and it lets both implementations answer the same question.
abuuba_follows_peer() {
  local handle="$PEER_ACCOUNT@$PEER_DOMAIN"
  local account_id answer

  answer="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" \
    GET "/api/v2/search?q=$handle&resolve=true&type=accounts&limit=1")"
  account_id="$(echo "$answer" | json_first_account_id)"

  [ -n "$account_id" ] ||
    fail "abuuba could not resolve $handle; it answered $(echo "$answer" | head -c 200)"

  api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$account_id/follow" >/dev/null

  await "abuuba to be following $handle" \
    "api '$ABUUBA_URL' '$ABUUBA_TOKEN' GET '/api/v1/accounts/relationships?id[]=$account_id' | grep -q '\"following\":true'" ||
    fail "abuuba could not follow $handle, so nothing this checks could arrive"

  # The other half, and the mirror of the one `peer_follows_abuuba` learned in
  # #243. "following: true" above is abuuba's own bookkeeping; what decides
  # whether a post is ever sent this way is the follower row on the *peer*,
  # because the peer is the side doing the delivering. Between abuuba recording
  # the follow and the peer processing the Follow there is a window, and a
  # scenario that posts from the peer inside it gets nothing and blames the
  # feature it was testing -- `block` reported "nothing from them arrived even
  # before the block" from exactly this.
  peer_sees_follower && return 0

  api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$account_id/unfollow" >/dev/null
  api "$ABUUBA_URL" "$ABUUBA_TOKEN" POST "/api/v1/accounts/$account_id/follow" >/dev/null

  await "the peer to have abuuba as a follower" peer_sees_follower ||
    fail "abuuba believes it follows $handle and the peer has no such follower"
}

# Whether the peer has the follower row abuuba believes in. The mirror of
# `abuuba_sees_follower`, asked of the peer about abuuba's account, for the same
# reason: a relationship has two ends and only one of them decides whether
# anything is delivered.
peer_sees_follower() {
  local answer id

  answer="$(api "$PEER_URL" "$PEER_TOKEN" \
    GET "/api/v2/search?q=$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN&resolve=true&type=accounts&limit=1")"
  id="$(echo "$answer" | json_first_account_id)"

  [ -n "$id" ] || return 1

  api "$PEER_URL" "$PEER_TOKEN" GET "/api/v1/accounts/relationships?id[]=$id" |
    grep -q '"followed_by":true'
}

peer_follows_abuuba() {
  local handle="$ABUUBA_ACCOUNT@$ABUUBA_DOMAIN"
  local account_id answer

  answer="$(api "$PEER_URL" "$PEER_TOKEN" \
    GET "/api/v2/search?q=$handle&resolve=true&type=accounts&limit=1")"
  account_id="$(echo "$answer" | json_first_account_id)"

  # What the peer actually said. A whole phase once failed with eleven
  # scenarios all reporting that this account could not be resolved, and the
  # next identical run was green -- so the interesting thing is not that it
  # failed but what the answer was: an error, an empty list, or an account
  # with no id. Without it the three are the same sentence.
  [ -n "$account_id" ] ||
    fail "the peer could not resolve $handle; it answered $(echo "$answer" | head -c 200)"

  api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$account_id/follow" >/dev/null

  await "the peer to be following $handle" \
    "api '$PEER_URL' '$PEER_TOKEN' GET '/api/v1/accounts/relationships?id[]=$account_id' | grep -q '\"following\":true'" ||
    fail "the peer could not follow $handle, so nothing this checks could arrive"

  # Both halves, and this is the half that was missing. "following: true" is
  # the peer's own bookkeeping, and after abuuba has severed a follow -- which
  # suspending a domain does, in both directions -- the peer still believes it
  # follows and will not send a Follow it thinks it has already sent. The
  # request above then costs nothing, abuuba has no follower row, and the
  # scenario walks into its assertions with a precondition that is green and
  # untrue. That is where "the post never arrived" came from (#243): there was
  # no delivery to make, so abuuba's queue was empty and innocent.
  #
  # So ask abuuba as well, and if the edge is missing here, make the peer let go
  # of the follow it believes in before asking for it again.
  abuuba_sees_follower && return 0

  api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$account_id/unfollow" >/dev/null
  api "$PEER_URL" "$PEER_TOKEN" POST "/api/v1/accounts/$account_id/follow" >/dev/null

  await "abuuba to have the peer as a follower" abuuba_sees_follower ||
    fail "the peer believes it follows $handle and abuuba has no such follower"
}

# Whether abuuba has the follower row the peer believes in. Asked of abuuba, about
# the peer's account, because a relationship has two ends and only one of them
# decides whether anything is delivered.
abuuba_sees_follower() {
  local answer id

  answer="$(api "$ABUUBA_URL" "$ABUUBA_TOKEN" \
    GET "/api/v2/search?q=$PEER_ACCOUNT@$PEER_DOMAIN&resolve=true&type=accounts&limit=1")"
  id="$(echo "$answer" | json_first_account_id)"

  [ -n "$id" ] || return 1

  api "$ABUUBA_URL" "$ABUUBA_TOKEN" GET "/api/v1/accounts/relationships?id[]=$id" |
    grep -q '"followed_by":true'
}

# The Mastodon client API, which GoToSocial and Akkoma also implement. Using it
# rather than each server's own admin interface is what keeps the scenarios
# readable, and it is the same API a real client would use.
# Two headers beyond the obvious, both about talking to a production server
# over plain HTTP on a published port.
#
# `Host`, because a server may only answer to the domain it was configured
# with: Mastodon puts LOCAL_DOMAIN and WEB_DOMAIN in `config.hosts` and Rails
# answers 403 to anything else, so every request to `localhost:3111` was
# refused before it reached a controller.
#
# `X-Forwarded-Proto`, because production forces SSL and redirects http to
# https — to a domain with no TLS in front of it, so the scenario followed a
# redirect to nowhere. This is what a reverse proxy would send, and it is how
# the server is meant to be run.
api() {
  local base="$1"
  local token="$2"
  local method="$3"
  local path="$4"
  shift 4

  curl -s -X "$method" "$base$path" \
    -H "Host: $(domain_for "$base")" \
    -H "X-Forwarded-Proto: https" \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/json" \
    "$@"
}

# Which server a base URL belongs to. The scenarios reach both over localhost
# on different ports, and the name each one answers to is the one it was
# configured with.
domain_for() {
  case "$1" in
    "${ABUUBA_URL:-abuuba-url-unset}"*) echo "${ABUUBA_DOMAIN:-localhost}"; return ;;
  esac

  if [ "$1" = "${ABUUBA_URL:-}" ]; then
    echo "${ABUUBA_DOMAIN:-localhost}"
  else
    echo "${PEER_DOMAIN:-localhost}"
  fi
}

# The ActivityPub document at an address, signed the way an authorized-fetch
# server insists on. Unsigned first: a server that does not require a signature
# should answer either way, and finding out which is one of the scenarios.
fetch_ap() {
  # The same two headers `api` sends, and for the same reasons. Without the
  # Host, Mastodon answers `Blocked hosts: localhost:3111` from its own host
  # authorization and the scenario reads that as the collection not answering.
  curl -s -H 'Accept: application/activity+json' \
    -H "Host: $(domain_for "$1")" \
    -H "X-Forwarded-Proto: https" "$1"
}

# A top-level field of a JSON object on stdin.
#
#   echo "$posted" | json_field . id
#
# Parsed rather than grepped. The grep this replaces took the first `"id":`
# anywhere in the document, and JSON key order is not a promise: Mastodon
# serialises a status with `id` first, abuuba does not, so the same line read the
# status id from one server and the *account's* id from the other. Every
# scenario that then acted on "the post" was acting on an account.
# The id of the item in a JSON array whose text contains a marker.
#
#   api ... GET /api/v1/timelines/home | json_id_containing "$marker"
#
# Finding a post in a timeline by the words in it, which is how every scenario
# identifies the thing it just made on the other side. The line this replaces
# split the document on commas and grepped two lines either side of the marker,
# which found whichever `"id"` happened to be nearby.
json_id_containing() {
  python3 -c '
import json, sys

try:
    items = json.load(sys.stdin)
except ValueError:
    sys.exit(0)

marker = sys.argv[1]

for item in items if isinstance(items, list) else []:
    if marker in json.dumps(item):
        print(item.get("id", ""))
        break
' "$1"
}

# The first account in a search result.
#
#   api ... GET "/api/v2/search?q=...&resolve=true" | json_first_account_id
json_first_account_id() {
  python3 -c '
import json, sys

try:
    document = json.load(sys.stdin)
except ValueError:
    sys.exit(0)

accounts = document.get("accounts") or []

if accounts:
    print(accounts[0].get("id", ""))
'
}

# The id of the poll on the post carrying a marker, or nothing when the post
# arrived without one -- which is a result the caller has to be able to tell
# apart from the post not arriving at all.
json_poll_id() {
  python3 -c '
import json, sys

try:
    items = json.load(sys.stdin)
except ValueError:
    sys.exit(0)

marker = sys.argv[1]

for item in items if isinstance(items, list) else []:
    if marker in json.dumps(item):
        poll = item.get("poll") or {}
        print(poll.get("id", ""))
        break
' "$1"
}

# A field of a field: `json_subfield quote id` reads the id of the quote on a
# status, and prints nothing when the status has no quote -- which is a
# different answer from a quote with no id, and the caller usually wants to
# tell those apart.
json_subfield() {
  python3 -c '
import json, sys

try:
    document = json.load(sys.stdin)
except ValueError:
    sys.exit(0)

if isinstance(document, list):
    document = document[0] if document else {}

inner = document.get(sys.argv[1])

if isinstance(inner, dict):
    value = inner.get(sys.argv[2])

    if value is not None:
        print(value)
' "$1" "$2"
}

json_field() {
  python3 -c '
import json, sys

try:
    document = json.load(sys.stdin)
except ValueError:
    sys.exit(0)

if isinstance(document, list):
    document = document[0] if document else {}

value = document.get(sys.argv[1])

if value is not None:
    print(value)
' "$2"
}
