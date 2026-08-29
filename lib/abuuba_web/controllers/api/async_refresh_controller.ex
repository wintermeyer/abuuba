defmodule AbuubaWeb.API.AsyncRefreshController do
  @moduledoc """
  `GET /api/v1_alpha/async_refreshes/:id`, how far along work a client is
  waiting on has got.

  A refresh belongs to the account that started it and is only readable by it.
  Mastodon signs the id instead; abuuba scopes the read, which needs no key
  management and refuses a guessed id for the same reason.
  """

  use AbuubaWeb, :controller

  alias Abuuba.AsyncRefreshes
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser

  # The child scope and not the umbrella `read`: coverage runs downwards
  # only, so a token holding `read:accounts` satisfies nothing spelled
  # `read`, and asking for the umbrella would refuse every narrow token.
  plug AbuubaWeb.Plugs.RequireScopes, ["read:accounts"] when action in [:show]

  def show(conn, %{"id" => id}) do
    case AsyncRefreshes.get(current_account(conn), id) do
      nil -> API.error(conn, 404, "Record not found")
      refresh -> json(conn, Entities.async_refresh(refresh))
    end
  end
end
