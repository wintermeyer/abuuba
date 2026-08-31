defmodule AbuubaWeb.MediaController do
  @moduledoc """
  The page a media address lands on, and the player an embed uses.

  A URL that points at a picture is shared, pasted and followed like any other
  link, and until now this server answered one with nothing. `/media/:id` sends
  the reader to the post the file belongs to, which is where the picture has
  its caption, its author and its thread — everything that makes it mean
  something. A file on its own is the least useful version of itself.

  `/media/:id/player` is the same file with nothing around it, for an embed. It
  is framed by other sites on purpose, which is exactly why it carries nothing
  of this server: no session, no navigation, and a policy that stops it being
  read as a page.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Statuses
  alias AbuubaWeb.API

  @doc """
  Sends a media link to the post it belongs to.
  """
  def show(conn, %{"id" => id}) do
    with %Attachment{status_id: status_id} when not is_nil(status_id) <- attachment(id),
         %{account: %{username: username}} = status <-
           Statuses.readable(status_id, nil) |> Abuuba.Repo.preload(:account) do
      redirect(conn, to: ~p"/@#{username}/#{status.id}")
    else
      # A file with no post is a file nobody can see in context, and there is
      # nothing honest to show instead.
      _ -> conn |> put_status(:not_found) |> text("")
    end
  end

  @doc """
  The bare file, for something else to frame.
  """
  def player(conn, %{"id" => id}) do
    case attachment(id) do
      %Attachment{} = attachment -> render_player(conn, attachment)
      _ -> conn |> put_status(:not_found) |> text("")
    end
  end

  defp render_player(conn, attachment) do
    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:player, attachment: attachment, page_title: attachment.description || "")
  end

  defp attachment(id) do
    case API.parse_id(id) do
      nil -> nil
      parsed -> Media.get_attachment(parsed)
    end
  end
end
