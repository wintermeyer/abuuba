defmodule Abuuba.Federation.RFC9421Test do
  use ExUnit.Case, async: true

  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.DoubleKnock
  alias Abuuba.Federation.Signature
  alias Abuuba.Federation.Signature.RFC9421

  @now ~U[2026-08-05 12:00:00Z]
  @url "https://remote.example/inbox"

  setup_all do
    %{public_key: public, private_key: private} = Keypair.generate()
    %{public: public, private: private}
  end

  defp resolver(pem), do: fn _key_id -> {:ok, pem} end

  defp sign(private, opts \\ []) do
    body = Keyword.get(opts, :body, ~s({"type":"Create"}))

    {:ok, headers} =
      RFC9421.sign(
        method: Keyword.get(opts, :method, :post),
        url: Keyword.get(opts, :url, @url),
        body: body,
        key_id: "https://here.example/users/alice#main-key",
        private_key: private,
        now: Keyword.get(opts, :now, @now)
      )

    {headers, body}
  end

  defp verify(headers, body, opts) do
    RFC9421.verify(
      method: Keyword.get(opts, :method, :post),
      target_uri: Keyword.get(opts, :target_uri, @url),
      headers: headers,
      body: body,
      resolve_key: Keyword.fetch!(opts, :resolve_key),
      now: Keyword.get(opts, :now, @now)
    )
  end

  describe "which scheme a request is checked with" do
    # Both verifiers are tested thoroughly, and the thing that picks between
    # them was tested by nothing. `Signature.verify/1` chooses on the presence
    # of `Signature-Input`, and if that choice broke, every request signed the
    # newer way would be handed to the older verifier and refused -- which
    # since Mastodon 4.4 is most of the fediverse. Both verifiers would still
    # pass their own tests.
    test "a request signed the RFC 9421 way verifies through the front door", %{
      private: private,
      public: public
    } do
      {headers, body} = sign(private)

      assert {:ok, "https://here.example/users/alice#main-key"} =
               Signature.verify(
                 method: :post,
                 path: "/inbox",
                 host: "remote.example",
                 headers: headers,
                 body: body,
                 resolve_key: resolver(public),
                 now: @now
               )
    end

    test "and one signed the older way still does", %{private: private, public: public} do
      # The other half of the same door: adding the newer scheme must not have
      # taken the older one away, and plenty of the fediverse still speaks it.
      {:ok, headers} =
        Signature.sign(
          method: :post,
          url: @url,
          body: ~s({"type":"Create"}),
          key_id: "https://here.example/users/alice#main-key",
          private_key: private,
          now: @now
        )

      refute Enum.any?(headers, fn {name, _value} ->
               String.downcase(name) == "signature-input"
             end),
             "this is meant to be the older construction, and it carries the newer one's header"

      assert {:ok, "https://here.example/users/alice#main-key"} =
               Signature.verify(
                 method: :post,
                 path: "/inbox",
                 host: "remote.example",
                 headers: headers,
                 body: ~s({"type":"Create"}),
                 resolve_key: resolver(public),
                 now: @now
               )
    end
  end

  describe "signing" do
    test "produces the headers RFC 9421 names", %{private: private} do
      {headers, _body} = sign(private)
      lookup = Map.new(headers)

      assert lookup["signature-input"] =~ ~S|sig1=("@method" "@target-uri" "content-digest")|
      assert lookup["signature-input"] =~ "created="
      assert lookup["signature-input"] =~ ~s(keyid="https://here.example/users/alice#main-key")
      assert lookup["signature-input"] =~ ~s(alg="rsa-v1_5-sha256")

      assert lookup["signature"] =~ ~r/^sig1=:.+:$/
      assert lookup["content-digest"] =~ ~r/^sha-256=:.+:$/
    end

    test "covers no digest when there is no body", %{private: private} do
      {:ok, headers} =
        RFC9421.sign(
          method: :get,
          url: "https://remote.example/users/bob",
          key_id: "k",
          private_key: private,
          now: @now
        )

      lookup = Map.new(headers)

      refute Map.has_key?(lookup, "content-digest")
      assert lookup["signature-input"] =~ ~S|("@method" "@target-uri")|
    end
  end

  describe "verifying" do
    test "accepts what we signed", %{private: private, public: public} do
      {headers, body} = sign(private)

      assert {:ok, "https://here.example/users/alice#main-key"} =
               verify(headers, body, resolve_key: resolver(public))
    end

    test "refuses a swapped body", %{private: private, public: public} do
      {headers, _body} = sign(private)

      assert verify(headers, ~s({"type":"Delete"}), resolve_key: resolver(public)) ==
               {:error, :digest_mismatch}
    end

    test "refuses a different key", %{private: private} do
      {headers, body} = sign(private)
      %{public_key: other} = Keypair.generate()

      assert verify(headers, body, resolve_key: resolver(other)) == {:error, :bad_signature}
    end

    test "refuses a request aimed somewhere else", %{private: private, public: public} do
      # @target-uri is covered, so a signature made for one inbox does not
      # verify against another.
      {headers, body} = sign(private)

      assert verify(headers, body,
               target_uri: "https://elsewhere.example/inbox",
               resolve_key: resolver(public)
             ) == {:error, :bad_signature}
    end

    test "refuses a re-described signature", %{private: private, public: public} do
      # The parameters are themselves the last signed line, so claiming the
      # signature covered fewer components does not verify.
      {headers, body} = sign(private)

      tampered =
        Enum.map(headers, fn
          {"signature-input", value} ->
            {"signature-input",
             String.replace(
               value,
               ~S|("@method" "@target-uri" "content-digest")|,
               ~S|("@method")|
             )}

          other ->
            other
        end)

      assert {:error, reason} = verify(tampered, body, resolve_key: resolver(public))
      assert reason in [:bad_signature, :missing_digest, :missing_target]
    end

    test "refuses an algorithm it cannot check", %{private: private, public: public} do
      {headers, body} = sign(private)

      tampered =
        Enum.map(headers, fn
          {"signature-input", value} ->
            {"signature-input", String.replace(value, "rsa-v1_5-sha256", "ed25519")}

          other ->
            other
        end)

      assert verify(tampered, body, resolve_key: resolver(public)) ==
               {:error, :unsupported_algorithm}
    end

    test "refuses a stale request", %{private: private, public: public} do
      {headers, body} = sign(private, now: DateTime.add(@now, -13, :hour))

      assert verify(headers, body, resolve_key: resolver(public)) == {:error, :stale_request}
    end

    test "refuses a POST that covers no digest", %{private: private, public: public} do
      {:ok, headers} =
        RFC9421.sign(
          method: :post,
          url: @url,
          key_id: "k",
          private_key: private,
          now: @now
        )

      assert verify(headers, "", resolve_key: resolver(public)) == {:error, :missing_digest}
    end

    test "refuses garbage", %{public: public} do
      assert verify([{"signature-input", "nonsense"}], "", resolve_key: resolver(public)) ==
               {:error, :malformed_signature}
    end
  end

  describe "dispatch" do
    test "picks the scheme from the headers, not from a guess", %{
      private: private,
      public: public
    } do
      {rfc_headers, body} = sign(private)

      assert RFC9421.applies?(rfc_headers)

      # Signature.verify/1 routes to RFC 9421 on its own.
      assert {:ok, _} =
               Signature.verify(
                 method: :post,
                 path: "/inbox",
                 host: "remote.example",
                 headers: rfc_headers,
                 body: body,
                 resolve_key: resolver(public),
                 now: @now
               )
    end

    test "still verifies a cavage request", %{private: private, public: public} do
      {:ok, cavage_headers} =
        Signature.sign(
          method: :post,
          url: @url,
          body: ~s({"type":"Create"}),
          key_id: "k",
          private_key: private,
          now: @now
        )

      refute RFC9421.applies?(cavage_headers)

      assert {:ok, _} =
               Signature.verify(
                 method: :post,
                 path: "/inbox",
                 headers: cavage_headers,
                 body: ~s({"type":"Create"}),
                 resolve_key: resolver(public),
                 now: @now
               )
    end
  end

  describe "double knock" do
    defp delivery_opts(private) do
      [
        method: :post,
        url: @url,
        body: ~s({"type":"Create"}),
        key_id: "k",
        private_key: private,
        now: @now
      ]
    end

    test "tries cavage first, because most of the network still speaks it", %{private: private} do
      {:ok, result} =
        DoubleKnock.deliver(delivery_opts(private), fn _url, headers, _body ->
          refute RFC9421.applies?(headers)
          {:ok, 202}
        end)

      assert result == %{status: 202, scheme: :cavage}
    end

    test "knocks again with RFC 9421 when the peer says 401", %{private: private} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      {:ok, result} =
        DoubleKnock.deliver(delivery_opts(private), fn _url, headers, _body ->
          Agent.update(agent, &[RFC9421.applies?(headers) | &1])

          if RFC9421.applies?(headers), do: {:ok, 202}, else: {:ok, 401}
        end)

      assert result == %{status: 202, scheme: :rfc9421}
      assert Agent.get(agent, &Enum.reverse/1) == [false, true]
    end

    test "knocks again on 400 too", %{private: private} do
      {:ok, result} =
        DoubleKnock.deliver(delivery_opts(private), fn _url, headers, _body ->
          if RFC9421.applies?(headers), do: {:ok, 202}, else: {:ok, 400}
        end)

      assert result.scheme == :rfc9421
    end

    test "does not knock again on anything else", %{private: private} do
      for status <- [404, 410, 500, 503] do
        {:ok, agent} = Agent.start_link(fn -> 0 end)

        {:ok, result} =
          DoubleKnock.deliver(delivery_opts(private), fn _url, _headers, _body ->
            Agent.update(agent, &(&1 + 1))
            {:ok, status}
          end)

        assert result == %{status: status, scheme: :cavage}

        assert Agent.get(agent, & &1) == 1,
               "a #{status} is not a signature problem; re-sending is a second failure"
      end
    end

    test "can start with RFC 9421 for a host already known to want it", %{private: private} do
      {:ok, result} =
        DoubleKnock.deliver([{:prefer, :rfc9421} | delivery_opts(private)], fn _url,
                                                                               headers,
                                                                               _body ->
          assert RFC9421.applies?(headers)
          {:ok, 202}
        end)

      assert result.scheme == :rfc9421
    end

    test "reports which scheme worked, so the wasted knock can be skipped later", %{
      private: private
    } do
      {:ok, result} =
        DoubleKnock.deliver(delivery_opts(private), fn _url, headers, _body ->
          if RFC9421.applies?(headers), do: {:ok, 202}, else: {:ok, 401}
        end)

      assert result.scheme == :rfc9421
    end

    test "reports the peer's own status when both schemes are refused", %{private: private} do
      # Not flattened into an error of our own: the delivery pipeline decides
      # what a 401 means for retries and for marking an instance dead, and it
      # cannot do that from a status we threw away.
      assert DoubleKnock.deliver(delivery_opts(private), fn _url, _headers, _body ->
               {:ok, 401}
             end) == {:ok, %{status: 401, scheme: :rfc9421}}
    end

    test "passes a transport failure straight back", %{private: private} do
      assert DoubleKnock.deliver(delivery_opts(private), fn _url, _headers, _body ->
               {:error, :timeout}
             end) == {:error, :timeout}
    end
  end
end
