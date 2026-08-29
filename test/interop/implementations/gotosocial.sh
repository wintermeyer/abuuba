# How to make an account on GoToSocial and get a token for it.
#
# When a step fails, what it said is kept in `results/raw/gotosocial-setup.log`
# — the runner captures this function's stderr — and the implementation is
# reported as skipped rather than as sixteen failures that all mean the same
# thing. Nothing here discards output on the way to a `return 1`: the previous
# version did, and "could not make an account" was the whole of what a reader
# got for a flow that had never worked.

PEER_ID=gotosocial
PEER_NAME="GoToSocial"
PEER_DOMAIN=gotosocial.interop
PEER_URL=http://localhost:${GOTOSOCIAL_INTEROP_PORT:-8080}
PEER_ACCOUNT=interop
PEER_PASSWORD='interop-password-1'

# Every request carries the headers the rest of the suite sends, for the same
# reasons: the server answers to the domain it was configured with, and it
# builds its own URLs from the forwarded scheme.
#
# The session cookie is carried by hand rather than in a cookie jar. GoToSocial
# is configured with `GTS_PROTOCOL: https`, because that is the scheme it must
# advertise to federate at all, so it marks its session cookie `Secure` -- and
# curl will not store, let alone send, a Secure cookie over the plain http port
# this talks to. The jar stayed empty, the consent step ran signed out, and it
# redirected with no code and no explanation. Reading `Set-Cookie` off the
# response and echoing it back is the same exchange without curl's rule about
# which scheme it happened on.
gts_curl() {
  local args=(-s -H "Host: $PEER_DOMAIN" -H "X-Forwarded-Proto: https")

  [ -n "${gts_cookie:-}" ] && args+=(-H "Cookie: $gts_cookie")

  curl "${args[@]}" -D "$gts_headers" "$@"
}

# Whatever the last response set, ready for the next request.
gts_keep_cookie() {
  local set
  set="$(grep -i '^set-cookie:' "$gts_headers" |
    sed 's/^[Ss]et-[Cc]ookie: //;s/;.*//' | paste -sd'; ')"

  [ -n "$set" ] && gts_cookie="$set"

  return 0
}

# The whole dance for one named account: create, confirm, register an app,
# sign in, consent, exchange the code. Parameterised because the move scenario
# needs two throwaway accounts made exactly the way the main one is.
gts_account() {
  local username="$1"

  gts_headers="$(mktemp)"
  gts_cookie=""
  trap 'rm -f "$gts_headers"' RETURN

  docker compose -f "$COMPOSE" exec -T gotosocial \
    /gotosocial/gotosocial admin account create \
    --username "$username" \
    --email "$username@$PEER_DOMAIN" \
    --password "$PEER_PASSWORD" >&2 || return 1

  docker compose -f "$COMPOSE" exec -T gotosocial \
    /gotosocial/gotosocial admin account confirm --username "$username" >&2 || true

  # An app to be a client of, which is the one part the previous version got
  # right.
  local app id secret
  app="$(gts_curl -X POST "$PEER_URL/api/v1/apps" \
    -d "client_name=interop" \
    -d "redirect_uris=urn:ietf:wg:oauth:2.0:oob" \
    -d "scopes=read write follow")"

  id="$(echo "$app" | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)"
  secret="$(echo "$app" | grep -o '"client_secret":"[^"]*"' | cut -d'"' -f4)"

  if [ -z "$id" ] || [ -z "$secret" ]; then
    echo "registering an app failed: $app" >&2
    return 1
  fi

  # Then the authorization-code flow, driven by the sign-in form.
  #
  # Not the password grant. GoToSocial does not implement it -- it answers
  # `unsupported_grant_type` and names the two it does support, authorization
  # code and client credentials -- and this adapter asked for it anyway on the
  # stated grounds that there was no other way to mint a token. There was.
  # Client credentials would have been no use either: that gives a token for
  # the application and there is no account behind it, and every scenario here
  # acts as somebody.
  #
  # Four steps: ask to authorize, which redirects to a sign-in; sign in, which
  # sets the session cookie and redirects back; ask again, which now answers
  # with a consent form; and post the consent, which redirects to the
  # out-of-band page with the code in the query string.
  gts_curl -o /dev/null "$PEER_URL/oauth/authorize?response_type=code&client_id=$id&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=read+write+follow"
  gts_keep_cookie

  local signed_in
  signed_in="$(gts_curl -o /dev/null -w '%{http_code}' -X POST "$PEER_URL/auth/sign_in" \
    -d "username=$username@$PEER_DOMAIN" \
    -d "password=$PEER_PASSWORD")"

  gts_keep_cookie

  case "$signed_in" in
    30*) : ;;
    *)
      echo "signing in answered $signed_in rather than a redirect" >&2
      return 1
      ;;
  esac

  gts_curl -o /dev/null "$PEER_URL/oauth/authorize"

  local granted code
  granted="$(gts_curl -o /dev/null -w '%{redirect_url}' -X POST "$PEER_URL/oauth/authorize")"
  code="$(echo "$granted" | grep -o 'code=[^&]*' | cut -d= -f2)"

  if [ -z "$code" ]; then
    echo "granting consent redirected to '$granted', which carries no code" >&2
    return 1
  fi

  local token
  token="$(gts_curl -X POST "$PEER_URL/oauth/token" \
    -d "client_id=$id" -d "client_secret=$secret" \
    -d "redirect_uri=urn:ietf:wg:oauth:2.0:oob" \
    -d "grant_type=authorization_code" \
    -d "code=$code" |
    grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)"

  if [ -z "$token" ]; then
    echo "the code could not be exchanged for a token" >&2
    return 1
  fi

  echo "$token"
}

