defmodule Abuuba.Federation.SignatureTest do
  use ExUnit.Case, async: true

  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.Signature

  @now ~U[2026-08-05 12:00:00Z]

  setup_all do
    %{public_key: public, private_key: private} = Keypair.generate()
    %{public: public, private: private}
  end

  defp resolver(pem), do: fn _key_id -> {:ok, pem} end

  defp sign_post(private, opts \\ []) do
    body = Keyword.get(opts, :body, ~s({"type":"Create"}))
    url = Keyword.get(opts, :url, "https://remote.example/inbox")
    now = Keyword.get(opts, :now, @now)

    {:ok, headers} =
      Signature.sign(
        method: :post,
        url: url,
        body: body,
        key_id: "https://here.example/users/alice#main-key",
        private_key: private,
        now: now
      )

    {headers, body}
  end

  defp verify(headers, body, opts) do
    Signature.verify(
      Keyword.merge(
        [
          method: Keyword.get(opts, :method, :post),
          path: Keyword.get(opts, :path, "/inbox"),
          query: Keyword.get(opts, :query),
          headers: headers,
          body: body,
          resolve_key: Keyword.fetch!(opts, :resolve_key),
          now: Keyword.get(opts, :now, @now)
        ],
        []
      )
    )
  end

  describe "signing" do
    test "produces the headers a peer expects", %{private: private} do
      {headers, _body} = sign_post(private)
      lookup = Map.new(headers)

      assert lookup["host"] == "remote.example"
      assert lookup["date"] =~ ~r/^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/
      assert lookup["digest"] =~ ~r/^SHA-256=/

      assert lookup["signature"] =~ ~s(algorithm="rsa-sha256")
      assert lookup["signature"] =~ ~s(keyId="https://here.example/users/alice#main-key")
      assert lookup["signature"] =~ "(request-target) host date digest"
    end

    test "omits the digest when there is no body", %{private: private} do
      {:ok, headers} =
        Signature.sign(
          method: :get,
          url: "https://remote.example/users/bob",
          key_id: "https://here.example/users/alice#main-key",
          private_key: private,
          now: @now
        )

      lookup = Map.new(headers)

      refute Map.has_key?(lookup, "digest")
      assert lookup["signature"] =~ "(request-target) host date"
    end

    test "keeps a non-default port in the host header", %{private: private} do
      {:ok, headers} =
        Signature.sign(
          method: :get,
          url: "https://remote.example:8443/users/bob",
          key_id: "k",
          private_key: private,
          now: @now
        )

      assert Map.new(headers)["host"] == "remote.example:8443"
    end
  end

  describe "verifying" do
    test "accepts what we signed", %{private: private, public: public} do
      {headers, body} = sign_post(private)

      assert {:ok, "https://here.example/users/alice#main-key"} =
               verify(headers, body, resolve_key: resolver(public))
    end

    test "refuses a body that was swapped after signing", %{private: private, public: public} do
      {headers, _body} = sign_post(private)

      assert verify(headers, ~s({"type":"Delete"}), resolve_key: resolver(public)) ==
               {:error, :digest_mismatch}
    end

    test "refuses a signature made by a different key", %{private: private} do
      {headers, body} = sign_post(private)
      %{public_key: other} = Keypair.generate()

      assert verify(headers, body, resolve_key: resolver(other)) == {:error, :bad_signature}
    end

    test "refuses a request replayed against a different path", %{
      private: private,
      public: public
    } do
      {headers, body} = sign_post(private)

      assert verify(headers, body, path: "/somewhere-else", resolve_key: resolver(public)) ==
               {:error, :bad_signature}
    end

    test "refuses when no key can be found", %{private: private} do
      {headers, body} = sign_post(private)

      assert verify(headers, body, resolve_key: fn _ -> :error end) == {:error, :unknown_key}
    end

    test "refuses a request with no signature at all" do
      assert verify([{"date", "x"}], "", resolve_key: fn _ -> :error end) ==
               {:error, :missing_signature}
    end

    test "refuses a signature header it cannot parse" do
      assert verify([{"signature", "garbage"}], "", resolve_key: fn _ -> :error end) ==
               {:error, :malformed_signature}
    end

    test "accepts hs2019 as a name for the same thing", %{private: private, public: public} do
      {headers, body} = sign_post(private)

      headers =
        Enum.map(headers, fn
          {"signature", value} ->
            {"signature", String.replace(value, "rsa-sha256", "hs2019")}

          other ->
            other
        end)

      assert {:ok, _} = verify(headers, body, resolve_key: resolver(public))
    end

    test "refuses an algorithm it does not know", %{private: private, public: public} do
      {headers, body} = sign_post(private)

      headers =
        Enum.map(headers, fn
          {"signature", value} -> {"signature", String.replace(value, "rsa-sha256", "ed25519")}
          other -> other
        end)

      assert verify(headers, body, resolve_key: resolver(public)) ==
               {:error, :unsupported_algorithm}
    end
  end

  describe "the time window" do
    test "accepts a request from within it", %{private: private, public: public} do
      {headers, body} = sign_post(private, now: DateTime.add(@now, -6, :hour))

      assert {:ok, _} = verify(headers, body, resolve_key: resolver(public))
    end

    test "refuses one that is too old", %{private: private, public: public} do
      {headers, body} = sign_post(private, now: DateTime.add(@now, -13, :hour))

      assert verify(headers, body, resolve_key: resolver(public)) == {:error, :stale_request}
    end

    test "tolerates a peer whose clock is an hour fast", %{private: private, public: public} do
      {headers, body} = sign_post(private, now: DateTime.add(@now, 30, :minute))

      assert {:ok, _} = verify(headers, body, resolve_key: resolver(public))
    end

    test "refuses one from further in the future than that", %{private: private, public: public} do
      {headers, body} = sign_post(private, now: DateTime.add(@now, 2, :hour))

      assert verify(headers, body, resolve_key: resolver(public)) == {:error, :stale_request}
    end
  end

  describe "what must be signed" do
    test "a POST that does not sign its digest is refused", %{private: private, public: public} do
      # This is the check that stops a captured signed request from being
      # turned into a different activity.
      {headers, body} = sign_post(private)

      stripped =
        Enum.map(headers, fn
          {"signature", value} ->
            {"signature",
             String.replace(
               value,
               "(request-target) host date digest",
               "(request-target) host date"
             )}

          other ->
            other
        end)

      assert verify(stripped, body, resolve_key: resolver(public)) == {:error, :missing_digest}
    end

    test "a GET that does not sign host is refused", %{private: private, public: public} do
      {:ok, headers} =
        Signature.sign(
          method: :get,
          url: "https://remote.example/users/bob",
          key_id: "k",
          private_key: private,
          now: @now
        )

      stripped =
        Enum.map(headers, fn
          {"signature", value} ->
            {"signature",
             String.replace(value, "(request-target) host date", "(request-target) date")}

          other ->
            other
        end)

      assert verify(stripped, nil,
               method: :get,
               path: "/users/bob",
               resolve_key: resolver(public)
             ) == {:error, :missing_host}
    end

    test "a request with no date at all is refused", %{private: private, public: public} do
      {headers, body} = sign_post(private)

      stripped =
        Enum.map(headers, fn
          {"signature", value} ->
            {"signature",
             String.replace(
               value,
               "(request-target) host date digest",
               "(request-target) host digest"
             )}

          other ->
            other
        end)

      assert verify(stripped, body, resolve_key: resolver(public)) == {:error, :missing_date}
    end
  end

  describe "the request-target quirk" do
    test "accepts a peer that leaves the query string out", %{private: private, public: public} do
      # Signed against the path alone, verified against a request that has a
      # query string. Both spellings are in the wild; refusing one means
      # silently failing to federate with everybody who chose it.
      {:ok, headers} =
        Signature.sign(
          method: :get,
          url: "https://remote.example/outbox",
          key_id: "k",
          private_key: private,
          now: @now
        )

      assert {:ok, _} =
               verify(headers, nil,
                 method: :get,
                 path: "/outbox",
                 query: "page=true",
                 resolve_key: resolver(public)
               )
    end

    test "accepts a peer that includes it", %{private: private, public: public} do
      {:ok, headers} =
        Signature.sign(
          method: :get,
          url: "https://remote.example/outbox?page=true",
          key_id: "k",
          private_key: private,
          now: @now
        )

      assert {:ok, _} =
               verify(headers, nil,
                 method: :get,
                 path: "/outbox",
                 query: "page=true",
                 resolve_key: resolver(public)
               )
    end
  end

  describe "digest/1" do
    test "is the base64 SHA-256 of the body, as the header spells it" do
      assert Signature.digest("hello") ==
               "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, "hello"))
    end

    test "accepts a list as long as ours is among them, not just first" do
      # RFC 3230 allows several. Comparing only the first would let a peer lead
      # with an algorithm we do not compute and hide a mismatch behind it.
      ours = Signature.digest("hello")

      assert Signature.digest_matches?(ours, "hello")
      assert Signature.digest_matches?("SHA-512=whatever, " <> ours, "hello")
      assert Signature.digest_matches?(ours <> ", SHA-512=whatever", "hello")

      refute Signature.digest_matches?("SHA-512=whatever", "hello")
      refute Signature.digest_matches?(ours, "goodbye")
    end

    test "the digest header is itself signed, so it cannot be extended later", %{
      private: private,
      public: public
    } do
      {headers, body} = sign_post(private)

      widened =
        Enum.map(headers, fn
          {"digest", value} -> {"digest", "SHA-512=whatever, " <> value}
          other -> other
        end)

      assert verify(widened, body, resolve_key: resolver(public)) == {:error, :bad_signature}
    end
  end

  describe "key ids" do
    test "point at the actor they belong to" do
      assert Signature.key_id("https://here.example/users/alice") ==
               "https://here.example/users/alice#main-key"

      assert Signature.actor_uri_from_key_id("https://here.example/users/alice#main-key") ==
               "https://here.example/users/alice"
    end
  end
end
