defmodule AbuubaWeb.DomainListController do
  @moduledoc """
  The domain block and allow lists as files a browser saves.

  A controller rather than a LiveView event because both end in a file, and a
  socket has no response to hang `content-disposition` on.

  Behind the same permission as deciding about domains in the first place: the
  block list is a list of this server's opinions about other people's servers,
  and publishing it is the admin's decision rather than anybody who finds the
  URL.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Moderation.DomainLists
  alias Abuuba.Moderation.Domains
  alias Abuuba.Roles

  plug :require_federation_permission

  def export(conn, %{"kind" => "allows"}),
    do: send_csv(conn, "allows.csv", DomainLists.export_allows())

  # `Domains.export_csv/0`, which writes the six columns shared blocklists use
  # and which `Domains.import_csv/2` reads back. The three-column version this
  # used to send could not be imported here without landing the public comment
  # in `reject_media`: the download button and the import button have to agree
  # about the format, and they did not.
  def export(conn, %{"kind" => "blocks"}),
    do: send_csv(conn, "blocks.csv", Domains.export_csv())

  def export(conn, _params) do
    conn
    |> put_flash(:error, gettext("There is no list of that kind."))
    |> redirect(to: ~p"/admin/domain-lists")
  end

  defp send_csv(conn, filename, body) do
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, body)
  end

  defp require_federation_permission(conn, _opts) do
    if Roles.can?(conn.assigns.current_scope.user, "manage_federation") do
      conn
    else
      conn
      |> put_flash(:error, gettext("That is not something your account can do."))
      |> redirect(to: ~p"/")
      |> halt()
    end
  end
end
