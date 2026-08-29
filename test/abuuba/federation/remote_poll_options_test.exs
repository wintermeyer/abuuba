defmodule Abuuba.Federation.RemotePollOptionsTest do
  @moduledoc """
  A poll with more options than ours may have still arrives.

  Four is what this server offers its own people, matching the reference
  implementation's default. Other implementations offer ten or twenty, and the
  four-option rule was applied to their polls too -- so the post arrived and
  the poll did not, leaving a question on the timeline with nothing to vote on
  and nothing to say why.

  `Abuuba.Federation.Limits` has had a bound for this since it was written and
  nothing ever called it.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.Limits
  alias Abuuba.Statuses

  defp remote_status do
    author = remote_account_fixture(%{username: "alice", domain: "remote.example"})

    status_fixture(%{
      account_id: author.id,
      local: false,
      uri: "https://remote.example/statuses/#{System.unique_integer([:positive])}",
      text: "which one?"
    })
  end

  test "a ten-option poll from another server is kept" do
    status = remote_status()
    options = for n <- 1..10, do: "option #{n}"

    :ok =
      Statuses.replace_remote_poll(status, %{
        options: options,
        tallies: List.duplicate(0, 10),
        multiple: false,
        voters_count: 0,
        uri: "https://remote.example/polls/1"
      })

    poll = Statuses.get_poll(status)

    assert poll, "the poll was dropped and the question left unanswerable"
    assert length(poll.options) == 10
  end

  test "and one with absurdly many is bounded rather than unbounded" do
    status = remote_status()
    options = for n <- 1..(Limits.poll_options_max() + 1), do: "option #{n}"

    :ok =
      Statuses.replace_remote_poll(status, %{
        options: options,
        tallies: List.duplicate(0, length(options)),
        multiple: false,
        voters_count: 0,
        uri: "https://remote.example/polls/2"
      })

    assert Statuses.get_poll(status) == nil
  end

  test "while our own are still held to four" do
    # The control: the latitude is for polls this server did not write.
    author = account_fixture()
    status = status_fixture(%{account_id: author.id, text: "which one?"})

    assert {:error, changeset} =
             Statuses.create_poll(status, %{
               options: ["a", "b", "c", "d", "e"],
               expires_in: 3600
             })

    assert %{options: [_message]} = errors_on(changeset)
  end
end
