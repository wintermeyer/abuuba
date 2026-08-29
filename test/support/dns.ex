defmodule Abuuba.TestDNS do
  @moduledoc """
  What a host resolves to during the tests: an address if it is already one,
  and otherwise nothing.

  The suite must not depend on the network, and until this existed it did --
  every federation fetch reached through an activity handler resolved its host
  against whatever resolver this machine has. The hosts in the fixtures are
  `.example`, which is reserved and does not resolve, so the answer was always
  the same; the cost was a real lookup per fetch, and a suite that got slower
  and then flaky when the resolver did. One lookup held a database connection
  for the fifteen seconds Postgrex allows, took its owner down with it, and
  five unrelated tests failed with ownership errors.

  Names failing to resolve is what those hosts really do, so this changes
  nothing about what the tests exercise. A test that wants a fetch to reach the
  transport passes its own `resolver:`, which several already do.

  ## Why literals still resolve

  `https://127.0.0.1/x` must be refused for being a private address, not for
  being unresolvable -- the two are different answers and only one of them
  proves the address check ran. `:inet.getaddrs/2` hands a literal straight
  back, so this does too, or the SSRF test would pass without testing anything.
  """

  @doc "An address if the host already is one, otherwise unresolvable."
  @spec resolve(String.t()) :: {:ok, [tuple()]} | {:error, :unresolvable}
  def resolve(host) do
    case host |> to_charlist() |> :inet.parse_address() do
      {:ok, address} -> {:ok, [address]}
      {:error, :einval} -> {:error, :unresolvable}
    end
  end
end
