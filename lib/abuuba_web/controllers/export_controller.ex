defmodule AbuubaWeb.ExportController do
  @moduledoc """
  Downloading your own data.

  Controllers rather than LiveView events, because both of these end in a file:
  a socket has no response to hang `content-disposition` on, and a browser
  needs a real request to save one.

  Both actions read only the signed-in account's own rows. An archive is that
  account's entire history in one file, so it is fetched scoped to its owner
  rather than by id — an id somebody can guess must never be an id somebody can
  download.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Exports

  @doc """
  One list, as a CSV a browser saves.
  """
  def csv(conn, %{"kind" => kind}) do
    account = Accounts.get_account(conn.assigns.current_scope.user.account_id)

    case Exports.csv(account, kind) do
      nil ->
        conn
        |> put_flash(:error, gettext("There is nothing of that kind to export."))
        |> redirect(to: ~p"/settings/export")

      body ->
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{Exports.filename(kind)}")
        )
        |> send_resp(200, body)
    end
  end

  @doc """
  The archive, once it is built.
  """
  def archive(conn, %{"id" => id}) do
    account = Accounts.get_account(conn.assigns.current_scope.user.account_id)

    with export when not is_nil(export) <- Exports.get(account, id),
         true <- Exports.downloadable?(export) do
      send_download(conn, {:file, export.path}, filename: export.filename)
    else
      _ ->
        conn
        |> put_flash(:error, gettext("That archive is not there any more. Ask for a new one."))
        |> redirect(to: ~p"/settings/export")
    end
  end
end
