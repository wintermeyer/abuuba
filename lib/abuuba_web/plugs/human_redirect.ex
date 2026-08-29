defmodule AbuubaWeb.Plugs.HumanRedirect do
  @moduledoc """
  Sends a browser from a federated address to the page a person reads.

  ## Why these addresses in particular

  `/users/alice` and `/users/alice/statuses/123` are the ids abuuba puts inside
  every activity it sends. They travel the network, so they are also the ones
  that end up pasted into a browser, into chat, and into somebody's notes — and
  until now a browser asking for one got a 406, which reads as the server being
  broken rather than as the address being for machines.

  So an HTML request is redirected to `/@alice` and `/@alice/123`. A request
  for JSON or `application/activity+json` is untouched, which is the whole
  point: the same URI has to keep meaning the same object to every other
  server.

  ## Before `:accepts`, and only for these paths

  The API pipeline accepts JSON only, and it refuses a browser before any
  controller runs — so this has to come first. It is narrow on purpose: it
  matches the two path shapes and nothing else, and a request that is not
  plainly a browser asking for a page is left exactly as it arrived.

  ## 301 and `Vary: Accept`

  Permanent, because the address will always redirect for a browser. `Vary`
  because the answer depends on the `Accept` header, and a cache that stored
  the redirect and then served it to another server would break federation for
  everybody behind that cache.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD"] do
    with true <- wants_html?(conn),
         target when is_binary(target) <- human_path(conn.path_info) do
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

  # An actor and a post, in both id schemes. The collections that hang off them
  # are deliberately not here: a browser opening `/users/alice/outbox` is
  # asking for something that has no page, and a redirect to the profile would
  # answer a question nobody asked.
  defp human_path(["users", username]), do: "/@" <> username
  defp human_path(["users", username, "statuses", id]), do: "/@" <> username <> "/" <> id
  defp human_path(_path), do: nil

  # A browser says `text/html` first and every machine here says JSON. Anything
  # that names a JSON type at all is left alone, whatever else it also lists,
  # because a peer sending `*/*` alongside `application/activity+json` must not
  # be sent to a page.
  defp wants_html?(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",") |> String.downcase()

    String.contains?(accept, "text/html") and not String.contains?(accept, "json")
  end
end
