defmodule Abuuba.Federation.DuplicateHostTest do
  @moduledoc """
  A request carries one Host header.

  Two is not a stylistic matter: RFC 9112 makes a request with duplicate Host
  headers malformed, and nginx — which sits in front of most of the fediverse —
  answers 400 without reading the rest. Since the signature covers `host`, this
  broke exactly the requests that carry one: every signed fetch, which is every
  fetch to a server in authorized-fetch mode.
  """

  use ExUnit.Case, async: true

  alias Abuuba.Federation.HTTP

  @url "https://remote.example/.well-known/webfinger?resource=acct%3Aalice%40remote.example"
  @address {172, 22, 0, 9}

  defp hosts(headers) do
    headers |> Keyword.get(:headers, []) |> Enum.filter(&(elem(&1, 0) == "host"))
  end

  test "when the caller has already set one, as a signed request has" do
    signed = [{"host", "remote.example"}, {"date", "Mon, 11 Aug 2026 00:00:00 GMT"}]

    pinned = HTTP.pinned(:get, @url, nil, signed, [@address])

    assert [{"host", "remote.example"}] = hosts(pinned)
  end

  test "and when nobody has, because the connection is pinned to an address" do
    # The header has to be added in that case: the URL now names an IP, and a
    # server hosting more than one site needs the name to know which is meant.
    pinned = HTTP.pinned(:get, @url, nil, [{"accept", "application/json"}], [@address])

    assert [{"host", "remote.example"}] = hosts(pinned)
  end

  test "the request still goes to the address that was checked" do
    # The positive control: dropping the duplicate must not undo the pinning,
    # which is half of the SSRF defence.
    pinned = HTTP.pinned(:get, @url, nil, [], [@address])

    assert %URI{host: "172.22.0.9"} = Keyword.fetch!(pinned, :url)
    assert Keyword.fetch!(pinned, :connect_options)[:hostname] == "remote.example"
  end
end
