defmodule Abuuba.AccountListingTest do
  @moduledoc """
  Who this server puts in front of somebody who did not ask for them by name.

  Four surfaces answer that, and each carried its own spelling of the answer:
  the public directory, follow suggestions, the admin's popular list, and
  whether a post may feed the trends. The clauses had drifted -- the admin
  list and the trends check both still offered an account that had migrated
  away, and the admin docstring claimed it matched the suggestions it did not
  match.

  Written per surface rather than per clause, for the reason
  `AbuubaWeb.CollectionsVisibilityTest` gives: the bug is never that a rule was
  wrong, it is that a surface never asked it.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Suggestions
  alias Abuuba.Admin
  alias Abuuba.Relationships
  alias Abuuba.Trends

  setup do
    # Every surface below needs somebody to already follow the subject: two of
    # them rank by exactly that, and one is friend-of-a-friend.
    reader = account_fixture()
    friend = account_fixture(%{discoverable: true})
    subject = account_fixture(%{discoverable: true})

    {:ok, _} = Relationships.follow(reader, friend)
    {:ok, _} = Relationships.follow(friend, subject)

    %{reader: reader, subject: subject}
  end

  defp in_directory?(subject), do: subject.id in Enum.map(Accounts.directory(), & &1.id)

  defp suggested?(reader, subject),
    do: subject.id in Enum.map(Suggestions.for_account(reader), & &1.id)

  defp popular_for_admin?(subject),
    do: subject.id in Enum.map(Admin.suggestion_candidates(), & &1.id)

  defp trendable?(subject),
    do: Trends.eligible?(status_fixture(%{account_id: subject.id, text: "hello"}))

  describe "an account that has asked for nothing in particular" do
    test "is offered by all four", %{reader: reader, subject: subject} do
      # The control. Every assertion below is that something is absent, which a
      # server offering nobody anything would satisfy just as well.
      assert in_directory?(subject)
      assert suggested?(reader, subject)
      assert popular_for_admin?(subject)
      assert trendable?(subject)
    end
  end

  describe "an account that is not discoverable" do
    setup %{subject: subject} do
      {:ok, subject} = Accounts.update_profile(subject, %{"discoverable" => false})
      %{subject: subject}
    end

    test "is offered by none of them", %{reader: reader, subject: subject} do
      refute in_directory?(subject)
      refute suggested?(reader, subject)
      refute popular_for_admin?(subject)
      refute trendable?(subject)
    end
  end

  describe "an account a moderator suspended" do
    setup %{subject: subject} do
      {:ok, subject} = Accounts.update_moderation(subject, %{suspended_at: DateTime.utc_now()})
      %{subject: subject}
    end

    test "is offered by none of them", %{reader: reader, subject: subject} do
      refute in_directory?(subject)
      refute suggested?(reader, subject)
      refute popular_for_admin?(subject)
      refute trendable?(subject)
    end
  end

  describe "an account a moderator limited" do
    setup %{subject: subject} do
      {:ok, subject} = Accounts.update_moderation(subject, %{silenced_at: DateTime.utc_now()})
      %{subject: subject}
    end

    test "is offered by none of them", %{reader: reader, subject: subject} do
      refute in_directory?(subject)
      refute suggested?(reader, subject)
      refute popular_for_admin?(subject)
      refute trendable?(subject)
    end
  end

  describe "an account that has migrated away" do
    setup %{subject: subject} do
      # The column is set directly because what is under test is the listing,
      # not the migration that writes it.
      {:ok, subject} =
        subject
        |> Ecto.Changeset.change(moved_to_account_id: account_fixture().id)
        |> Repo.update()

      %{subject: subject}
    end

    test "is offered by none of them", %{reader: reader, subject: subject} do
      # Two of these were the bug: pointing a newcomer at an account that will
      # never post again, and letting one drive what the server is talking
      # about today.
      refute in_directory?(subject)
      refute suggested?(reader, subject)
      refute popular_for_admin?(subject)
      refute trendable?(subject)
    end
  end

  describe "the clauses that are genuinely one surface's own" do
    test "the directory is local and the other three are not", %{reader: reader} do
      # Nobody on another server agreed to appear in our directory. They can
      # still be suggested, be popular, and be part of a trend.
      friend = account_fixture(%{discoverable: true})
      elsewhere = remote_account_fixture(%{domain: "remote.example", discoverable: true})

      {:ok, _} = Relationships.follow(reader, friend)
      {:ok, _} = Relationships.follow(friend, elsewhere)

      refute in_directory?(elsewhere)
      assert suggested?(reader, elsewhere)
      assert popular_for_admin?(elsewhere)
    end

    test "only the trends honour trendable", %{reader: reader, subject: subject} do
      # A moderator can stop an account trending without taking it out of the
      # directory, which is a smaller thing than limiting them.
      {:ok, subject} = Accounts.update_moderation(subject, %{trendable: false})

      assert in_directory?(subject)
      assert suggested?(reader, subject)
      assert popular_for_admin?(subject)
      refute trendable?(subject)
    end
  end
end
