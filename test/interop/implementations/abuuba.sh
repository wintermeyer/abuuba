# How to make the abuuba account the scenarios post as.
#
# This is abuuba's own registration path, and the same one the archive-import
# smoke test uses.
#
# Both of these mark what they print and grep for the mark, rather than taking
# the last line. The runtime writes to stdout too — an SCTP library warning, on
# this machine — and `tail -1` handed that back as the token. Nothing noticed,
# because a non-empty string looks like a token until sixteen scenarios have
# failed for reasons none of them can explain.
#
# The application is created with `name`, which is what the context casts.
# `client_name` is the *API* parameter, and passing it here made the changeset
# fail, the match raise, and whatever the rpc had printed become the "token" —
# non-empty, so nothing complained, and every scenario then ran unauthenticated
# against abuuba. Fifteen of sixteen failed and none of them said why.

ABUUBA_DOMAIN=abuuba.interop
ABUUBA_URL=http://localhost:${ABUUBA_INTEROP_PORT:-4000}
ABUUBA_ACCOUNT=interop

abuuba_create_account() {
  docker compose -f "$COMPOSE" exec -T abuuba /app/bin/abuuba rpc '
    alias Abuuba.Accounts.Auth

    Abuuba.Settings.put_registration_mode(:open)

    {:ok, %{user: user, account: _account}} =
      Auth.register(
        %{
          "username" => "interop",
          "email" => "interop@abuuba.interop",
          "password" => "interop password here",
          "agreement" => "true"
        },
        rules_required: false
      )

    {:ok, user} =
      user
      |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(), approved: true)
      |> Abuuba.Repo.update()

    # Three elements: the secret comes back once, here, and is not wanted.
    {:ok, application, _secret} =
      Abuuba.OAuth.create_application(%{
        "name" => "interop",
        "redirect_uris" => "urn:ietf:wg:oauth:2.0:oob",
        "scopes" => "read write follow"
      })

    {:ok, _token, raw} = Abuuba.OAuth.issue_token(application, user, ["read", "write", "follow"])

    IO.puts("INTEROP_TOKEN=" <> raw)
  ' 2>/dev/null | grep -o 'INTEROP_TOKEN=.*' | cut -d= -f2
}

abuuba_version() {
  docker compose -f "$COMPOSE" exec -T abuuba /app/bin/abuuba rpc \
    'IO.puts("INTEROP_VERSION=" <> to_string(Application.spec(:abuuba, :vsn)))' 2>/dev/null |
    grep -o 'INTEROP_VERSION=.*' | cut -d= -f2
}
