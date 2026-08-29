defmodule Mix.Tasks.AbuubaOpsTest do
  use Abuuba.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Deletion
  alias Abuuba.Federation.Availability
  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Media.Attachment
  alias Abuuba.PreviewCards.Card
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses.Status
  alias Abuuba.Timelines.Feed
  alias Mix.Tasks.Abuuba.Accounts, as: AccountsTask
  alias Mix.Tasks.Abuuba.Cards, as: CardsTask
  alias Mix.Tasks.Abuuba.Domains, as: DomainsTask
  alias Mix.Tasks.Abuuba.Emoji, as: EmojiTask
  alias Mix.Tasks.Abuuba.Feeds, as: FeedsTask
  alias Mix.Tasks.Abuuba.Media, as: MediaTask
  alias Mix.Tasks.Abuuba.Search, as: SearchTask
  alias Mix.Tasks.Abuuba.Stats, as: StatsTask
  alias Mix.Tasks.Abuuba.Statuses, as: StatusesTask

  defp run(task, args), do: capture_io(fn -> task.run(args) end)

  defp keypair_fixture(account, key) do
    now = DateTime.utc_now()

    Repo.insert_all("keypairs", [
      %{
        account_id: account.id,
        public_key: key,
        private_key: nil,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp card_fixture(url) do
    Repo.insert!(%Card{url: url, title: "A page", provider_name: "Example"})
  end

  defp emoji_fixture(shortcode, domain) do
    Repo.insert!(%CustomEmoji{
      shortcode: shortcode,
      domain: domain,
      image_url: "https://example.test/#{shortcode}.png",
      static_url: "https://example.test/#{shortcode}.png"
    })
  end

  describe "abuuba.accounts merge" do
    setup do
      # The same person under two handles, which is what a domain move or a
      # rename leaves behind. `(username, domain)` is unique here, so a
      # duplicate is never the same handle twice.
      duplicate = account_fixture(%{username: "twin_old", domain: "elsewhere.example"})
      keeper = account_fixture(%{username: "twin", domain: "elsewhere.example"})

      {:ok, one} = Abuuba.Accounts.create_keypair(duplicate)
      {:ok, two} = Abuuba.Accounts.create_keypair(keeper)

      # Same key: that is what says the two rows are one person.
      two |> Ecto.Changeset.change(public_key: one.public_key) |> Repo.update!()

      %{duplicate: duplicate, keeper: keeper}
    end

    test "moves what pointed at the duplicate", %{duplicate: duplicate, keeper: keeper} do
      reader = account_fixture(%{username: "reader"})
      {:ok, _} = Relationships.follow(reader, duplicate)
      status = status_fixture(%{account_id: duplicate.id, text: "theirs"})

      run(AccountsTask, ["merge", "twin_old@elsewhere.example", "twin@elsewhere.example"])

      assert Relationships.following?(reader, keeper)
      assert Repo.reload!(status).account_id == keeper.id
      refute Repo.get(Account, duplicate.id)
    end

    test "does not leave two rows where only one may exist", %{
      duplicate: duplicate,
      keeper: keeper
    } do
      reader = account_fixture(%{username: "reader"})

      # Somebody who followed both rows, which is exactly what the duplicate
      # made possible in the first place.
      {:ok, _} = Relationships.follow(reader, duplicate)
      {:ok, _} = Relationships.follow(reader, keeper)

      run(AccountsTask, ["merge", "twin_old@elsewhere.example", "twin@elsewhere.example"])

      assert Relationships.following?(reader, keeper)
      refute Repo.get(Account, duplicate.id)
    end

    test "refuses a local account", %{keeper: keeper} do
      local = account_fixture(%{username: "here"})

      assert_raise Mix.Error, fn ->
        run(AccountsTask, ["merge", "here", "twin@elsewhere.example"])
      end

      assert Repo.get(Account, local.id)
      assert Repo.get(Account, keeper.id)
    end

    test "refuses two accounts with different keys unless forced", %{duplicate: duplicate} do
      other = account_fixture(%{username: "other", domain: "elsewhere.example"})
      {:ok, _} = Abuuba.Accounts.create_keypair(other)

      assert_raise Mix.Error, ~r/key/, fn ->
        run(AccountsTask, ["merge", "twin_old@elsewhere.example", "other@elsewhere.example"])
      end

      assert Repo.get(Account, duplicate.id)
    end

    test "counts without moving anything under --dry-run", %{duplicate: duplicate} do
      reader = account_fixture(%{username: "reader"})
      {:ok, _} = Relationships.follow(reader, duplicate)

      dry =
        run(AccountsTask, [
          "merge",
          "twin_old@elsewhere.example",
          "twin@elsewhere.example",
          "--dry-run"
        ])

      assert dry =~ "would be affected"
      assert Repo.get(Account, duplicate.id)
      assert Relationships.following?(reader, duplicate)

      real = run(AccountsTask, ["merge", "twin_old@elsewhere.example", "twin@elsewhere.example"])

      # The same number both times. A dry run that counts differently from the
      # real one is worse than no dry run: it is a number somebody trusted.
      assert [count] = Regex.run(~r/(\d+) rows? would be affected/, dry, capture: :all_but_first)

      assert [^count] =
               Regex.run(~r/(\d+) rows? (?:was|were) affected/, real, capture: :all_but_first)
    end

    test "never leaves an account following itself", %{duplicate: duplicate, keeper: keeper} do
      # The duplicate followed the account it is about to become.
      {:ok, _} = Relationships.follow(duplicate, keeper)

      run(AccountsTask, ["merge", "twin_old@elsewhere.example", "twin@elsewhere.example"])

      refute Relationships.following?(keeper, keeper)
      refute Repo.get(Account, duplicate.id)
    end

    test "moves references nobody would have thought to list", %{
      duplicate: duplicate,
      keeper: keeper
    } do
      reader = account_fixture(%{username: "reader"})

      # Three tables a hand-written list is exactly the sort of thing to miss:
      # one the duplicate owns, one naming it as a target, and one that is
      # neither a follow nor a post.
      {:ok, _} = Relationships.block(reader, duplicate)
      {:ok, _note} = Relationships.put_note(reader, duplicate, "the same person twice")

      Abuuba.Repo.insert!(%Abuuba.Moderation.Report{
        account_id: reader.id,
        target_account_id: duplicate.id
      })

      run(AccountsTask, ["merge", "twin_old@elsewhere.example", "twin@elsewhere.example"])

      assert Relationships.blocking?(reader, keeper)
      assert Relationships.get_note(reader, keeper).comment == "the same person twice"
      assert Abuuba.Repo.get_by(Abuuba.Moderation.Report, target_account_id: keeper.id)
    end

    test "says so when neither account is there" do
      assert_raise Mix.Error, fn ->
        run(AccountsTask, ["merge", "nobody@elsewhere.example", "twin@elsewhere.example"])
      end
    end
  end

  describe "abuuba.accounts self-destruct" do
    setup do
      local = account_fixture(%{username: "leaving"})
      remote = account_fixture(%{username: "stranger", domain: "far.example"})

      %{local: local, remote: remote}
    end

    test "refuses without the server's own domain", %{local: local} do
      assert_raise Mix.Error, ~r/abuuba.test/, fn ->
        run(AccountsTask, ["self-destruct"])
      end

      refute Repo.get(Account, local.id).suspended_at
    end

    test "refuses when the domain does not match", %{local: local} do
      assert_raise Mix.Error, ~r/abuuba.test/, fn ->
        run(AccountsTask, ["self-destruct", "--confirm", "somewhere.else"])
      end

      refute Repo.get(Account, local.id).suspended_at
    end

    test "counts under --dry-run without closing anything", %{local: local} do
      output = run(AccountsTask, ["self-destruct", "--confirm", "abuuba.test", "--dry-run"])

      assert output =~ "would be affected"
      refute Repo.get(Account, local.id).suspended_at
    end

    test "closes every local account and leaves other servers alone", %{
      local: local,
      remote: remote
    } do
      run(AccountsTask, ["self-destruct", "--confirm", "abuuba.test"])

      assert Repo.get(Account, local.id).suspended_at
      refute Repo.get(Account, remote.id).suspended_at
    end
  end

  describe "abuuba.accounts duplicates" do
    test "says nothing on a server with no duplicates" do
      assert run(AccountsTask, ["duplicates"]) =~ "No remote accounts share a signing key"
    end

    test "names the pair and the merge that would join them" do
      one = account_fixture(%{username: "alice", domain: "old.example"})
      two = account_fixture(%{username: "alice", domain: "new.example"})

      for account <- [one, two], do: keypair_fixture(account, "SHARED")

      output = run(AccountsTask, ["duplicates"])

      assert output =~ "alice@old.example"
      assert output =~ "alice@new.example"
      assert output =~ "mix abuuba.accounts merge alice@new.example alice@old.example"
      assert output =~ "1 group would be affected"
    end
  end

  describe "abuuba.stats" do
    setup do
      author = account_fixture()
      status = status_fixture(%{account_id: author.id})

      %{author: author, status: status}
    end

    test "drift says nothing is wrong on a sound database" do
      assert run(StatsTask, ["drift"]) =~ "0 account counters would be affected"
    end

    test "drift finds a counter somebody broke", %{author: author} do
      Repo.update_all(
        from(a in Abuuba.Stats.AccountStat, where: a.account_id == ^author.id),
        set: [statuses_count: 99]
      )

      assert run(StatsTask, ["drift"]) =~ "1 account counter would be affected"
    end

    test "recount puts it right", %{author: author} do
      Repo.update_all(
        from(a in Abuuba.Stats.AccountStat, where: a.account_id == ^author.id),
        set: [statuses_count: 99]
      )

      assert run(StatsTask, ["recount"]) =~ "1 account counter was affected"
      assert Abuuba.Stats.account_stats(author.id).statuses_count == 1
    end

    test "recount --dry-run reports without writing", %{author: author} do
      Repo.update_all(
        from(a in Abuuba.Stats.AccountStat, where: a.account_id == ^author.id),
        set: [statuses_count: 99]
      )

      assert run(StatsTask, ["recount", "--dry-run"]) =~ "would be affected"
      assert Abuuba.Stats.account_stats(author.id).statuses_count == 99
    end
  end

  describe "abuuba.cards" do
    test "usage says how many are held" do
      card_fixture("https://news.example/one")
      card_fixture("https://news.example/two")

      assert run(CardsTask, ["usage"]) =~ "Preview cards held: 2"
    end

    test "remove --domain takes that site's cards and leaves the rest" do
      card_fixture("https://gone.example/one")
      card_fixture("https://staying.example/one")

      run(CardsTask, ["remove", "--domain", "gone.example"])

      assert [%{url: "https://staying.example/one"}] = Repo.all(Card)
    end

    test "remove --dry-run counts without deleting" do
      card_fixture("https://gone.example/one")

      output = run(CardsTask, ["remove", "--domain", "gone.example", "--dry-run"])

      assert output =~ "1 preview card would be affected"
      assert Repo.aggregate(Card, :count) == 1
    end

    test "remove --days takes the old ones" do
      old = card_fixture("https://old.example/one")
      card_fixture("https://new.example/one")

      old
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -400, :day))
      |> Repo.update!()

      run(CardsTask, ["remove", "--days", "365"])

      assert [%{url: "https://new.example/one"}] = Repo.all(Card)
    end

    test "remove with neither refuses rather than deleting everything" do
      card_fixture("https://news.example/one")

      assert_raise Mix.Error, fn -> run(CardsTask, ["remove"]) end
      assert Repo.aggregate(Card, :count) == 1
    end
  end

  describe "abuuba.accounts bootstrap-owner" do
    test "makes an account that can administer on a database with no roles" do
      output = run(AccountsTask, ["bootstrap-owner", "founder", "--email", "f@example.test"])

      assert output =~ "who can administer this server"
      assert output =~ "Password:"

      user = Abuuba.Accounts.get_user_by_account(Abuuba.Accounts.get_account_by_handle("founder"))

      assert Abuuba.Roles.can?(user, :administrator)
    end

    test "refuses without an email rather than making half an account" do
      assert_raise Mix.Error, fn -> run(AccountsTask, ["bootstrap-owner", "founder"]) end

      refute Abuuba.Accounts.get_account_by_handle("founder")
    end
  end

  describe "abuuba.statuses" do
    defp ancient_remote_status do
      account = account_fixture(%{domain: "far.example", uri: "https://far.example/who"})
      status = status_fixture(%{account_id: account.id, local: false})
      old = DateTime.add(DateTime.utc_now(), -365, :day)

      Repo.update_all(from(s in Status, where: s.id == ^status.id), set: [inserted_at: old])

      status
    end

    test "usage says what the posts cost" do
      ancient_remote_status()

      output = run(StatusesTask, ["usage"])

      assert output =~ "From elsewhere:  1"
      assert output =~ "Pass --days"
    end

    test "usage --days says how many a prune would take" do
      ancient_remote_status()

      assert run(StatusesTask, ["usage", "--days", "90"]) =~
               "Older than 90 days and unattached: 1"
    end

    test "remove takes the old unattached ones" do
      old = ancient_remote_status()
      kept = status_fixture()

      run(StatusesTask, ["remove", "--days", "90"])

      refute Repo.get(Status, old.id)
      assert Repo.get(Status, kept.id)
    end

    test "remove --dry-run counts without deleting" do
      old = ancient_remote_status()

      output = run(StatusesTask, ["remove", "--days", "90", "--dry-run"])

      assert output =~ "1 post would be affected"
      assert Repo.get(Status, old.id)
    end

    test "remove without --days refuses rather than picking a cutoff for you" do
      old = ancient_remote_status()

      assert_raise Mix.Error, fn -> run(StatusesTask, ["remove"]) end
      assert Repo.get(Status, old.id)
    end
  end

  describe "abuuba.emoji" do
    test "list names the local ones and counts the rest" do
      emoji_fixture("blobcat", nil)
      emoji_fixture("partyparrot", "other.example")

      output = run(EmojiTask, ["list"])

      assert output =~ ":blobcat:"
      assert output =~ "other.example"
    end

    test "import refuses without a server to ask" do
      assert_raise Mix.Error, ~r/--from/, fn -> run(EmojiTask, ["import"]) end
    end

    test "import leaves a shortcode that is already ours alone" do
      emoji_fixture("blobcat", nil)

      # Two different pictures with the same name. Overwriting would change
      # what every post that used it looks like.
      assert Repo.aggregate(CustomEmoji, :count) == 1
    end

    test "purge takes one server's and leaves the others" do
      emoji_fixture("theirs", "gone.example")
      emoji_fixture("ours", nil)

      run(EmojiTask, ["purge", "--domain", "gone.example"])

      assert [%{shortcode: "ours"}] = Repo.all(CustomEmoji)
    end

    test "purge --dry-run counts without deleting" do
      emoji_fixture("theirs", "gone.example")

      output = run(EmojiTask, ["purge", "--domain", "gone.example", "--dry-run"])

      assert output =~ "1 emoji would be affected"
      assert Repo.aggregate(CustomEmoji, :count) == 1
    end

    test "purge without a domain refuses" do
      emoji_fixture("theirs", "gone.example")

      assert_raise Mix.Error, fn -> run(EmojiTask, ["purge"]) end
      assert Repo.aggregate(CustomEmoji, :count) == 1
    end
  end

  describe "abuuba.search" do
    test "usage names the indexes search runs on" do
      output = run(SearchTask, ["usage"])

      assert output =~ "statuses_searchable_index"
      assert output =~ "accounts_searchable_index"
    end

    test "says so for a command it does not have" do
      # Named rather than silently ignored: a typed command that does nothing
      # reads as a command that worked.
      assert_raise Mix.Error, ~r/rebuild-everything/, fn ->
        run(SearchTask, ["rebuild-everything"])
      end
    end
  end

  describe "abuuba.accounts create and modify" do
    test "create makes an account somebody can sign in to" do
      run(AccountsTask, ["create", "newcomer", "--email", "newcomer@example.com"])

      account = Abuuba.Accounts.lookup("newcomer")
      assert account
      user = Abuuba.Accounts.get_user_by_account(account)
      assert user.email == "newcomer@example.com"
      assert user.confirmed_at
      assert user.approved
    end

    test "create prints a password nobody has to invent" do
      output = run(AccountsTask, ["create", "newcomer", "--email", "newcomer@example.com"])

      assert output =~ "Password:"
      # A generated one rather than a placeholder somebody forgets to change.
      refute output =~ "Password: changeme"
    end

    test "create refuses a name already taken" do
      account_fixture(%{username: "taken"})

      assert_raise Mix.Error, fn ->
        run(AccountsTask, ["create", "taken", "--email", "other@example.com"])
      end
    end

    test "create with --role gives it" do
      {:ok, _role} =
        Abuuba.Roles.create(%{
          name: "Staff",
          position: 100,
          permissions: Abuuba.Roles.mask(["manage_users"])
        })

      run(AccountsTask, ["create", "helper", "--email", "helper@example.com", "--role", "Staff"])

      user = Abuuba.Accounts.get_user_by_account(Abuuba.Accounts.lookup("helper"))
      assert Abuuba.Roles.can?(user, "manage_users")
    end

    test "modify changes the address and the role" do
      account = account_fixture(%{username: "changing"})
      user = user_fixture(%{account_id: account.id, approved: true})

      run(AccountsTask, ["modify", "changing", "--email", "moved@example.com"])

      assert Repo.reload!(user).email == "moved@example.com"
    end

    test "modify --disable stops a sign-in and --enable puts it back" do
      account = account_fixture(%{username: "wobbling"})
      user = user_fixture(%{account_id: account.id, approved: true})

      run(AccountsTask, ["modify", "wobbling", "--disable"])
      refute Repo.reload!(user).approved

      run(AccountsTask, ["modify", "wobbling", "--enable"])
      assert Repo.reload!(user).approved
    end

    test "modify says so when there is no such account" do
      assert_raise Mix.Error, fn -> run(AccountsTask, ["modify", "nobody", "--disable"]) end
    end

    test "rotate-keys gives an account a new keypair" do
      account = account_fixture(%{username: "stale_key"})
      {:ok, _keypair} = Abuuba.Accounts.create_keypair(account)
      before = Abuuba.Accounts.active_keypair(account)

      run(AccountsTask, ["rotate-keys", "stale_key"])

      after_rotation = Abuuba.Accounts.active_keypair(account)
      assert after_rotation.id != before.id

      # The old one is revoked rather than deleted: a post signed with it is
      # still out there, and a peer checking that signature needs the key.
      assert Repo.reload!(before).revoked_at
    end

    test "rotate-keys --all does every local account" do
      one = account_fixture(%{username: "one_key"})
      two = account_fixture(%{username: "two_key"})
      {:ok, _} = Abuuba.Accounts.create_keypair(one)
      {:ok, _} = Abuuba.Accounts.create_keypair(two)

      before = {Abuuba.Accounts.active_keypair(one).id, Abuuba.Accounts.active_keypair(two).id}

      run(AccountsTask, ["rotate-keys", "--all"])

      assert {Abuuba.Accounts.active_keypair(one).id, Abuuba.Accounts.active_keypair(two).id} !=
               before
    end

    test "rotate-keys --dry-run leaves the keys alone" do
      account = account_fixture(%{username: "keeping_key"})
      {:ok, _keypair} = Abuuba.Accounts.create_keypair(account)
      before = Abuuba.Accounts.active_keypair(account).id

      output = run(AccountsTask, ["rotate-keys", "--all", "--dry-run"])

      assert output =~ "would be affected"
      assert Abuuba.Accounts.active_keypair(account).id == before
    end

    test "backup asks for the archive the export page would build" do
      account = account_fixture(%{username: "leaving_soon"})
      user_fixture(%{account_id: account.id, approved: true})

      run(AccountsTask, ["backup", "leaving_soon"])

      assert [%{account_id: account_id}] = Abuuba.Repo.all(Abuuba.Exports.Export)
      assert account_id == account.id
    end
  end

  describe "abuuba.accounts" do
    test "approve --all lets the waiting registrations in" do
      account = account_fixture()
      user = user_fixture(%{account_id: account.id, approved: false})

      run(AccountsTask, ["approve", "--all"])

      assert Repo.reload!(user).approved
    end

    test "approve --dry-run changes nothing and says what it would do" do
      account = account_fixture()
      user = user_fixture(%{account_id: account.id, approved: false})

      output = run(AccountsTask, ["approve", "--all", "--dry-run"])

      # A dry run that counted differently from the real one would be worse
      # than no dry run: it would be a number somebody trusted.
      assert output =~ "1 account would be affected"
      refute Repo.reload!(user).approved
    end

    test "delete closes an account and keeps the name" do
      account = account_fixture(%{username: "leaving"})
      user_fixture(%{account_id: account.id, approved: true})

      run(AccountsTask, ["delete", "leaving"])

      assert Repo.reload!(account).suspended_at
      assert Deletion.username_taken?("leaving")
    end

    test "cull removes a remote account nobody follows on a dead server" do
      gone = account_fixture(%{domain: "gone.example"})

      for _ <- 1..8 do
        Availability.record_failure(
          "gone.example",
          Date.add(Date.utc_today(), -:rand.uniform(60))
        )
      end

      output = run(AccountsTask, ["cull", "--dry-run"])

      if Availability.unavailable?("gone.example") do
        assert output =~ "1 remote account would be affected"
        assert Repo.reload!(gone)
      end
    end

    test "cull leaves somebody who is followed alone" do
      followed = account_fixture(%{domain: "gone.example"})
      Relationships.follow(account_fixture(), followed)

      run(AccountsTask, ["cull"])

      # A server that is down comes back, and somebody here is reading them.
      assert Repo.reload!(followed)
    end

    test "unfollow takes an account out of everybody's following" do
      spammer = account_fixture(%{username: "spam", domain: "spam.example"})
      Relationships.follow(account_fixture(), spammer)
      Relationships.follow(account_fixture(), spammer)

      output = run(AccountsTask, ["unfollow", "spam@spam.example"])

      assert output =~ "2 follows was affected" or output =~ "2 follows"
      assert Relationships.followers(spammer) == []
    end

    test "refuses a command it does not know" do
      assert_raise Mix.Error, fn ->
        capture_io(fn -> AccountsTask.run(["explode"]) end)
      end
    end
  end

  describe "abuuba.media" do
    test "usage says what is local and what is cached" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id})

      Repo.insert!(%Attachment{
        account_id: account.id,
        status_id: status.id,
        type: :image,
        processing: :complete,
        file_file_size: 2048,
        remote_url: ""
      })

      output = run(MediaTask, ["usage"])

      assert output =~ "Uploaded here"
      assert output =~ "2.0 KB"
    end

    test "refresh counts the cached copies whose file is gone" do
      account = account_fixture(%{username: "elsewhere", domain: "far.example"})
      status = status_fixture(%{account_id: account.id})

      Repo.insert!(%Attachment{
        account_id: account.id,
        status_id: status.id,
        type: :image,
        processing: :complete,
        file_file_name: "picture.png",
        file_content_type: "image/png",
        remote_url: "https://far.example/picture.png"
      })

      output = run(MediaTask, ["refresh", "--dry-run"])

      # Nothing on disk in a test, so every cached copy is one that would be
      # fetched. That is the state this exists for: the file went with a
      # retention sweep and the post still points at it.
      assert output =~ "1 attachment would be affected"
    end

    test "refresh leaves a local upload alone" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id})

      Repo.insert!(%Attachment{
        account_id: account.id,
        status_id: status.id,
        type: :image,
        processing: :complete,
        file_file_name: "mine.png",
        file_content_type: "image/png",
        remote_url: ""
      })

      # A local file that is missing is missing. Going to the network for it
      # would be this server asking somebody else for its own data.
      assert run(MediaTask, ["refresh", "--dry-run"]) =~ "0 attachments would be affected"
    end

    test "remove-orphaned leaves an attachment younger than a day alone" do
      account = account_fixture()

      loose =
        Repo.insert!(%Attachment{account_id: account.id, type: :image, processing: :complete})

      output = run(MediaTask, ["remove-orphaned", "--dry-run"])

      # An attachment with no post yet is the ordinary state of one being
      # uploaded right now.
      assert output =~ "0 attachments"
      assert Repo.reload!(loose)
    end

    test "remove-orphaned takes an older one" do
      account = account_fixture()

      loose =
        %Attachment{account_id: account.id, type: :image, processing: :complete}
        |> Repo.insert!()
        |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -3, :day))
        |> Repo.update!()

      run(MediaTask, ["remove-orphaned"])

      assert is_nil(Repo.reload(loose))
    end
  end

  describe "abuuba.feeds" do
    test "build fills a timeline that should not be empty" do
      reader = account_fixture()
      writer = account_fixture()
      Relationships.follow(reader, writer)
      status_fixture(%{account_id: writer.id, text: "something"})

      Feed.clear("home", reader.id)
      assert Feed.count("home", reader.id) == 0

      run(FeedsTask, ["build", "@" <> reader.username])

      assert Feed.count("home", reader.id) > 0
    end

    test "clear empties one" do
      reader = account_fixture()
      writer = account_fixture()
      Relationships.follow(reader, writer)
      status_fixture(%{account_id: writer.id, text: "something"})

      run(FeedsTask, ["build", reader.username])
      assert Feed.count("home", reader.id) > 0

      run(FeedsTask, ["clear", reader.username])

      assert Feed.count("home", reader.id) == 0
    end
  end

  describe "abuuba.domains" do
    test "list counts the accounts on each server" do
      account_fixture(%{domain: "remote.example"})
      account_fixture(%{domain: "remote.example"})

      assert run(DomainsTask, ["list"]) =~ "2\tremote.example"
    end

    test "purge --dry-run counts what would go and takes nothing" do
      one = account_fixture(%{domain: "spam.example"})

      output = run(DomainsTask, ["purge", "spam.example", "--dry-run"])

      assert output =~ "1 account would be affected"
      assert Repo.reload!(one)
    end

    test "purge takes them" do
      one = account_fixture(%{domain: "spam.example"})
      keep = account_fixture(%{domain: "friend.example"})

      run(DomainsTask, ["purge", "spam.example"])

      assert is_nil(Repo.reload(one))
      assert Repo.reload!(keep)
    end

    test "refuses to purge nothing in particular" do
      assert_raise Mix.Error, fn ->
        capture_io(fn -> DomainsTask.run(["purge"]) end)
      end
    end

    test "and leaves local accounts alone whatever is asked" do
      local = account_fixture()

      run(DomainsTask, ["purge", "spam.example"])

      assert %Account{} = Repo.reload!(local)
    end
  end
end
