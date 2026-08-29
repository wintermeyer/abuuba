defmodule Abuuba.RejectMediaTest do
  @moduledoc """
  What ticking "reject media" on a domain block does.

  It did nothing: the predicate existed, the admin form wrote the column, the
  CSV carried it, and no code in `lib/` ever asked. An admin who ticked the box
  believed no bytes from that server were landing on their disk, and every
  picture in every post from it was fetched and kept the moment somebody
  opened the post.
  """
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Moderation.Domains
  alias Abuuba.Repo

  @actor "https://loud.example/users/alice"

  setup do
    moderator = account_fixture()
    remote = remote_account_fixture(%{username: "alice", domain: "loud.example", uri: @actor})

    %{moderator: moderator, remote: remote}
  end

  defp reject_media(moderator, domain) do
    {:ok, block} =
      Domains.block(moderator, %{
        "domain" => domain,
        "severity" => "noop",
        "reject_media" => true
      })

    block
  end

  defp attachment_for(account) do
    status = status_fixture(%{account_id: account.id, text: "with a picture"})

    Repo.insert!(%Attachment{
      status_id: status.id,
      account_id: account.id,
      type: :image,
      processing: :complete,
      file_content_type: "image/png",
      file_file_name: "one.png",
      remote_url: "https://files.loud.example/pictures/one.png"
    })
  end

  describe "fetching somebody else's picture" do
    test "is refused for an account on a domain that rejects media", %{
      moderator: moderator,
      remote: remote
    } do
      attachment = attachment_for(remote)

      # The positive control. Without a block the check passes and the fetch is
      # attempted, which fails here for want of a network -- but it fails
      # somewhere else and with another reason, which is the whole point.
      assert Media.cache_remote(attachment) != {:error, :rejected_domain}

      reject_media(moderator, "loud.example")

      assert Media.cache_remote(attachment) == {:error, :rejected_domain}
    end

    test "and a local attachment is unaffected by anybody's block", %{moderator: moderator} do
      reject_media(moderator, "loud.example")

      local = account_fixture()
      attachment = attachment_for(local)

      assert Media.cache_remote(attachment) != {:error, :rejected_domain}
    end
  end

  describe "a post arriving from a domain that rejects media" do
    defp note(overrides) do
      Map.merge(
        %{
          "id" => "https://loud.example/statuses/1",
          "type" => "Note",
          "attributedTo" => @actor,
          "content" => "<p>look at this</p>",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "attachment" => [
            %{
              "type" => "Document",
              "mediaType" => "image/png",
              "url" => "https://files.loud.example/pictures/one.png"
            }
          ]
        },
        overrides
      )
    end

    defp resolve(remote, document) do
      ResolveStatus.resolve(document["id"],
        fetch: fn _uri -> {:ok, document} end,
        resolve_actor: fn _uri -> {:ok, remote} end
      )
    end

    test "records no attachment at all", %{moderator: moderator, remote: remote} do
      assert {:ok, kept} = resolve(remote, note(%{}))
      assert length(Repo.all(from(a in Attachment, where: a.status_id == ^kept.id))) == 1

      reject_media(moderator, "loud.example")

      assert {:ok, bare} =
               resolve(remote, note(%{"id" => "https://loud.example/statuses/2"}))

      assert Repo.all(from(a in Attachment, where: a.status_id == ^bare.id)) == []
      assert Repo.reload!(bare).ordered_media_attachment_ids == []
    end
  end
end
