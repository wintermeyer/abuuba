defmodule Abuuba.Security.SignatureTest do
  use ExUnit.Case, async: true

  alias Abuuba.Accounts.Keypair
  alias Abuuba.Federation.Signature

  # Signature edge cases. A verifier that accepts one of these is a verifier
  # that can be made to accept anything.

  @now ~U[2026-01-01 12:00:00Z]

  setup do
    %{public_key: public, private_key: private} = Keypair.generate()
    %{public_key: other_public, private_key: other_private} = Keypair.generate()

    %{public: public, private: private, other_public: other_public, other_private: other_private}
  end

  defp sign(private, opts \\ []) do
    {:ok, headers} =
      Signature.sign(
        Keyword.merge(
          [
            method: :post,
            url: "https://here.example/inbox",
            body: "{}",
            key_id: "https://peer.example/users/bob#main-key",
            private_key: private,
            now: @now
          ],
          opts
        )
      )

    headers
  end

  defp verify(headers, public, opts \\ []) do
    Signature.verify(
      Keyword.merge(
        [
          method: :post,
          path: "/inbox",
          headers: headers,
          body: "{}",
          resolve_key: fn _requested -> {:ok, public} end,
          now: @now
        ],
        opts
      )
    )
  end

  describe "the key that signed is the key that is checked" do
    test "a signature made with one key does not verify against another", %{
      private: private,
      other_public: other_public
    } do
      # Key confusion: if the verifier resolves a key by anything the request
      # itself controls without checking the maths, anybody can sign anything.
      assert {:error, :bad_signature} = verify(sign(private), other_public)
    end

    test "and a body swapped after signing is refused", %{private: private, public: public} do
      # The digest is what ties the body to the signature. Without checking it,
      # a signed request is a signed envelope with anybody's letter in it.
      assert {:error, :digest_mismatch} =
               verify(sign(private), public, body: ~s({"evil":true}))
    end

    test "and a request whose path was changed after signing", %{
      private: private,
      public: public
    } do
      assert {:error, :bad_signature} =
               verify(sign(private), public, path: "/somebody-else/inbox")
    end

    test "and one whose method was changed", %{private: private, public: public} do
      assert {:error, :bad_signature} = verify(sign(private), public, method: :get)
    end
  end

  describe "replay" do
    test "a signature from outside the window is refused" do
      # Twelve hours, which is what the rest of the network uses. There is no
      # nonce store, so a captured request can be replayed inside that window;
      # what makes that survivable is that every activity handler is
      # idempotent, so a replayed Create stores nothing new. Both halves are
      # load-bearing, and this is the half that has a boundary to test.
      %{public_key: public, private_key: private} = Keypair.generate()

      old = sign(private, now: DateTime.add(@now, -13, :hour))

      assert {:error, :stale_request} = verify(old, public)
    end

    test "and one from further in the future than a wrong clock explains" do
      %{public_key: public, private_key: private} = Keypair.generate()

      ahead = sign(private, now: DateTime.add(@now, 2, :hour))

      assert {:error, :stale_request} = verify(ahead, public)
    end

    test "while a peer whose clock is half an hour out still federates" do
      # Refusing these would cut off every server with a slightly wrong clock,
      # which is a great many of them.
      %{public_key: public, private_key: private} = Keypair.generate()

      skewed = sign(private, now: DateTime.add(@now, 30, :minute))

      assert {:ok, _key_id} = verify(skewed, public)
    end
  end

  describe "what has to be covered" do
    test "a signature that does not cover the digest is refused", %{
      private: private,
      public: public
    } do
      # Otherwise the body is unsigned and the digest header is decoration.
      headers = sign(private)
      stripped = Enum.reject(headers, fn {name, _value} -> name == "digest" end)

      assert {:error, reason} = verify(stripped, public)
      assert reason in [:missing_digest, :bad_signature]
    end

    test "and one that does not cover the date", %{private: private, public: public} do
      headers = sign(private)
      stripped = Enum.reject(headers, fn {name, _value} -> name == "date" end)

      assert {:error, reason} = verify(stripped, public)
      assert reason in [:missing_date, :bad_signature]
    end

    test "and a request with no signature at all", %{public: public} do
      assert {:error, :missing_signature} = verify([{"date", "x"}], public)
    end
  end

  describe "a key nobody can produce" do
    test "an unresolvable key id is a refusal, not a pass", %{private: private} do
      # Failing open here would make every unknown key a valid one.
      assert {:error, :unknown_key} =
               Signature.verify(
                 method: :post,
                 path: "/inbox",
                 headers: sign(private),
                 body: "{}",
                 resolve_key: fn _requested -> :error end,
                 now: @now
               )
    end
  end

  describe "algorithms" do
    test "an algorithm this server does not implement is refused", %{
      private: private,
      public: public
    } do
      # `hs2019` and `rsa-sha256` are the two in use. Anything else is either a
      # downgrade attempt or a server we cannot verify, and both are refusals.
      headers =
        Enum.map(sign(private), fn
          {"signature", value} -> {"signature", String.replace(value, "rsa-sha256", "md5")}
          other -> other
        end)

      assert {:error, reason} = verify(headers, public)
      assert reason in [:unsupported_algorithm, :bad_signature]
    end
  end
end
