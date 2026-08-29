defmodule Abuuba.ExportImportRoundTripTest do
  @moduledoc """
  An archive this server writes, opened by the importer this server ships.

  Both halves had tests and both passed while the round trip was broken: the
  exporter was checked against what another server's importer wants and the
  importer against what another server's exporter writes, and nobody put our
  own two ends together. The result was an archive whose bookmarks the
  importer walked straight past -- `bookmarks.csv` written, `bookmarks.json`
  read -- and favourites that were not in the zip at all.

  That is the same shape as a stubbed transport: two sides each tested against
  a fixture it wrote itself, and the seam between them never once exercised.
  """
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Exports
  alias Abuuba.Exports.Worker
  alias Abuuba.Federation.Serializer
  alias Abuuba.Importer.Archive
  alias Abuuba.Statuses

  setup do
    account = account_fixture()
    other = account_fixture()

    mine = status_fixture(%{account_id: account.id, text: "something I wrote"})
    theirs = status_fixture(%{account_id: other.id, text: "something I kept"})
    also = status_fixture(%{account_id: other.id, text: "something I liked"})

    {:ok, _} = Statuses.bookmark(account, theirs)
    {:ok, _} = Statuses.favourite(account, also)

    %{account: account, mine: mine, theirs: theirs, also: also}
  end

  defp build(account) do
    {:ok, export} = Exports.request(account)
    :ok = Worker.perform(%Oban.Job{args: %{"export_id" => export.id}})

    export = Repo.reload!(export)
    assert export.state == "done", "the export failed: #{export.error}"

    on_exit(fn -> File.rm_rf(export.path) end)

    export
  end

  defp opened(export) do
    into = Path.join(System.tmp_dir!(), "round-trip-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(into) end)

    {:ok, archive} = Archive.open(export.path, into)

    archive
  end

  describe "an archive from here" do
    test "carries what the importer here reads", %{account: account, theirs: theirs, also: also} do
      archive = account |> build() |> opened()

      assert length(archive.outbox) == 1
      assert archive.bookmarks == [Serializer.status_uri(theirs)]
      assert archive.likes == [Serializer.status_uri(also)]
    end

    test "and still carries the CSVs another server's settings importer reads", %{
      account: account
    } do
      export = build(account)

      {:ok, listing} = :zip.list_dir(String.to_charlist(export.path))
      names = for {:zip_file, name, _, _, _, _} <- listing, do: to_string(name)

      # The two shapes are for two different jobs rather than one written
      # twice: a spreadsheet of handles, and a collection of post addresses.
      assert "bookmarks.csv" in names
      assert "bookmarks.json" in names
      assert "likes.json" in names
      assert "outbox.json" in names
      assert "actor.json" in names
    end

    test "and says nothing kept when nothing was kept" do
      bare = account_fixture()

      archive = bare |> build() |> opened()

      assert archive.likes == []
      assert archive.bookmarks == []
    end
  end
end
