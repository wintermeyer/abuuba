defmodule Abuuba.PollsTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll

  setup do
    author = account_fixture()

    %{author: author, status: status_fixture(%{account_id: author.id})}
  end

  # A poll belongs to one status, so a second poll needs a second post.
  defp another_post(status), do: status_fixture(%{account_id: status.account_id})

  defp poll(status, attrs \\ %{}) do
    {:ok, poll} =
      Statuses.create_poll(status, Map.merge(%{options: ["yes", "no"], multiple: false}, attrs))

    poll
  end

  describe "creating a poll" do
    test "starts every option at nothing", %{status: status} do
      assert %Poll{options: ["yes", "no"], tallies: [0, 0], voters_count: 0} = poll(status)
    end

    test "needs at least two options, because one is not a question", %{status: status} do
      assert {:error, changeset} = Statuses.create_poll(status, %{options: ["only"]})
      assert %{options: [_]} = errors_on(changeset)
    end

    test "refuses more options than a client can render", %{status: status} do
      options = for i <- 1..9, do: "option #{i}"

      assert {:error, changeset} = Statuses.create_poll(status, %{options: options})
      assert %{options: [_]} = errors_on(changeset)
    end

    test "refuses two options with the same text", %{status: status} do
      # A voter cannot tell which one they picked, and neither can anybody
      # reading the result.
      assert {:error, changeset} = Statuses.create_poll(status, %{options: ["yes", "yes"]})
      assert %{options: [_]} = errors_on(changeset)
    end

    test "refuses an option that is only whitespace", %{status: status} do
      assert {:error, _} = Statuses.create_poll(status, %{options: ["yes", "   "]})
    end

    test "belongs to whoever wrote the post", %{status: status, author: author} do
      assert poll(status).account_id == author.id
    end
  end

  describe "voting" do
    setup %{status: status} do
      %{poll: poll(status), voter: account_fixture()}
    end

    test "counts one answer", %{poll: poll, voter: voter} do
      assert {:ok, poll} = Statuses.vote(poll, voter, [0])

      assert poll.tallies == [1, 0]
      assert poll.voters_count == 1
    end

    test "counts people once however many boxes they tick", %{status: status, voter: voter} do
      # `voters_count` is people and the tallies are answers. On a poll that
      # allows several, the two stop being the same number, and clients show
      # the first as the turnout.
      poll =
        poll(another_post(status), %{
          options: ["a", "b", "c"],
          multiple: true
        })

      assert {:ok, poll} = Statuses.vote(poll, voter, [0, 2])

      assert poll.tallies == [1, 0, 1]
      assert poll.voters_count == 1
    end

    test "refuses a second answer to a single-choice poll", %{poll: poll, voter: voter} do
      {:ok, _} = Statuses.vote(poll, voter, [0])

      assert Statuses.vote(poll, voter, [1]) == {:error, :already_voted}
    end

    test "refuses two choices on a single-choice poll", %{poll: poll, voter: voter} do
      assert Statuses.vote(poll, voter, [0, 1]) == {:error, :too_many_choices}
    end

    test "refuses an option that does not exist", %{poll: poll, voter: voter} do
      assert Statuses.vote(poll, voter, [7]) == {:error, :invalid_choice}
      assert Statuses.vote(poll, voter, [-1]) == {:error, :invalid_choice}
    end

    test "refuses no choice at all", %{poll: poll, voter: voter} do
      assert Statuses.vote(poll, voter, []) == {:error, :invalid_choice}
    end

    test "refuses a poll that has closed", %{status: status, voter: voter} do
      closed =
        poll(another_post(status), %{
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert Statuses.vote(closed, voter, [0]) == {:error, :expired}
    end

    test "refuses the author voting in their own poll", %{poll: poll, author: author} do
      # The reference implementation does the same. A poll is a question you
      # asked, and answering it yourself is not something clients offer.
      assert Statuses.vote(poll, author, [0]) == {:error, :own_poll}
    end

    test "two people are two votes", %{poll: poll} do
      {:ok, _} = Statuses.vote(poll, account_fixture(), [0])
      {:ok, poll} = Statuses.vote(poll, account_fixture(), [0])

      assert poll.tallies == [2, 0]
      assert poll.voters_count == 2
    end
  end

  describe "reading a poll back" do
    setup %{status: status} do
      %{poll: poll(status), voter: account_fixture()}
    end

    test "says which options a reader picked", %{poll: poll, voter: voter} do
      {:ok, _} = Statuses.vote(poll, voter, [1])

      assert Statuses.own_votes(poll, voter) == [1]
    end

    test "says nothing for somebody who has not voted", %{poll: poll} do
      assert Statuses.own_votes(poll, account_fixture()) == []
      assert Statuses.own_votes(poll, nil) == []
    end

    test "knows when it has closed", %{status: status} do
      closed =
        poll(another_post(status), %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })

      assert Poll.expired?(closed)
      refute Poll.expired?(poll(another_post(status)))
    end
  end
end
