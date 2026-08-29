defmodule AbuubaWeb.Plugs.RateLimit do
  @moduledoc """
  Slows down repeated attempts against the endpoints worth guessing at.

      plug AbuubaWeb.Plugs.RateLimit, bucket: "login", limit: 10, window_ms: 60_000

  Counted per client address. That is a blunt instrument behind a shared NAT,
  which is why the limits here are set where a person could not plausibly reach
  them and a script reaches them immediately, rather than tuned tight.
  """

  use Gettext, backend: AbuubaWeb.Gettext

  import Phoenix.Controller
  import Plug.Conn

  alias Abuuba.RateLimit
  alias AbuubaWeb.ClientIP

  @behaviour Plug

  @impl Plug
  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      limit: Keyword.fetch!(opts, :limit),
      window_ms: Keyword.fetch!(opts, :window_ms)
    }
  end

  @impl Plug
  def call(conn, %{bucket: bucket, limit: limit, window_ms: window_ms}) do
    key = "#{bucket}:#{ClientIP.of(conn)}"

    case RateLimit.hit(key, limit: limit, window_ms: window_ms) do
      {:ok, _remaining} ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> put_flash(:error, gettext("Too many attempts. Wait a minute and try again."))
        |> redirect(to: conn.request_path)
        |> halt()
    end
  end
end
