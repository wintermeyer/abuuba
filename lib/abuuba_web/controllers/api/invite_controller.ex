defmodule AbuubaWeb.API.InviteController do
  @moduledoc """
  `/api/v1/invites`: the codes one account has issued.

  Scoped to whoever is asking rather than to the server. An invite carries the
  name of the person who wrote it, and a list of everybody's would tell one
  moderator who else is vouching for whom, which is not what the permission
  grants.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Invites
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["read:accounts"] when action in [:index]
  plug AbuubaWeb.Plugs.RequireScopes, ["write:accounts"] when action in [:create, :delete]

  def index(conn, _params) do
    json(conn, conn |> current_account() |> Invites.list() |> Enum.map(&Entities.invite/1))
  end

  def create(conn, params) do
    case Invites.create(current_account(conn), params) do
      {:ok, invite} -> json(conn, Entities.invite(invite))
      {:error, :not_allowed} -> API.error(conn, 403, "This action is not allowed")
      {:error, _changeset} -> API.error(conn, 422, "That invite could not be saved")
    end
  end

  def delete(conn, %{"id" => id}) do
    account = current_account(conn)

    with invite when not is_nil(invite) <- Invites.get(account, id),
         :ok <- Invites.delete(account, invite) do
      json(conn, %{})
    else
      {:error, :not_yours} -> API.error(conn, 403, "This action is not allowed")
      _ -> API.error(conn, 404, "Record not found")
    end
  end
end
