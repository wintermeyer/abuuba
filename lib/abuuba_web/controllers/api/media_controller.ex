defmodule AbuubaWeb.API.MediaController do
  @moduledoc """
  `/api/v1/media` and `/api/v2/media`.

  ## The status codes are the protocol

  A client uploads, then polls, then attaches, and it decides which of those to
  do next from the status code alone:

  * **202** from the v2 upload means "accepted, not ready" and the client polls.
  * **206** from the poll means "still working"; the body is the attachment
    without a URL, so a client can render a placeholder.
  * **200** means ready, and only then may it be attached to a post.

  Answering 200 too early is the failure that matters: the client attaches
  immediately, the post goes out, and it federates with a URL that serves
  nothing.

  ## Two upload endpoints

  v1 blocks until the upload is ready and v2 does not. Both stay because both
  are in use, and a small image finishes inside the request either way, so an
  ordinary photo post is one round trip on either.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser
  plug AbuubaWeb.Plugs.APIRateLimit, [bucket: :media] when action in [:create, :create_v2]

  plug AbuubaWeb.Plugs.RequireScopes, ["write:media"] when action in [:create, :update]

  plug AbuubaWeb.Plugs.RequireScopes, ["write:media"] when action in [:create_v2, :delete, :show]

  @doc """
  v1: answers when the upload is ready.
  """
  def create(conn, params), do: upload(conn, params, :v1)

  @doc """
  v2: answers 202 as soon as the upload is stored.
  """
  def create_v2(conn, params), do: upload(conn, params, :v2)

  defp upload(conn, params, version) do
    account = current_account(conn)

    case params["file"] do
      %Plug.Upload{} = file ->
        store(conn, account, file, params, version)

      _ ->
        API.error(conn, 422, "Validation failed: file is required")
    end
  end

  defp store(conn, account, file, params, version) do
    case Media.upload(account, Map.from_struct(file), params) do
      {:ok, attachment} ->
        answer(conn, attachment, version)

      {:error, :unsupported} ->
        API.error(conn, 422, "Validation failed: file content type is not supported")

      {:error, :too_large} ->
        API.error(conn, 422, "Validation failed: file is too large")

      {:error, :storage} ->
        API.error(conn, 500, "The file could not be stored")

      {:error, changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  # v2 says "accepted" whether or not it happened to finish, because the client
  # polls either way and a 202 it does not need to poll on costs one request.
  # v1 promised a finished upload, so a queued one is an error rather than a
  # half-answer it would attach immediately.
  defp answer(conn, attachment, :v2) do
    conn |> put_status(:accepted) |> json(Entities.media_attachment(attachment))
  end

  defp answer(conn, %Attachment{processing: :complete} = attachment, :v1) do
    json(conn, Entities.media_attachment(attachment))
  end

  defp answer(conn, _attachment, :v1) do
    API.error(conn, 422, "The file is still being processed. Use the v2 endpoint and poll.")
  end

  @doc """
  What a client polls while it waits.
  """
  def show(conn, %{"id" => id}) do
    with_own(conn, id, fn attachment ->
      if Attachment.ready?(attachment) do
        json(conn, Entities.media_attachment(attachment))
      else
        # 206 rather than 200, because a client that reads 200 attaches it and
        # posts something whose picture serves nothing.
        conn
        |> put_status(:partial_content)
        |> json(Entities.media_attachment(attachment))
      end
    end)
  end

  @doc """
  Changes the description or the focal point.
  """
  def update(conn, %{"id" => id} = params) do
    with_own(conn, id, fn attachment ->
      case Media.update_upload(attachment, params) do
        {:ok, updated} ->
          json(conn, Entities.media_attachment(updated))

        {:error, changeset} ->
          API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
      end
    end)
  end

  @doc """
  Forgets an upload nobody has posted.
  """
  def delete(conn, %{"id" => id}) do
    with_own(conn, id, fn attachment ->
      case Media.delete_upload(attachment) do
        {:ok, _} ->
          send_resp(conn, :no_content, "")

        # A picture already in a post is part of the post. Removing it here
        # would leave the post pointing at nothing and other servers holding a
        # copy we can no longer describe.
        {:error, :already_attached} ->
          API.error(
            conn,
            422,
            "Validation failed: the file has already been attached to a status"
          )
      end
    end)
  end

  # Only ever an account's own, and only while unattached. Somebody else's
  # upload is not theirs to read, rename or delete.
  defp with_own(conn, id, fun) do
    account = current_account(conn)

    case Media.get_own_unattached(account, API.id_param(%{"id" => id}, "id") || 0) do
      nil -> API.error(conn, 404, "Record not found")
      attachment -> fun.(attachment)
    end
  end
end
