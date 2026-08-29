defmodule AbuubaWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Keeps the raw request body so a signature can be checked against it.

  An HTTP signature covers the bytes that arrived. Re-encoding the parsed JSON
  and hashing that would fail for entirely legitimate reasons: key order,
  whitespace and number formatting all differ between encoders, and none of
  those differences mean the body was tampered with. So the exact bytes are
  kept.

  Only for the paths that need them. Holding every request body in memory to
  serve the handful that verify signatures would be a needless cost, and on an
  upload endpoint a genuinely large one.
  """

  @paths_needing_raw_body ["/inbox"]

  @doc """
  A `Plug.Parsers` body reader that stashes what it read.
  """
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    if needs_raw_body?(conn) do
      {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
    else
      {:ok, body, conn}
    end
  end

  defp needs_raw_body?(conn) do
    Enum.any?(@paths_needing_raw_body, &String.ends_with?(conn.request_path, &1))
  end
end
