defmodule Abuuba.PollExpiryTest do
  @moduledoc """
  Being told a poll has closed.

  `poll` was a declared notification type that nothing produced: it is in the
  type list, the per-type filters, the push titles and the labels, and
  `notify/4` was never called with it. A poll is the one kind of post whose
  point arrives after the post does, so somebody who voted was left to go back
  and look.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Notifications
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.PollExpiry

  setup do
    %{author: account_fixture(), voter: account_fixture()}
  end

  # `expires_at` in the past, which is the state the worker looks for. Written
  # rather than waited for: a test that sleeps until a poll closes is a test
  # that takes as long as the poll.
  defp closed_poll(author, opts \\ []) do
    minutes = Keyword.get(opts, :ago, 5)

    {:ok, status} =
      Statuses.create_status(%{account_id: author.id, text: "tea or coffee?"},
        poll: %{
          "options" => ["tea", "coffee"],
          "expires_in" => 3600
        }
      )

    poll = Repo.get_by!(Poll, status_id: status.id)

    {:ok, poll} =
      poll
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -minutes, :minute))
      |> Repo.update()

    {status, poll}
  end

  defp types(account), do: account |> Notifications.list() |> Enum.map(& &1.type)

  describe "a poll that has closed" do
    test "tells its author", %{author: author} do
      {status, _poll} = closed_poll(author)

      assert {:ok, 1} = PollExpiry.run()

      assert types(author) == ["poll"]
      assert [%{status_id: id}] = Notifications.list(author)
      assert id == status.id
    end

    test "and everybody who voted in it", %{author: author, voter: voter} do
      {_status, poll} = closed_poll(author)
      # Voting is refused once the poll is closed, so the vote goes in while it
      # is still open and the clock is moved afterwards.
      {:ok, open} = Repo.update(Ecto.Changeset.change(poll, expires_at: hours_from_now(1)))
      {:ok, _vote} = Statuses.vote(open, voter, [0])
      {:ok, _} = Repo.update(Ecto.Changeset.change(open, expires_at: minutes_ago(5)))

      assert {:ok, 1} = PollExpiry.run()

      assert types(voter) == ["poll"]
      assert types(author) == ["poll"]
    end

    test "once, however often the worker runs", %{author: author} do
      closed_poll(author)

      assert {:ok, 1} = PollExpiry.run()
      assert {:ok, 0} = PollExpiry.run()
      assert {:ok, 0} = PollExpiry.run()

      assert types(author) == ["poll"]
    end
  end

  describe "a poll that has not closed" do
    test "tells nobody", %{author: author} do
      {_status, poll} = closed_poll(author)
      {:ok, _} = Repo.update(Ecto.Changeset.change(poll, expires_at: hours_from_now(1)))

      assert {:ok, 0} = PollExpiry.run()
      assert types(author) == []
    end

    test "and neither does one with no closing time at all", %{author: author} do
      {_status, poll} = closed_poll(author)
      {:ok, _} = Repo.update(Ecto.Changeset.change(poll, expires_at: nil))

      assert {:ok, 0} = PollExpiry.run()
      assert types(author) == []
    end

    test "and neither does one whose post has been deleted", %{author: author} do
      {status, _poll} = closed_poll(author)
      {:ok, _} = Statuses.delete_status(status)

      assert {:ok, 0} = PollExpiry.run()
      assert types(author) == []
    end
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes, :minute)
  defp hours_from_now(hours), do: DateTime.add(DateTime.utc_now(), hours, :hour)
end
