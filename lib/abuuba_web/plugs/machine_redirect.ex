defmodule AbuubaWeb.Plugs.MachineRedirect do
  @moduledoc """
  Sends a machine from the page a person copies to the object it means.

  The mirror image of `AbuubaWeb.Plugs.HumanRedirect`. `/@alice` and
  `/@alice/123` are what the address bar shows and what `og:url` carries, so
  they are what gets pasted into another server's search box -- and that
  server fetches them asking for ActivityPub. Until this existed it was
  handed the page, found no way onward, and the search came up empty: an abuuba
  address pasted anywhere else meant nothing.

  ## Preferring, not merely mentioning

  The reference implementation's fetcher asks for
  `application/activity+json, ... , text/html;q=0.1` -- it *mentions* HTML as
  a last resort. A browser asks for HTML first and does not mention
  ActivityPub at all. So the rule is a comparison, never a containment check:
  redirected only when the best ActivityPub quality beats the best HTML one.
  A request that says nothing, or says `*/*`, is left alone, because the only
  fetchers that matter name their type.

  ## To the username shape, on purpose

  The target is `/users/:username` without looking the account up: a plug
  ahead of the router has no business costing a query on every page view. For
  the accounts whose canonical id is the numeric shape, that address answers
  with one more permanent redirect, and the chain still ends on a document
  whose id is the URL it came from -- which is the property strict peers
  check.
  """

  @behaviour Plug

  import Plug.Conn

  @ap_types ["application/activity+json", "application/ld+json"]
  @html_types ["text/html", "application/xhtml+xml"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD"] do
    with target when is_binary(target) <- machine_path(conn.path_info),
         true <- prefers_activity_json?(conn) do
      conn
      |> put_resp_header("vary", "Accept")
      |> put_resp_header("location", target)
      |> send_resp(301, "")
      |> halt()
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  # Only the two shapes a person pastes. The follower pages, the media tab and
  # the rest have no object of their own to redirect to, and a wide match here
  # would be a way to bounce machines off pages that were never ids.
  defp machine_path(["@" <> username]) when username != "", do: "/users/" <> username

  defp machine_path(["@" <> username, id]) when username != "" do
    if id =~ ~r/^\d+$/, do: "/users/#{username}/statuses/#{id}"
  end

  defp machine_path(_path), do: nil

  defp prefers_activity_json?(conn) do
    parsed =
      conn
      |> get_req_header("accept")
      |> Enum.join(",")
      |> String.downcase()
      |> String.split(",")
      |> Enum.map(&parse_entry/1)

    best(parsed, @ap_types) > best(parsed, @html_types)
  end

  defp parse_entry(entry) do
    [type | params] = entry |> String.trim() |> String.split(";")

    {String.trim(type), Enum.find_value(params, 1.0, &quality/1)}
  end

  # `q=0.1` somewhere among the parameters, or nothing, which the RFC says
  # means 1. A q that does not parse is treated as absent rather than as zero:
  # a malformed parameter must not make a type vanish from the comparison.
  defp quality(param) do
    with ["q", value] <- param |> String.trim() |> String.split("="),
         {q, _rest} <- Float.parse(value) do
      q
    else
      _not_a_quality -> nil
    end
  end

  defp best(parsed, types) do
    parsed
    |> Enum.filter(fn {type, _q} -> type in types end)
    |> Enum.map(fn {_type, q} -> q end)
    |> Enum.max(fn -> 0.0 end)
  end
end
