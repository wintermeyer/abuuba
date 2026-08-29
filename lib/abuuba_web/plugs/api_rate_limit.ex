defmodule AbuubaWeb.Plugs.APIRateLimit do
  @moduledoc """
  The buckets every API request is counted against, and what the client is told
  about them.

      plug AbuubaWeb.Plugs.APIRateLimit
      plug AbuubaWeb.Plugs.APIRateLimit, bucket: :media

  Counted per authenticated account where there is one, and per client address
  where there is not. That split is the point: one person's app is allowed far
  more than an anonymous scraper, and holding both to the anonymous limit would
  make ordinary use of a client feel broken.

  ## Two limits at once

  An authenticated request counts against its account **and** against its
  token, because an account with six apps should not get six times the budget,
  and one misbehaving app should not spend the whole account's. The headers
  describe whichever of the two is closer to its limit, since that is the one
  the client will actually hit.

  ## The headers

  `X-RateLimit-Limit`, `-Remaining`, and `-Reset` as an ISO 8601 instant.
  Clients display the reset to a person and sleep until it, so it has to be a
  time a wall clock can name rather than a number of seconds.
  """

  import Plug.Conn

  alias Abuuba.Accounts.User
  alias Abuuba.OAuth.AccessToken
  alias Abuuba.RateLimit
  alias AbuubaWeb.API
  alias AbuubaWeb.ClientIP

  @behaviour Plug

  @five_minutes 5 * 60 * 1000
  @ten_minutes 10 * 60 * 1000
  @thirty_minutes 30 * 60 * 1000
  @one_hour 60 * 60 * 1000

  # The reference implementation's numbers. A client tuned against those will
  # behave the same here, and one that backs off correctly there backs off
  # correctly here.
  @buckets %{
    api: [account: {1_500, @five_minutes}, token: {300, @five_minutes}, ip: {300, @five_minutes}],
    media: [account: {30, @thirty_minutes}],
    # `address` rather than `ip`: these two are the buckets that exist because
    # nobody is signed in, and `ip` deliberately stops counting as soon as a
    # token is present. A sign-up carries a client-credentials token and would
    # therefore have been counted against nothing at all.
    sign_up: [address: {5, @thirty_minutes}],
    app_registration: [address: {5, @ten_minutes}],
    # Counted against whoever is typing rather than the account named, because
    # the account id is theirs to choose and the sending is not. Five
    # confirmations an hour from one place is already more than anybody
    # subscribing in good faith needs.
    email_subscription: [address: {5, @one_hour}],
    # Counted only when the picture is not here yet, because that is the
    # request that costs something: a miss is an outbound fetch to somebody
    # else's server. A reader scrolling a timeline of pictures this server
    # already holds is reading its own disk and is not counted at all, which is
    # why this can be as tight as the reference implementation's number
    # without making ordinary reading feel broken.
    media_proxy: [address: {30, @ten_minutes}],
    delete: [account: {30, @thirty_minutes}]
  }

  @impl Plug
  def init(opts), do: Keyword.get(opts, :bucket, :api)

  @impl Plug
  # A browser preflights before every request it cannot send simply. Counting
  # both would halve the budget of every web client, and a preflight is not a
  # request for anything.
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _bucket), do: conn

  def call(conn, bucket) do
    conn
    |> counters(bucket)
    |> Enum.map(fn {key, {limit, window}} ->
      RateLimit.take(key, limit: limit, window_ms: window)
    end)
    |> tightest()
    |> answer(conn)
  end

  # Whichever bucket the client is closest to exhausting. Reporting the
  # roomiest one would tell a client it has budget it cannot spend.
  defp tightest([]), do: nil
  defp tightest(results), do: Enum.min_by(results, fn {_outcome, state} -> state.remaining end)

  defp answer(nil, conn), do: conn

  defp answer({:ok, state}, conn), do: put_headers(conn, state)

  defp answer({:error, state}, conn) do
    conn
    |> put_headers(state)
    # An English literal, like every other API error: clients match on it.
    |> API.error(429, "Too many requests")
  end

  # Across plugs as well as within one. An endpoint with a narrow bucket of its
  # own runs this twice, and writing the headers unconditionally meant the
  # second run overwrote the first: an account five requests from the end of
  # its general budget was told it had twenty-nine deletes in hand, and then
  # got a 429 the headers had said nothing about.
  defp put_headers(conn, state) do
    if roomier?(conn, state) do
      conn
    else
      conn
      |> put_resp_header("x-ratelimit-limit", Integer.to_string(state.limit))
      |> put_resp_header("x-ratelimit-remaining", Integer.to_string(state.remaining))
      |> put_resp_header("x-ratelimit-reset", DateTime.to_iso8601(state.reset_at))
    end
  end

  defp roomier?(conn, state) do
    case get_resp_header(conn, "x-ratelimit-remaining") do
      [already] -> String.to_integer(already) < state.remaining
      _none -> false
    end
  end

  # Which scopes a request is counted against, and under which key. An
  # authenticated request counts against both the account and the token; an
  # anonymous one has only an address.
  defp counters(conn, bucket) do
    prefix = Atom.to_string(bucket)

    @buckets
    |> Map.fetch!(bucket)
    |> Enum.flat_map(fn {scope, limit} ->
      case scope_key(conn, scope) do
        nil -> []
        key -> [{"#{prefix}:#{scope}:#{key}", limit}]
      end
    end)
  end

  defp scope_key(conn, :account) do
    case conn.assigns[:current_token] do
      %AccessToken{user: %User{account_id: account_id}} -> account_id
      # A client-credentials token has no person behind it, so there is no
      # account to count against.
      _ -> nil
    end
  end

  defp scope_key(conn, :token) do
    case conn.assigns[:current_token] do
      %AccessToken{id: id} -> id
      _ -> nil
    end
  end

  # Only where nobody is signed in. An authenticated caller is counted by who
  # they are, so that moving to a new address does not reset their budget.
  defp scope_key(conn, :ip) do
    case conn.assigns[:current_token] do
      %AccessToken{} -> nil
      _ -> ClientIP.of(conn)
    end
  end

  # The address, whatever else the request carries. For the endpoints where the
  # token says nothing about who is asking — an app signing somebody up, an app
  # registering itself — and the address is the only thing there is to bound.
  defp scope_key(conn, :address), do: ClientIP.of(conn)
end
