defmodule AbuubaWeb.ComposeTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.Preferences
  alias Abuuba.Instance
  alias Abuuba.Media
  alias Abuuba.Notifications
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Draft

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice", display_name: "Alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    %{conn: log_in(conn, user), account: account, user: user}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp draft(live, params) do
    live |> form("#compose-form", draft: params) |> render_change()
  end

  defp caret(live, at) do
    live |> element("#compose-form") |> render_hook("caret", %{"at" => at})
  end

  defp box(live) do
    live |> element("#compose-text") |> render()
  end

  defp submit(live, params) do
    live |> form("#compose-form", draft: params) |> render_submit()
  end

  defp unattached(account) do
    Media.unattached_before(DateTime.add(DateTime.utc_now(), 60, :second))
    |> Enum.filter(&(&1.account_id == account.id))
  end

  defp posted(account) do
    Statuses.account_timeline(account, account, %{limit: 10})
  end

  describe "posting" do
    test "puts what somebody typed on their timeline", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      submit(live, %{"text" => "hello world"})

      assert [status] = posted(account)
      assert status.text == "hello world"
      assert render(live) =~ "hello world"
    end

    test "empties the box afterwards, because the next post is a new one", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/home")

      submit(live, %{"text" => "said once"})

      refute render(live) =~ ~s(>said once</textarea>)
    end

    test "refuses an empty post rather than making a blank one", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      html = submit(live, %{"text" => "   "})

      assert posted(account) == []
      assert html =~ "Write something"
    end

    test "refuses a post over the limit and says so", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      html = submit(live, %{"text" => String.duplicate("a", Instance.max_characters() + 1)})

      assert posted(account) == []
      assert html =~ "too long"
    end

    test "carries the content warning and marks the post sensitive", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/home")

      submit(live, %{"text" => "the spoiler", "spoiler_text" => "Film ending", "warn" => "true"})

      assert [status] = posted(account)
      assert status.spoiler_text == "Film ending"
      assert status.sensitive
    end

    test "drops a warning that was typed and then switched off", %{conn: conn, account: account} do
      # Otherwise a warning the author decided against still folds the post.
      {:ok, live, _html} = live(conn, ~p"/home")

      submit(live, %{"text" => "no spoiler", "spoiler_text" => "left over", "warn" => "false"})

      assert [status] = posted(account)
      assert status.spoiler_text == ""
      refute status.sensitive
    end

    test "records who was named", %{conn: conn} do
      bob = account_fixture(%{username: "bob"})
      {:ok, live, _html} = live(conn, ~p"/home")

      submit(live, %{"text" => "hi @bob"})

      assert [_notification] = Notifications.list(bob)
    end
  end

  describe "the counter" do
    test "shows how much room is left", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/home")

      html = draft(live, %{"text" => "12345"})

      assert html =~ to_string(Instance.max_characters() - 5)
    end

    test "charges a remote mention as the name alone", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/home")

      html = draft(live, %{"text" => "@bob@very-long-domain.example"})

      assert html =~ to_string(Instance.max_characters() - 4)
    end

    test "counts the content warning too, because the limit covers both", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/home")

      html = draft(live, %{"text" => "abc", "spoiler_text" => "de", "warn" => "true"})

      assert html =~ to_string(Instance.max_characters() - 5)
    end
  end

  describe "the preview" do
    test "shows a mention as the link it will become", %{conn: conn} do
      account_fixture(%{username: "bob"})
      {:ok, live, _html} = live(conn, ~p"/home")

      html = draft(live, %{"text" => "hi @bob"})

      assert html =~ ~s(class="mention")
    end

    test "shows markup as the text it is, never as markup", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/home")

      html = draft(live, %{"text" => "<script>alert(1)</script>"})

      refute html =~ "<script>alert(1)</script>"
    end
  end

  describe "autosuggest" do
    test "offers accounts while a handle is being typed", %{conn: conn} do
      account_fixture(%{username: "bobby", display_name: "Bobby"})
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "hi @bob"})

      assert caret(live, 7) =~ "Bobby"
    end

    test "offers tags", %{conn: conn} do
      {:ok, _} = Statuses.upsert_tag("elixir")
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "about #eli"})

      assert caret(live, 10) =~ "#elixir"
    end

    test "offers emoji", %{conn: conn} do
      {:ok, _} =
        Instance.put_custom_emoji(%{shortcode: "waving", image_url: "https://x.test/w.png"})

      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "hey :wav"})

      assert caret(live, 8) =~ ":waving:"
    end

    test "offers nothing once the word is finished", %{conn: conn} do
      account_fixture(%{username: "bobby"})
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "hi @bobby "})

      refute caret(live, 10) =~ "compose-suggestion"
    end

    test "reads the word the caret is in, not the last one typed", %{conn: conn} do
      # Somebody who went back to fix a handle mid-sentence is suggested that
      # handle, not whatever the sentence happens to end with.
      account_fixture(%{username: "bobby", display_name: "Bobby"})
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "hi @bob and goodbye"})

      assert caret(live, 7) =~ "Bobby"
    end

    test "counts the caret in characters, not in bytes", %{conn: conn} do
      # "Grüße" is five characters and six bytes. Measured in bytes the caret
      # lands mid-word and the suggestion replaces the wrong part of the text.
      account_fixture(%{username: "bobby", display_name: "Bobby"})
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "Grüße @bob"})

      assert caret(live, 10) =~ "Bobby"
    end

    test "replaces the whole word when the caret sits inside it", %{conn: conn} do
      account_fixture(%{username: "bobby"})
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "hi @bobbb end"})
      caret(live, 7)

      live |> element("button[phx-value-suggestion='@bobby']") |> render_click()

      assert box(live) =~ "hi @bobby end"
    end

    test "picking one completes the word and leaves the rest alone", %{conn: conn} do
      account_fixture(%{username: "bobby"})
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "hi @bob and goodbye"})
      caret(live, 7)

      live |> element("button[phx-value-suggestion='@bobby']") |> render_click()

      assert box(live) =~ "hi @bobby and goodbye"
    end
  end

  describe "audience" do
    test "posts publicly unless somebody says otherwise", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      submit(live, %{"text" => "for everyone"})

      assert [%{visibility: :public}] = posted(account)
    end

    test "keeps the audience that was chosen", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-value-visibility='private']") |> render_click()
      submit(live, %{"text" => "for followers"})

      assert [%{visibility: :private}] = posted(account)
    end

    test "keeps the quote policy that was chosen", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-value-quote-policy='nobody']") |> render_click()
      submit(live, %{"text" => "do not quote me"})

      assert [%{quote_policy: :nobody}] = posted(account)
    end

    test "records the language somebody wrote in", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      submit(live, %{"text" => "guten Tag", "language" => "de"})

      assert [%{language: "de"}] = posted(account)
    end
  end

  describe "polls" do
    test "asks a question with the options that were filled in", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-click='poll_add']") |> render_click()

      submit(live, %{
        "text" => "tabs or spaces?",
        "poll_options" => ["Tabs", "Spaces"],
        "poll_expires_in" => "86400"
      })

      assert [status] = posted(account)
      assert poll = Statuses.get_poll(status)
      assert poll.options == ["Tabs", "Spaces"]
      refute poll.multiple
    end

    test "can let people pick more than one", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-click='poll_add']") |> render_click()

      submit(live, %{
        "text" => "which of these?",
        "poll_options" => ["One", "Two"],
        "poll_multiple" => "true",
        "poll_expires_in" => "3600"
      })

      assert [status] = posted(account)
      assert Statuses.get_poll(status).multiple
    end

    test "refuses a poll with one usable option", %{conn: conn, account: account} do
      # A poll people cannot choose within is a question with no answers.
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-click='poll_add']") |> render_click()

      html = submit(live, %{"text" => "pick one", "poll_options" => ["Only", "  "]})

      assert posted(account) == []
      assert html =~ "two options"
    end

    test "refuses two identical choices rather than posting an unreadable poll", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-click='poll_add']") |> render_click()

      html = submit(live, %{"text" => "pick one", "poll_options" => ["Same", "Same"]})

      assert posted(account) == []
      assert html =~ "different"
    end

    test "refuses a choice longer than a poll may carry, before posting anything", %{
      conn: conn,
      account: account
    } do
      # The post and the poll are two writes. Catching this after the first one
      # leaves the post up with the question missing and an error saying it was
      # not saved.
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-click='poll_add']") |> render_click()

      html =
        submit(live, %{
          "text" => "pick one",
          "poll_options" => [String.duplicate("a", 51), "short"]
        })

      assert posted(account) == []
      assert html =~ "too long"
    end

    test "a poll can be taken back off again", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-click='poll_add']") |> render_click()
      live |> element("button[phx-click='poll_remove']") |> render_click()

      submit(live, %{"text" => "no poll after all"})

      assert [status] = posted(account)
      refute Statuses.get_poll(status)
    end
  end

  describe "replying" do
    setup %{account: account} do
      bob = account_fixture(%{username: "bob", display_name: "Bob"})
      carol = account_fixture(%{username: "carol"})
      {:ok, _} = Relationships.follow(account, bob)

      status = status_fixture(%{account_id: bob.id, text: "the original, cc @carol"})
      Statuses.link_text(status)

      %{bob: bob, carol: carol, original: status}
    end

    test "shows what is being replied to", %{conn: conn, original: original} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-id='#{original.id}'][phx-click='reply']")
      |> render_click()

      html = render(live)

      assert html =~ "Replying to"
      assert html =~ "Bob"
    end

    test "names the author and everybody else in the thread", %{conn: conn, original: original} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-id='#{original.id}'][phx-click='reply']")
      |> render_click()

      assert box(live) =~ "@bob"
      assert box(live) =~ "@carol"
    end

    test "does not name the person writing the reply", %{conn: conn, account: account} do
      # Everybody knows they are in their own thread.
      mine = status_fixture(%{account_id: account.id, text: "mine"})
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-value-id='#{mine.id}'][phx-click='reply']") |> render_click()

      refute box(live) =~ "@alice"
    end

    test "an extra name can be taken off before sending", %{
      conn: conn,
      account: account,
      original: original
    } do
      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-id='#{original.id}'][phx-click='reply']")
      |> render_click()

      live |> element("button[phx-value-handle='carol']") |> render_click()

      submit(live, %{"text" => "@bob just you then"})

      assert [reply] = posted(account)
      refute reply.text =~ "@carol"
    end

    test "the reply is attached to what it answers", %{
      conn: conn,
      account: account,
      original: original,
      bob: bob
    } do
      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-id='#{original.id}'][phx-click='reply']")
      |> render_click()

      submit(live, %{"text" => "@bob agreed"})

      assert [reply] = posted(account)
      assert reply.in_reply_to_id == original.id
      assert reply.in_reply_to_account_id == bob.id
    end

    test "a reply to a followers-only post stays followers-only", %{conn: conn, account: account} do
      # Answering somebody's private post in public quotes them into the open.
      dave = account_fixture(%{username: "dave"})
      {:ok, _} = Relationships.follow(account, dave)
      private = status_fixture(%{account_id: dave.id, text: "quiet", visibility: :private})

      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-value-id='#{private.id}'][phx-click='reply']") |> render_click()
      submit(live, %{"text" => "@dave understood"})

      assert [%{visibility: :private}] = posted(account)
    end

    test "the reply context can be dropped", %{conn: conn, account: account, original: original} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-id='#{original.id}'][phx-click='reply']")
      |> render_click()

      live |> element("button[phx-click='reply_cancel']") |> render_click()

      submit(live, %{"text" => "on its own"})

      assert [status] = posted(account)
      assert status.in_reply_to_id == nil
    end
  end

  describe "drafts" do
    # Two renders: the timer message makes the view ask the component to save,
    # and the component's own update is processed on the round trip after that.
    defp autosave(live) do
      send(live.pid, {:compose_autosave, "compose"})
      render(live)

      render(live)
    end

    test "keeps what somebody stopped in the middle of", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "half a thought"})
      autosave(live)

      assert [saved] = Statuses.drafts(account)
      assert saved.params["text"] == "half a thought"
    end

    test "keeps the rest of the box too", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "careful now", "spoiler_text" => "spoiler", "warn" => "true"})
      autosave(live)

      assert [saved] = Statuses.drafts(account)
      assert saved.params["spoiler_text"] == "spoiler"
      assert saved.params["warn"] == true
    end

    test "keeps writing into the same draft rather than a pile", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "half"})
      autosave(live)
      draft(live, %{"text" => "half a thought"})
      autosave(live)

      assert [saved] = Statuses.drafts(account)
      assert saved.params["text"] == "half a thought"
    end

    test "saves nothing for an empty box", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "   "})
      autosave(live)

      assert Statuses.drafts(account) == []
    end

    test "lists what is waiting", %{conn: conn, account: account} do
      {:ok, _} = Statuses.save_draft(account, %{"text" => "started on Tuesday"})

      {:ok, live, _html} = live(conn, ~p"/home")

      assert render(live) =~ "started on Tuesday"
    end

    test "restoring puts it back in the box", %{conn: conn, account: account} do
      {:ok, saved} = Statuses.save_draft(account, %{"text" => "started on Tuesday"})

      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-draft='#{saved.id}'][phx-click='draft_restore']")
      |> render_click()

      assert box(live) =~ "started on Tuesday"
    end

    test "restoring brings back the audience it was written with", %{
      conn: conn,
      account: account
    } do
      {:ok, saved} =
        Statuses.save_draft(account, %{"text" => "quiet one", "visibility" => "private"})

      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-draft='#{saved.id}'][phx-click='draft_restore']")
      |> render_click()

      submit(live, %{"text" => "quiet one"})

      assert [%{visibility: :private}] = posted(account)
    end

    test "survives an id that is not one", %{conn: conn} do
      # Event payloads are the client's to write, so nothing here may assume
      # the id came from a button this server drew.
      {:ok, live, _html} = live(conn, ~p"/home")

      render_click(live, "draft_restore", %{"draft" => "not-an-id"})
      render_click(live, "draft_discard", %{"draft" => "../../etc/passwd"})
      render_click(live, "schedule_cancel", %{"scheduled" => "9999999999999999999999"})
      render_hook(live, "media_focus", %{"nothing" => "useful"})

      assert render(live) =~ "compose-form"
    end

    test "will not restore somebody else's", %{conn: conn, account: account} do
      {:ok, theirs} = Statuses.save_draft(account_fixture(), %{"text" => "not yours"})

      {:ok, live, _html} = live(conn, ~p"/home")
      render_click(live, "draft_restore", %{"draft" => to_string(theirs.id)})

      refute box(live) =~ "not yours"
      assert Statuses.drafts(account) == []
    end

    test "sending a restored draft forgets it", %{conn: conn, account: account} do
      # Otherwise the drafts list fills up with things that were posted.
      {:ok, saved} = Statuses.save_draft(account, %{"text" => "finish me"})

      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-draft='#{saved.id}'][phx-click='draft_restore']")
      |> render_click()

      submit(live, %{"text" => "finished"})

      assert Statuses.drafts(account) == []
      assert [_status] = posted(account)
    end

    test "discarding forgets it", %{conn: conn, account: account} do
      {:ok, saved} = Statuses.save_draft(account, %{"text" => "never mind"})

      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-draft='#{saved.id}'][phx-click='draft_discard']")
      |> render_click()

      assert Statuses.drafts(account) == []
    end

    test "says so when there are too many to start another", %{conn: conn, account: account} do
      for n <- 1..Draft.limit() do
        {:ok, _} = Statuses.save_draft(account, %{"text" => "draft #{n}"})
      end

      {:ok, live, _html} = live(conn, ~p"/home")

      draft(live, %{"text" => "one too many"})

      assert autosave(live) =~ "too many drafts"
    end
  end

  describe "scheduling" do
    defp schedule_at(live, local) do
      live |> element("button[phx-click='schedule_toggle']") |> render_click()

      submit(live, %{"text" => "for later", "scheduled_at" => local})
    end

    defp in_hours(hours) do
      DateTime.utc_now()
      |> DateTime.add(hours * 3600, :second)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_iso8601()
      |> String.slice(0, 16)
    end

    test "keeps the post for later rather than publishing it", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      schedule_at(live, in_hours(2))

      assert posted(account) == []
      assert [waiting] = Statuses.scheduled(account)
      assert waiting.params["text"] == "for later"
    end

    test "carries the audience and language with it", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-value-visibility='private']") |> render_click()
      live |> element("button[phx-click='schedule_toggle']") |> render_click()

      submit(live, %{
        "text" => "later and quiet",
        "language" => "de",
        "scheduled_at" => in_hours(2)
      })

      assert [waiting] = Statuses.scheduled(account)
      assert waiting.params["visibility"] == "private"
      assert waiting.params["language"] == "de"
    end

    test "refuses a time too close to be a schedule", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      html = schedule_at(live, in_hours(0))

      assert Statuses.scheduled(account) == []
      assert html =~ "5 minutes"
    end

    test "refuses a time nobody typed", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      html = schedule_at(live, "")

      assert Statuses.scheduled(account) == []
      assert html =~ "when"
    end

    test "reads the time in the browser's own zone", %{conn: conn, account: account} do
      # A picker shows local time and sends no zone with it. Read as UTC, a
      # post scheduled for six in the evening in Berlin goes out at eight.
      {:ok, live, _html} = live(conn, ~p"/home")

      # Two hours ahead of UTC, which is what the browser reports as -120.
      live |> element("#compose-form") |> render_hook("timezone", %{"offset" => -120})

      local = in_hours(4)
      schedule_at(live, local)

      assert [waiting] = Statuses.scheduled(account)
      {:ok, naive} = NaiveDateTime.from_iso8601(local <> ":00")

      assert DateTime.diff(waiting.scheduled_at, DateTime.from_naive!(naive, "Etc/UTC"), :minute) ==
               -120
    end

    test "lists what is waiting to go out", %{conn: conn, account: account} do
      {:ok, _} =
        Statuses.schedule(
          account,
          %{"text" => "the announcement"},
          DateTime.add(DateTime.utc_now(), 7200, :second)
        )

      {:ok, live, _html} = live(conn, ~p"/home")

      assert render(live) =~ "the announcement"
    end

    test "one can be called off", %{conn: conn, account: account} do
      {:ok, waiting} =
        Statuses.schedule(
          account,
          %{"text" => "on second thoughts"},
          DateTime.add(DateTime.utc_now(), 7200, :second)
        )

      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-scheduled='#{waiting.id}'][phx-click='schedule_cancel']")
      |> render_click()

      assert Statuses.scheduled(account) == []
    end

    test "will not call off somebody else's", %{conn: conn} do
      stranger = account_fixture()

      {:ok, theirs} =
        Statuses.schedule(
          stranger,
          %{"text" => "theirs"},
          DateTime.add(DateTime.utc_now(), 7200, :second)
        )

      {:ok, live, _html} = live(conn, ~p"/home")
      render_click(live, "schedule_cancel", %{"scheduled" => to_string(theirs.id)})

      assert [_still_there] = Statuses.scheduled(stranger)
    end

    test "carries a poll with it", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-click='poll_add']") |> render_click()
      live |> element("button[phx-click='schedule_toggle']") |> render_click()

      submit(live, %{
        "text" => "tabs or spaces?",
        "poll_options" => ["Tabs", "Spaces"],
        "scheduled_at" => in_hours(2)
      })

      assert [waiting] = Statuses.scheduled(account)
      assert waiting.params["poll"]["options"] == ["Tabs", "Spaces"]
    end

    test "ignores an offset no timezone has", %{conn: conn, account: account} do
      # The number comes from a browser, so it is somebody's to make up.
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("#compose-form") |> render_hook("timezone", %{"offset" => -999_999})

      schedule_at(live, in_hours(4))

      assert [waiting] = Statuses.scheduled(account)
      assert DateTime.diff(waiting.scheduled_at, DateTime.utc_now(), :hour) < 24
    end

    test "a scheduled post can be put back in the box to edit", %{conn: conn, account: account} do
      {:ok, waiting} =
        Statuses.schedule(
          account,
          %{"text" => "needs a rewrite"},
          DateTime.add(DateTime.utc_now(), 7200, :second)
        )

      {:ok, live, _html} = live(conn, ~p"/home")

      live
      |> element("button[phx-value-scheduled='#{waiting.id}'][phx-click='schedule_edit']")
      |> render_click()

      assert box(live) =~ "needs a rewrite"
      assert Statuses.scheduled(account) == []
    end
  end

  describe "attachments" do
    defp pick(live, entries) do
      input = file_input(live, "#compose-form", :media, entries)

      render_upload(input, hd(entries).name)
    end

    defp png(name) do
      %{name: name, content: "a small pretend png", type: "image/png"}
    end

    test "uploads what was dropped on the box", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("cat.png")])

      assert [attachment] = unattached(account)
      assert attachment.file_content_type == "image/png"
    end

    test "shows what is attached", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("cat.png")])

      assert render(live) =~ "media-attachment"
    end

    test "hangs them on the post, in order", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("one.png")])
      pick(live, [png("two.png")])
      submit(live, %{"text" => "two pictures"})

      assert [status] = posted(account)
      assert [first, second] = Media.for_status(status)
      assert first.meta["original"]["name"] == "one.png"
      assert second.meta["original"]["name"] == "two.png"
    end

    test "the order can be changed before sending", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("one.png")])
      pick(live, [png("two.png")])

      [_first, second] = unattached(account)

      live
      |> element("button[phx-value-media='#{second.id}'][phx-click='media_up']")
      |> render_click()

      submit(live, %{"text" => "the other way round"})

      assert [status] = posted(account)

      assert ["two.png", "one.png"] =
               Enum.map(Media.for_status(status), & &1.meta["original"]["name"])
    end

    test "one can be taken off again", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("cat.png")])
      [attachment] = unattached(account)

      live
      |> element("button[phx-value-media='#{attachment.id}'][phx-click='media_remove']")
      |> render_click()

      submit(live, %{"text" => "no picture after all"})

      assert [status] = posted(account)
      assert Media.for_status(status) == []
    end

    test "alt text is written before the post goes out", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("cat.png")])
      [attachment] = unattached(account)

      live
      |> element("#media-attachment-#{attachment.id} textarea")
      |> render_blur(%{"description" => "a cat asleep on a keyboard"})

      assert Media.get_attachment(attachment.id).description ==
               "a cat asleep on a keyboard"
    end

    test "a focal point is recorded from where somebody clicked", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("cat.png")])
      [attachment] = unattached(account)

      live
      |> element("#media-focus-#{attachment.id}")
      |> render_hook("media_focus", %{
        "media" => to_string(attachment.id),
        "x" => 0.4,
        "y" => -0.25
      })

      assert Media.get_attachment(attachment.id).meta["focus"] == %{"x" => 0.4, "y" => -0.25}
    end

    test "a focal point outside the picture is brought back inside", %{
      conn: conn,
      account: account
    } do
      # The numbers come from a browser, so they are somebody's to make up.
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("cat.png")])
      [attachment] = unattached(account)

      live
      |> element("#media-focus-#{attachment.id}")
      |> render_hook("media_focus", %{"media" => to_string(attachment.id), "x" => 9, "y" => -9})

      assert Media.get_attachment(attachment.id).meta["focus"] == %{"x" => 1.0, "y" => -1.0}
    end

    test "will not touch somebody else's upload", %{conn: conn} do
      stranger = account_fixture()
      path = Path.join(System.tmp_dir!(), "theirs-#{System.unique_integer([:positive])}")
      File.write!(path, "a picture")

      {:ok, theirs} =
        Media.upload(stranger, %{path: path, filename: "t.png", content_type: "image/png"})

      {:ok, live, _html} = live(conn, ~p"/home")

      render_hook(live, "media_describe", %{
        "media" => to_string(theirs.id),
        "description" => "not yours to caption"
      })

      assert Media.get_attachment(theirs.id).description == nil
    end

    test "shows the placeholder colour a blurhash carries", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("cat.png")])
      [attachment] = unattached(account)

      {:ok, _} =
        attachment
        |> Ecto.Changeset.change(blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        |> Repo.update()

      live
      |> element("#media-attachment-#{attachment.id} textarea")
      |> render_blur(%{"description" => "x"})

      assert render(live) =~ "#979695"
    end

    test "refuses more than a post can carry", %{conn: conn, account: account} do
      # The upload limit bounds what is in flight at once, and a file finishes
      # and clears its entry, so uploading one at a time walks straight past it.
      {:ok, live, _html} = live(conn, ~p"/home")

      for n <- 1..(Instance.max_media_attachments() + 2) do
        pick(live, [png("photo-#{n}.png")])
      end

      assert length(unattached(account)) == Instance.max_media_attachments()
      assert render(live) =~ "as many pictures"
    end

    test "ignores a focal point that is not a pair of numbers", %{conn: conn, account: account} do
      # Storing nothing beats storing the middle: a wiped focal point crops the
      # picture somewhere the author never chose and says nothing about it.
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("cat.png")])
      [attachment] = unattached(account)

      live
      |> element("#media-focus-#{attachment.id}")
      |> render_hook("media_focus", %{"media" => to_string(attachment.id), "x" => 0.5, "y" => 0.5})

      live
      |> element("#media-focus-#{attachment.id}")
      |> render_hook("media_focus", %{
        "media" => to_string(attachment.id),
        "x" => "left",
        "y" => nil
      })

      assert Media.get_attachment(attachment.id).meta["focus"] == %{"x" => 0.5, "y" => 0.5}
    end

    test "the box is empty of attachments once the post is sent", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      pick(live, [png("cat.png")])
      submit(live, %{"text" => "with a picture"})

      refute render(live) =~ "media-attachment"
      assert unattached(account) == []
    end
  end

  describe "the missing alt text reminder" do
    setup %{user: user} do
      {:ok, user} =
        Accounts.update_user_settings(
          user,
          Preferences.merge(user.settings, %{"warn_missing_alt" => true})
        )

      %{user: user}
    end

    test "stops the first send and says what is missing", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      input = file_input(live, "#compose-form", :media, [png("cat.png")])
      render_upload(input, "cat.png")

      html = submit(live, %{"text" => "look at this"})

      assert posted(account) == []
      assert html =~ "without a description"
    end

    test "sends on the second, because the person was asked and answered", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/home")

      input = file_input(live, "#compose-form", :media, [png("cat.png")])
      render_upload(input, "cat.png")

      submit(live, %{"text" => "look at this"})
      submit(live, %{"text" => "look at this"})

      assert [_status] = posted(account)
    end

    test "is not spent by an unrelated refusal", %{conn: conn, account: account} do
      # An empty post and a missing description are two different problems.
      # Letting the first one answer the second means the reminder never fires.
      {:ok, live, _html} = live(conn, ~p"/home")

      input = file_input(live, "#compose-form", :media, [png("cat.png")])
      render_upload(input, "cat.png")

      submit(live, %{"text" => "   "})
      html = submit(live, %{"text" => "look at this"})

      assert posted(account) == []
      assert html =~ "without a description"
    end

    test "says nothing when every picture has one", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/home")

      input = file_input(live, "#compose-form", :media, [png("cat.png")])
      render_upload(input, "cat.png")

      [attachment] = unattached(account)

      live
      |> element("#media-attachment-#{attachment.id} textarea")
      |> render_blur(%{"description" => "a cat"})

      submit(live, %{"text" => "look at this"})

      assert [_status] = posted(account)
    end
  end

  describe "editing" do
    setup %{account: account} do
      %{status: status_fixture(%{account_id: account.id, text: "the first wording"})}
    end

    test "opens with what the post says", %{conn: conn, status: status} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-value-id='#{status.id}'][phx-click='edit']") |> render_click()
      html = render(live)

      assert html =~ "the first wording"
      assert html =~ "Save changes"
    end

    test "changes the post rather than making a second one", %{
      conn: conn,
      account: account,
      status: status
    } do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-value-id='#{status.id}'][phx-click='edit']") |> render_click()
      submit(live, %{"text" => "the second wording"})

      assert [only] = posted(account)
      assert only.id == status.id
      assert only.text == "the second wording"
      assert only.edited_at
    end

    test "keeps a copy of what it said before", %{conn: conn, status: status} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-value-id='#{status.id}'][phx-click='edit']") |> render_click()
      submit(live, %{"text" => "reworded"})

      assert [%{text: "the first wording"}] = Statuses.edit_history(status)
    end

    test "will not edit somebody else's post", %{conn: conn} do
      theirs = status_fixture(%{account_id: account_fixture().id, text: "not mine"})

      {:ok, live, _html} = live(conn, ~p"/home")

      render_click(live, "edit", %{"id" => to_string(theirs.id)})

      refute render(live) =~ "Save changes"
      assert Repo.reload(theirs).text == "not mine"
    end

    test "an edit can be abandoned", %{conn: conn, status: status} do
      {:ok, live, _html} = live(conn, ~p"/home")

      live |> element("button[phx-value-id='#{status.id}'][phx-click='edit']") |> render_click()
      live |> element("button[phx-click='edit_cancel']") |> render_click()
      html = render(live)

      refute html =~ "Save changes"
      assert Repo.reload(status).edited_at == nil
    end
  end
end
