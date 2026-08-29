defmodule Abuuba.Federation.RefusalReasonTest do
  @moduledoc """
  What a peer says when it refuses a delivery reaches the log.

  "The other server would not take it" is one of the two questions anybody
  running one of these ever asks, and the answer is already on the wire: the
  peer puts it in the body. It used to be discarded, leaving an operator with a
  status code and nowhere to look.
  """

  use Abuuba.DataCase, async: false

  import ExUnit.CaptureLog

  alias Abuuba.Federation.HTTP

  defp resolver do
    fn
      "remote.example" -> {:ok, [{93, 184, 216, 34}]}
      _other -> {:error, :unresolvable}
    end
  end

  defp answering(status, body) do
    fn _method, _url, _headers, _body ->
      {:ok, status, [{"content-type", "application/json"}], body}
    end
  end

  defp post(status, body) do
    capture_log(fn ->
      HTTP.post_json("https://remote.example/users/alice/inbox", %{"type" => "Create"},
        sign_as: nil,
        resolver: resolver(),
        transport: answering(status, body)
      )
    end)
  end

  test "a refusal is logged with what the peer said" do
    log = post(401, ~s|{"error":"Verification failed for alice@remote.example"}|)

    assert log =~ "remote.example refused a delivery with 401"
    assert log =~ "Verification failed for alice@remote.example"
  end

  test "a server having a bad minute is not, because it is retried" do
    # A 5xx body is a stack trace or an error page, and the delivery is coming
    # back anyway. Logging those would bury the refusals that matter.
    log = post(503, "<html><body>Bad Gateway</body></html>")

    refute log =~ "refused a delivery"
  end

  test "and neither is a delivery the peer accepted" do
    log = post(202, "")

    refute log =~ "refused a delivery"
  end

  test "a very long refusal is cut short" do
    # Some servers answer a refusal with an HTML page. The reason is worth
    # keeping; the page is not.
    log = post(403, String.duplicate("x", 5_000))

    assert log =~ "refused a delivery with 403"
    refute log =~ String.duplicate("x", 500)
  end
end
