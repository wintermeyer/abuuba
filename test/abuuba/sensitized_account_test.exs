defmodule Abuuba.SensitizedAccountTest do
  @moduledoc """
  What "mark posts as sensitive" does once a moderator has taken it.

  The action wrote `sensitized_at` and nothing read it, so the whole of its
  effect was a column and a line in the admin API. These tests are about the
  three places the mark has to reach for the moderator's decision to mean
  anything: what a reader is served, what a peer is sent, and what arrives
  from a peer whose author we have marked here.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Federation.Serializer
  alias AbuubaWeb.API.Entities

  setup do
    author = account_fixture()
    reader = account_fixture()
    status = status_fixture(%{account_id: author.id, text: "a picture of my lunch"})

    %{author: author, reader: reader, status: status}
  end

  defp sensitize(account) do
    {:ok, account} = Accounts.update_moderation(account, %{sensitized_at: DateTime.utc_now()})
    account
  end

  describe "a post by a sensitized account" do
    test "is served to a reader as sensitive", %{
      author: author,
      reader: reader,
      status: status
    } do
      refute Entities.status(status, reader)["sensitive"]

      sensitize(author)

      assert Entities.status(status, reader)["sensitive"]
    end

    test "and to a stranger with no account at all", %{author: author, status: status} do
      sensitize(author)

      assert Entities.status(status, nil)["sensitive"]
    end

    test "but its author still sees what they wrote", %{author: author, status: status} do
      # A moderator marking an account is not an edit to somebody's post. The
      # author's own view of it stays as they left it, which is also what stops
      # the flag being silently baked in the next time they edit.
      sensitize(author)

      refute Entities.status(status, author)["sensitive"]
    end

    test "goes out to other servers marked as well", %{author: author, status: status} do
      refute Serializer.note(status)["sensitive"]

      sensitize(author)

      assert Serializer.note(Abuuba.Repo.reload!(status))["sensitive"]
    end
  end

  describe "a post arriving from a sensitized account" do
    @uri "https://remote.example/statuses/1"
    @actor "https://remote.example/users/alice"

    setup do
      remote =
        remote_account_fixture(%{username: "alice", domain: "remote.example", uri: @actor})

      %{remote: remote}
    end

    defp resolve(remote, document) do
      ResolveStatus.resolve(document["id"],
        fetch: fn _uri -> {:ok, document} end,
        resolve_actor: fn _uri -> {:ok, remote} end
      )
    end

    defp note(overrides) do
      Map.merge(
        %{
          "id" => @uri,
          "type" => "Note",
          "attributedTo" => @actor,
          "content" => "<p>hello</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        },
        overrides
      )
    end

    test "is stored sensitive whatever it said about itself", %{remote: remote} do
      assert {:ok, plain} = resolve(remote, note(%{"sensitive" => false}))
      refute plain.sensitive

      marked_author = sensitize(remote)

      assert {:ok, marked} =
               resolve(marked_author, note(%{"id" => @uri <> "/2", "sensitive" => false}))

      assert marked.sensitive
    end
  end
end
