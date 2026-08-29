defmodule Abuuba.TrendsTest do
  use Abuuba.DataCase, async: true
  use Oban.Testing, repo: Abuuba.Repo

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Notifications
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Trends
  alias Abuuba.Trends.RankWorker

  defp count_queries(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "trends-count-#{inspect(ref)}",
      [:abuuba, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == parent, do: send(parent, {ref, :query})
      end,
      nil
    )

    fun.()

    :telemetry.detach("trends-count-#{inspect(ref)}")

    drain_queries(ref, 0)
  end

  defp drain_queries(ref, count) do
    receive do
      {^ref, :query} -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end

  setup do
    %{moderator: account_fixture()}
  end

  defp discoverable_account do
    account = account_fixture()

    {:ok, account} = Accounts.update_profile(account, %{"discoverable" => true})

    account
  end

  defp post(account, text, attrs \\ %{}) do
    status_fixture(Map.merge(%{account_id: account.id, text: text}, attrs))
  end

  # Counting happens as part of making a post, so these tests reach the counters
  # the way the server does rather than by writing rows.
  defp record(status), do: status

  describe "counting" do
    test "a tag used once has been used once" do
      author = discoverable_account()

      record(post(author, "something about #caturday"))

      assert Trends.counts("tag", "caturday").uses == 1
      assert Trends.counts("tag", "caturday").accounts == 1
    end

    test "one person using it twice is one person", %{} do
      # A trend is people, not posts. Somebody posting the same tag two hundred
      # times is one person shouting.
      author = discoverable_account()

      record(post(author, "#caturday one"))
      record(post(author, "#caturday two"))

      counts = Trends.counts("tag", "caturday")

      assert counts.uses == 2
      assert counts.accounts == 1
    end

    test "two people are two" do
      record(post(discoverable_account(), "#caturday one"))
      record(post(discoverable_account(), "#caturday two"))

      assert Trends.counts("tag", "caturday").accounts == 2
    end

    test "links are counted by their address" do
      author = discoverable_account()

      record(post(author, "read this https://news.example/a-story"))

      assert Trends.counts("link", "https://news.example/a-story").uses == 1
    end

    test "and remembered with the site they came from" do
      record(post(discoverable_account(), "https://news.example/a-story"))

      assert [link] = Trends.links()
      assert link.provider == "news.example"
    end

    test "a post is counted by the attention it gets" do
      author = discoverable_account()
      status = post(author, "something people liked")

      {:ok, _} = Statuses.favourite(account_fixture(), status)

      assert Trends.counts("status", to_string(status.id)).accounts == 1
    end
  end

  describe "what is left out" do
    test "a post nobody may see" do
      author = discoverable_account()

      record(post(author, "#secret", %{visibility: :private}))

      assert Trends.counts("tag", "secret").uses == 0
    end

    test "a reply", %{} do
      # A conversation is not a trend, and counting replies makes the loudest
      # argument on the server the thing everybody is shown.
      author = discoverable_account()
      parent = post(author, "the first word")

      record(post(author, "#argument", %{in_reply_to_id: parent.id}))

      assert Trends.counts("tag", "argument").uses == 0
    end

    test "a post marked sensitive" do
      author = discoverable_account()

      record(post(author, "#nsfw", %{sensitive: true}))

      assert Trends.counts("tag", "nsfw").uses == 0
    end

    test "a post by somebody who asked not to be listed" do
      # Discoverable is off by default, and somebody who never opened a
      # settings page has not agreed to be on the front page.
      author = account_fixture()

      record(post(author, "#quiet"))

      assert Trends.counts("tag", "quiet").uses == 0
    end

    test "a post by a silenced account", %{moderator: mod} do
      author = discoverable_account()
      {:ok, _} = Actions.take(mod, author, "silence")

      record(post(Accounts.get_account(author.id), "#loud"))

      assert Trends.counts("tag", "loud").uses == 0
    end
  end

  describe "scoring" do
    test "something nobody used before scores by how much it is used now" do
      subject = "caturday"
      Trends.put_counts("tag", subject, Date.utc_today(), uses: 10, accounts: 10)

      assert Trends.score("tag", subject) > 0
    end

    test "something as busy as yesterday does not trend" do
      # Steady use is not a trend. A tag ten people use every day is the
      # server's furniture.
      subject = "daily"
      Trends.put_counts("tag", subject, Date.add(Date.utc_today(), -1), accounts: 10)
      Trends.put_counts("tag", subject, Date.utc_today(), accounts: 10)

      assert Trends.score("tag", subject) == 0.0
    end

    test "a jump scores higher than a nudge" do
      Trends.put_counts("tag", "jump", Date.add(Date.utc_today(), -1), accounts: 2)
      Trends.put_counts("tag", "jump", Date.utc_today(), accounts: 40)

      Trends.put_counts("tag", "nudge", Date.add(Date.utc_today(), -1), accounts: 2)
      Trends.put_counts("tag", "nudge", Date.utc_today(), accounts: 4)

      assert Trends.score("tag", "jump") > Trends.score("tag", "nudge")
    end

    test "each kind forgets at its own pace" do
      # A post is interesting for an hour, a tag for an afternoon, a link for
      # most of a day. One half-life for all three would be wrong twice.
      assert Trends.half_life_hours("status") < Trends.half_life_hours("tag")
      assert Trends.half_life_hours("tag") < Trends.half_life_hours("link")
    end

    test "an old score is worth less than a fresh one" do
      fresh = Trends.decay(100.0, 0, "tag")
      old = Trends.decay(100.0, Trends.half_life_hours("tag"), "tag")

      assert_in_delta old, fresh / 2, 0.001
    end
  end

  describe "the ranking" do
    setup do
      author = discoverable_account()

      %{author: author}
    end

    test "puts the busiest first", %{author: author} do
      approve_tag("big")
      approve_tag("small")
      Trends.put_counts("tag", "big", Date.utc_today(), accounts: 50)
      Trends.put_counts("tag", "small", Date.utc_today(), accounts: 5)

      :ok = perform_job(RankWorker, %{})

      assert ["big", "small"] = Enum.map(Trends.list("tag"), & &1.subject)
      assert author
    end

    test "leaves out what nobody has reviewed" do
      Trends.put_counts("tag", "unseen", Date.utc_today(), accounts: 50)

      :ok = perform_job(RankWorker, %{})

      assert Trends.list("tag") == []
    end

    test "unless the server trusts what it has not reviewed" do
      :ok = Settings.put("trendable_by_default", true)
      Trends.put_counts("tag", "unseen", Date.utc_today(), accounts: 50)

      :ok = perform_job(RankWorker, %{})

      assert [%{subject: "unseen"}] = Trends.list("tag")
    end

    test "and never what was turned down", %{moderator: mod} do
      :ok = Settings.put("trendable_by_default", true)
      Trends.put_counts("tag", "refused", Date.utc_today(), accounts: 50)
      {:ok, tag} = Statuses.upsert_tag("refused")
      :ok = Trends.reject(mod, "tag", tag.name)

      :ok = perform_job(RankWorker, %{})

      assert Trends.list("tag") == []
    end

    test "is kept apart by language" do
      approve_tag("hallo")
      Trends.put_counts("tag", "hallo", Date.utc_today(), accounts: 20, language: "de")

      :ok = perform_job(RankWorker, %{})

      assert [_] = Trends.list("tag", language: "de")
      assert Trends.list("tag", language: "fr") == []
    end

    test "replaces what it wrote last time rather than adding to it" do
      approve_tag("once")
      Trends.put_counts("tag", "once", Date.utc_today(), accounts: 20)

      :ok = perform_job(RankWorker, %{})
      :ok = perform_job(RankWorker, %{})

      assert length(Trends.list("tag")) == 1
    end

    test "drops something that has stopped being used" do
      approve_tag("over")
      Trends.put_counts("tag", "over", Date.utc_today(), accounts: 20)
      :ok = perform_job(RankWorker, %{})

      Trends.put_counts("tag", "over", Date.utc_today(), accounts: 0)
      Trends.put_counts("tag", "over", Date.add(Date.utc_today(), -1), accounts: 20)
      :ok = perform_job(RankWorker, %{})

      assert Trends.list("tag") == []
    end
  end

  describe "a server with nothing on it" do
    test "does not go looking for trends every five minutes" do
      # Ranking runs on a timer whether or not anybody has posted. On a fresh
      # server that was eighteen queries producing nothing, five minutes apart,
      # each one logged — which is what a new admin sees filling their console
      # after `mix setup` and reads, reasonably, as something being wrong.
      # Two of the four are Oban's own bookkeeping for running the job at all.
      assert count_queries(fn -> assert :ok = perform_job(RankWorker, %{}) end) <= 4
    end

    test "still ranks as soon as there is something to rank" do
      # The positive control. A ranker that had learned to do nothing would
      # pass the budget above and be useless.
      author = discoverable_account()
      approve_tag("busy")
      Trends.put_counts("tag", "busy", Date.utc_today(), accounts: 20)

      :ok = perform_job(RankWorker, %{})

      assert [%{subject: "busy"}] = Trends.list("tag")
      assert author
    end
  end

  describe "the review queue" do
    test "holds what has been used but not looked at" do
      Trends.put_counts("tag", "waiting", Date.utc_today(), accounts: 50)
      {:ok, _} = Statuses.upsert_tag("waiting")

      :ok = perform_job(RankWorker, %{})

      assert [%{subject: "waiting"}] = Trends.pending_reviews("tag")
    end

    test "tells the people who review things" do
      # A queue nobody is told about is a queue nobody reads, and an unreviewed
      # trend stays invisible until somebody does.
      mod = taxonomist()
      Trends.put_counts("tag", "waiting", Date.utc_today(), accounts: 50)
      {:ok, _} = Statuses.upsert_tag("waiting")

      :ok = perform_job(RankWorker, %{})

      assert [%{type: "admin.report"}] = Notifications.list(mod)
    end

    test "and only once about the same thing" do
      mod = taxonomist()
      Trends.put_counts("tag", "waiting", Date.utc_today(), accounts: 50)
      {:ok, _} = Statuses.upsert_tag("waiting")

      :ok = perform_job(RankWorker, %{})
      :ok = perform_job(RankWorker, %{})

      assert length(Notifications.list(mod)) == 1
    end

    test "approving lets it through", %{moderator: mod} do
      {:ok, tag} = Statuses.upsert_tag("fine")
      Trends.put_counts("tag", "fine", Date.utc_today(), accounts: 50)

      :ok = Trends.approve(mod, "tag", tag.name)
      :ok = perform_job(RankWorker, %{})

      assert [%{subject: "fine"}] = Trends.list("tag")
    end

    test "rejecting keeps it out for good", %{moderator: mod} do
      {:ok, tag} = Statuses.upsert_tag("nope")

      :ok = Trends.reject(mod, "tag", tag.name)

      refute Repo.reload(tag).trendable
      assert Repo.reload(tag).reviewed_at
    end

    test "is written down", %{moderator: mod} do
      {:ok, tag} = Statuses.upsert_tag("fine")

      :ok = Trends.approve(mod, "tag", tag.name)

      assert Enum.any?(AuditLog.by_actor(mod), &(&1.action == "trend.approve"))
    end

    test "a link can be decided on by the site it came from", %{moderator: mod} do
      # One decision about a site rather than one per article. A news site
      # posting forty stories a day is one judgement, not forty.
      record(post(discoverable_account(), "https://news.example/one"))
      record(post(discoverable_account(), "https://news.example/two"))

      :ok = Trends.approve_provider(mod, "news.example")

      assert Enum.all?(Trends.links(), & &1.trendable)
    end

    test "and an author's posts by the author", %{moderator: mod} do
      author = discoverable_account()

      :ok = Trends.approve_author(mod, author)

      assert Accounts.get_account(author.id).trendable
    end
  end

  describe "sweeping" do
    test "old counts are thrown away" do
      # The tables should be the size of what is happening now, not of
      # everything that ever happened.
      old = Date.add(Date.utc_today(), -30)
      Trends.put_counts("tag", "ancient", old, accounts: 5)

      :ok = Trends.sweep()

      assert Trends.counts("tag", "ancient", old).uses == 0
    end

    test "yesterday's are kept, because the score needs them" do
      yesterday = Date.add(Date.utc_today(), -1)
      Trends.put_counts("tag", "recent", yesterday, uses: 5, accounts: 5)

      :ok = Trends.sweep()

      assert Trends.counts("tag", "recent", yesterday).uses == 5
    end
  end

  defp approve_tag(name) do
    {:ok, tag} = Statuses.upsert_tag(name)

    :ok = Trends.approve(account_fixture(), "tag", tag.name)
  end

  defp taxonomist do
    {:ok, role} =
      Roles.create(%{
        name: "Taxonomist #{System.unique_integer([:positive])}",
        position: 10,
        permissions: Roles.mask(["manage_taxonomies"])
      })

    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, _} = Roles.assign(user, role)

    account
  end
end
