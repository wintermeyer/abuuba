defmodule Abuuba.MediaTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Snowflake

  defp attachment_fixture(attrs \\ %{}) do
    account_id = Map.get_lazy(attrs, :account_id, fn -> account_fixture().id end)

    {:ok, attachment} =
      attrs
      |> Enum.into(%{account_id: account_id, type: :image, file_file_name: "cat.jpg"})
      |> Media.create_attachment()

    attachment
  end

  describe "create_attachment/1" do
    test "takes a snowflake id from the database" do
      attachment = attachment_fixture()

      assert attachment.id > 0

      assert DateTime.diff(Snowflake.to_time(attachment.id), DateTime.utc_now(), :second)
             |> abs() < 60
    end

    test "starts queued, unattached and local" do
      attachment = attachment_fixture()

      assert attachment.processing == :queued
      assert Attachment.unattached?(attachment)
      assert Attachment.local?(attachment)
      refute Attachment.ready?(attachment)
    end

    test "exists before any status does, which is the whole point" do
      assert %{status_id: nil} = attachment_fixture()
    end

    test "accepts every type and processing state the API knows" do
      for type <- ~w(image gifv video audio unknown)a do
        assert %{type: ^type} = attachment_fixture(%{type: type})
      end

      for state <- ~w(queued in_progress complete failed)a do
        assert %{processing: ^state} = attachment_fixture(%{processing: state})
      end
    end

    test "refuses a type or state it does not know" do
      assert {:error, changeset} = Media.create_attachment(%{type: :hologram})
      assert errors_on(changeset).type != []

      assert {:error, changeset} = Media.create_attachment(%{processing: :thinking})
      assert errors_on(changeset).processing != []
    end

    test "keeps the metadata the renderer needs" do
      meta = %{
        "original" => %{"width" => 1920, "height" => 1080},
        "focus" => %{"x" => -0.5, "y" => 0.25},
        "duration" => 12.5
      }

      attachment = attachment_fixture(%{meta: meta, blurhash: "LEHV6nWB2yk8pyo0adR*"})

      reloaded = Repo.get!(Attachment, attachment.id)
      assert reloaded.meta == meta
      assert reloaded.blurhash == "LEHV6nWB2yk8pyo0adR*"
    end

    test "refuses a negative file size" do
      assert {:error, changeset} = Media.create_attachment(%{file_file_size: -1})
      assert errors_on(changeset).file_file_size != []
    end
  end

  describe "remote_url" do
    test "is the empty string for a file we hold, never null" do
      # Mastodon's API returns "" here and clients test for it, so null would
      # be a different value with the same meaning.
      assert attachment_fixture().remote_url == ""
      assert attachment_fixture(%{remote_url: nil}).remote_url == ""
    end

    test "carries the address for a file somebody else holds" do
      attachment = attachment_fixture(%{remote_url: "https://remote.example/media/1.jpg"})

      refute Attachment.local?(attachment)
      assert attachment.remote_url == "https://remote.example/media/1.jpg"
    end
  end

  describe "alt text" do
    test "is stored and can be changed after the upload" do
      attachment = attachment_fixture()

      assert {:ok, described} = Media.describe(attachment, "a tabby cat asleep on a keyboard")
      assert described.description == "a tabby cat asleep on a keyboard"
    end

    test "treats whitespace as no description at all" do
      # Worse than nothing: a screen reader announces the image as described
      # and then reads out nothing.
      assert attachment_fixture(%{description: "   "}).description == nil
      assert {:ok, %{description: nil}} = Media.describe(attachment_fixture(), "  \n ")
    end

    test "is capped, generously" do
      assert {:error, changeset} =
               Media.create_attachment(%{
                 description: String.duplicate("a", Attachment.max_description() + 1)
               })

      assert errors_on(changeset).description != []
    end

    test "accepts a long description, because a good one is long" do
      long = String.duplicate("a", Attachment.max_description())

      assert %{description: ^long} = attachment_fixture(%{description: long})
    end
  end

  describe "processing" do
    test "moves to complete with the metadata the job produced" do
      attachment = attachment_fixture()

      assert {:ok, done} =
               Media.set_processing(attachment, :complete, %{
                 meta: %{"original" => %{"width" => 100, "height" => 100}},
                 thumbnail_file_name: "cat_small.jpg",
                 thumbnail_file_size: 4096
               })

      assert Attachment.ready?(done)
      assert done.thumbnail_file_name == "cat_small.jpg"
    end

    test "records a failure rather than losing the row" do
      attachment = attachment_fixture()

      assert {:ok, failed} = Media.set_processing(attachment, :failed)
      assert failed.processing == :failed
      refute Attachment.ready?(failed)
      assert Media.get_attachment(attachment.id).id == attachment.id
    end
  end

  describe "attaching to a status" do
    test "records the author's order on the status, not on the attachments" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id})

      first = attachment_fixture(%{account_id: account.id})
      second = attachment_fixture(%{account_id: account.id})
      third = attachment_fixture(%{account_id: account.id})

      order = [third.id, first.id, second.id]

      assert {:ok, updated} = Media.attach(status, order)
      assert updated.ordered_media_attachment_ids == order
      assert Enum.map(Media.for_status(updated), & &1.id) == order
    end

    test "refuses somebody else's upload" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id})
      theirs = attachment_fixture()

      assert {:error, :unknown_attachment} = Media.attach(status, [theirs.id])
      assert Repo.get!(Attachment, theirs.id).status_id == nil
    end

    test "refuses an upload already posted" do
      account = account_fixture()
      first = status_fixture(%{account_id: account.id})
      second = status_fixture(%{account_id: account.id})
      attachment = attachment_fixture(%{account_id: account.id})

      {:ok, _} = Media.attach(first, [attachment.id])

      assert {:error, :unknown_attachment} = Media.attach(second, [attachment.id])
    end

    test "attaches all of them or none" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id})
      mine = attachment_fixture(%{account_id: account.id})
      theirs = attachment_fixture()

      assert {:error, :unknown_attachment} = Media.attach(status, [mine.id, theirs.id])

      assert Repo.get!(Attachment, mine.id).status_id == nil,
             "a half-attached post shows some pictures and silently drops the rest"
    end

    test "for_status/1 still returns an attachment the status forgot to list" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id})
      attachment = attachment_fixture(%{account_id: account.id})

      {:ok, _} = Media.attach(status, [attachment.id])
      stripped = Repo.update!(Ecto.Changeset.change(status, ordered_media_attachment_ids: []))

      assert Enum.map(Media.for_status(stripped), & &1.id) == [attachment.id]
    end
  end

  describe "the media another server says a post carries" do
    setup do
      account = remote_account_fixture(%{username: "far", domain: "far.example"})

      %{account: account, status: status_fixture(%{account_id: account.id})}
    end

    defp document(url, overrides) do
      Enum.into(overrides, %{remote_url: url, file_content_type: "image/png"})
    end

    test "records them in the order they were listed", %{status: status} do
      {:ok, status} =
        Media.replace_remote(status, [
          document("https://far.example/a.png", %{}),
          document("https://far.example/b.png", %{})
        ])

      assert Enum.map(Media.for_status(status), & &1.remote_url) ==
               ["https://far.example/a.png", "https://far.example/b.png"]
    end

    test "keeps the row for a picture that is still there", %{status: status} do
      {:ok, status} = Media.replace_remote(status, [document("https://far.example/a.png", %{})])
      [before] = Media.for_status(status)

      {:ok, status} =
        Media.replace_remote(status, [
          document("https://far.example/a.png", %{description: "now with alt text"})
        ])

      [after_edit] = Media.for_status(status)

      # The id is what every cached `/media_proxy/<id>` URL names, in a browser
      # and in a CDN. Replacing the row on every edit re-pulls bytes this
      # server already has and orphans the copy it had.
      assert after_edit.id == before.id
      assert after_edit.description == "now with alt text"
    end

    test "drops one the sender no longer lists", %{status: status} do
      {:ok, status} =
        Media.replace_remote(status, [
          document("https://far.example/a.png", %{}),
          document("https://far.example/b.png", %{})
        ])

      gone = Enum.find(Media.for_status(status), &(&1.remote_url =~ "b.png"))

      {:ok, status} = Media.replace_remote(status, [document("https://far.example/a.png", %{})])

      assert Enum.map(Media.for_status(status), & &1.remote_url) == ["https://far.example/a.png"]
      refute Repo.get(Attachment, gone.id)
    end

    test "gives every row a key for both styles", %{status: status} do
      {:ok, status} = Media.replace_remote(status, [document("https://far.example/a.png", %{})])

      [attachment] = Media.for_status(status)

      # The small style is the URL every client asks for first. Without a name
      # for it there is no storage key, the proxy refuses, and every federated
      # picture renders as a broken thumbnail.
      assert Media.Storage.key_for(attachment, :original)
      assert Media.Storage.key_for(attachment, :small)
    end

    test "leaves the status with nothing when the sender lists nothing", %{status: status} do
      {:ok, status} = Media.replace_remote(status, [document("https://far.example/a.png", %{})])
      {:ok, status} = Media.replace_remote(status, [])

      assert Media.for_status(status) == []
      assert status.ordered_media_attachment_ids == []
    end
  end

  describe "the sweeper's view" do
    test "an attachment outlives the status it was on" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id})
      attachment = attachment_fixture(%{account_id: account.id})
      {:ok, _} = Media.attach(status, [attachment.id])

      Repo.delete!(status)

      orphan = Repo.get!(Attachment, attachment.id)
      assert Attachment.unattached?(orphan), "the file on disk needs a row to be found by"
    end

    test "an attachment outlives the account that uploaded it" do
      account = account_fixture()
      attachment = attachment_fixture(%{account_id: account.id})

      Repo.delete!(account)

      assert Repo.get!(Attachment, attachment.id).account_id == nil
    end

    test "collects uploads that were never posted and are old enough" do
      account = account_fixture()
      old = attachment_fixture(%{account_id: account.id})
      recent = attachment_fixture(%{account_id: account.id})

      Repo.update_all(
        from(a in Attachment, where: a.id == ^old.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -2, :day)]
      )

      collected = Media.unattached_before(DateTime.add(DateTime.utc_now(), -1, :day))
      ids = Enum.map(collected, & &1.id)

      assert old.id in ids
      refute recent.id in ids
    end

    test "leaves posted uploads alone however old they are" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id})
      attachment = attachment_fixture(%{account_id: account.id})
      {:ok, _} = Media.attach(status, [attachment.id])

      Repo.update_all(
        from(a in Attachment, where: a.id == ^attachment.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -365, :day)]
      )

      refute attachment.id in Enum.map(Media.unattached_before(DateTime.utc_now()), & &1.id)
    end
  end
end
