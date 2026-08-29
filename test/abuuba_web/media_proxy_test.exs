defmodule AbuubaWeb.MediaProxyTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Storage
  alias Abuuba.Repo
  alias AbuubaWeb.API.Entities

  setup do
    account = account_fixture(%{username: "alice"})
    status = status_fixture(%{account_id: account.id, text: "with a picture"})

    %{account: account, status: status}
  end

  defp remote_attachment(status, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Attachment{
          status_id: status.id,
          account_id: status.account_id,
          type: :image,
          processing: :complete,
          file_content_type: "image/png",
          remote_url: "https://remote.example/pictures/one.png"
        },
        attrs
      )
    )
  end

  # A remote attachment whose bytes are already on this disk, which is what
  # every picture becomes after the first reader asks for it.
  defp stored_attachment(status) do
    attachment = remote_attachment(status, %{file_file_name: "cached.png"})
    key = Storage.key_for(attachment, :original)
    scratch = Path.join(System.tmp_dir!(), "proxy-#{System.unique_integer([:positive])}.png")

    File.write!(scratch, "PNG!")
    Storage.put(key, scratch)
    File.rm(scratch)

    attachment
  end

  defp local_attachment(status) do
    Repo.insert!(%Attachment{
      status_id: status.id,
      account_id: status.account_id,
      type: :image,
      processing: :complete,
      file_file_name: "local.png",
      file_content_type: "image/png",
      remote_url: ""
    })
  end

  describe "what a client is told a remote file's address is" do
    test "is this server, not the one it came from", %{status: status} do
      attachment = remote_attachment(status)

      rendered = Entities.media_attachment(attachment)

      # Twelve servers learning the reader's address, their browser and which
      # posts they looked at is none of their business.
      assert rendered["url"] =~ "/media_proxy/#{attachment.id}/original"
      assert rendered["preview_url"] =~ "/media_proxy/#{attachment.id}/small"
      refute rendered["url"] =~ "remote.example"
    end

    test "still says where the file really came from", %{status: status} do
      attachment = remote_attachment(status)

      assert Entities.media_attachment(attachment)["remote_url"] ==
               "https://remote.example/pictures/one.png"
    end

    test "is left alone for a local file", %{status: status} do
      rendered = status |> local_attachment() |> Entities.media_attachment()

      refute rendered["url"] =~ "/media_proxy/"
    end
  end

  describe "GET /media_proxy/:id/:style" do
    test "refuses an id that is not one", %{conn: conn} do
      assert conn |> get(~p"/media_proxy/not-an-id/original") |> response(404)
    end

    test "refuses an id too large for the column", %{conn: conn} do
      assert conn |> get(~p"/media_proxy/99999999999999999999/original") |> response(404)
    end

    test "refuses a style nobody asked for", %{conn: conn, status: status} do
      attachment = remote_attachment(status)

      assert conn |> get(~p"/media_proxy/#{attachment.id}/enormous") |> response(404)
    end

    test "refuses a local attachment", %{conn: conn, status: status} do
      attachment = local_attachment(status)

      # The proxy exists to fetch somebody else's file. Going to the network
      # for one of ours would be this server asking a stranger for its own data.
      assert conn |> get(~p"/media_proxy/#{attachment.id}/original") |> response(404)
    end

    test "answers 404 when the other server will not give it", %{conn: conn, status: status} do
      attachment = remote_attachment(status)

      # No transport is configured in the test environment, so the fetch fails
      # the way an unreachable server does. A picture that will not come is a
      # picture that is not there, as far as the reader is concerned.
      assert conn |> get(~p"/media_proxy/#{attachment.id}/original") |> response(404)
    end
  end

  describe "how often one address may make this server fetch" do
    test "a stranger cannot walk the ids and make it fetch for each", %{
      conn: conn,
      status: status
    } do
      # Every miss is an outbound request to somebody else's server, at the
      # pace of whoever is asking. The proxy can only be pointed at rows this
      # server already holds, so it is not an open proxy -- but there is
      # nothing to stop one address naming a thousand of those rows in turn,
      # and each one costs a fetch. The reference implementation throttles this
      # route for the same reason.
      attachments = for _ <- 1..40, do: remote_attachment(status)

      answers =
        for attachment <- attachments do
          conn |> get(~p"/media_proxy/#{attachment.id}/original") |> Map.get(:status)
        end

      assert 429 in answers, "one address made forty fetches without being slowed down"
    end

    test "and a picture already here is not counted at all", %{conn: conn, status: status} do
      # The cost is the fetch, not the request. A reader scrolling a busy
      # timeline of pictures this server already holds must never be throttled
      # for reading what is on its own disk.
      attachment = stored_attachment(status)

      for _ <- 1..40 do
        assert conn |> get(~p"/media_proxy/#{attachment.id}/original") |> Map.get(:status) == 200
      end
    end
  end

  describe "GET /media/:id" do
    test "sends a media link to the post it belongs to", %{conn: conn, status: status} do
      attachment = local_attachment(status)

      # A file on its own is the least useful version of itself: the post is
      # where it has its caption, its author and its thread.
      assert conn |> get(~p"/media/#{attachment.id}") |> redirected_to() ==
               "/@alice/#{status.id}"
    end

    test "404s for a file with no post", %{conn: conn, account: account} do
      orphan =
        Repo.insert!(%Attachment{
          account_id: account.id,
          type: :image,
          processing: :complete,
          file_file_name: "loose.png"
        })

      assert conn |> get(~p"/media/#{orphan.id}") |> response(404)
    end

    test "404s for an id that is not one", %{conn: conn} do
      assert conn |> get(~p"/media/not-an-id") |> response(404)
    end
  end

  describe "GET /media/:id/player" do
    test "renders the file with nothing around it", %{conn: conn, status: status} do
      attachment = local_attachment(status)

      body = conn |> get(~p"/media/#{attachment.id}/player") |> response(200)

      assert body =~ "<img"
      # Nothing of this server: it is framed by other sites on purpose.
      refute body =~ "<nav"
    end

    test "uses a video tag for a video", %{conn: conn, status: status} do
      attachment =
        status
        |> local_attachment()
        |> Ecto.Changeset.change(type: :video)
        |> Repo.update!()

      assert conn |> get(~p"/media/#{attachment.id}/player") |> response(200) =~ "<video"
    end

    test "404s for an id that is not one", %{conn: conn} do
      assert conn |> get(~p"/media/not-an-id/player") |> response(404)
    end
  end
end
