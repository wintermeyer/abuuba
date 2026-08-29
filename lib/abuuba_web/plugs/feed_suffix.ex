defmodule AbuubaWeb.Plugs.FeedSuffix do
  @moduledoc """
  Turns `/@alice.rss` and `/tags/gardening.rss` into routable paths.

  Phoenix cannot express a dot after a path parameter — `/@:username.rss` is
  rejected at compile time — but those two addresses are the ones every feed
  reader and every other server already knows. So the suffix is stripped here,
  before routing, and the request continues as `/@alice/feed.rss`, which is an
  ordinary route.

  A rewrite rather than a redirect, because a feed reader that has to follow
  one on every poll is a reader making two requests forever.

  Only these two shapes, and only at the end of the path. Anything else is left
  exactly as it arrived: a plug that rewrote more than it was asked to would be
  a plug nobody could reason about from the router.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: path} = conn, _opts) do
    case rewrite(path) do
      nil -> conn
      rewritten -> %{conn | path_info: rewritten, request_path: "/" <> Enum.join(rewritten, "/")}
    end
  end

  defp rewrite(["@" <> _rest = handle]) do
    with {:ok, stripped} <- strip(handle), do: [stripped, "feed.rss"]
  end

  defp rewrite(["tags", tag]) do
    with {:ok, stripped} <- strip(tag), do: ["tags", stripped, "feed.rss"]
  end

  defp rewrite(_path), do: nil

  defp strip(segment) do
    case String.ends_with?(segment, ".rss") do
      true -> {:ok, String.replace_suffix(segment, ".rss", "")}
      false -> nil
    end
  end
end
