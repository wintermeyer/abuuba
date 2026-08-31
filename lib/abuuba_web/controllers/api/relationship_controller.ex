defmodule AbuubaWeb.API.RelationshipController do
  @moduledoc """
  The lists a client shows in its settings: who you have blocked, who you have
  muted, which domains you have blocked, and who is waiting to follow you.

  Every one of these is an account's own. They are scoped to whoever is signed
  in rather than checked afterwards, so a query cannot return a stranger's row
  in the first place.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Relationships
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.Pagination

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:blocks"] when action in [:block_domain, :unblock_domain]

  plug AbuubaWeb.Plugs.RequireScopes, ["write:follows"] when action in [:authorize, :reject]
  plug AbuubaWeb.Plugs.RequireScopes, ["read:follows"] when action in [:follow_requests]
  plug AbuubaWeb.Plugs.RequireScopes, ["read:blocks"] when action in [:blocks, :domain_blocks]

  plug AbuubaWeb.Plugs.RequireScopes, ["read:mutes"] when action in [:mutes]

  def blocks(conn, params) do
    account = current_account(conn)

    accounts(conn, account, Relationships.blocked_accounts(account, Pagination.params(params)))
  end

  def mutes(conn, params) do
    account = current_account(conn)
    muted = Relationships.muted_accounts(account, Pagination.params(params))
    expiries = Relationships.mute_expiries(account, Enum.map(muted, & &1.id))

    # An account, plus the one thing that is true of it only here: when this
    # mute lifts itself. A client offering "mute for an hour" had nothing to
    # show afterwards, because the answer never said.
    rendered =
      muted
      |> Entities.accounts(account)
      |> Enum.zip(muted)
      |> Enum.map(fn {payload, muted_account} ->
        Map.put(payload, "mute_expires_at", timestamp(expiries[muted_account.id]))
      end)

    conn
    |> Pagination.put_link_header(muted)
    |> json(rendered)
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  def follow_requests(conn, params) do
    account = current_account(conn)

    accounts(conn, account, Relationships.pending_followers(account, Pagination.params(params)))
  end

  @doc """
  Which domains this account has silenced entirely.
  """
  def domain_blocks(conn, params) do
    account = current_account(conn)

    json(conn, Relationships.blocked_domains(account, Pagination.params(params)))
  end

  def block_domain(conn, params) do
    case params["domain"] do
      domain when is_binary(domain) and domain != "" ->
        {:ok, _} = Relationships.block_domain(current_account(conn), domain)

        json(conn, %{})

      _ ->
        API.error(conn, 422, "Validation failed: domain is required")
    end
  end

  def unblock_domain(conn, params) do
    Relationships.unblock_domain(current_account(conn), params["domain"] || "")

    json(conn, %{})
  end

  @doc """
  Letting somebody follow a locked account.
  """
  def authorize(conn, %{"id" => id}) do
    answer_request(conn, id, &Relationships.accept_follow_request/1)
  end

  @doc """
  Turning them down.
  """
  def reject(conn, %{"id" => id}) do
    answer_request(conn, id, &Relationships.reject_follow_request/1)
  end

  # The request is looked up by the pair rather than by its own id, because
  # that is the id a client holds: the accounts endpoint answers with accounts,
  # so `/follow_requests/:id/authorize` names the person, not the request.
  defp answer_request(conn, id, fun) do
    account = current_account(conn)
    follower_id = API.parse_id(id)

    case follower_id && Relationships.get_follow_request(follower_id, account) do
      nil ->
        API.error(conn, 404, "Record not found")

      request ->
        fun.(request)

        json(conn, Entities.relationship(Relationships.relationship(account, follower_id)))
    end
  end

  defp accounts(conn, viewer, list) do
    conn
    |> Pagination.put_link_header(list)
    |> json(Entities.accounts(list, viewer))
  end
end
