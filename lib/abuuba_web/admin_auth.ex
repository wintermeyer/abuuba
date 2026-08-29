defmodule AbuubaWeb.AdminAuth do
  @moduledoc """
  The same permission check, for a LiveView.

      on_mount: [{AbuubaWeb.AdminAuth, {:require, "manage_reports"}}]
      on_mount: [{AbuubaWeb.AdminAuth, {:require_any, ~w(view_dashboard manage_users)}}]

  It has to be the same answer the API gives. Two implementations of "may this
  person see the reports queue" is one implementation and one bug, and the bug
  is always in the surface nobody is looking at.
  """

  use AbuubaWeb, :verified_routes

  import Phoenix.LiveView

  alias Abuuba.Roles
  import AbuubaWeb.Scope

  @doc false
  def on_mount({:require, permission}, params, session, socket) do
    on_mount({:require_any, [permission]}, params, session, socket)
  end

  # The admin area is one surface with sections needing different permissions,
  # so getting in asks whether the person may use any of them. Which sections
  # they see, and may reach by typing the address, is asked again per section:
  # a link that answers "not allowed" is a worse answer than no link.
  def on_mount({:require_any, permissions}, _params, _session, socket) do
    user = current_user(socket)

    if Enum.any?(permissions, &Roles.can?(user, &1)) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "That is not something your account can do.")
       |> redirect(to: ~p"/")}
    end
  end
end
