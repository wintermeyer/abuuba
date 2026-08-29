defmodule Abuuba.Statuses.ReplyAuthorTest do
  @moduledoc """
  A reply records whose post it answers.

  Read by clients to draw "in reply to @somebody", and by fan-out to decide
  who a reply is shown to — so a reply missing it is not merely unlabelled, it
  reaches a different set of people.
  """

  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Statuses

  describe "create_status/2" do
    test "fills in whose post is being replied to" do
      parent = status_fixture(%{text: "a question"})
      reply = status_fixture(%{text: "an answer", in_reply_to_id: parent.id})

      assert reply.in_reply_to_account_id == parent.account_id
    end

    test "including when somebody replies to themselves" do
      author = account_fixture()
      root = status_fixture(%{account_id: author.id, text: "one of two"})
      second = status_fixture(%{account_id: author.id, text: "two", in_reply_to_id: root.id})

      assert second.in_reply_to_account_id == author.id
    end

    test "leaves it alone on a post that replies to nothing" do
      status = status_fixture(%{text: "on its own"})

      refute status.in_reply_to_account_id
    end

    test "and a caller that names one is believed" do
      # The importer carries the value from the server it is importing from,
      # where the parent may not exist here at all.
      parent = status_fixture(%{text: "a question"})
      someone = account_fixture()

      reply =
        status_fixture(%{
          text: "an answer",
          in_reply_to_id: parent.id,
          in_reply_to_account_id: someone.id
        })

      assert reply.in_reply_to_account_id == someone.id
    end

    test "string keys work too, because that is what the API hands it" do
      # Straight to the context rather than through the fixture, which adds
      # atom-keyed defaults: Ecto refuses a params map that mixes the two, and
      # a real caller uses one style throughout.
      parent = status_fixture(%{text: "a question"})

      {:ok, reply} =
        Statuses.create_status(%{
          "account_id" => account_fixture().id,
          "text" => "an answer",
          "in_reply_to_id" => to_string(parent.id)
        })

      assert reply.in_reply_to_account_id == parent.account_id
      assert reply.conversation_id == parent.conversation_id
    end
  end
end
