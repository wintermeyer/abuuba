defmodule AbuubaWeb.MediaProxyController do
  @moduledoc """
  Serves another server's picture from this one.

  ## Why a reader's address is not another server's business

  A timeline of twenty posts from twelve servers, rendered with the origin
  URLs, is twelve servers learning the reader's IP address, their browser, and
  which posts they looked at and when. None of them has any business knowing
  that: the reader chose to be here, not there. Fetched through this server,
  each of those becomes one request from a machine that was going to fetch it
  anyway.

  ## Fetched once, then it is ours

  The first request pulls the file through the ordinary outbound layer — the
  same SSRF guards, the same circuit breaker, the same timeouts as everything
  else this server fetches — and writes it where local attachments live.
  Everything after that is served off disk, and the existing vacuum drops it on
  the admin's retention policy exactly as it drops any other cached remote
  media. There is no second cache with its own rules to reason about.

  ## What it will not proxy

  Anything whose stored record is not a remote attachment. The id names a row
  this server already has, so the proxy can only ever be pointed at a URL this
  server had already decided to accept — an open proxy is what you get when the
  URL comes from the request instead.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Storage
  alias AbuubaWeb.API
  alias AbuubaWeb.Plugs.APIRateLimit

  @styles ~w(original small)

  def show(conn, %{"id" => id, "style" => style}) when style in @styles do
    case attachment(id) do
      %Attachment{} = attachment -> serve(conn, attachment, String.to_existing_atom(style))
      _ -> not_found(conn)
    end
  end

  def show(conn, _params), do: not_found(conn)

  # Parsed before it reaches a query. This route is open to anybody, so a path
  # segment that is not an id has to be a 404 rather than a cast error anybody
  # passing by can raise.
  defp attachment(id) do
    case API.parse_id(id) do
      nil -> nil
      parsed -> Media.get_attachment(parsed)
    end
  end

  defp serve(conn, attachment, style) do
    key = Storage.key_for(attachment, style)

    if stored?(key) do
      send_stored(conn, attachment, key)
    else
      fetch_and_serve(conn, attachment, style, key)
    end
  end

  defp stored?(nil), do: false
  defp stored?(key), do: Storage.exists?(key)

  # The counted path. Every miss here is a request to somebody else's server at
  # the pace of whoever is asking, and the proxy can be pointed at any remote
  # attachment this server holds -- so one address naming a thousand of them in
  # turn is a thousand fetches. Only misses are counted: a reader on a busy
  # timeline of pictures already on this disk never reaches this branch.
  defp fetch_and_serve(conn, attachment, style, key) do
    case APIRateLimit.call(conn, :media_proxy) do
      %Plug.Conn{halted: true} = refused -> refused
      counted -> perform_fetch(counted, attachment, style, key)
    end
  end

  defp perform_fetch(conn, attachment, style, key) do
    # `Media.cache_remote/2` is the one thing that fetches somebody else's
    # picture onto this server, so the proxy and `mix abuuba.media refresh` agree
    # about what may be fetched and where it lands.
    case Media.cache_remote(attachment, style) do
      :already -> send_stored(conn, attachment, key)
      {:ok, body} -> send_body(conn, attachment, body)
      # Not this server's failure to explain. A picture that will not come is a
      # picture that is not there as far as the reader is concerned.
      {:error, _reason} -> not_found(conn)
    end
  end

  defp send_stored(conn, attachment, key) do
    case Storage.local_path(key) do
      nil ->
        redirect(conn, external: Storage.url(key))

      path ->
        conn |> cache_headers(attachment) |> send_file(200, path)
    end
  end

  defp send_body(conn, attachment, body) do
    conn |> cache_headers(attachment) |> send_resp(200, body)
  end

  # A year, and immutable. The id names one file that never changes: a new
  # picture is a new attachment with a new id, so there is nothing a shorter
  # life could ever catch.
  defp cache_headers(conn, attachment) do
    conn
    |> put_resp_content_type(content_type(attachment))
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    # Somebody else's file served from this origin. Nothing here should ever be
    # read as a page, whatever the bytes turn out to be.
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp content_type(%Attachment{file_content_type: type}) when is_binary(type) and type != "",
    do: type

  defp content_type(_attachment), do: "application/octet-stream"

  defp not_found(conn), do: send_resp(conn, 404, "")
end
