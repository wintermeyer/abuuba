defmodule Abuuba.Federation.HTTP.Address do
  @moduledoc """
  Whether an address is somewhere we are willing to send a request.

  Every URL abuuba fetches came from somewhere else: an actor document, a link in
  a post, a WebFinger answer. So "fetch this URL" is an instruction from a
  stranger, and without a check it is an instruction to make requests from
  inside our own network. That is server-side request forgery, and the targets
  that matter are not exotic: `127.0.0.1` reaches whatever else runs on this
  box, `169.254.169.254` is the cloud metadata service that hands out
  credentials, and `10.0.0.0/8` is the rest of the private network.

  Three rules shape this module.

  **Name the effect, not the spelling.** The check is "does this resolve to an
  address that is not on the public internet", not a list of hostnames or
  literals to refuse. `localhost`, `127.0.0.1`, `0x7f.1`, `[::ffff:127.0.0.1]`
  and a DNS name whose A record points at `127.0.0.1` are all the same request,
  and only the resolved address tells them apart.

  **Fail closed.** A hostname that does not resolve, a resolver that errors, an
  address family we do not recognise: all refused. If we cannot prove an
  address is public, it is not.

  **Every address, not the first.** A name resolving to one public and one
  private address is refused outright. Accepting it would leave which one gets
  connected to up to the resolver.
  """

  @typedoc "Why an address was refused."
  @type reason ::
          :unresolvable
          | :private_address
          | :unsupported_scheme
          | :missing_host
          | :blocked_port

  # Ports that are not HTTP. Reaching one still speaks whatever protocol lives
  # there, and a crafted URL is a way to poke at it.
  @allowed_ports [80, 443, 8080, 8443, 4000, 4001, 4002]

  # Everything that is not the public internet, as {network, prefix length}
  # rather than as a chain of comparisons. Written this way because it is a
  # list of facts, and a list of facts is easier to check against a reference
  # than a cond is: each line can be read straight off RFC 6890.
  @reserved_v4 [
    # "this network"
    {{0, 0, 0, 0}, 8},
    # private
    {{10, 0, 0, 0}, 8},
    # carrier-grade NAT: another network we are inside of, not the internet
    {{100, 64, 0, 0}, 10},
    # loopback
    {{127, 0, 0, 0}, 8},
    # link-local, which is where the cloud metadata service lives
    {{169, 254, 0, 0}, 16},
    # private
    {{172, 16, 0, 0}, 12},
    # IETF protocol assignments
    {{192, 0, 0, 0}, 24},
    # documentation
    {{192, 0, 2, 0}, 24},
    # 6to4 relay anycast
    {{192, 88, 99, 0}, 24},
    # private
    {{192, 168, 0, 0}, 16},
    # benchmarking, routable nowhere
    {{198, 18, 0, 0}, 15},
    # documentation
    {{198, 51, 100, 0}, 24},
    # documentation
    {{203, 0, 113, 0}, 24},
    # multicast, and everything reserved above it
    {{224, 0, 0, 0}, 3}
  ]

  @doc """
  Checks a URL end to end: scheme, host, port, and every address the host
  resolves to.
  """
  @spec check(String.t(), keyword()) :: :ok | {:error, reason()}
  def check(url, opts \\ []) do
    with {:ok, _addresses} <- checked(url, opts), do: :ok
  end

  @doc """
  The same check, handing back the addresses it approved.

  The caller needs them because approving a name and then connecting to it are
  two separate resolutions, and a record with a one-second lifetime can point
  somewhere public for the first and at `127.0.0.1` for the second. The only
  way to close that is to connect to the address that was actually checked.
  """
  @spec checked(String.t(), keyword()) :: {:ok, [tuple()]} | {:error, reason()}
  # Scheme first, so that `file:///etc/passwd` is refused for being a scheme we
  # do not speak rather than for lacking a host. Both refuse it, but only one
  # of them says something true about why.
  def checked(url, opts \\ []) do
    with {:ok, uri} <- parse(url),
         :ok <- check_scheme(uri, opts),
         :ok <- check_host(uri),
         :ok <- check_port(uri, opts),
         {:ok, addresses} <- resolve(uri.host, opts),
         :ok <- check_addresses(addresses, opts) do
      {:ok, addresses}
    end
  end

  defp parse(url) when is_binary(url), do: {:ok, URI.parse(url)}
  defp parse(_url), do: {:error, :missing_host}

  defp check_host(%URI{host: host}) when is_binary(host) and host != "", do: :ok
  defp check_host(_uri), do: {:error, :missing_host}

  # Plain HTTP is refused outside development. A federation fetch over HTTP is
  # readable and rewritable by anything between here and there, which makes the
  # signature on it the only thing left, and the body is what we act on.
  defp check_scheme(%URI{scheme: scheme}, opts) do
    allowed = Keyword.get(opts, :schemes, allowed_schemes())

    if scheme in allowed, do: :ok, else: {:error, :unsupported_scheme}
  end

  defp allowed_schemes do
    if Application.get_env(:abuuba, :allow_insecure_federation, false) do
      ["https", "http"]
    else
      ["https"]
    end
  end

  defp check_port(%URI{port: nil}, _opts), do: :ok

  defp check_port(%URI{port: port}, opts) do
    allowed = Keyword.get(opts, :ports, @allowed_ports)

    if port in allowed, do: :ok, else: {:error, :blocked_port}
  end

  @doc """
  Every address a host resolves to.

  An IP literal resolves to itself, which is the point: writing the address
  directly must not skip the check.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, [tuple()]} | {:error, :unresolvable}
  def resolve(host, opts \\ []) do
    case Keyword.get(opts, :resolver) || configured_resolver() do
      nil -> resolve_with_inet(host)
      resolver -> resolver.(host)
    end
  end

  # The per-call resolver is how the tests around this module drive it, but a
  # fetch reached through an activity handler threads no options at all, so the
  # whole suite was resolving hosts against the real DNS. `remote.example` does
  # not exist, so it answered quickly and the tests passed -- until a lookup
  # took its time, and one held a database connection for the fifteen seconds
  # Postgrex allows, because the fetch happens inside a transaction. Losing
  # that connection took its owner with it, and every test sharing it failed
  # somewhere else entirely with an ownership error.
  #
  # Configured rather than compiled in, so production keeps `:inet` and the
  # test environment names its own without production carrying a test double.
  defp configured_resolver do
    case Application.get_env(:abuuba, :address_resolver) do
      nil -> nil
      {module, function} -> &apply(module, function, [&1])
      resolver when is_function(resolver, 1) -> resolver
    end
  end

  defp resolve_with_inet(host) do
    charlist = String.to_charlist(host)

    v4 = lookup(charlist, :inet)
    v6 = lookup(charlist, :inet6)

    case v4 ++ v6 do
      [] -> {:error, :unresolvable}
      addresses -> {:ok, addresses}
    end
  end

  defp lookup(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  defp check_addresses([], _opts), do: {:error, :unresolvable}

  defp check_addresses(addresses, opts) do
    # Every one of them. A name resolving to one public and one private address
    # is refused rather than accepted, because otherwise which address gets
    # connected to is the resolver's choice and not ours.
    if Enum.all?(addresses, &public?(&1, opts)) do
      :ok
    else
      {:error, :private_address}
    end
  end

  @doc """
  Whether an address is on the public internet.
  """
  @spec public?(tuple(), keyword()) :: boolean()
  def public?(address, opts \\ [])

  def public?(address, opts) do
    if Keyword.get(opts, :allow_private, allow_private?()) do
      true
    else
      not private?(address)
    end
  end

  # Off unless a configuration file says otherwise, and there is only one thing
  # it is for: a closed test network. The interop suite runs several servers on
  # a Docker bridge where every address is private, so with this off they
  # cannot reach each other at all and no scenario can pass.
  #
  # On a server anybody can reach, this is the whole of the SSRF guard. A fetch
  # is aimed by what a stranger's document said, and following one into
  # 127.0.0.1 or 169.254.169.254 hands them the inside of the machine. Never
  # set it from a request, a header or a database row — only from config.
  defp allow_private? do
    Application.get_env(:abuuba, :allow_private_federation_addresses, false)
  end

  @doc """
  Whether an address is one we refuse to connect to.
  """
  @spec private?(tuple()) :: boolean()
  # IPv4-mapped IPv6. Written as an IPv6 address but reaching an IPv4 one, so
  # it has to be judged as the address it actually reaches.
  def private?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    private?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  # NAT64, which is the same trick with a different prefix.
  def private?({0x64, 0xFF9B, 0, 0, 0, 0, ab, cd}) do
    private?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  def private?({_a, _b, _c, _d} = address) do
    packed = pack_v4(address)

    Enum.any?(@reserved_v4, fn {network, bits} ->
      Bitwise.bsr(packed, 32 - bits) == Bitwise.bsr(pack_v4(network), 32 - bits)
    end)
  end

  def private?({a, _b, _c, _d, _e, _f, _g, _h} = address) do
    cond do
      address == {0, 0, 0, 0, 0, 0, 0, 0} -> true
      address == {0, 0, 0, 0, 0, 0, 0, 1} -> true
      # Unique local, the IPv6 private range.
      Bitwise.band(a, 0xFE00) == 0xFC00 -> true
      # Link-local.
      Bitwise.band(a, 0xFFC0) == 0xFE80 -> true
      # Multicast.
      Bitwise.band(a, 0xFF00) == 0xFF00 -> true
      true -> false
    end
  end

  # Anything we cannot recognise is refused. An address family we have never
  # seen is not one we can prove is public.
  def private?(_address), do: true

  defp pack_v4({a, b, c, d}) do
    Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d
  end
end