peer_create_account() {
  gts_account "$PEER_ACCOUNT"
}

# The two halves of driving a real migration, split so the scenario can put
# abuuba's follow between them: a Move only moves the followers that exist when
# it happens.
#
# GoToSocial is the implementation that makes this scriptable at all -- it has
# an API for the alias and one for the move, where Mastodon's migration lives
# behind a web form with no API. That asymmetry is why the scenario asks the
# implementation for these functions instead of assuming them.
# Sets four globals rather than printing anything: the scenario calls this in
# its own process, because the tokens have to still exist when
# `peer_trigger_move` runs. A subshell would take them with it.
peer_prepare_move() {
  MOVE_ORIGIN=mover
  MOVE_TARGET=landed
  MOVE_ORIGIN_TOKEN="$(gts_account "$MOVE_ORIGIN")" || return 1
  MOVE_TARGET_TOKEN="$(gts_account "$MOVE_TARGET")" || return 1

  # GoToSocial creates accounts locked, the same reason run.sh unlocks the
  # main one: a locked origin leaves abuuba's follow pending forever, and a
  # locked target would do the same to the follows the Move carries over.
  api "$PEER_URL" "$MOVE_ORIGIN_TOKEN" PATCH "/api/v1/accounts/update_credentials" \
    --data-urlencode "locked=false" >&2 || return 1
  api "$PEER_URL" "$MOVE_TARGET_TOKEN" PATCH "/api/v1/accounts/update_credentials" \
    --data-urlencode "locked=false" >&2 || return 1
}

peer_trigger_move() {
  # The consent half first: the target names the origin as its former self.
  api "$PEER_URL" "$MOVE_TARGET_TOKEN" POST "/api/v1/accounts/alias" \
    --data-urlencode "also_known_as_uris=https://$PEER_DOMAIN/users/$MOVE_ORIGIN" >&2 || return 1

  # Then the origin moves. The password is the account's own: a migration is
  # the one action GoToSocial refuses on a token alone.
  api "$PEER_URL" "$MOVE_ORIGIN_TOKEN" POST "/api/v1/accounts/move" \
    --data-urlencode "password=$PEER_PASSWORD" \
    --data-urlencode "moved_to_uri=https://$PEER_DOMAIN/users/$MOVE_TARGET" >&2 || return 1
}

peer_version() {
  curl -s -H "Host: $PEER_DOMAIN" -H "X-Forwarded-Proto: https" \
    "$PEER_URL/api/v1/instance" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4
}
