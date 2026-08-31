defmodule AbuubaWeb.EmbedController do
  @moduledoc """
  One post, meant to be put in a frame on somebody else's page.

  ## A controller rather than a LiveView

  There is nothing to update. An embed is read once inside a frame on a page
  this server does not control, and a socket connecting back from there would
  be a websocket per embed on every page somebody's post appears on, for no
  behaviour at all.

  ## It is the one page that may be framed

  Everything else refuses framing, which is what stops this server's pages
  being wrapped in somebody else's chrome. An embed's whole purpose is to be
  wrapped, so this route drops that header and nothing else does.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Statuses
  alias AbuubaWeb.API.Entities

  plug :allow_framing

  def show(conn, %{"id" => id}) do
    with {number, ""} <- Integer.parse(to_string(id)),
         status when not is_nil(status) <- Statuses.readable(number, nil) do
      conn
      |> put_root_layout(false)
      |> put_layout(false)
      |> render(:show,
        status: Entities.status(status, nil),
        author: Accounts.get_account(status.account_id)
      )
    else
      _ -> raise AbuubaWeb.NotFound, "no such post"
    end
  end

  # `nil` as the viewer above is what keeps this honest: an embed is read by
  # whoever loads somebody else's page, so only what everybody may see is here.
  #
  # Said outright rather than by deleting the header: an embed that any page
  # may frame is the decision, and a missing header would read as one nobody
  # made. Everything else on this server refuses framing outright.
  defp allow_framing(conn, _opts) do
    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header("content-security-policy", "frame-ancestors *")
  end
end
