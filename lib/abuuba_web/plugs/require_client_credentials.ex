defmodule AbuubaWeb.Plugs.RequireClientCredentials do
  @moduledoc """
  Refuses a request that is not the application acting as itself.

  One endpoint needs this: signing somebody up. An app creating an account has
  no person to act on behalf of yet, and a token that does have one behind it
  would be one person's session making another person's account.

  The status codes are the reference implementation's. No token at all is a
  401, because there is nothing to act on; a user token is a 403, because the
  credential is real and simply the wrong kind, and a client that got a 401
  there would throw away a token that works.
  """

  alias Abuuba.OAuth.AccessToken
  alias AbuubaWeb.API

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.assigns[:current_token] do
      %AccessToken{user_id: nil} ->
        conn

      %AccessToken{} ->
        # The reference implementation's wording, grammar and all: clients
        # show this string to developers and some match on it.
        API.error(conn, 403, "This method requires an client credentials authentication")

      _ ->
        API.error(conn, 401, "The access token is invalid")
    end
  end
end
