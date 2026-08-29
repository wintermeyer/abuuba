defmodule Abuuba.Security.SpoofingTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Federation.Activity
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status

  # Object spoofing: one server writing a document that claims to be another
  # server's. Every one of these is somebody putting words in an account's
  # mouth, which is the worst thing this protocol can be made to do.

  defp author do
    account_fixture(%{
      domain: "author.example",
      uri: "https://author.example/users/alice",
      inbox_url: "https://author.example/users/alice/inbox"
    })
  end

  defp note(overrides) do
    Map.merge(
      %{
        "id" => "https://author.example/statuses/1",
        "type" => "Note",
        "attributedTo" => "https://author.example/users/alice",
        "content" => "<p>hello</p>",
        "published" => "2026-01-01T00:00:00Z",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      },
      overrides
    )
  end

  describe "a post claiming to be from somewhere else" do
    test "is refused when its id and its author are on different hosts" do
      # The whole rule: a server may speak for its own accounts and for nobody
      # else's. Without it, any server can publish a post as anybody.
      author()

      assert {:error, :untrustworthy_attribution} =
               ResolveStatus.from_document(
                 note(%{"id" => "https://evil.example/statuses/1"}),
                 transport: refuses()
               )
    end

    test "and when the author is named as a bare handle with no host" do
      author()

      assert {:error, :untrustworthy_attribution} =
               ResolveStatus.from_document(note(%{"attributedTo" => "alice"}),
                 transport: refuses()
               )
    end

    test "and when it has no id at all" do
      assert {:error, :object_without_id} =
               ResolveStatus.from_document(note(%{"id" => nil}), transport: refuses())
    end

    test "and when it is not a post" do
      # An object type this server has no rules for is not one to store and
      # hope.
      assert {:error, :unsupported_object_type} =
               ResolveStatus.from_document(note(%{"type" => "Person"}), transport: refuses())
    end
  end

  describe "a Create wrapping somebody else's post" do
    test "does not store it" do
      # The activity's actor and the object's author are two different claims,
      # and an attacker controls both. The object's own attribution is what
      # decides.
      author()

      activity = %{
        "type" => "Create",
        "actor" => "https://evil.example/users/nobody",
        "object" => note(%{"id" => "https://evil.example/statuses/9"})
      }

      Activity.Create.handle(activity, transport: refuses())

      refute Repo.get_by(Status, uri: "https://evil.example/statuses/9")
    end
  end

  describe "a Delete for somebody else's post" do
    test "leaves it alone" do
      # Otherwise any server on the network can delete any post on it.
      account = author()

      {:ok, status} =
        Statuses.create_status(%{
          account_id: account.id,
          text: "still here",
          visibility: :public,
          uri: "https://author.example/statuses/2"
        })

      Activity.Delete.handle(
        %{
          "type" => "Delete",
          "actor" => "https://evil.example/users/nobody",
          "object" => "https://author.example/statuses/2"
        },
        transport: refuses()
      )

      assert %Status{deleted_at: nil} = Repo.get(Status, status.id)
    end
  end

  # Nothing here is allowed to reach the network: a test that quietly fetched
  # the document it was asked about would be testing the fetch rather than the
  # rule.
  defp refuses do
    fn _method, _url, _headers, _body -> {:error, :refused_in_test} end
  end
end
