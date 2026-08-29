# How to make an account on Akkoma and get a token for it.
#
# NOT WIRED UP. Akkoma is not in compose.yml because it publishes no container
# image — see the note where its services used to be. This file is kept so that
# adding it back is a matter of building the image rather than working out the
# commands again.
#
# NOT YET VERIFIED against a running instance either, for the same reason as
# GoToSocial's file. The commands are Akkoma's documented `pleroma_ctl`, which
# it inherited from Pleroma.

PEER_ID=akkoma
PEER_NAME="Akkoma"
PEER_DOMAIN=akkoma.interop
PEER_URL=http://localhost:4002
PEER_ACCOUNT=interop

peer_create_account() {
  docker compose -f "$COMPOSE" exec -T akkoma \
    ./bin/pleroma_ctl user new "$PEER_ACCOUNT" "$PEER_ACCOUNT@$PEER_DOMAIN" \
    --password 'interop-password-1' --moderator --admin -y >/dev/null 2>&1 || return 1

  local app
  app="$(curl -s -X POST "$PEER_URL/api/v1/apps" \
    -d "client_name=interop" \
    -d "redirect_uris=urn:ietf:wg:oauth:2.0:oob" \
    -d "scopes=read write follow")"

  local id secret
  id="$(echo "$app" | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)"
  secret="$(echo "$app" | grep -o '"client_secret":"[^"]*"' | cut -d'"' -f4)"

  [ -n "$id" ] || return 1

  curl -s -X POST "$PEER_URL/oauth/token" \
    -d "client_id=$id" -d "client_secret=$secret" \
    -d "redirect_uri=urn:ietf:wg:oauth:2.0:oob" \
    -d "grant_type=password" \
    -d "username=$PEER_ACCOUNT@$PEER_DOMAIN" \
    -d "password=interop-password-1" \
    -d "scope=read write follow" |
    grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

peer_version() {
  curl -s "$PEER_URL/api/v1/instance" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4
}
