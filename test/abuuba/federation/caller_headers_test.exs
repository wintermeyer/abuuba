defmodule Abuuba.Federation.CallerHeadersTest do
  @moduledoc """
  Headers a caller supplies reach the other server.

  A delivery is signed by `Abuuba.Federation.DoubleKnock` before it gets here,
  which hands the signature over as headers — so dropping them means every
  delivery arrives unsigned, and an inbox that requires a signature answers 401
  to all of them. That is every Mastodon server, whether or not authorized
  fetch is on.
  """

  use Abuuba.DataCase, async: true

  alias Abuuba.Federation.HTTP

  defp resolver do
    fn
      "remote.example" -> {:ok, [{93, 184, 216, 34}]}
      _other -> {:error, :unresolvable}
    end
  end

  defp capturing do
    parent = self()

    fn _method, _url, headers, _body ->
      send(parent, {:headers, headers})

      {:ok, 202, [{"content-type", "application/json"}], "{}"}
    end
  end

  defp sent do
    receive do
      {:headers, headers} -> headers
    after
      0 -> flunk("no request was made")
    end
  end

  defp value(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  test "a signature computed by the caller is the one that goes out" do
    assert {:ok, 202} =
             HTTP.post_json("https://remote.example/users/alice/inbox", %{"type" => "Create"},
               headers: [
                 {"signature", ~s|keyId="k",signature="abc"|},
                 {"date", "Mon, 11 Aug 2026 01:00:00 GMT"}
               ],
               sign_as: nil,
               resolver: resolver(),
               transport: capturing()
             )

    headers = sent()

    assert value(headers, "signature") == ~s|keyId="k",signature="abc"|
    assert value(headers, "date") == "Mon, 11 Aug 2026 01:00:00 GMT"
  end

  test "and it is sent once, not beside one of ours" do
    assert {:ok, 202} =
             HTTP.post_json("https://remote.example/users/alice/inbox", %{"type" => "Create"},
               headers: [{"signature", ~s|keyId="k",signature="abc"|}],
               sign_as: nil,
               resolver: resolver(),
               transport: capturing()
             )

    signatures = Enum.filter(sent(), fn {name, _v} -> String.downcase(name) == "signature" end)

    assert length(signatures) == 1
  end

  test "what the caller does not set is still filled in" do
    # The positive control: taking the caller's headers must not mean sending
    # only those. A request with no user-agent or content type is one plenty of
    # servers refuse.
    assert {:ok, 202} =
             HTTP.post_json("https://remote.example/users/alice/inbox", %{"type" => "Create"},
               headers: [{"signature", "x"}],
               sign_as: nil,
               resolver: resolver(),
               transport: capturing()
             )

    headers = sent()

    assert value(headers, "user-agent") =~ "abuuba"
    assert value(headers, "content-type") =~ "activity+json"
  end
end
