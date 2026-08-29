defmodule AbuubaWeb.API.DirectoryController do
  @moduledoc """
  Ways of finding somebody you do not already follow.

  All three answer with accounts, and all three deliberately answer with fewer
  than a client might expect. A directory of everybody a server has ever heard
  of is a directory of the fediverse rather than of this instance, and nobody
  on another server agreed to appear in ours.
  """

  use AbuubaWeb, :controller

  plug AbuubaWeb.Plugs.RequireUser
       when action in [:endorsements, :suggestions, :suggestions_v2, :dismiss_suggestion]

  plug AbuubaWeb.Plugs.RequireScopes, ["write:accounts"] when action in [:dismiss_suggestion]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["read:accounts"] when action in [:endorsements, :suggestions, :suggestions_v2]

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Suggestions
  alias Abuuba.Relationships
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.Pagination

  @doc """
  Accounts here that asked to be listed.
  """
  def index(conn, params) do
    viewer = current_account(conn)

    accounts =
      Accounts.directory(
        limit: API.limit(params, 40, 80),
        offset: offset(params),
        order: params["order"]
      )

    json(conn, Entities.accounts(accounts, viewer))
  end

  @doc """
  Who a client might suggest following: the accounts the reader's own follows
  follow.

  See `Abuuba.Accounts.Suggestions` for why that signal and no other.
  """
  def suggestions(conn, params) do
    account = current_account(conn)

    json(conn, Entities.accounts(suggested(account, params), account))
  end

  @doc """
  The same, wrapped the way a newer client expects.

  Each entry says where the suggestion came from, so a client can show "you
  follow people who follow them" rather than an unexplained face.
  """
  def suggestions_v2(conn, params) do
    account = current_account(conn)

    entries =
      account
      |> suggested(params)
      |> Enum.map(
        &%{
          "source" => "past_interactions",
          "sources" => ["friends_of_friends"],
          "account" => Entities.account(&1, account)
        }
      )

    json(conn, entries)
  end

  @doc """
  Stops suggesting somebody.

  Remembered rather than only removed from this answer: the list is computed
  on every request, so a dismissal nobody wrote down lasts until the column
  reloads and the button reads as broken.
  """
  def dismiss_suggestion(conn, %{"id" => id}) do
    :ok = Suggestions.dismiss(current_account(conn), API.parse_id(id))

    json(conn, %{})
  end

  defp suggested(account, params) do
    Suggestions.for_account(account,
      limit: API.limit(params, 40, 80),
      offset: offset(params)
    )
  end

  @doc """
  Accounts the reader has put on their own profile as worth following.

  Somebody else's are read from their profile; this one is yours, which is why
  it needs a token and takes no id.
  """
  def endorsements(conn, params) do
    account = current_account(conn)

    endorsed =
      Relationships.endorsements(account, Pagination.params(params, default: 40, max: 80))

    conn
    |> Pagination.put_link_header(endorsed)
    |> json(Entities.accounts(endorsed, account))
  end

  defp offset(params) do
    case Integer.parse(to_string(Map.get(params, "offset", "0"))) do
      {number, _rest} when number > 0 -> number
      _ -> 0
    end
  end
end
