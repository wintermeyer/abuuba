#!/usr/bin/env bash
# The interop suite, one command.
#
#   test/interop/run.sh                 every implementation
#   test/interop/run.sh mastodon        one of them
#
# Publishes on 4000, 3000 and 8080; set ABUUBA_INTEROP_PORT, MASTODON_INTEROP_PORT
# or GOTOSOCIAL_INTEROP_PORT where those are taken.
#
# Brings up abuuba and every implementation whose image can be pulled on one
# Docker network, makes an account on each, runs every scenario that applies,
# writes a matrix, and tears everything down. Needs Docker and nothing else.
#
# It takes a while. Several servers and their databases, and every scenario
# waits for real asynchronous delivery.
#
# An implementation whose image cannot be pulled is reported as skipped and the
# rest still run. Somebody else's registry having a bad day is not an abuuba
# defect and must not read like one.
set -uo pipefail

export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export COMPOSE="$here/compose.yml"

results="$here/results"
raw="$results/raw"

only="${1:-}"

# The scenarios to run, in order. `INTEROP_SCENARIOS` narrows it to a
# space-separated list of names, which is how one failing scenario is looked at
# without waiting for the other fifteen. Most of them assume the follow that
# `follow_in` sets up, so name that one too rather than wondering why a post
# reached nobody.
#
# Some of them change something the others stand on and so run last, whatever
# the alphabet says: `move` migrates the peer's account and takes its follows
# with it, `account_closure` deletes an account the peer knows about.
#
# `domain_block` is here for a reason that took two full runs to separate from
# the first one. It severed the follows and left them severed (#243), and it
# restores them itself now -- but that was only half of what it left behind.
# While the block stands, abuuba refuses the peer's deliveries, and the peer does
# not shrug that off: Mastodon marks the jobs failed and retries them on a
# backoff measured in minutes, so the next scenario waits on a server that has
# decided to wait too. The give-up report says `retrying: 3` and the post is
# nowhere. Nothing on this side can undo that, which is exactly the case the
# rule allows for -- so it runs last, and the reason is the peer's clock rather
# than our own state.
LAST_SCENARIOS="account_closure block domain_block move_out move"

