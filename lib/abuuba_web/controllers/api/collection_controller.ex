defmodule AbuubaWeb.API.CollectionController do
  @moduledoc """
  The lists of posts somebody has kept: favourites, bookmarks, and the
  conversations column.

  All three are paged on the mark rather than on the post. What a client walks
  is the order things were saved in, not the order they were written, and a
  post favourited today that was written last year belongs at the top.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Conversations
  alias Abuuba.Statuses
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.Pagination

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["read:favourites"] when action in [:favourites]
  plug AbuubaWeb.Plugs.RequireScopes, ["read:bookmarks"] when action in [:bookmarks]
  plug AbuubaWeb.Plugs.RequireScopes, ["read:statuses"] when action in [:conversations]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:conversations"]
       when action in [:read_conversation, :unread_conversation, :delete_conversation]

  def favourites(conn, params) do
    account = current_account(conn)
    marks = Statuses.favourites(account, Pagination.params(params, default: 20, max: 40))

    render_page(conn, marks, account)
  end

  def bookmarks(conn, params) do
    account = current_account(conn)
    marks = Statuses.bookmarks(account, Pagination.params(params, default: 20, max: 40))

    render_page(conn, marks, account)
  end

  @doc """
  Direct exchanges, one line each.

  A conversation rather than a post, because twenty messages back and forth is
  one conversation somebody is having and not twenty things to read.
  """
  def conversations(conn, params) do
    account = current_account(conn)
    rows = Conversations.list(account, Pagination.params(params, default: 20))

    conn
    |> Pagination.put_link_header(rows, cursor: & &1.last_status_id)
    |> json(Entities.conversations(rows, account))
  end

  @doc """
  Marking one read.

  Answered rather than refused even where nothing is stored yet: a client marks
  a conversation read as soon as somebody opens it, and a 404 would show them an
  error for having read their own messages.
  """
  def read_conversation(conn, %{"id" => id}) do
    account = current_account(conn)

    case Conversations.mark_read(account, id) do
      {:ok, row} -> json(conn, Entities.conversation(row, account))
      # Answered rather than refused: a client marks a conversation read as
      # soon as somebody opens it, and racing a delete should not show them an
      # error for having read their own messages.
      {:error, :not_found} -> json(conn, %{})
    end
  end

  def unread_conversation(conn, %{"id" => id}) do
    account = current_account(conn)

    case Conversations.mark_unread(account, id) do
      {:ok, row} -> json(conn, Entities.conversation(row, account))
      {:error, :not_found} -> json(conn, %{})
    end
  end

  def delete_conversation(conn, %{"id" => id}) do
    :ok = Conversations.remove(current_account(conn), id)

    json(conn, %{})
  end

  # The Link header pages by the mark's id, not the post's: the list walks
  # the order things were saved in, and a post-id cursor from a different id
  # sequence would hand a client the same page forever.
  defp render_page(conn, marks, account) do
    conn
    |> Pagination.put_link_header(marks, cursor: & &1.mark_id)
    |> json(Entities.statuses(Enum.map(marks, & &1.status), account))
  end
end
