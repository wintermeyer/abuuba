defmodule AbuubaWeb.Plugs.RequirePermission do
  @moduledoc """
  Refuses a request from somebody who may not make it.

  One plug rather than a check written into each controller, because the check
  that gets forgotten is the one written twenty times. Every admin route names
  the permission it needs and this answers it.

      plug AbuubaWeb.Plugs.RequirePermission, "manage_reports"

  A missing permission is 403 rather than 404: the person is authenticated and
  the route exists, and pretending otherwise would send an admin hunting for a
  typo in a URL that was right.
  """

  import Plug.Conn

  alias Abuuba.Roles
  alias AbuubaWeb.API
  import AbuubaWeb.Scope

  @doc false
  def init(permission) when is_binary(permission), do: permission

  @doc false
  def call(conn, permission) do
    if Roles.can?(current_user(conn), permission) do
      conn
    else
      conn
      |> API.error(403, "This action is not allowed")
      |> halt()
    end
  end
end
