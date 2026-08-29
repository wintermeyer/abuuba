defmodule Abuuba.Security.SSRFTest do
  use ExUnit.Case, async: true

  alias Abuuba.Federation.HTTP
  alias Abuuba.Federation.HTTP.Address

  # An adversarial pass over the one door every outbound request goes through.
  # Each of these is a way somebody has actually reached a metadata service or
  # an internal admin port from a server that fetches URLs on request.

  describe "addresses nobody may reach" do
    test "loopback, however it is spelled" do
      for address <- ["127.0.0.1", "127.1.2.3", "0.0.0.0", "[::1]"] do
        assert {:error, :private_address} =
                 Address.check("https://host.example", resolver: fixed(address)),
               "#{address} was allowed"
      end
    end

    test "the link-local range every cloud puts its credentials on" do
      # 169.254.169.254 is the metadata service on AWS, GCP and Azure alike.
      # It is the single most valuable address an SSRF can reach.
      assert {:error, :private_address} =
               Address.check("https://host.example", resolver: fixed("169.254.169.254"))
    end

    test "the private ranges" do
      for address <- ["10.0.0.1", "172.16.5.4", "192.168.1.1", "100.64.0.1"] do
        assert {:error, :private_address} =
                 Address.check("https://host.example", resolver: fixed(address)),
               "#{address} was allowed"
      end
    end

    test "and the IPv6 spellings of the same places" do
      # An IPv4 address written as IPv6 reaches the IPv4 address, so it has to
      # be judged as the address it actually reaches.
      for address <- ["[::ffff:127.0.0.1]", "[::ffff:169.254.169.254]", "[fd00::1]", "[fe80::1]"] do
        assert {:error, :private_address} =
                 Address.check("https://host.example", resolver: fixed(address)),
               "#{address} was allowed"
      end
    end

    test "a name that resolves to one public and one private address" do
      # Which of them gets connected to would otherwise be the resolver's
      # choice, and an attacker who controls the record makes that choice.
      resolver = fn _host -> {:ok, [{93, 184, 216, 34}, {127, 0, 0, 1}]} end

      assert {:error, :private_address} =
               Address.check("https://host.example", resolver: resolver)
    end

    test "and a name that resolves to nothing" do
      assert {:error, :unresolvable} =
               Address.check("https://host.example", resolver: fn _host -> {:ok, []} end)
    end
  end

  describe "what may be asked for at all" do
    test "not a scheme this server does not speak" do
      for url <- ["file:///etc/passwd", "gopher://host.example/", "ftp://host.example/"] do
        assert {:error, :unsupported_scheme} =
                 Address.check(url, resolver: fixed("93.184.216.34")),
               "#{url} was allowed"
      end
    end

    test "not a port that is not a web port" do
      # 6379 is Redis, 5432 is Postgres, 22 is SSH. A federation fetch has no
      # business on any of them.
      for port <- [22, 5432, 6379, 11_211] do
        assert {:error, :blocked_port} =
                 Address.check("https://host.example:#{port}/", resolver: fixed("93.184.216.34")),
               "port #{port} was allowed"
      end
    end

    test "and not a URL with no host in it" do
      assert {:error, :missing_host} = Address.check("https:///nowhere")
      assert {:error, :missing_host} = Address.check(nil)
    end
  end

  describe "the connection goes where the check went" do
    test "dials the address that was approved, not the name again" do
      # Checking a name and connecting to it are two resolutions. Anybody who
      # controls the record can answer them differently: public for the check,
      # 127.0.0.1 for the connection. Pinning is what closes that.
      pinned = HTTP.pinned(:get, "https://host.example/inbox", nil, [], [{93, 184, 216, 34}])

      assert pinned[:url].host == "93.184.216.34"
    end

    test "and still tells the server which name it wanted" do
      # Without this every server hosting more than one site answers with the
      # wrong one, and the certificate is checked against a number.
      pinned = HTTP.pinned(:get, "https://host.example/inbox", nil, [], [{93, 184, 216, 34}])

      assert {"host", "host.example"} in pinned[:headers]
      assert pinned[:connect_options][:hostname] == "host.example"
    end

    test "carrying a non-default port into the Host header" do
      pinned = HTTP.pinned(:get, "https://host.example:8443/x", nil, [], [{93, 184, 216, 34}])

      assert {"host", "host.example:8443"} in pinned[:headers]
    end

    test "bracketing an IPv6 address, which a URL needs" do
      pinned =
        HTTP.pinned(:get, "https://host.example/x", nil, [], [{0x2606, 0x2800, 0, 0, 0, 0, 0, 1}])

      assert pinned[:url].host == "[2606:2800::1]"
    end

    test "and asking for the name unchanged when there is nothing to pin to" do
      # Belt and braces: the address check has already refused anything worth
      # refusing, so this path is a fallback rather than a hole.
      pinned = HTTP.pinned(:get, "https://host.example/x", nil, [], [])

      assert pinned[:url] == "https://host.example/x"
      assert is_nil(pinned[:connect_options])
    end
  end

  defp fixed(address) do
    parsed =
      address
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.to_charlist()
      |> :inet.parse_address()

    fn _host ->
      case parsed do
        {:ok, tuple} -> {:ok, [tuple]}
        _unparsable -> {:error, :unresolvable}
      end
    end
  end
end
