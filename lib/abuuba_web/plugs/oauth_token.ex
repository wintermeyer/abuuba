defmodule AbuubaWeb.Plugs.OAuthToken do
  @moduledoc """
  Reads the bearer token off an API request and puts it on the connection.

  Only reads it. Deciding whether a given token may reach a given endpoint is
  `require_scopes/2`'s job, so that an endpoint which forgets to declare its
  scopes fails closed rather than inheriting whatever the last one wanted.
  """

  import Plug.Conn

  alias Abuuba.OAuth

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    token = conn |> bearer_token() |> OAuth.get_token()

    conn
    |> assign(:current_token, token)
    |> assign(:current_scope, %{user: token && token.user})
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      ["bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end
end
