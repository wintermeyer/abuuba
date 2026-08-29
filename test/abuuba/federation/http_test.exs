defmodule Abuuba.Federation.HTTPTest do
  use Abuuba.DataCase, async: false

  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.HTTP
  alias Abuuba.Federation.HTTP.Address
  alias Abuuba.Federation.HTTP.CircuitBreaker

  setup do
    CircuitBreaker.reset()
    :ok
  end

  # Resolves whatever the test says, so the address rules can be checked
  # without depending on real DNS.
  defp resolver(mapping) do
    fn host ->
      case Map.fetch(mapping, host) do
        {:ok, addresses} -> {:ok, addresses}
        :error -> {:error, :unresolvable}
      end
    end
  end

  describe "which addresses count as private" do
    test "loopback, whichever way it is written" do
      assert Address.private?({127, 0, 0, 1})
      assert Address.private?({127, 255, 255, 254})
      assert Address.private?({0, 0, 0, 0, 0, 0, 0, 1})

      # Written as IPv6 but reaching IPv4 loopback. Judged as the address it
      # actually reaches, not as the notation it was written in.
      assert Address.private?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
    end

    test "the cloud metadata service, which hands out credentials" do
      assert Address.private?({169, 254, 169, 254})
      assert Address.private?({169, 254, 0, 1})
    end

    test "every private IPv4 range" do
      assert Address.private?({10, 0, 0, 1})
      assert Address.private?({172, 16, 0, 1})
      assert Address.private?({172, 31, 255, 255})
      assert Address.private?({192, 168, 1, 1})
      assert Address.private?({0, 0, 0, 0})
      assert Address.private?({100, 64, 0, 1})
      assert Address.private?({198, 18, 0, 1})
      assert Address.private?({224, 0, 0, 1})
      assert Address.private?({255, 255, 255, 255})
    end

    test "the IPv6 ranges that are not the internet" do
      assert Address.private?({0, 0, 0, 0, 0, 0, 0, 0})
      assert Address.private?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert Address.private?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
      assert Address.private?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert Address.private?({0xFF02, 0, 0, 0, 0, 0, 0, 1})
    end

    test "NAT64, which is the mapped-address trick with another prefix" do
      assert Address.private?({0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001})
    end

    test "an address family we do not recognise is refused, not allowed" do
      refute Address.public?({:something, :else})
      refute Address.public?("127.0.0.1")
      refute Address.public?(nil)
    end

    test "an ordinary public address is fine" do
      refute Address.private?({93, 184, 216, 34})
      refute Address.private?({0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946})
      assert Address.public?({93, 184, 216, 34})
    end
  end

  describe "which resolver answers" do
    setup do
      configured = Application.get_env(:abuuba, :address_resolver)

      on_exit(fn -> Application.put_env(:abuuba, :address_resolver, configured) end)
    end

    test "the configured one, when the call names none" do
      # Without this the suite resolves every federated host against the real
      # DNS, which is both a dependency on the network and how one lookup came
      # to hold a database connection until Postgrex killed it.
      Application.put_env(:abuuba, :address_resolver, fn _host -> {:ok, [{203, 0, 113, 7}]} end)

      assert Address.resolve("anything.example") == {:ok, [{203, 0, 113, 7}]}
    end

    test "and the call's own, when it names one" do
      Application.put_env(:abuuba, :address_resolver, fn _host -> {:ok, [{203, 0, 113, 7}]} end)

      assert Address.resolve("anything.example",
               resolver: fn _host -> {:ok, [{198, 51, 100, 2}]} end
             ) ==
               {:ok, [{198, 51, 100, 2}]}
    end

    test "and nothing in this suite reaches the network" do
      # The double stands in for `:inet` here, and a host that does not resolve
      # is what these fixture domains really do.
      assert Address.resolve("remote.example") == {:error, :unresolvable}
    end
  end

  describe "check/2" do
    test "allows a public host" do
      resolver = resolver(%{"remote.example" => [{93, 184, 216, 34}]})

      assert Address.check("https://remote.example/inbox", resolver: resolver) == :ok
    end

    test "refuses a host that resolves anywhere private" do
      resolver = resolver(%{"evil.example" => [{127, 0, 0, 1}]})

      assert Address.check("https://evil.example/x", resolver: resolver) ==
               {:error, :private_address}
    end

    test "refuses when any one of several addresses is private" do
      # Otherwise which address gets connected to is the resolver's choice
      # rather than ours.
      resolver = resolver(%{"mixed.example" => [{93, 184, 216, 34}, {10, 0, 0, 1}]})

      assert Address.check("https://mixed.example/x", resolver: resolver) ==
               {:error, :private_address}
    end

    test "refuses a host that does not resolve, rather than trying anyway" do
      assert Address.check("https://nowhere.example/x", resolver: resolver(%{})) ==
               {:error, :unresolvable}
    end

    test "refuses a host resolving to nothing at all" do
      assert Address.check("https://empty.example/x",
               resolver: resolver(%{"empty.example" => []})
             ) ==
               {:error, :unresolvable}
    end

    test "refuses a scheme that is not https" do
      resolver = resolver(%{"remote.example" => [{93, 184, 216, 34}]})

      for url <- [
            "http://remote.example/x",
            "file:///etc/passwd",
            "gopher://remote.example/x",
            "ftp://remote.example/x"
          ] do
        assert Address.check(url, resolver: resolver) == {:error, :unsupported_scheme},
               "accepted #{url}"
      end
    end

    test "refuses a URL with no host" do
      assert Address.check("https:///x") == {:error, :missing_host}
      assert Address.check(nil) == {:error, :missing_host}
    end

    test "refuses something that is not a URL at all" do
      # No scheme, so it fails at the first gate rather than the host one.
      assert Address.check("not a url") == {:error, :unsupported_scheme}
      assert Address.check("") == {:error, :unsupported_scheme}
    end

    test "refuses a port that is not HTTP" do
      # Reaching one still speaks whatever protocol lives there, and a crafted
      # URL is a way to poke at it.
      resolver = resolver(%{"remote.example" => [{93, 184, 216, 34}]})

      assert Address.check("https://remote.example:22/x", resolver: resolver) ==
               {:error, :blocked_port}

      assert Address.check("https://remote.example:6379/x", resolver: resolver) ==
               {:error, :blocked_port}

      assert Address.check("https://remote.example:443/x", resolver: resolver) == :ok
    end

    test "an IP literal does not skip the check" do
      # Writing the address directly is the most obvious way to try.
      assert Address.check("https://127.0.0.1/x") == {:error, :private_address}
      assert Address.check("https://[::1]/x") == {:error, :private_address}

      assert Address.check("https://169.254.169.254/latest/meta-data/") ==
               {:error, :private_address}
    end
  end

  describe "fetching" do
    defp ok_transport(body, content_type \\ "application/activity+json") do
      fn _method, _url, _headers, _body ->
        {:ok, 200, [{"content-type", content_type}], body}
      end
    end

    defp public_resolver do
      resolver(%{
        "remote.example" => [{93, 184, 216, 34}],
        "evil.example" => [{127, 0, 0, 1}],
        "redirector.example" => [{93, 184, 216, 34}]
      })
    end

    test "redirect_hop/2 answers where a URL points, without going there" do
      # An ordinary web page is fetched on somebody else's behalf, and a
      # signature would tell every site anybody links to that this server is
      # the one asking. The option name has to be the one `signing_key/1`
      # reads: an unrecognised one is a default that silently signs.
      capture = fn method, _url, headers, _body ->
        send(self(), {:headers, method, headers})
        {:ok, 302, [{"location", "/elsewhere"}], ""}
      end

      # Relative in the header, absolute in the answer: every caller would
      # otherwise have to resolve it, and one of them would forget.
      assert {:ok, "https://remote.example/elsewhere"} =
               HTTP.redirect_hop("https://remote.example/page",
                 resolver: public_resolver(),
                 transport: capture
               )

      assert_received {:headers, :head, headers}
      refute Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "signature" end)

      # One request. A redirect is the answer rather than a hop to take.
      refute_received {:headers, _method, _headers}
    end

    test "redirect_hop/2 says nil when the URL is not a redirect" do
      assert {:ok, nil} =
               HTTP.redirect_hop("https://remote.example/page",
                 resolver: public_resolver(),
                 transport: ok_transport("<html></html>", "text/html")
               )
    end

    test "get_document/2 is unsigned" do
      capture = fn _method, _url, headers, _body ->
        send(self(), {:headers, headers})
        {:ok, 200, [{"content-type", "text/html"}], "<html></html>"}
      end

      assert {:ok, _document} =
               HTTP.get_document("https://remote.example/page",
                 resolver: public_resolver(),
                 transport: capture
               )

      assert_received {:headers, headers}
      refute Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "signature" end)
    end

    test "returns a decoded document" do
      assert {:ok, %{"type" => "Person"}} =
               HTTP.get_json("https://remote.example/actor",
                 resolver: public_resolver(),
                 transport: ok_transport(~s({"type":"Person"})),
                 sign_as: nil
               )
    end

    test "a host that answers is not a host we have given up on" do
      # Availability is one opinion about a server, so it has to be revised by
      # every kind of contact. A domain that answers a fetch but that delivery
      # once gave up on would otherwise stay skipped until somebody noticed.
      for day <- 1..Availability.failure_days_before_unavailable() do
        Availability.record_failure("remote.example", Date.add(Date.utc_today(), -day))
      end

      assert Availability.unavailable?("remote.example")

      assert {:ok, _} =
               HTTP.get_json("https://remote.example/actor",
                 resolver: public_resolver(),
                 transport: ok_transport(~s({"type":"Person"})),
                 sign_as: nil
               )

      refute Availability.unavailable?("remote.example")
    end

    test "get_json/2 still refuses plain JSON" do
      # Deliberate: that one speaks ActivityPub, and accepting anything that
      # parses would let a peer hand it a document it never agreed to read.
      assert HTTP.get_json("https://remote.example/actor",
               resolver: public_resolver(),
               transport: ok_transport(~s({"type":"Person"}), "application/json"),
               sign_as: nil
             ) == {:error, :wrong_content_type}
    end

    test "get_rest_json/2 reads what a REST API answers" do
      # `application/json` is what every REST endpoint answers, and the only
      # JSON fetch here refused it — so the update check threw GitHub's answer
      # away on every run for as long as the feature existed.
      assert {:ok, %{"tag_name" => "v1.2.3"}} =
               HTTP.get_rest_json("https://remote.example/releases/latest",
                 resolver: public_resolver(),
                 transport: ok_transport(~s({"tag_name":"v1.2.3"}), "application/json")
               )
    end

    test "get_rest_json/2 reads a list, which an object-only decoder cannot" do
      # `/api/v1/custom_emojis` answers an array.
      assert {:ok, [%{"shortcode" => "blobcat"}]} =
               HTTP.get_rest_json("https://remote.example/api/v1/custom_emojis",
                 resolver: public_resolver(),
                 transport: ok_transport(~s([{"shortcode":"blobcat"}]), "application/json")
               )
    end

    test "get_rest_json/2 is unsigned" do
      capture = fn _method, _url, headers, _body ->
        send(self(), {:headers, headers})
        {:ok, 200, [{"content-type", "application/json"}], "{}"}
      end

      assert {:ok, _} =
               HTTP.get_rest_json("https://remote.example/releases/latest",
                 resolver: public_resolver(),
                 transport: capture
               )

      # A public JSON endpoint has no business learning which server is asking.
      assert_received {:headers, headers}
      refute Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "signature" end)

      assert Enum.any?(headers, fn {name, value} ->
               String.downcase(name) == "accept" and String.contains?(value, "application/json")
             end)
    end

    test "get_rest_json/2 refuses something that is not JSON at all" do
      assert HTTP.get_rest_json("https://remote.example/page",
               resolver: public_resolver(),
               transport: ok_transport("<html></html>", "text/html")
             ) == {:error, :wrong_content_type}
    end

    test "get_rest_json/2 keeps the SSRF guard" do
      assert HTTP.get_rest_json("https://evil.example/releases",
               resolver: public_resolver(),
               transport: ok_transport("{}", "application/json")
             ) == {:error, :private_address}
    end

    test "refuses a document built with JSON-LD constructions we do not read" do
      # The inbox guards what is delivered to us. This guards what we went and
      # fetched, which is the same problem: an actor document whose real
      # content hides under @graph reads, through plain map access, as an
      # actor with no inbox and no key.
      assert HTTP.get_json("https://remote.example/actor",
               resolver: public_resolver(),
               transport: ok_transport(~s({"type":"Person","@graph":[]})),
               sign_as: nil
             ) == {:error, :unreadable_shape}
    end

    test "refuses a document that is not declared as ActivityPub" do
      # A host that merely serves user uploads could otherwise hand us an actor
      # document somebody uploaded to it.
      assert HTTP.get_json("https://remote.example/actor",
               resolver: public_resolver(),
               transport: ok_transport(~s({"type":"Person"}), "text/html"),
               sign_as: nil
             ) == {:error, :wrong_content_type}
    end

    test "accepts ld+json with the ActivityStreams profile" do
      assert {:ok, _} =
               HTTP.get_json("https://remote.example/actor",
                 resolver: public_resolver(),
                 transport:
                   ok_transport(
                     ~s({"type":"Person"}),
                     ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams")
                   ),
                 sign_as: nil
               )
    end

    test "refuses a response with no content type at all" do
      transport = fn _method, _url, _headers, _body -> {:ok, 200, [], ~s({"a":1})} end

      assert HTTP.get_json("https://remote.example/actor",
               resolver: public_resolver(),
               transport: transport,
               sign_as: nil
             ) == {:error, :missing_content_type}
    end

    test "reports gone and not-found distinctly, since they mean different things" do
      for {status, expected} <- [{410, :gone}, {404, :not_found}] do
        transport = fn _m, _u, _h, _b -> {:ok, status, [], ""} end

        assert HTTP.get_json("https://remote.example/actor",
                 resolver: public_resolver(),
                 transport: transport,
                 sign_as: nil
               ) == {:error, expected}
      end
    end

    test "refuses a body that is not JSON" do
      assert HTTP.get_json("https://remote.example/actor",
               resolver: public_resolver(),
               transport: ok_transport("<html>nope</html>"),
               sign_as: nil
             ) == {:error, :malformed_json}
    end

    test "checks the address again on every redirect" do
      # A public URL that redirects to a private address is exactly how the
      # check gets skipped.
      transport = fn _method, url, _headers, _body ->
        if String.contains?(url, "redirector.example") do
          {:ok, 302, [{"location", "https://evil.example/inbox"}], ""}
        else
          {:ok, 200, [{"content-type", "application/activity+json"}], ~s({"ok":true})}
        end
      end

      assert HTTP.get_json("https://redirector.example/go",
               resolver: public_resolver(),
               transport: transport,
               sign_as: nil
             ) == {:error, :private_address}
    end

    test "follows a redirect to a public address" do
      transport = fn _method, url, _headers, _body ->
        if String.contains?(url, "/go") do
          {:ok, 302, [{"location", "https://remote.example/actor"}], ""}
        else
          {:ok, 200, [{"content-type", "application/activity+json"}], ~s({"ok":true})}
        end
      end

      assert {:ok, %{"ok" => true}} =
               HTTP.get_json("https://redirector.example/go",
                 resolver: public_resolver(),
                 transport: transport,
                 sign_as: nil
               )
    end

    test "gives up rather than following a redirect loop" do
      transport = fn _method, _url, _headers, _body ->
        {:ok, 302, [{"location", "https://remote.example/loop"}], ""}
      end

      assert HTTP.get_json("https://remote.example/loop",
               resolver: public_resolver(),
               transport: transport,
               sign_as: nil
             ) == {:error, :too_many_redirects}
    end

    test "refuses a redirect with nowhere to go" do
      transport = fn _method, _url, _headers, _body -> {:ok, 302, [], ""} end

      assert HTTP.get_json("https://remote.example/x",
               resolver: public_resolver(),
               transport: transport,
               sign_as: nil
             ) == {:error, :redirect_without_location}
    end

    test "sends a user agent that says who we are" do
      transport = fn _method, _url, headers, _body ->
        agent = headers |> Map.new() |> Map.get("user-agent")

        assert agent =~ "abuuba/"
        assert agent =~ "bot"

        {:ok, 200, [{"content-type", "application/activity+json"}], ~s({})}
      end

      assert {:ok, _} =
               HTTP.get_json("https://remote.example/x",
                 resolver: public_resolver(),
                 transport: transport,
                 sign_as: nil
               )
    end
  end

  describe "the circuit breaker" do
    test "lets a host through until it has failed enough times" do
      for _ <- 1..(CircuitBreaker.failure_threshold() - 1) do
        CircuitBreaker.failed("flaky.example")
      end

      assert CircuitBreaker.check("flaky.example") == :ok

      CircuitBreaker.failed("flaky.example")

      assert CircuitBreaker.check("flaky.example") == {:error, :circuit_open}
    end

    test "forgets everything when a host answers" do
      for _ <- 1..CircuitBreaker.failure_threshold(), do: CircuitBreaker.failed("dead.example")

      assert CircuitBreaker.check("dead.example") == {:error, :circuit_open}

      CircuitBreaker.succeeded("dead.example")

      assert CircuitBreaker.check("dead.example") == :ok
    end

    test "keeps one host's failures away from another" do
      for _ <- 1..CircuitBreaker.failure_threshold(), do: CircuitBreaker.failed("dead.example")

      assert CircuitBreaker.check("fine.example") == :ok
    end

    test "does not count our own refusals against a peer" do
      # Blocking a private address a thousand times must not trip a breaker on
      # a host that never saw a request.
      resolver = resolver(%{"evil.example" => [{127, 0, 0, 1}]})

      for _ <- 1..10 do
        HTTP.get_json("https://evil.example/x", resolver: resolver, sign_as: nil)
      end

      assert CircuitBreaker.check("evil.example") == :ok
    end

    test "counts a peer that actually failed" do
      transport = fn _m, _u, _h, _b -> {:error, :timeout} end
      resolver = resolver(%{"slow.example" => [{93, 184, 216, 34}]})

      for _ <- 1..CircuitBreaker.failure_threshold() do
        HTTP.get_json("https://slow.example/x",
          resolver: resolver,
          transport: transport,
          sign_as: nil
        )
      end

      assert CircuitBreaker.check("slow.example") == {:error, :circuit_open}
    end

    test "refuses without even trying once the circuit is open" do
      resolver = resolver(%{"dead.example" => [{93, 184, 216, 34}]})

      for _ <- 1..CircuitBreaker.failure_threshold(), do: CircuitBreaker.failed("dead.example")

      transport = fn _m, _u, _h, _b -> flunk("should not have been called") end

      assert HTTP.get_json("https://dead.example/x",
               resolver: resolver,
               transport: transport,
               sign_as: nil
             ) == {:error, :circuit_open}
    end
  end
end
