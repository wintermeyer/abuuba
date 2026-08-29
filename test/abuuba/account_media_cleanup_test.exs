defmodule Abuuba.AccountMediaCleanupTest do
  @moduledoc """
  What happens to somebody's pictures when their account goes.

  `media_attachments.account_id` is `nilify_all` while `statuses.account_id` is
  `delete_all`, so deleting an account took the posts and left the pictures:
  rows owned by nobody, and bytes on the disk that nothing named. The only
  thing that reclaimed them was a mix task an admin had to remember, and the
  settings page tells somebody their account is deleted.

  Found by running it rather than reading it -- the file was still there
  afterwards, which is the only assertion here that could not have been
  written from the schema.
  """
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Exports
  alias Abuuba.Media
  alias Abuuba.Media.OrphanWorker
  alias Abuuba.Media.ProfileImages
  alias Abuuba.Media.Storage

  defp attachment_with_file(account, attrs \\ %{}) do
    {:ok, attachment} =
      Media.create_attachment(
        Map.merge(
          %{
            account_id: account.id,
            type: :image,
            processing: :complete,
            file_file_name: "photo.png",
            file_content_type: "image/png",
            file_file_size: 4
          },
          attrs
        )
      )

    key = Storage.key_for(attachment, :original)
    scratch = Path.join(System.tmp_dir!(), "cleanup-#{System.unique_integer([:positive])}.png")
    File.write!(scratch, "PNG!")
    Storage.put(key, scratch)
    File.rm(scratch)

    assert Storage.exists?(key)

    {attachment, key}
  end

  describe "closing an account" do
    test "takes its pictures with it, rows and bytes", %{} do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id, text: "with a picture"})
      {attachment, key} = attachment_with_file(account, %{status_id: status.id})

      {:ok, _} = Accounts.delete_account(account)

      refute Repo.get(Media.Attachment, attachment.id)
      refute Storage.exists?(key)
    end

    test "including one that was never posted", %{} do
      account = account_fixture()
      {attachment, key} = attachment_with_file(account)

      {:ok, _} = Accounts.delete_account(account)

      refute Repo.get(Media.Attachment, attachment.id)
      refute Storage.exists?(key)
    end

    test "and the two pictures that are columns rather than rows", %{} do
      # The avatar and the header are not attachments, so neither the cascade
      # nor the orphan sweep can reach them: the sweep looks for attachment
      # rows with no post, and a profile picture has never been one.
      account = account_fixture()

      {:ok, account} =
        Accounts.update_account(account, %{
          avatar_file_name: "face.png",
          avatar_content_type: "image/png",
          avatar_file_size: 4,
          avatar_updated_at: DateTime.utc_now(),
          header_file_name: "banner.png",
          header_content_type: "image/png",
          header_file_size: 4,
          header_updated_at: DateTime.utc_now()
        })

      keys = for kind <- ProfileImages.kinds(), do: profile_key(account, kind)

      for key <- keys do
        scratch = Path.join(System.tmp_dir!(), "profile-#{System.unique_integer([:positive])}")
        File.write!(scratch, "PNG!")
        Storage.put(key, scratch)
        File.rm(scratch)
        assert Storage.exists?(key)
      end

      {:ok, _} = Accounts.delete_account(account)

      for key <- keys, do: refute(Storage.exists?(key))
    end

    test "and the archive it built of itself", %{} do
      # An export is the whole account in one file, kept for two days for that
      # reason. The rows are `delete_all`, so the cascade took them and left
      # the zips: the sweep that removes a file only sees rows past their
      # expiry, and a deleted row never gets there.
      account = account_fixture()
      status_fixture(%{account_id: account.id, text: "in the archive"})

      {:ok, export} = Exports.request(account)
      :ok = Exports.Worker.perform(%Oban.Job{args: %{"export_id" => export.id}})
      export = Repo.reload!(export)

      assert export.state == "done"
      assert File.exists?(export.path)

      {:ok, _} = Accounts.delete_account(account)

      refute File.exists?(export.path)
    end

    test "and leaves everybody else's alone", %{} do
      account = account_fixture()
      bystander = account_fixture()
      {_mine, mine_key} = attachment_with_file(account)
      {theirs, theirs_key} = attachment_with_file(bystander)

      {:ok, _} = Accounts.delete_account(account)

      # The control. Every other assertion here is that something went, which a
      # sweep that emptied the table would satisfy as well.
      assert Repo.get(Media.Attachment, theirs.id)
      assert Storage.exists?(theirs_key)
      refute Storage.exists?(mine_key)
    end
  end

  describe "the orphan sweep" do
    test "takes an upload nobody posted, once it is a day old", %{} do
      account = account_fixture()
      {attachment, key} = attachment_with_file(account)

      # Younger than a day: the ordinary state of a picture somebody is in the
      # middle of posting.
      assert :ok = OrphanWorker.perform(%Oban.Job{args: %{}})
      assert Repo.get(Media.Attachment, attachment.id)
      assert Storage.exists?(key)

      age(attachment, 2)

      assert :ok = OrphanWorker.perform(%Oban.Job{args: %{}})
      refute Repo.get(Media.Attachment, attachment.id)
      refute Storage.exists?(key)
    end

    test "and leaves one that is on a post", %{} do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id})
      {attachment, key} = attachment_with_file(account, %{status_id: status.id})

      age(attachment, 2)

      assert :ok = OrphanWorker.perform(%Oban.Job{args: %{}})

      assert Repo.get(Media.Attachment, attachment.id)
      assert Storage.exists?(key)
    end
  end

  # The storage layer derives this from the row; a test that hard-coded the
  # shape would pass while the two disagreed.
  defp profile_key(account, kind) do
    account
    |> ProfileImages.url(kind)
    |> String.split("/media/", parts: 2)
    |> List.last()
  end

  defp age(attachment, days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    attachment |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end
end