scenario_paths() {
  if [ -n "${INTEROP_SCENARIOS:-}" ]; then
    for name in $INTEROP_SCENARIOS; do printf '%s\n' "$here/scenarios/$name.sh"; done
    return
  fi

  local name applicable

  # Which of them apply to this server, asked of the list that already knows.
  # `applies_to` used to be read only when the report was written, so every
  # scenario ran against every implementation and a feature a peer does not
  # have came out as a failure -- `pin` against GoToSocial, which answers
  # `unhandled object type: Add` in its own log. If the question cannot be
  # asked, everything runs, which is what happened before and is no worse.
  applicable="$(mix abuuba.interop --scenarios-for "$1" 2>/dev/null || true)"

  for scenario in "$here"/scenarios/*.sh; do
    name="$(basename "$scenario" .sh)"

    if [ -n "$applicable" ]; then
      case " $(echo "$applicable" | tr '\n' ' ') " in
        *" $name "*) : ;;
        *) continue ;;
      esac
    fi

    case " $LAST_SCENARIOS " in
      *" $name "*) : ;;
      *) printf '%s\n' "$scenario" ;;
    esac
  done

  for name in $LAST_SCENARIOS; do
    [ -f "$here/scenarios/$name.sh" ] && printf '%s\n' "$here/scenarios/$name.sh"
  done

  return 0
}

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "This needs $1." >&2; exit 1; }
}

say "Checking what is here"
require docker
docker info >/dev/null 2>&1 || {
  echo "The Docker daemon is not reachable. On Linux you may need to be in the docker group." >&2
  exit 1
}

# What there is to test against, and which containers each one needs. Kept here
# rather than in the implementation files because the runner has to know it
# before sourcing anything: it decides what to start.
IMPLEMENTATIONS=(mastodon gotosocial)

# The proxy comes up with abuuba because every server in the stack is reached
# through it: the aliases the peers resolve point at it, not at the
# applications.
ABUUBA_SERVICES=(abuuba proxy)

# The containers to start for each. Their databases are not listed because
# compose starts what a service depends on; sidekiq is, because Mastodon does
# not depend on its own worker and nothing federates without it.
services_of() {
  case "$1" in
    mastodon) echo "mastodon mastodon-sidekiq" ;;
    gotosocial) echo "gotosocial" ;;
    *) echo "" ;;
  esac
}

# The service whose image decides whether the implementation can run at all.
main_service_of() {
  services_of "$1" | awk '{print $1}'
}

# Every image an implementation needs, asked of compose rather than written
# down again here: `config --images <service>` answers with the service's own
# image and its dependencies'. A pin bumped in compose.yml and not here would
# otherwise mean this checks one tag while the run pulls another.
images_of() {
  docker compose -f "$COMPOSE" config --images "$1" 2>/dev/null
}

# Made before anything starts, because the proxy mounts them and every
# container mounts the authority that signed them.
say "Making the certificates the stack talks over"
bash "$here/tls/generate.sh"

mkdir -p "$raw"
: >"$raw/results.txt"
: >"$raw/versions.txt"

cleanup() {
  # Kept before the containers go, because what the proxy refused is often the
  # only record of why a scenario saw nothing: every request between two
  # servers passes through it, and a delivery that never arrived left its
  # trace here rather than in either application.
  if [ -d "$raw" ]; then
    docker compose -f "$COMPOSE" logs --no-color proxy >"$raw/proxy.log" 2>&1 || true

    # And each server's own. The proxy says a delivery was refused; only the
    # server that refused it says why, and by the time anybody reads the
    # report the containers are gone.
    for service in abuuba mastodon mastodon-sidekiq gotosocial; do
      docker compose -f "$COMPOSE" logs --no-color --tail 400 "$service" \
        >"$raw/$service-server.log" 2>&1 || true
    done
  fi

  # Left standing on request. A dropped activity leaves its reason in a
  # database rather than in a log -- whether the row exists at all is the
  # difference between a peer refusing a document and a peer filing it
  # somewhere nobody looked -- and by the time the report is read the only
  # copy of that database has been deleted.
  if [ -n "${INTEROP_KEEP:-}" ]; then
    say "Leaving everything up, because INTEROP_KEEP is set. Take it down with:"
    say "  docker compose -f $COMPOSE down -v --remove-orphans"
    return
  fi

  say "Tearing down"
  docker compose -f "$COMPOSE" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Every image, resolved before anything is started. A third-party registry
# going away is not an abuuba defect, but it used to read like one: an image that
# cannot be pulled fails `compose up` for every service at once, so abuuba's own
# never started either and the run ended with no report — no Mastodon result,
# no GoToSocial result, nothing to look at but a red tick.
#
# `docker manifest inspect` asks the registry without downloading anything, so
# this costs seconds and turns "the suite is broken" into "that one is skipped".
available=()
for implementation in "${IMPLEMENTATIONS[@]}"; do
  if [ -n "$only" ] && [ "$only" != "$implementation" ]; then
    continue
  fi

  missing=""

  while read -r image; do
    [ -n "$image" ] || continue

    docker manifest inspect "$image" >/dev/null 2>&1 || missing="$image"
  done <<<"$(images_of "$(main_service_of "$implementation")")"

  if [ -z "$missing" ]; then
    available+=("$implementation")
  else
    say "$implementation cannot be pulled ($missing) — skipping it"
    echo "SKIP $implementation image-unavailable" >>"$raw/results.txt"
  fi
done

services=("${ABUUBA_SERVICES[@]}")
for implementation in "${available[@]}"; do
  read -r -a peer_services <<<"$(services_of "$implementation")"
  services+=("${peer_services[@]}")
done

# A port already in use fails the bind three layers into compose's output,
# which is not an answer anybody reads. The suite publishes on the host so the
# scenarios can drive it from here, and 3000 and 8080 are ordinary things for a
# working machine to be using — 4000 doubly so, because it is abuuba's own dev
# port and `mix phx.server` is what you are most likely to have running while
# working on federation.
port_of() {
  case "$1" in
    abuuba) echo "${ABUUBA_INTEROP_PORT:-4000}" ;;
    mastodon) echo "${MASTODON_INTEROP_PORT:-3000}" ;;
    gotosocial) echo "${GOTOSOCIAL_INTEROP_PORT:-8080}" ;;
  esac
}

variable_of() {
  case "$1" in
    abuuba) echo "ABUUBA_INTEROP_PORT" ;;
    mastodon) echo "MASTODON_INTEROP_PORT" ;;
    gotosocial) echo "GOTOSOCIAL_INTEROP_PORT" ;;
  esac
}

taken=0
for name in abuuba "${available[@]}"; do
  port="$(port_of "$name")"

  # The descriptor is opened inside a subshell and goes with it, so there is
  # nothing to close afterwards. Emphatically not `exec 3<&- 2>/dev/null`:
  # `exec` carrying only redirections applies them to the shell itself, for
  # good, and that one silences every message this check exists to print.
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo "Port $port is in use, and $name needs it. Set $(variable_of "$name") to another one." >&2
    taken=1
  fi
done

if [ "$taken" -eq 1 ]; then
  echo "For example: ABUUBA_INTEROP_PORT=4100 MASTODON_INTEROP_PORT=3100 $0" >&2
  exit 1
fi

say "Starting ${#services[@]} containers"

if ! docker compose -f "$COMPOSE" up -d --build "${services[@]}"; then
  echo "Could not start the containers." >&2
  exit 1
fi

# Waiting on each one's own idea of being ready rather than on a fixed sleep:
# Mastodon migrates on boot and Akkoma compiles its config, and both are slow
# the first time and fast afterwards.
wait_for() {
  local name="$1" url="$2" host="$3" waited=0

  while [ "$waited" -lt 300 ]; do
    # `-f` so a 403 is not "up". Mastodon answers 403 to a host it was not
    # configured for, which made a server refusing every request look ready and
    # pushed the failure into the scenarios, where it read as sixteen protocol
    # disagreements.
    if curl -s -f -o /dev/null --max-time 3 \
      -H "Host: $host" -H "X-Forwarded-Proto: https" "$url"; then
      say "$name is up"
      return 0
    fi

    sleep 2
    waited=$((waited + 2))
  done

  say "$name never came up"

  return 1
}

source "$here/implementations/abuuba.sh"

wait_for abuuba "$ABUUBA_URL/api/v1/instance" "$ABUUBA_DOMAIN" || exit 1

say "Making the abuuba account"
ABUUBA_TOKEN="$(abuuba_create_account)"
export ABUUBA_TOKEN ABUUBA_URL ABUUBA_DOMAIN ABUUBA_ACCOUNT

[ -n "$ABUUBA_TOKEN" ] || { echo "Could not make an account on abuuba." >&2; exit 1; }

# That it is a token, not merely a non-empty string. A failed rpc prints
# something, `tail -1` takes it, and a bogus token is indistinguishable from a
# good one until every scenario has failed for reasons none of them can
# explain — which is exactly what happened, for as long as this suite has
# existed.
if ! curl -s -o /dev/null -f -H "Host: $ABUUBA_DOMAIN" -H "X-Forwarded-Proto: https" \
  -H "Authorization: Bearer $ABUUBA_TOKEN" \
  "$ABUUBA_URL/api/v1/accounts/verify_credentials"; then
  echo "The abuuba token does not authenticate. It was: $ABUUBA_TOKEN" >&2
  exit 1
fi

echo "abuuba $(abuuba_version)" >>"$raw/versions.txt"

# One implementation at a time. They are independent, and running them in
# sequence means a report that says which one was being talked to when
# something went wrong.
for implementation in "${available[@]}"; do
  say "Against $implementation"

  # shellcheck disable=SC1090
  source "$here/implementations/$implementation.sh"

  # Scenarios run as child shells, and a function is not inherited the way an
  # environment variable is. This one is asked for when an await gives up, to
  # say whether the other server is the slow half, so it has to reach them.
  declare -F peer_queue_state >/dev/null && export -f peer_queue_state
  export PEER_ID PEER_NAME PEER_DOMAIN PEER_URL PEER_ACCOUNT

  if ! wait_for "$PEER_NAME" "$PEER_URL/api/v1/instance" "$PEER_DOMAIN"; then
    echo "SKIP $implementation server-never-started" >>"$raw/results.txt"
    continue
  fi

  echo "$PEER_NAME $(peer_version)" >>"$raw/versions.txt"

  # Kept, not discarded. Every command in an implementation file ends in
  # `2>/dev/null` so its noise stays out of the matrix, which means a failure
  # to make an account used to leave nothing at all to read — and both of these
  # files carried a comment saying they had never been verified against a
  # running instance, which nobody could have done.
  PEER_TOKEN="$(peer_create_account 2>>"$raw/$implementation-setup.log")"
  export PEER_TOKEN

  # The same check for the peer: a token that does not work turns into sixteen
  # failures that all mean "not signed in" and say something else.
  if [ -n "$PEER_TOKEN" ] &&
    ! curl -s -o /dev/null -f -H "Host: $PEER_DOMAIN" -H "X-Forwarded-Proto: https" \
      -H "Authorization: Bearer $PEER_TOKEN" \
      "$PEER_URL/api/v1/accounts/verify_credentials"; then
    say "The $PEER_NAME token does not authenticate"
    echo "the token did not authenticate" >>"$raw/$implementation-setup.log"
    PEER_TOKEN=""
  fi

  if [ -z "$PEER_TOKEN" ]; then
    # Reported once, as a skipped implementation, rather than as sixteen
    # scenario failures that all mean the same thing.
    say "Could not make an account on $PEER_NAME; see $raw/$implementation-setup.log"
    echo "SKIP $implementation could-not-make-an-account" >>"$raw/results.txt"
    continue
  fi

  # The peer's account has to accept a follow without somebody approving it.
  #
  # GoToSocial creates one locked -- `manuallyApprovesFollowers` is true on a
  # fresh account -- so abuuba's Follow correctly became a request that nobody
  # was ever going to answer, and three scenarios reported that as abuuba being
  # unable to follow. Mastodon creates them unlocked, so this changes nothing
  # there.
  #
  # `follow_locked` is the scenario that tests the other case, and it locks the
  # abuuba account itself rather than relying on the peer's default.
  curl -s -o /dev/null -X PATCH "$PEER_URL/api/v1/accounts/update_credentials" \
    -H "Host: $PEER_DOMAIN" \
    -H "X-Forwarded-Proto: https" \
    -H "Authorization: Bearer $PEER_TOKEN" \
    --data-urlencode "locked=false" || true

  # Each server serves its own actor once, asked from here, before the other
  # server ever asks for it.
  #
  # Not a nicety. Mastodon fetches the signer's key to verify a signature, and
  # wraps that fetch in a breaker whose threshold is one failure and whose
  # cool-off is five minutes (`STOPLIGHT_THRESHOLD` in
  # signature_verification.rb). abuuba builds its instance actor and its RSA key
  # on the first request that asks for it, so the first fetch of `/actor` is
  # also the slowest one -- and when that first fetch is Mastodon's, it times
  # out, the breaker opens, and for the next five minutes every signed request
  # abuuba makes is refused with "Fetching attempt skipped because of recent
  # connection failure". One 499 in the proxy log, and an entire run of
  # authorized-fetch scenarios reporting that abuuba cannot federate at all.
  #
  # Paying that cost from here costs a second and is charged to nobody's
  # breaker.
  for pair in "$ABUUBA_DOMAIN|$ABUUBA_URL/actor" "$PEER_DOMAIN|$PEER_URL/users/$PEER_ACCOUNT"; do
    curl -s -o /dev/null --max-time 30 \
      -H "Host: ${pair%%|*}" \
      -H "X-Forwarded-Proto: https" \
      -H "Accept: application/activity+json" "${pair#*|}" || true
  done

  for scenario in $(scenario_paths "$implementation"); do
    name="$(basename "$scenario" .sh)"

    printf '  %-20s ' "$name"

    output="$(bash "$scenario" 2>>"$raw/$implementation-$name.log")"
    status=$?

    outcome="$(echo "$output" | grep -o '"outcome":"[^"]*"' | cut -d'"' -f4)"
    reason="$(echo "$output" | grep -o '"reason":"[^"]*"' | cut -d'"' -f4)"

    # A skip exits 0, like a pass, and used to be printed as one -- so a
    # scenario that decided it could say nothing here was reported as having
    # proved something. `move` has skipped that way since it was written, and
    # the report has been counting it.
    if [ "$status" -ne 0 ]; then
      printf 'FAIL %s\n' "${reason:-no reason given}"
      echo "FAIL $name $implementation ${reason:-no reason given}" >>"$raw/results.txt"
    elif [ "$outcome" = "skip" ]; then
      printf 'skip %s\n' "${reason:-no reason given}"
      echo "SKIP_SCENARIO $name $implementation ${reason:-no reason given}" >>"$raw/results.txt"
    else
      printf 'pass\n'
      echo "PASS $name $implementation" >>"$raw/results.txt"
    fi
  done
done

say "Writing the matrix"
mix abuuba.interop --raw "$raw" --out "$results/report.md"

say "Done: $results/report.md"

# A failing scenario fails the run, which is what makes this useful on a
# schedule: a green run is a green run and a red one gets looked at.
#
# A skipped implementation does not, because somebody else's registry is not a
# abuuba defect — but a run where *everything* was skipped tested nothing at all,
# and reporting that as green is the quietest way for this suite to stop being
# worth having.
# Nothing measured is not a pass. A skipped implementation does not fail the
# run, because somebody else's registry is not an abuuba defect — but if that
# leaves no scenario actually run, the suite has proved nothing and saying so
# is the whole of its job. This is wider than the image check above on purpose:
# an implementation that pulled and started and then could not be logged into
# is skipped too, and a run of nothing but those used to exit 0.
if ! grep -qE '^(PASS|FAIL) ' "$raw/results.txt"; then
  echo "Nothing was tested: every implementation was skipped. See $raw for why." >&2
  exit 1
fi

! grep -q '^FAIL ' "$raw/results.txt"
