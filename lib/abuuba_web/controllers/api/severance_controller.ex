defmodule AbuubaWeb.API.SeveranceController do
  @moduledoc """
  `/api/v1/severed_relationships`.

  What this server's own moderation decisions cost one account. The
  notification that arrives at the time says something was lost; this is where
  a client goes to say what, and it is the only place that can, because the
  accounts on the other side have already been cut off.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Moderation.Domains
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["read:accounts"] when action in [:index]

  def index(conn, _params) do
    account = current_account(conn)

    events =
      account
      |> Domains.severance_summary()
      |> Enum.map(&Entities.severance_event/1)

    json(conn, events)
  end
end
