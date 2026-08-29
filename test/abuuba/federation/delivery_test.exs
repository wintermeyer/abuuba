defmodule Abuuba.Federation.DeliveryTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.Delivery
  alias Abuuba.Federation.DeliveryWorker
  alias Abuuba.Federation.FollowerSync
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses

  defp remote(username, domain, opts \\ []) do
    remote_account_fixture(
      %{
        username: username,
        domain: domain,
        uri: "https://#{domain}/users/#{username}",
        inbox_url: "https://#{domain}/users/#{username}/inbox"
      }
      |> Map.merge(Map.new(opts))
    )
  end

  describe "who is in reach" do
    test "remote followers are", _context do
      author = account_fixture()
      follower = remote("bob", "remote.example")
      {:ok, _} = Relationships.follow(follower, author)

      assert Delivery.inboxes_for(author) == ["https://remote.example/users/bob/inbox"]
    end

    test "local followers are not, because they are already here", _context do
      author = account_fixture()
      {:ok, _} = Relationships.follow(account_fixture(), author)

      assert Delivery.inboxes_for(author) == []
    end

    test "mentioned accounts are, whether or not they follow", _context do
      author = account_fixture()
      status = status_fixture(%{account_id: author.id})
      mentioned = remote("carol", "third.example")
      {:ok, _} = Statuses.mention(status, mentioned)

      assert "https://third.example/users/carol/inbox" in Delivery.inboxes_for(author, status)
    end

    test "the author of what is being replied to is", _context do
      # A reply that never reaches the person replied to is a reply they never
      # see, however many of their followers get it.
      author = account_fixture()
      other = remote("dave", "fourth.example")

      parent =
        status_fixture(%{account_id: other.id, uri: "https://fourth.example/s/1", local: false})

      reply =
        status_fixture(%{
          account_id: author.id,
          in_reply_to_id: parent.id,
          in_reply_to_account_id: other.id
        })

      assert "https://fourth.example/users/dave/inbox" in Delivery.inboxes_for(author, reply)
    end

    test "the author of what is being boosted is", _context do
      author = account_fixture()
      other = remote("erin", "fifth.example")

      original =
        status_fixture(%{account_id: other.id, uri: "https://fifth.example/s/1", local: false})

      {:ok, boost} = Statuses.boost(author, original)

      assert "https://fifth.example/users/erin/inbox" in Delivery.inboxes_for(author, boost)
    end
  end

  describe "one delivery per server" do
    test "collapses followers on the same instance onto its shared inbox" do
      # The difference between a few hundred requests and a few hundred
      # thousand on a popular post.
      author = account_fixture()

      for name <- ~w(a b c d e) do
        follower =
          remote(name, "big.example", shared_inbox_url: "https://big.example/inbox")

        {:ok, _} = Relationships.follow(follower, author)
      end

      assert Delivery.inboxes_for(author) == ["https://big.example/inbox"]
    end

    test "still delivers individually where a server offers no shared inbox" do
      author = account_fixture()

      for name <- ~w(a b) do
        {:ok, _} = Relationships.follow(remote(name, "small.example"), author)
      end

      inboxes = Delivery.inboxes_for(author)

      assert length(inboxes) == 2
    end

    test "does not deliver twice to somebody who is both a follower and mentioned" do
      author = account_fixture()
      both = remote("bob", "remote.example")
      {:ok, _} = Relationships.follow(both, author)

      status = status_fixture(%{account_id: author.id})
      {:ok, _} = Statuses.mention(status, both)

      assert Delivery.inboxes_for(author, status) ==
               ["https://remote.example/users/bob/inbox"]
    end

    test "skips a server we have given up on" do
      author = account_fixture()
      {:ok, _} = Relationships.follow(remote("bob", "dead.example"), author)

      for day <- 1..Availability.failure_days_before_unavailable() do
        Availability.record_failure("dead.example", Date.add(Date.utc_today(), -day))
      end

      assert Availability.unavailable?("dead.example")
      assert Delivery.inboxes_for(author) == []
    end
  end

  describe "giving up on a server" do
    test "counts days, not failures" do
      # A server down for an hour produces thousands of failures and is not
      # dead. One that has failed on seven separate days is.
      for _ <- 1..50 do
        Availability.record_failure("flaky.example", Date.utc_today())
      end

      assert Availability.failure_day_count("flaky.example") == 1
      refute Availability.unavailable?("flaky.example")
    end

    test "gives up after enough distinct days" do
      threshold = Availability.failure_days_before_unavailable()

      for day <- 1..(threshold - 1) do
        Availability.record_failure("dying.example", Date.add(Date.utc_today(), -day))
      end

      refute Availability.unavailable?("dying.example")

      Availability.record_failure("dying.example", Date.utc_today())

      assert Availability.unavailable?("dying.example")
    end

    test "a server that talks to us is not dead, whatever we concluded" do
      # Continuing to treat it as gone because our outbound attempts failed
      # would be believing our own diagnosis over the evidence.
      for day <- 1..Availability.failure_days_before_unavailable() do
        Availability.record_failure("back.example", Date.add(Date.utc_today(), -day))
      end

      assert Availability.unavailable?("back.example")

      Availability.record_success("back.example")

      refute Availability.unavailable?("back.example")
      assert Availability.failure_day_count("back.example") == 0
    end

    test "is per domain" do
      for day <- 1..Availability.failure_days_before_unavailable() do
        Availability.record_failure("dead.example", Date.add(Date.utc_today(), -day))
      end

      refute Availability.unavailable?("fine.example")
    end

    test "does not mind how a domain was capitalised" do
      Availability.record_failure("Mixed.Example")

      assert Availability.failure_day_count("mixed.example") == 1
    end
  end

  describe "retry policy" do
    test "does not blame a peer for our own missing signing key" do
      # Sixteen attempts at signing with a key that is not there, and then a
      # failure day recorded against somebody else's server for a problem
      # entirely on this side of the connection.
      author = account_fixture()

      job = %Oban.Job{
        args: %{
          "inbox" => "https://one.example/inbox",
          "activity" => %{"type" => "Create"},
          "account_id" => author.id,
          "key_id" => "#{Actor.id(author)}#main-key"
        },
        attempt: 1,
        max_attempts: 16
      }

      assert DeliveryWorker.perform(job) == {:cancel, :no_signing_key}
      assert Availability.failure_day_count("one.example") == 0
    end

    test "cancels an inbox with no host rather than retrying it" do
      job = %Oban.Job{
        args: %{"inbox" => "not a url", "activity" => %{}},
        attempt: 1,
        max_attempts: 16
      }

      assert DeliveryWorker.perform(job) == {:cancel, :inbox_without_host}
    end

    test "backs off polynomially, with jitter" do
      # Exponential reaches days between attempts inside sixteen tries, which
      # is longer than anybody waits for a post to arrive.
      delays =
        for attempt <- 1..5 do
          DeliveryWorker.backoff(%Oban.Job{attempt: attempt})
        end

      assert Enum.all?(delays, &(&1 > 0))
      assert delays == Enum.sort(delays), "each wait should be at least as long as the last"

      # The jitter is what stops a thousand deliveries retrying in the same
      # second, so two jobs on the same attempt must not agree.
      repeated = for _ <- 1..20, do: DeliveryWorker.backoff(%Oban.Job{attempt: 5})

      assert length(Enum.uniq(repeated)) > 1
    end
  end

  describe "distributing" do
    setup do
      author = account_fixture(%{username: "author"})
      {:ok, _keypair} = Accounts.create_keypair(author)

      {:ok, _} = Relationships.follow(remote("bob", "one.example"), author)
      {:ok, _} = Relationships.follow(remote("carol", "two.example"), author)

      %{author: author}
    end

    test "queues one job per inbox, not one per activity", %{author: author} do
      # One unreachable server must not hold up delivery to every other server
      # on the same post.
      status = status_fixture(%{account_id: author.id})
      # Making the post now queues its own distribution. This test is about
      # what one call to `distribute/3` queues, so it starts from an empty
      # queue rather than counting that one too.
      Repo.delete_all(Oban.Job)

      :ok = Delivery.distribute(author, %{"type" => "Create"}, status: status)

      assert Repo.aggregate(Oban.Job, :count) == 2
    end

    test "signs as the account whose activity it is", %{author: author} do
      :ok = Delivery.distribute(author, %{"type" => "Create"})

      assert [job | _] = Repo.all(Oban.Job)
      assert job.args["key_id"] == "#{Actor.id(author)}#main-key"
    end

    test "never puts a signing key in the queue", %{author: author} do
      # Keys are encrypted at rest. A copy of the decrypted PEM in every job
      # row would undo that, once per destination server.
      :ok = Delivery.distribute(author, %{"type" => "Create"})

      for job <- Repo.all(Oban.Job) do
        assert job.args["account_id"] == author.id
        refute job.args["private_key"]
        refute inspect(job.args) =~ "PRIVATE KEY"
      end
    end

    test "tells each server about its own followers and nobody else's", %{author: author} do
      status = status_fixture(%{account_id: author.id, visibility: :private})

      :ok = Delivery.distribute(author, %{"type" => "Create"}, status: status)

      for job <- Repo.all(Oban.Job) do
        domain = URI.parse(job.args["inbox"]).host
        %{"collection-synchronization" => header} = job.args["headers"]

        assert header =~ ~s(domain=#{domain})
        assert header =~ FollowerSync.digest(FollowerSync.follower_uris_on(author, domain))
      end
    end

    test "sends no digest with a public status", %{author: author} do
      # A public status reaches people who follow nobody, so a follower digest
      # would describe something other than what was delivered.
      status = status_fixture(%{account_id: author.id, visibility: :public})

      :ok = Delivery.distribute(author, %{"type" => "Create"}, status: status)

      assert Oban.Job |> Repo.all() |> Enum.all?(&(&1.args["headers"] == %{}))
    end

    test "counts only followers in a digest, not everybody it reaches", %{author: author} do
      # The collection a peer fetches after a mismatch holds followers. A
      # mentioned stranger in the digest would make the two disagree by
      # construction, and the peer would resync forever.
      status = status_fixture(%{account_id: author.id, visibility: :private})
      {:ok, _} = Statuses.mention(status, remote("erin", "one.example"))

      :ok = Delivery.distribute(author, %{"type" => "Create"}, status: status)

      job =
        Repo.all(Oban.Job) |> Enum.find(&(URI.parse(&1.args["inbox"]).host == "one.example"))

      %{"collection-synchronization" => header} = job.args["headers"]

      assert header =~ FollowerSync.digest(["https://one.example/users/bob"])
    end

    test "queues nothing when nobody is in reach" do
      lonely = account_fixture()
      {:ok, _keypair} = Accounts.create_keypair(lonely)

      :ok = Delivery.distribute(lonely, %{"type" => "Create"})

      assert Repo.aggregate(Oban.Job, :count) == 0
    end
  end
end
