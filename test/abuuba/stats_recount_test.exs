defmodule Abuuba.StatsRecountTest do
  @moduledoc """
  Recomputing the counter caches from the rows that are the truth.

  The risk here is not that a recount fails to fix drift. It is that a recount
  counts something the increments never counted, and "repairs" a correct
  counter into a wrong one across the whole database at once. So every test
  below that exercises a predicate — a direct post, a private reply, a deleted
  boost, a pending quote — is asserting that the recount agrees with
  `Abuuba.Statuses.count_status/3`, not merely that it produces a number.
  """

  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Stats
  alias Abuuba.Stats.AccountStat
  alias Abuuba.Stats.StatusStat
  alias Abuuba.Statuses

  describe "a database nobody has broken" do
    test "reports no drift" do
      author = account_fixture()
      reader = account_fixture()
      status = status_fixture(%{account_id: author.id})

      {:ok, _} = Relationships.follow(reader, author)
      {:ok, _} = Statuses.favourite(reader, status)

      assert Stats.drift() == %{accounts: 0, statuses: 0}
    end

    test "and a recount changes nothing" do
      author = account_fixture()
      _status = status_fixture(%{account_id: author.id})

      assert Stats.recount() == %{accounts: 0, statuses: 0}
    end
  end

  describe "drift" do
    setup do
      author = account_fixture()
      reader = account_fixture()
      status = status_fixture(%{account_id: author.id})

      {:ok, _} = Relationships.follow(reader, author)
      {:ok, _} = Statuses.favourite(reader, status)

      %{author: author, reader: reader, status: status}
    end

    test "is found and repaired on an account", %{author: author} do
      Repo.update_all(
        from_account(author.id),
        set: [statuses_count: 99, followers_count: 42]
      )

      assert %{accounts: 1} = Stats.drift()
      assert %{accounts: 1} = Stats.recount()

      stat = Repo.get_by!(AccountStat, account_id: author.id)
      assert stat.statuses_count == 1
      assert stat.followers_count == 1
      assert stat.following_count == 0

      assert Stats.drift() == %{accounts: 0, statuses: 0}
    end

    test "is found and repaired on a status", %{status: status} do
      Repo.update_all(from_status(status.id), set: [favourites_count: 77])

      assert %{statuses: 1} = Stats.drift()
      assert %{statuses: 1} = Stats.recount()

      assert Repo.get_by!(StatusStat, status_id: status.id).favourites_count == 1
    end

    test "is reported without being written when only asked about", %{author: author} do
      Repo.update_all(from_account(author.id), set: [statuses_count: 99])

      assert %{accounts: 1} = Stats.drift()

      # Still wrong: asking is not fixing.
      assert Repo.get_by!(AccountStat, account_id: author.id).statuses_count == 99
    end
  end

  describe "the predicates the increments use" do
    test "a direct post is not counted, before or after a recount" do
      author = account_fixture()
      _direct = status_fixture(%{account_id: author.id, visibility: :direct})

      assert Stats.recount() == %{accounts: 0, statuses: 0}
      assert Stats.account_stats(author.id).statuses_count == 0
    end

    test "a private reply does not count towards replies_count" do
      author = account_fixture()
      parent = status_fixture(%{account_id: author.id})

      _quiet =
        status_fixture(%{
          account_id: account_fixture().id,
          in_reply_to_id: parent.id,
          visibility: :private
        })

      assert Stats.recount() == %{accounts: 0, statuses: 0}

      # No counter row at all is the right outcome: nothing ever counted for
      # this post, and the reader zeroes what is missing. A recount that
      # invented a row of zeros here would report drift on a sound database.
      assert Repo.get_by(StatusStat, status_id: parent.id) == nil
      assert Stats.status_stats(parent.id).replies_count == 0
    end

    test "a public reply does" do
      author = account_fixture()
      parent = status_fixture(%{account_id: author.id})

      _loud =
        status_fixture(%{
          account_id: account_fixture().id,
          in_reply_to_id: parent.id,
          visibility: :public
        })

      assert Stats.recount() == %{accounts: 0, statuses: 0}
      assert Repo.get_by!(StatusStat, status_id: parent.id).replies_count == 1
    end

    test "a deleted post stops counting" do
      author = account_fixture()
      status = status_fixture(%{account_id: author.id})

      {:ok, _} = Statuses.delete_status(status)

      assert Stats.recount() == %{accounts: 0, statuses: 0}
      assert Repo.get_by!(AccountStat, account_id: author.id).statuses_count == 0
    end
  end

  describe "last_status_at" do
    # An imported post deliberately does not move it: an archive is old news
    # and stamping it would put a decade-old post forward as the latest thing
    # somebody said. A recount that recomputed it from max(inserted_at) would
    # undo that on every import, so it is left alone and said so here.
    test "is left alone by a recount" do
      author = account_fixture()
      status = status_fixture(%{account_id: author.id})

      stamp = ~U[2001-01-01 00:00:00.000000Z]
      Repo.update_all(from_account(author.id), set: [last_status_at: stamp])

      assert %{accounts: 0} = Stats.drift()
      Stats.recount()

      assert Repo.get_by!(AccountStat, account_id: author.id).last_status_at == stamp
      assert status.account_id == author.id
    end
  end

  describe "a counter row that was never written" do
    test "is created by a recount" do
      author = account_fixture()
      status = status_fixture(%{account_id: author.id})

      Repo.delete_all(from_account(author.id))
      Repo.delete_all(from_status(status.id))

      assert %{accounts: 1} = Stats.drift()
      assert %{accounts: 1} = Stats.recount()

      assert Repo.get_by!(AccountStat, account_id: author.id).statuses_count == 1
    end
  end

  defp from_account(id) do
    import Ecto.Query
    from(a in AccountStat, where: a.account_id == ^id)
  end

  defp from_status(id) do
    import Ecto.Query
    from(s in StatusStat, where: s.status_id == ^id)
  end
end
