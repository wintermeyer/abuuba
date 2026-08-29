defmodule AbuubaWeb.SettingsLiveTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.PostingDefaults
  alias Abuuba.Accounts.Preferences
  alias Abuuba.Accounts.User
  alias Abuuba.EmailSubscriptions
  alias Abuuba.EmailSubscriptions.Message
  alias Abuuba.EmailSubscriptions.Subscription
  alias Abuuba.Federation.Actor
  alias Abuuba.Filters
  alias Abuuba.Imports
  alias Abuuba.Imports.Run
  alias Abuuba.Invites
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.Appeal
  alias Abuuba.Moderation.Domains
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Roles

  @password "the original password"

  setup %{conn: conn} do
    account = account_fixture(%{username: "alice", display_name: "Alice"})

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, user} =
      user |> User.password_changeset(%{password: @password}) |> Repo.update()

    %{conn: log_in(conn, user), account: account, user: user}
  end

  # The test adapter posts every message to this process; a test that has to
  # look at all of them takes them out of the mailbox rather than asking for
  # one at a time.
  defp flush_emails(collected \\ []) do
    receive do
      {:email, email} -> flush_emails([email | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp reload(user), do: Repo.get(User, user.id)

  describe "the area" do
    test "one page lists every section", %{conn: conn} do
      # The point of the issue: one surface rather than a seam between two
      # different interfaces.
      {:ok, _live, html} = live(conn, ~p"/settings")

      for path <-
            ~w(profile appearance posting privacy filters follows security applications account) do
        assert html =~ "/settings/#{path}"
      end
    end

    test "every section answers", %{conn: conn} do
      for path <-
            ~w(profile appearance posting privacy filters follows security applications account) do
        assert {:ok, _live, _html} = live(conn, "/settings/#{path}")
      end
    end

    test "the section being looked at is marked current", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/profile")

      assert html =~ ~s(aria-current="page")
    end

    test "somebody signed out gets none of it", %{} do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/settings/profile")
    end
  end

  describe "profile" do
    test "changes the name and the bio", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/profile")

      live
      |> form("#profile-form", %{
        "account" => %{"display_name" => "Alice Again", "note" => "a new bio"}
      })
      |> render_submit()

      saved = Accounts.get_account(account.id)
      assert saved.display_name == "Alice Again"
      assert saved.note == "a new bio"
    end

    test "keeps fields, in the order they were given", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/profile")

      live |> element("button[phx-click='add_field']") |> render_click()
      live |> element("button[phx-click='add_field']") |> render_click()

      live
      |> form("#profile-form", %{
        "account" => %{
          "display_name" => "Alice",
          "fields" => %{
            "0" => %{"name" => "Second", "value" => "two"},
            "1" => %{"name" => "First", "value" => "one"}
          }
        }
      })
      |> render_submit()

      assert [%{name: "Second"}, %{name: "First"}] = Accounts.get_account(account.id).fields
    end

    test "refuses a name longer than the limit and says so", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/profile")

      html =
        live
        |> form("#profile-form", %{
          "account" => %{"display_name" => String.duplicate("a", 200)}
        })
        |> render_submit()

      assert html =~ "could not be saved"
      assert Accounts.get_account(account.id).display_name == "Alice"
    end

    test "marks the field whose link was checked, and only that one", %{
      conn: conn,
      account: account
    } do
      # The badge is read from the saved account rather than from the row in
      # the form, because it is a fact about what this server fetched.
      {:ok, _account} =
        account
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_embed(:fields, [
          %Abuuba.Accounts.Account.Field{
            name: "Website",
            value: "https://alice.example/",
            verified_at: DateTime.utc_now()
          },
          %Abuuba.Accounts.Account.Field{name: "Blog", value: "https://blog.example/"}
        ])
        |> Repo.update()

      {:ok, _live, html} = live(conn, ~p"/settings/profile")

      assert html =~ "Verified"
      assert [_before, after_first] = String.split(html, "https://alice.example/", parts: 2)
      refute after_first |> String.split("https://blog.example/") |> List.last() =~ "Verified"
    end

    test "features a hashtag and takes it off again", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/profile")

      live |> form("#feature-tag-form", %{"tag" => "#gardening"}) |> render_submit()

      assert [%{tag: %{name: "gardening"}}] = Abuuba.Statuses.featured_tags(account)

      html =
        live
        |> element("button[phx-click='unfeature_tag'][phx-value-tag='gardening']")
        |> render_click()

      assert Abuuba.Statuses.featured_tags(account) == []
      assert html =~ "Featured hashtags"
    end

    test "offers the tags somebody actually writes under", %{conn: conn, account: account} do
      for _ <- 1..2 do
        Abuuba.StatusesFixtures.status_fixture(%{
          account_id: account.id,
          text: "more about #cycling"
        })
      end

      {:ok, _live, html} = live(conn, ~p"/settings/profile")

      assert html =~ "You often write about"
      assert html =~ "cycling"
    end

    test "cannot rename the account itself", %{conn: conn, account: account} do
      # The username decides who the account is, and every other server holds a
      # copy of it.
      {:ok, live, _html} = live(conn, ~p"/settings/profile")

      render_submit(live, "save_profile", %{"account" => %{"username" => "somebodyelse"}})

      assert Accounts.get_account(account.id).username == "alice"
    end
  end

  describe "appearance" do
    test "records an accessibility preference", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/settings/appearance")

      live
      |> form("#appearance-form", %{"preferences" => %{"reduce_motion" => "true"}})
      |> render_submit()

      assert Preferences.for_user(reload(user))["reduce_motion"]
    end

    test "keeps the ones it was not asked about", %{conn: conn, user: user} do
      {:ok, _} =
        Accounts.update_user_settings(
          user,
          Preferences.merge(user.settings, %{"high_contrast" => true})
        )

      {:ok, live, _html} = live(conn, ~p"/settings/appearance")

      live
      |> form("#appearance-form", %{"preferences" => %{"reduce_motion" => "true"}})
      |> render_submit()

      assert Preferences.for_user(reload(user))["high_contrast"]
    end
  end

  describe "posting defaults" do
    test "records the audience new posts start with", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/settings/posting")

      live
      |> form("#posting-form", %{"posting" => %{"visibility" => "private", "language" => "de"}})
      |> render_submit()

      posting = PostingDefaults.for_user(reload(user))
      assert posting["visibility"] == "private"
      assert posting["language"] == "de"
    end

    test "turns the app byline off", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/settings/posting")

      live
      |> form("#posting-form", %{"posting" => %{"show_application" => "false"}})
      |> render_submit()

      refute PostingDefaults.for_user(reload(user))["show_application"]
    end

    test "refuses an audience that would post to nobody", %{conn: conn, user: user} do
      # A default of "only the people I name" turns every post somebody forgets
      # to change into a message to nobody.
      {:ok, live, _html} = live(conn, ~p"/settings/posting")

      render_submit(live, "save_posting", %{"posting" => %{"visibility" => "direct"}})

      assert PostingDefaults.for_user(reload(user))["visibility"] == "public"
    end

    test "the compose box starts with what was chosen", %{conn: conn, user: user} do
      {:ok, _} =
        Accounts.update_user_settings(
          user,
          PostingDefaults.merge(user.settings, %{"visibility" => "private"})
        )

      {:ok, _live, html} = live(conn, ~p"/home")

      assert html =~ ~s(phx-value-visibility="private" phx-target="1" aria-pressed="true")
    end
  end

  describe "blocked servers" do
    test "blocks one, lists it, and lets it go again", %{conn: conn, account: account} do
      # The whole backend for this existed -- context, importer, exporter, and
      # the read paths that enforce it -- with no way to make one except
      # importing a CSV from another server.
      {:ok, live, _html} = live(conn, ~p"/settings/filters")

      live
      |> form("#domain-block-form", %{"domain" => "https://spam.example/"})
      |> render_submit()

      assert Relationships.blocked_domains(account) == ["spam.example"]
      assert render(live) =~ "spam.example"

      live |> element("button[phx-value-domain='spam.example']") |> render_click()

      assert Relationships.blocked_domains(account) == []
    end

    test "blocking one twice leaves it blocked once", %{conn: conn, account: account} do
      # The unique index means the second insert comes back as an error rather
      # than raising, and from the person's side blocking something already
      # blocked should simply be blocked.
      {:ok, live, _html} = live(conn, ~p"/settings/filters")

      for _ <- 1..2 do
        live |> form("#domain-block-form", %{"domain" => "spam.example"}) |> render_submit()
      end

      assert Relationships.blocked_domains(account) == ["spam.example"]
    end

    test "and ignores an empty one rather than storing it", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/filters")

      live |> form("#domain-block-form", %{"domain" => "   "}) |> render_submit()

      assert Relationships.blocked_domains(account) == []
    end
  end

  describe "privacy" do
    test "records who may find and index the account", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      live
      |> form("#privacy-form", %{
        "account" => %{"discoverable" => "true", "indexable" => "true", "locked" => "true"}
      })
      |> render_submit()

      saved = Accounts.get_account(account.id)
      assert saved.discoverable
      assert saved.indexable
      assert saved.locked
    end

    test "takes the sites allowed to name the account as an author", %{
      conn: conn,
      account: account
    } do
      # One per line is what a person types; the stored form is bare domains,
      # so a pasted address and a wildcard both land as something a preview
      # card can be matched against.
      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      live
      |> form("#privacy-form", %{
        "account" => %{"attribution_domains" => "https://news.example/\n*.blog.example"}
      })
      |> render_submit()

      assert Accounts.get_account(account.id).attribution_domains == [
               "news.example",
               "blog.example"
             ]
    end

    test "says what being discoverable actually does", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/privacy")

      assert html =~ "directory"
    end
  end

  describe "writing to the people who subscribed by email" do
    setup %{account: account, user: user} do
      Abuuba.Settings.put("email_subscriptions", true)

      {:ok, user} =
        user
        |> Ecto.Changeset.change(
          settings: Map.put(user.settings || %{}, "email_subscriptions", true)
        )
        |> Repo.update()

      :ok = EmailSubscriptions.subscribe(account, "reader@example.com")

      {:ok, _confirmed} =
        Subscription
        |> Repo.get_by!(email: "reader@example.com")
        |> EmailSubscriptions.confirm()

      on_exit(fn -> Abuuba.Settings.put("email_subscriptions", false) end)

      %{user: user}
    end

    test "offers the form once somebody has confirmed", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/privacy")

      assert html =~ "email-update-form"
    end

    test "sends what was written, and lists it afterwards", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      html =
        live
        |> form("#email-update-form", %{
          "message" => %{"subject" => "What I did", "body" => "Not much."}
        })
        |> render_submit()

      assert html =~ "What I did"

      assert [%{subject: "What I did", body: "Not much."}] =
               EmailSubscriptions.messages(account)

      Oban.drain_queue(queue: :ingress, with_recursion: true)

      assert_email_sent(fn email ->
        assert email.subject == "What I did"
        assert email.text_body =~ "Not much."
      end)
    end

    test "refuses an empty one and says so", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      html =
        live
        |> form("#email-update-form", %{"message" => %{"subject" => "", "body" => ""}})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert EmailSubscriptions.messages(account) == []
    end

    test "refuses a crafted send from an account that turned it off", %{
      conn: conn,
      account: account,
      user: user
    } do
      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      {:ok, _user} =
        user
        |> Ecto.Changeset.change(settings: Map.put(user.settings, "email_subscriptions", false))
        |> Repo.update()

      render_submit(live, "send_email_update", %{
        "message" => %{"subject" => "Sneaky", "body" => "Hello."}
      })

      assert EmailSubscriptions.messages(account) == []
    end

    test "says when the day's messages are used up", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      answers =
        for n <- 1..(EmailSubscriptions.messages_per_day() + 1) do
          live
          |> form("#email-update-form", %{
            "message" => %{"subject" => "Number #{n}", "body" => "Hello."}
          })
          |> render_submit()
        end

      assert List.last(answers) =~ "today"

      # The positive control: the earlier ones went out.
      assert hd(answers) =~ "Number 1"
    end

    test "cannot be aimed at somebody else's list", %{conn: conn, account: account} do
      # The crafted field is the whole attack: `account_id` says whose
      # subscribers hear it and whose name is on it, so a form that decided
      # either would let anybody here write to anybody else's readers as them.
      victim = account_fixture(%{username: "victim"})

      victim_user =
        user_fixture(%{account_id: victim.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, _victim_user} =
        victim_user
        |> Ecto.Changeset.change(
          settings: Map.put(victim_user.settings || %{}, "email_subscriptions", true)
        )
        |> Repo.update()

      :ok = EmailSubscriptions.subscribe(victim, "theirs@example.com")

      {:ok, _confirmed} =
        Subscription
        |> Repo.get_by!(email: "theirs@example.com")
        |> EmailSubscriptions.confirm()

      Oban.drain_queue(queue: :ingress, with_recursion: true)
      flush_emails()

      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      render_submit(live, "send_email_update", %{
        "message" => %{
          "subject" => "Not from them",
          "body" => "Hello.",
          "account_id" => to_string(victim.id)
        }
      })

      Oban.drain_queue(queue: :ingress, with_recursion: true)

      assert EmailSubscriptions.messages(victim) == []
      assert [%{subject: "Not from them"}] = EmailSubscriptions.messages(account)

      # And the victim's reader hears nothing, since the list that was mailed
      # is the sender's own.
      refute Enum.any?(flush_emails(), &(elem(hd(&1.to), 1) == "theirs@example.com"))
    end

    test "cannot forge how far a message got", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      render_submit(live, "send_email_update", %{
        "message" => %{
          "subject" => "Big news",
          "body" => "Hello.",
          "recipient_count" => "9999",
          "finished_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })

      [message] = EmailSubscriptions.messages(account)

      # The row is the record an admin reads when somebody complains about mail
      # sent in this account's name. A record its author can write is not one.
      assert message.recipient_count == 0
      refute message.finished_at

      Oban.drain_queue(queue: :ingress, with_recursion: true)

      assert Repo.reload!(message).recipient_count == 1
    end

    test "refuses a message longer than a message", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      html =
        live
        |> form("#email-update-form", %{
          "message" => %{
            "subject" => "Long",
            "body" => String.duplicate("a", Message.max_body() + 1)
          }
        })
        |> render_submit()

      assert html =~ "Message"
      assert EmailSubscriptions.messages(account) == []
    end

    test "says a message is still on its way until it is not", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/privacy")

      html =
        live
        |> form("#email-update-form", %{
          "message" => %{"subject" => "What I did", "body" => "Not much."}
        })
        |> render_submit()

      # "Sent to 0 addresses" is what this said before, which reads as a
      # message that reached nobody rather than one that has not gone yet.
      assert html =~ "On its way"

      Oban.drain_queue(queue: :ingress, with_recursion: true)

      {:ok, _live, html} = live(conn, ~p"/settings/privacy")
      assert html =~ "Sent to one address"
    end

    test "is not offered by an account that has not turned it on", %{conn: conn, user: user} do
      {:ok, _user} =
        user
        |> Ecto.Changeset.change(settings: Map.put(user.settings, "email_subscriptions", false))
        |> Repo.update()

      {:ok, _live, html} = live(conn, ~p"/settings/privacy")

      refute html =~ "email-update-form"
    end
  end

  describe "filters" do
    test "creates one, with the words it is meant to look for", %{conn: conn, account: account} do
      # A filter with no words matches nothing, so a form that cannot take any
      # is a form for making rules that quietly do nothing at all.
      {:ok, live, _html} = live(conn, ~p"/settings/filters")

      live
      |> form("#filter-form", %{
        "filter" => %{
          "title" => "No spoilers",
          "context" => ["home"],
          "filter_action" => "warn",
          "keywords" => "the finale\nwho dies"
        }
      })
      |> render_submit()

      assert [filter] = Filters.all(account)
      assert filter.title == "No spoilers"
      assert Enum.map(filter.keywords, & &1.keyword) == ["the finale", "who dies"]
      assert Enum.all?(filter.keywords, & &1.whole_word)
    end

    test "can be asked to match inside longer words", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/filters")

      live
      |> form("#filter-form", %{
        "filter" => %{
          "title" => "Cats",
          "context" => ["home"],
          "filter_action" => "warn",
          "keywords" => "cat",
          "whole_word" => "false"
        }
      })
      |> render_submit()

      assert [%{keywords: [%{whole_word: false}]}] = Filters.all(account)
    end

    test "refuses one with no words to look for", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/filters")

      html =
        live
        |> form("#filter-form", %{
          "filter" => %{"title" => "Empty", "context" => ["home"], "keywords" => "   "}
        })
        |> render_submit()

      # Named, not generic: "that could not be saved" leaves somebody staring
      # at four boxes wondering which one.
      assert html =~ "at least one word"
      assert Filters.all(account) == []
    end

    test "lists what is there, and the words in it", %{conn: conn, account: account} do
      {:ok, _} =
        Filters.create(account, %{
          "title" => "Quiet please",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "shouting"}]
        })

      {:ok, _live, html} = live(conn, ~p"/settings/filters")

      assert html =~ "Quiet please"
      assert html =~ "shouting"
    end

    test "deletes one", %{conn: conn, account: account} do
      {:ok, filter} = Filters.create(account, %{title: "Temporary", context: ["home"]})

      {:ok, live, _html} = live(conn, ~p"/settings/filters")

      live
      |> element("button[phx-value-filter='#{filter.id}'][phx-click='delete_filter']")
      |> render_click()

      assert Filters.all(account) == []
    end

    test "will not delete somebody else's", %{conn: conn} do
      {:ok, theirs} = Filters.create(account_fixture(), %{title: "Theirs", context: ["home"]})

      {:ok, live, _html} = live(conn, ~p"/settings/filters")
      render_click(live, "delete_filter", %{"filter" => to_string(theirs.id)})

      assert Repo.get(Abuuba.Filters.Filter, theirs.id)
    end

    test "refuses one with no context, and says why", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/filters")

      html =
        live
        |> form("#filter-form", %{
          "filter" => %{"title" => "Nowhere", "context" => [], "keywords" => "something"}
        })
        |> render_submit()

      assert html =~ "could not be saved"
    end
  end

  describe "follows" do
    setup %{account: account} do
      bob = account_fixture(%{username: "bob", display_name: "Bob"})
      {:ok, _} = Relationships.follow(account, bob)

      %{bob: bob}
    end

    test "lists who somebody follows", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/follows")

      assert html =~ "Bob"
    end

    test "unfollows in bulk", %{conn: conn, account: account, bob: bob} do
      carol = account_fixture(%{username: "carol"})
      {:ok, _} = Relationships.follow(account, carol)

      {:ok, live, _html} = live(conn, ~p"/settings/follows")

      live
      |> form("#follows-form", %{"accounts" => [to_string(bob.id), to_string(carol.id)]})
      |> render_submit()

      refute Relationships.following?(account, bob)
      refute Relationships.following?(account, carol)
    end

    test "does nothing when nobody is ticked", %{conn: conn, account: account, bob: bob} do
      {:ok, live, _html} = live(conn, ~p"/settings/follows")

      live |> form("#follows-form", %{}) |> render_submit()

      assert Relationships.following?(account, bob)
    end
  end

  describe "security" do
    test "changes the password when the old one is right", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/settings/security")

      live
      |> form("#password-form", %{
        "current_password" => @password,
        "user" => %{"password" => "a new long password"}
      })
      |> render_submit()

      assert Auth.get_user_by_email_and_password(user.email, "a new long password")
    end

    test "refuses without the old one", %{conn: conn, user: user} do
      # Otherwise somebody who walks up to an unlocked screen owns the account.
      {:ok, live, _html} = live(conn, ~p"/settings/security")

      html =
        live
        |> form("#password-form", %{
          "current_password" => "not the password",
          "user" => %{"password" => "a new long password"}
        })
        |> render_submit()

      assert html =~ "not right"
      assert Auth.get_user_by_email_and_password(user.email, @password)
    end

    test "signs every session out", %{conn: conn, user: user} do
      token = Auth.create_session_token(user)

      {:ok, live, _html} = live(conn, ~p"/settings/security")
      live |> element("button[phx-click='sign_out_everywhere']") |> render_click()

      refute Auth.get_user_by_session_token(token)
    end
  end

  describe "applications" do
    test "lists what has been let in", %{conn: conn, user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{name: "A Client", redirect_uris: "https://a.test/cb"})

      {:ok, _token, _raw} = OAuth.issue_token(application, user, ["read"])

      {:ok, _live, html} = live(conn, ~p"/settings/applications")

      assert html =~ "A Client"
    end

    test "says in plain words what each app may do", %{conn: conn, user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{name: "A Client", redirect_uris: "https://a.test/cb"})

      {:ok, _token, _raw} = OAuth.issue_token(application, user, ["read:statuses", "write:media"])

      {:ok, _live, html} = live(conn, ~p"/settings/applications")

      # The same sentences the sign-in screen used, because the question the
      # reader is asking is the one they answered then.
      assert html =~ "Read your posts and timelines"
      assert html =~ "Upload files as you"
    end

    test "shows everything an app signed in twice may do", %{conn: conn, user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{name: "A Client", redirect_uris: "https://a.test/cb"})

      {:ok, _token, _raw} = OAuth.issue_token(application, user, ["read:statuses"])
      {:ok, _second, _raw} = OAuth.issue_token(application, user, ["write:media"])

      {:ok, _live, html} = live(conn, ~p"/settings/applications")

      # One row, and what it may do is everything either token carries: a row
      # showing one token's scopes would understate what the app can reach.
      assert html =~ "Read your posts and timelines"
      assert html =~ "Upload files as you"
    end

    test "falls back to the raw scope for one nobody worded", %{conn: conn, user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{name: "A Client", redirect_uris: "https://a.test/cb"})

      {:ok, token, _raw} = OAuth.issue_token(application, user, ["read"])

      token
      |> Ecto.Changeset.change(scopes: "read read:invented")
      |> Repo.update!()

      {:ok, _live, html} = live(conn, ~p"/settings/applications")

      # Ugly rather than invisible: a scope this screen has no sentence for is
      # still something the app may do.
      assert html =~ "read:invented"
    end

    test "says so for an app that asked for nothing at all", %{conn: conn, user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{name: "A Client", redirect_uris: "https://a.test/cb"})

      {:ok, token, _raw} = OAuth.issue_token(application, user, ["read"])
      token |> Ecto.Changeset.change(scopes: "") |> Repo.update!()

      {:ok, _live, html} = live(conn, ~p"/settings/applications")

      assert html =~ "A Client"
      assert html =~ "Nothing"
    end

    test "lists only this account's apps", %{conn: conn, user: user} do
      {:ok, mine, _secret} =
        OAuth.create_application(%{name: "Mine", redirect_uris: "https://a.test/cb"})

      {:ok, theirs, _secret} =
        OAuth.create_application(%{name: "Theirs", redirect_uris: "https://b.test/cb"})

      stranger =
        user_fixture(%{
          account_id: account_fixture().id,
          approved: true,
          confirmed_at: DateTime.utc_now()
        })

      {:ok, _token, _raw} = OAuth.issue_token(mine, user, ["read:statuses"])
      {:ok, _token, _raw} = OAuth.issue_token(theirs, stranger, ["write:media"])

      {:ok, _live, html} = live(conn, ~p"/settings/applications")

      assert html =~ "Mine"
      refute html =~ "Theirs"
    end

    test "takes one back out", %{conn: conn, user: user} do
      {:ok, application, _secret} =
        OAuth.create_application(%{name: "A Client", redirect_uris: "https://a.test/cb"})

      {:ok, _token, _raw} = OAuth.issue_token(application, user, ["read"])

      {:ok, live, _html} = live(conn, ~p"/settings/applications")

      live
      |> element(
        "button[phx-value-application='#{application.id}'][phx-click='revoke_application']"
      )
      |> render_click()

      assert OAuth.authorized_applications(user) == []
    end
  end

  describe "account" do
    test "records an alias, which is what a move needs", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/account")

      live
      |> form("#aliases-form", %{"aliases" => "https://other.example/users/alice"})
      |> render_submit()

      assert Accounts.get_account(account.id).also_known_as == [
               "https://other.example/users/alice"
             ]
    end

    test "refuses something that is not an address", %{conn: conn, account: account} do
      {:ok, live, _html} = live(conn, ~p"/settings/account")

      html = live |> form("#aliases-form", %{"aliases" => "not a url"}) |> render_submit()

      assert html =~ "web address"
      assert Accounts.get_account(account.id).also_known_as == []
    end
  end

  describe "moderation" do
    setup %{account: account} do
      %{moderator: account_fixture(), account: account}
    end

    test "somebody with nothing against them is told so", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/moderation")

      assert html =~ "No moderator here has taken any action"
    end

    test "shows what was decided and what they were told", %{
      conn: conn,
      account: account,
      moderator: moderator
    } do
      {:ok, _} = Actions.take(moderator, account, "silence", text: "Please stop shouting.")

      {:ok, _live, html} = live(conn, ~p"/settings/moderation")

      assert html =~ "Please stop shouting."
      assert html =~ "limited"
    end

    test "shows nobody else's", %{conn: conn, moderator: moderator} do
      # The page is the one place somebody reads a decision about themselves,
      # so it must never be a place they read one about anybody else.
      {:ok, _} = Actions.take(moderator, account_fixture(), "suspend", text: "Not your business.")

      {:ok, _live, html} = live(conn, ~p"/settings/moderation")

      refute html =~ "Not your business."
    end

    test "an appeal can be filed from it", %{conn: conn, account: account, moderator: moderator} do
      {:ok, strike} = Actions.take(moderator, account, "silence")

      {:ok, live, _html} = live(conn, ~p"/settings/moderation")

      html =
        live
        |> form("form[phx-submit='appeal']", %{
          "strike" => strike.id,
          "text" => "I did not do that."
        })
        |> render_submit()

      assert Actions.appeal_for(strike).text == "I did not do that."
      assert html =~ "Nobody has decided yet"
    end

    test "and only once", %{conn: conn, account: account, moderator: moderator} do
      {:ok, strike} = Actions.take(moderator, account, "silence")
      {:ok, _} = Actions.appeal(account, strike, "Already said my piece.")

      {:ok, _live, html} = live(conn, ~p"/settings/moderation")

      refute html =~ "phx-submit=\"appeal\""
      assert html =~ "Nobody has decided yet"
    end

    test "the decision on an appeal is shown", %{
      conn: conn,
      account: account,
      moderator: moderator
    } do
      {:ok, strike} = Actions.take(moderator, account, "silence")
      {:ok, appeal} = Actions.appeal(account, strike, "I did not do that.")
      {:ok, _} = Actions.reject_appeal(moderator, appeal)

      {:ok, _live, html} = live(conn, ~p"/settings/moderation")

      assert html =~ "turned down"
    end

    test "a strike past the window says so instead of offering a form", %{
      conn: conn,
      account: account,
      moderator: moderator
    } do
      {:ok, strike} = Actions.take(moderator, account, "silence")
      old = DateTime.add(DateTime.utc_now(), -(Appeal.window_days() + 1), :day)
      {:ok, _} = strike |> Ecto.Changeset.change(inserted_at: old) |> Repo.update()

      {:ok, _live, html} = live(conn, ~p"/settings/moderation")

      assert html =~ "has passed"
      refute html =~ "phx-submit=\"appeal\""
    end

    test "says what a server-level decision cost them", %{conn: conn, account: account} do
      # The follows are gone and the accounts on the other side cannot be
      # asked, so this page is the only thing that can still say what happened.
      them = remote_account_fixture(%{domain: "bad.example"})
      {:ok, _} = Relationships.follow(account, them)

      {:ok, _} =
        Domains.block(account_fixture(), %{
          "domain" => "bad.example",
          "severity" => "suspend"
        })

      {:ok, _live, html} = live(conn, ~p"/settings/moderation")

      assert html =~ "bad.example"
      assert html =~ "1"
    end

    test "an appeal against somebody else's strike goes nowhere", %{
      conn: conn,
      moderator: moderator
    } do
      # The form is scoped to the reader, but the event carries an id and an id
      # can be typed by hand.
      {:ok, theirs} = Actions.take(moderator, account_fixture(), "silence")

      {:ok, live, _html} = live(conn, ~p"/settings/moderation")

      render_hook(live, "appeal", %{"strike" => to_string(theirs.id), "text" => "Let me out."})

      assert Actions.appeal_for(theirs) == nil
    end
  end

  describe "invites" do
    test "are not offered to somebody who may not make them", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/invites")

      assert html =~ "not something this account can do"
    end

    test "can be made and taken back", %{conn: conn, user: user} do
      {:ok, role} =
        Roles.create(%{
          name: "Inviter #{System.unique_integer([:positive])}",
          position: 10,
          permissions: Roles.mask(["invite_users"])
        })

      {:ok, _} = Roles.assign(user, role)

      {:ok, live, _html} = live(conn, ~p"/settings/invites")

      live
      |> form("#invite-form", %{"comment" => "For Jo", "max_uses" => "2"})
      |> render_submit()

      assert [invite] = Invites.list(user.account_id)
      assert invite.comment == "For Jo"
      assert invite.max_uses == 2

      live
      |> element("button[phx-click='delete_invite'][phx-value-invite='#{invite.id}']")
      |> render_click()

      assert Invites.list(user.account_id) == []
    end
  end

  describe "importing an archive" do
    test "says plainly what cannot come with the posts", %{conn: conn} do
      # Somebody discovering a week later that their followers did not come
      # across is somebody who was not told.
      {:ok, _live, html} = live(conn, ~p"/settings/import")

      assert html =~ "Your followers"
      assert html =~ "old addresses"
      assert html =~ "Boosts and polls"
    end

    test "shows how far a running import has got", %{conn: conn, account: account} do
      {:ok, _import} =
        %Run{}
        |> Run.changeset(%{
          account_id: account.id,
          path: "/tmp/nothing.zip",
          filename: "archive.zip"
        })
        |> Repo.insert()

      {:ok, _live, html} = live(conn, ~p"/settings/import")

      assert html =~ "Waiting to start"
    end

    test "and names what it could not bring over", %{conn: conn, account: account} do
      {:ok, archive_import} =
        %Run{}
        |> Run.changeset(%{
          account_id: account.id,
          path: "/tmp/nothing.zip"
        })
        |> Repo.insert()

      {:ok, _finished} =
        archive_import
        |> Run.progress_changeset(%{
          state: "finished",
          finished_at: DateTime.utc_now(),
          total: 1,
          done: 1,
          failures: [%{"what" => "post from 2019", "reason" => "boosts_are_not_carried"}]
        })
        |> Repo.update()

      {:ok, _live, html} = live(conn, ~p"/settings/import")

      assert html =~ "post from 2019"
      assert html =~ "cannot come with you"
    end

    test "a running import is announced to the page watching it", %{
      conn: conn,
      account: account
    } do
      {:ok, live, _html} = live(conn, ~p"/settings/import")

      {:ok, archive_import} =
        %Run{}
        |> Run.changeset(%{
          account_id: account.id,
          path: "/tmp/nothing.zip"
        })
        |> Repo.insert()

      Phoenix.PubSub.broadcast(
        Abuuba.PubSub,
        Imports.topic(account),
        {:archive_import, %{archive_import | state: "running", total: 10, done: 3}}
      )

      assert render(live) =~ "Reading your archive"
    end
  end

  describe "moving to another account" do
    test "says what has to be true before it can happen", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/account")

      assert html =~ "name this one in its own aliases"
      assert html =~ "once every 30 days"
    end

    test "refuses an account that does not name this one back", %{conn: conn} do
      # Without the backlink anybody could name any account as their
      # destination and be handed a follower list.
      other = account_fixture(%{domain: "other.example", uri: "https://other.example/users/bob"})

      {:ok, live, _html} = live(conn, ~p"/settings/account")

      html =
        live
        |> form("#move-form", %{"target" => "#{other.username}@other.example"})
        |> render_submit()

      assert html =~ "does not name this one as one of yours"
    end

    test "moves when it does", %{conn: conn, account: account} do
      other =
        account_fixture(%{
          domain: "other.example",
          uri: "https://other.example/users/elsewhere",
          also_known_as: [Actor.id(account)]
        })

      {:ok, live, _html} = live(conn, ~p"/settings/account")

      html =
        live
        |> form("#move-form", %{"target" => "#{other.username}@other.example"})
        |> render_submit()

      assert html =~ "This account has moved"
      assert Repo.reload(account).moved_to_account_id == other.id
    end
  end

  describe "importing a list" do
    test "offers the CSV files an old server hands out", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/settings/import")

      assert html =~ "follows, blocks, mutes"
      assert html =~ "Replace it with the file"
    end
  end
end
