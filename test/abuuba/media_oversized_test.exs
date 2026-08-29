defmodule Abuuba.MediaOversizedTest do
  @moduledoc """
  A picture too big to keep is refused, not kept in part.

  The fetch asked for at most `Upload.max_bytes()` and stored whatever came
  back. A body longer than that arrived truncated to exactly the ceiling, and
  nothing downstream can tell a short file from a small one, so the half of a
  photograph was written to the cache and served from then on.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Storage
  alias Abuuba.Media.Upload

  setup do
    account = account_fixture(%{domain: "other.example"})

    {:ok, attachment} =
      %Attachment{}
      |> Attachment.changeset(%{
        account_id: account.id,
        type: "image",
        remote_url: "https://other.example/pictures/big.jpg",
        file_file_name: "big.jpg"
      })
      |> Repo.insert()

    %{attachment: attachment}
  end

  # The address check runs before the transport, so the host has to resolve to
  # something the private-address guard accepts.
  defp resolver, do: fn _host -> {:ok, [{93, 184, 216, 34}]} end

  defp transport_returning(body) do
    fn _method, _url, _headers, _body ->
      {:ok, 200, [{"content-type", "image/jpeg"}], body}
    end
  end

  test "one over the limit is refused rather than stored in part", %{attachment: attachment} do
    # One byte past what is allowed, which is exactly the case the old ceiling
    # could not see: it asked for the maximum and got the maximum.
    oversized = String.duplicate("x", Upload.max_bytes() + 1)

    assert {:error, :too_large} =
             Media.cache_remote(attachment, :original,
               transport: transport_returning(oversized),
               resolver: resolver()
             )

    refute Storage.exists?(Storage.key_for(attachment, :original)),
           "half a photograph was written to the cache"
  end

  test "and one at the limit is kept, which is what makes the refusal mean something",
       %{attachment: attachment} do
    # The positive control. Without it, a refusal of everything would pass the
    # test above just as well.
    allowed = String.duplicate("x", 32)

    assert {:ok, _body} =
             Media.cache_remote(attachment, :original,
               transport: transport_returning(allowed),
               resolver: resolver()
             )

    assert Storage.exists?(Storage.key_for(attachment, :original))
  end
end
