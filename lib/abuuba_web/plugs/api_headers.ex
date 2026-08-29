defmodule AbuubaWeb.Plugs.APIHeaders do
  @moduledoc """
  Cross-origin access, and the headers a browser is allowed to read.

  The API is open to any origin on purpose. Every token is a bearer token sent
  in an `Authorization` header, never a cookie, so a page on another origin
  reading this API can only do so with a token its user gave it. Restricting
  origins would stop nothing an attacker cannot already do with a plain HTTP
  client, and would break every web client anybody writes.

  ## Exposing headers is not optional

  A browser hides every response header from JavaScript except a short safe
  list, so a web client that cannot read `Link` cannot page, and one that
  cannot read `X-RateLimit-Reset` cannot back off. Those are functional
  requirements rather than niceties, which is why they are named here.

  ## Ahead of the router, not in a pipeline

  A pipeline only runs once a route has matched, so a 404 or a 500 on an API
  path would carry none of this and a browser client would see an opaque
  network error rather than the answer. Running here also means a preflight can
  be answered without a route to match: a browser asks with `OPTIONS` against a
  path that may only answer `POST`.

  ## Vary: Authorization

  The same URL answers differently depending on who is asking, and a cache that
  does not know that will serve one person's home timeline to the next. `Origin`
  is in there for the same reason one step removed: the allow-origin header is
  echoed from the request, so a cache ignoring it would hand one site's response
  to another.
  """

  import Plug.Conn

  @behaviour Plug

  @exposed "Link, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset, X-Request-Id, Mastodon-Async-Refresh"
  @allowed_headers "Authorization, Content-Type, Idempotency-Key, X-Requested-With"
  @allowed_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  @preflight_max_age "86400"

  @impl Plug
  def init(opts), do: opts

  # Everything a program rather than a browser tab talks to. The HTML pages are
  # deliberately absent: they are same-origin, and a page that any site could
  # read cross-origin is a page whose CSRF protection has stopped meaning
  # anything.
  @paths ["/api", "/oauth", "/.well-known", "/nodeinfo"]

  @impl Plug
  def call(conn, _opts) do
    if api_path?(conn), do: apply_headers(conn), else: conn
  end

  defp api_path?(%Plug.Conn{request_path: path}) do
    Enum.any?(@paths, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  defp apply_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", origin(conn))
    |> put_resp_header("access-control-expose-headers", @exposed)
    |> put_resp_header("vary", "Authorization, Origin")
    |> answer_preflight()
  end

  # A preflight carries no token, so it must not reach an endpoint behind
  # authentication: that endpoint would refuse it and the browser would never
  # send the real request.
  defp answer_preflight(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn
    |> put_resp_header("access-control-allow-methods", @allowed_methods)
    |> put_resp_header("access-control-allow-headers", @allowed_headers)
    |> put_resp_header("access-control-max-age", @preflight_max_age)
    |> send_resp(:no_content, "")
    |> halt()
  end

  defp answer_preflight(conn), do: conn

  # Echoed rather than `*` where an origin was sent, so that the same handling
  # works for a client that sets `credentials: "include"`; `*` is rejected by
  # browsers in that case.
  defp origin(conn) do
    case get_req_header(conn, "origin") do
      [origin | _] -> origin
      [] -> "*"
    end
  end
end
