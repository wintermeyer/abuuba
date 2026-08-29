defmodule AbuubaWeb.ProfileLiveTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Media
  alias Abuuba.Relationships
  alias Abuuba.Statuses
  alias Abuuba.Translation
  alias Abuuba.Translation.Fake, as: TranslationFake

  setup %{conn: conn} do
    subject =
      account_fixture(%{
        username: "bob",
        display_name: "Bob",
        note: "a person who posts"
      })

    reader = account_fixture(%{username: "alice"})

    user =
      user_fixture(%{account_id: reader.id, approved: true, confirmed_at: DateTime.utc_now()})

    %{conn: conn, signed_in: log_in(conn, user), subject: subject, reader: reader, user: user}
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  describe "the page itself" do
    test "is rendered by the server, before any socket connects", %{
      conn: conn,
      subject: subject
    } do
      status_fixture(%{account_id: subject.id, text: "something bob said"})

      html = conn |> get("/@bob") |> html_response(200)

      assert html =~ "Bob"
      assert html =~ "a person who posts"
      assert html =~ "something bob said"
    end

    test "dates a post for a reader, not for a machine", %{conn: conn, subject: subject} do
      # The entity carries ISO 8601 because that is what the API hands clients,
      # and the component used to print that string straight into the page. A
      # timeline is read in the present tense, so a reader got
      # "2026-08-29T09:30:22.000000Z" where every other client shows an age.
      status_fixture(%{account_id: subject.id, text: "something bob said"})

      html = conn |> get("/@bob") |> html_response(200)

      assert html =~ "just now"
      refute html =~ ~r/>\s*\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
      # The machine-readable form keeps its place, which is the attribute.
      assert html =~ ~s(<time datetime=")
    end

    test "dates it in the reader's language, not the server's", %{conn: conn, subject: subject} do
      # The age is a translated string, so putting it in the page put Gettext
      # on a path that only ever ran from the admin area before. A German
      # reader asking for this page has to get the German phrasing.
      status_fixture(%{account_id: subject.id, text: "something bob said"})

      html =
        conn
        |> Plug.Conn.put_req_header("accept-language", "de")
        |> get("/@bob")
        |> html_response(200)

      assert html =~ "gerade eben"
      refute html =~ "just now"
    end

    test "carries what a link preview reads", %{conn: conn, subject: _subject} do
      html = conn |> get("/@bob") |> html_response(200)

      assert html =~ ~s(property="og:title")
      assert html =~ ~s(property="og:type")
      assert html =~ "Bob"
    end

    test "keeps markup out of what a preview reads", %{conn: conn} do
      # A remote bio is HTML. Copied into a meta tag as-is it closes the tag,
      # and everything after it becomes attributes somebody else chose.
      remote_account_fixture(%{
        username: "dave",
        domain: "remote.example",
        note: "<p>a bio with <em>markup</em></p>"
      })

      html = conn |> get("/@dave@remote.example") |> html_response(200)

      refute html =~ ~s(content="<p>)
      assert html =~ "a bio with markup"
    end

    test "a name nobody answers to is a plain miss", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/@nobody") end
    end

    test "somebody suspended is not shown", %{conn: conn, subject: subject} do
      {:ok, _} =
        subject |> Ecto.Changeset.change(suspended_at: DateTime.utc_now()) |> Abuuba.Repo.update()

      assert_error_sent 404, fn -> get(conn, "/@bob") end
    end
  end

  describe "the tabs" do
    setup %{subject: subject} do
      post = status_fixture(%{account_id: subject.id, text: "a plain post"})

      reply =
        status_fixture(%{
          account_id: subject.id,
          text: "an answer to somebody",
          in_reply_to_id: post.id,
          in_reply_to_account_id: subject.id
        })

      with_picture = status_fixture(%{account_id: subject.id, text: "look at this"})

      path = Path.join(System.tmp_dir!(), "profile-#{System.unique_integer([:positive])}")
      File.write!(path, "a file")

      {:ok, attachment} =
        Media.upload(subject, %{path: path, filename: "p.png", content_type: "image/png"})

      {:ok, _} = Media.attach(with_picture, [attachment.id])

      %{post: post, reply: reply, with_picture: with_picture}
    end

    test "posts leaves replies out", %{conn: conn} do
      html = conn |> get("/@bob") |> html_response(200)

      assert html =~ "a plain post"
      refute html =~ "an answer to somebody"
    end

    test "posts and replies shows both", %{conn: conn} do
      html = conn |> get("/@bob/with_replies") |> html_response(200)

      assert html =~ "a plain post"
      assert html =~ "an answer to somebody"
    end

    test "media shows only what carries something", %{conn: conn} do
      html = conn |> get("/@bob/media") |> html_response(200)

      assert html =~ "look at this"
      refute html =~ "a plain post"
    end

    test "the tab in the address is the one marked current", %{conn: conn} do
      html = conn |> get("/@bob/media") |> html_response(200)

      assert html =~ ~s(aria-current="page")
    end
  end

  describe "what a profile carries" do
    test "shows the posts its owner pinned, above the rest", %{conn: conn, subject: subject} do
      status_fixture(%{account_id: subject.id, text: "an ordinary post"})
      pinned = status_fixture(%{account_id: subject.id, text: "the pinned one"})
      {:ok, _} = Statuses.pin(subject, pinned)

      html = conn |> get("/@bob") |> html_response(200)

      assert html =~ "the pinned one"
      assert html =~ "Pinned"
    end

    test "and shows neither posts nor pins to somebody its owner blocked", %{
      signed_in: conn,
      subject: subject,
      reader: reader
    } do
      status_fixture(%{account_id: subject.id, text: "an ordinary post"})
      pinned = status_fixture(%{account_id: subject.id, text: "the pinned one"})
      {:ok, _} = Statuses.pin(subject, pinned)

      # The positive control, so the two refutes below cannot pass on a page
      # that simply renders nothing.
      html = conn |> get("/@bob") |> html_response(200)
      assert html =~ "an ordinary post"

      {:ok, _} = Relationships.block(subject, reader)

      html = conn |> get("/@bob") |> html_response(200)
      refute html =~ "an ordinary post"
      refute html =~ "the pinned one"
    end

    test "keeps crawlers off until its owner asks them in", %{conn: conn, subject: subject} do
      html = conn |> get("/@bob") |> html_response(200)
      assert html =~ ~s|name="robots"|
      assert html =~ "noindex, noarchive"

      {:ok, _} = Accounts.update_account(subject, %{indexable: true})

      html = conn |> get("/@bob") |> html_response(200)
      refute html =~ "noindex"
    end

    test "and so do the pages that aggregate other people's posts", %{conn: conn} do
      for path <- ["/explore", "/explore/tags", "/explore/people", "/search", "/tags/cats"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ "noindex, noarchive", "#{path} carries no robots tag"
      end

      # The positive control, and the point of the whole thing: the server's
      # own pages stay findable, or an instance nobody can search for is the
      # cure being worse than the illness.
      refute conn |> get("/about") |> html_response(200) =~ "noindex"
      refute conn |> get("/") |> html_response(200) =~ "noindex"
    end

    test "and the follower lists stay off whatever its owner asked for", %{
      conn: conn,
      subject: subject
    } do
      {:ok, _} = Accounts.update_account(subject, %{indexable: true})

      html = conn |> get("/@bob/followers") |> html_response(200)
      assert html =~ "noindex, noarchive"

      html = conn |> get("/@bob/following") |> html_response(200)
      assert html =~ "noindex, noarchive"
    end

    test "the follower list is closed to somebody the owner blocked", %{
      signed_in: signed_in,
      subject: subject,
      reader: reader
    } do
      # The API refuses this reader both lists -- a profile that answers the
      # person it blocked has not blocked them. The page answered.
      follower = account_fixture(%{username: "carol"})
      {:ok, _} = Relationships.follow(follower, subject)
      {:ok, _} = Relationships.block(subject, reader)

      html = signed_in |> get("/@bob/followers") |> html_response(200)

      refute html =~ "carol"
    end

    test "and open to everybody else", %{signed_in: signed_in, subject: subject} do
      # The control: hiding the list from everyone would satisfy the test
      # above without the block having anything to do with it.
      follower = account_fixture(%{username: "dave"})
      {:ok, _} = Relationships.follow(follower, subject)

      html = signed_in |> get("/@bob/followers") |> html_response(200)

      assert html =~ "dave"
    end

    test "a poll can be voted on from a profile, not only from the timeline", %{
      signed_in: signed_in,
      subject: subject,
      reader: reader
    } do
      # The form is drawn by the shared status component, so it appears on
      # every page that shows a post. Only the home timeline answers the event
      # it raises, and the other pages carry a catch-all that swallows it: the
      # button looks live, does nothing, and says nothing.
      status = status_fixture(%{account_id: subject.id, text: "pick one"})
      {:ok, poll} = Statuses.create_poll(status, %{options: ["yes", "no"]})

      {:ok, live, html} = live(signed_in, "/@bob")
      assert html =~ "Vote"

      live |> form("form[phx-submit=vote]", %{"choices" => ["0"]}) |> render_submit()

      assert Statuses.own_votes(poll, reader) == [0]
    end

    test "editing your own post from your own profile goes to where the box is", %{
      signed_in: signed_in,
      reader: reader
    } do
      # Same shape as replying: the pencil is drawn by the shared component on
      # every screen, and only the timeline and a post's own page answered it.
      # On a profile it was live and did nothing, which is where somebody is
      # most likely to press it -- looking at their own posts.
      status = status_fixture(%{account_id: reader.id, text: "mine to fix"})

      {:ok, live, _html} = live(signed_in, "/@alice")

      assert {:error, {:live_redirect, %{to: path}}} =
               live |> element("button[phx-click=edit]") |> render_click()

      assert path =~ to_string(status.id)
    end

    test "translating works from a profile, not only from a post's own page", %{
      signed_in: signed_in,
      subject: subject
    } do
      # The last of the events the shared component raises that only one screen
      # answered. A translation is not a change to the post, so the translated
      # words are put straight back into the list rather than re-read.
      on_exit(fn -> Application.delete_env(:abuuba, :translation_provider) end)

      status_fixture(%{account_id: subject.id, text: "hallo", language: "de"})

      Application.put_env(:abuuba, :translation_provider, TranslationFake)

      TranslationFake.set(fn texts, _source, target, _opts ->
        {:ok, Enum.map(texts, &("[#{target}] " <> &1))}
      end)

      Translation.expire_all()

      {:ok, live, _html} = live(signed_in, "/@bob")

      html = live |> element(~s(button[phx-click="translate"])) |> render_click()

      assert html =~ "[en]"
      assert html =~ "Translated by"
    end

    test "shows the hashtags its owner features", %{conn: conn, subject: subject} do
      {:ok, tag} = Statuses.upsert_tag("gardening")
      :ok = Statuses.feature_tag(subject, tag)

      html = conn |> get("/@bob") |> html_response(200)

      assert html =~ "gardening"
      # The address in the badge is the one this server publishes for that tag,
      # in the API and in the actor document. A page that 404s there is a link
      # every peer copies.
      assert html =~ "/@bob/tagged/gardening"
    end

    test "a featured hashtag opens that person's posts under it", %{
      conn: conn,
      subject: subject
    } do
      status_fixture(%{account_id: subject.id, text: "beetroot season #gardening"})
      status_fixture(%{account_id: subject.id, text: "nothing to do with it"})

      # Somebody else's post under the same tag: this page is one person's.
      status_fixture(%{account_id: account_fixture().id, text: "hedges too #gardening"})

      html = conn |> get("/@bob/tagged/gardening") |> html_response(200)

      # The hashtag itself is rendered as a link, so the assertions are on the
      # words around it.
      assert html =~ "beetroot season"
      refute html =~ "nothing to do with it"
      refute html =~ "hedges too"
    end

    test "shows fields", %{conn: conn, subject: subject} do
      {:ok, _} =
        Accounts.update_account(subject, %{
          fields: [
            %{name: "Website", value: "https://bob.example"},
            %{name: "Pronouns", value: "they/them"}
          ]
        })

      html = conn |> get("/@bob") |> html_response(200)

      assert html =~ "Website"
      assert html =~ "they/them"
    end

    test "a field somebody typed is text, not markup", %{conn: conn, subject: subject} do
      # `fields[].value` is HTML in this API, so a local value that reached the
      # page unescaped would be script execution in this origin — and a
      # hand-drawn Verified badge next to a link nobody checked, which is the
      # whole trust signal forged by typing.
      {:ok, _} =
        Accounts.update_account(subject, %{
          fields: [
            %{
              name: "Website",
              value:
                ~s|<img src=x onerror="alert(1)"><span class="badge badge-success">Verified</span>|
            }
          ]
        })

      html = conn |> get("/@bob") |> html_response(200)

      refute html =~ ~s|<img src=x onerror|
      refute html =~ ~s|<span class="badge badge-success">Verified</span>|
      assert html =~ "&lt;img src=x"
    end

    test "marks a field the other server verified", %{conn: conn} do
      # Their verification is theirs to assert and ours to show. Ours is earned
      # by fetching the linked page and finding a link back; see
      # `Abuuba.Accounts.LinkVerification`.
      remote =
        remote_account_fixture(%{
          username: "carol",
          domain: "remote.example",
          fields: [
            %{name: "Website", value: "https://carol.example", verified_at: DateTime.utc_now()}
          ]
        })

      html = conn |> get("/@#{remote.username}@#{remote.domain}") |> html_response(200)

      assert html =~ "Verified"
    end

    test "will not let somebody mark their own field verified", %{conn: conn, subject: subject} do
      {:ok, _} =
        Accounts.update_account(subject, %{
          fields: [
            %{name: "Website", value: "https://bob.example", verified_at: DateTime.utc_now()}
          ]
        })

      html = conn |> get("/@bob") |> html_response(200)

      refute html =~ "Verified"
    end

    test "says where somebody moved to", %{conn: conn, subject: subject} do
      # Somebody arriving at an abandoned profile has to be told, or they
      # follow an account that will never post again.
      elsewhere = account_fixture(%{username: "bob_new", display_name: "Bob elsewhere"})

      {:ok, _} =
        Accounts.update_account(subject, %{
          moved_to_account_id: elsewhere.id,
          moved_at: DateTime.utc_now()
        })

      html = conn |> get("/@bob") |> html_response(200)

      assert html =~ "moved"
      assert html =~ "bob_new"
    end
  end

  describe "following somebody who approves their followers" do
    setup %{subject: subject} do
      {:ok, locked} = Accounts.update_account(subject, %{locked: true})

      %{subject: locked}
    end

    test "asks rather than follows", %{signed_in: conn, subject: subject, reader: reader} do
      {:ok, live, _html} = live(conn, "/@bob")

      html = live |> element("button[phx-click='follow']") |> render_click()

      refute Relationships.following?(reader, subject),
             "the button followed a locked account outright instead of asking it"

      assert Relationships.get_follow_request(reader, subject)
      assert html =~ "approves"
    end

    test "says the request is waiting, and offers a way out of waiting", %{
      signed_in: conn,
      subject: subject,
      reader: reader
    } do
      {:ok, _request} = Relationships.request_follow(reader, subject)

      {:ok, live, html} = live(conn, "/@bob")

      refute html =~ ~s(phx-click="follow")
      assert html =~ "Cancel follow request"

      live |> element("button[phx-click='unfollow']") |> render_click()

      assert Relationships.get_follow_request(reader, subject) == nil
      assert render(live) =~ ~s(phx-click="follow")
    end
  end

  describe "acting on somebody" do
    test "following and unfollowing", %{signed_in: conn, subject: subject, reader: reader} do
      {:ok, live, _html} = live(conn, "/@bob")

      live |> element("button[phx-click='follow']") |> render_click()
      assert Relationships.following?(reader, subject)

      live |> element("button[phx-click='unfollow']") |> render_click()
      refute Relationships.following?(reader, subject)
    end

    # The page holds the profile it was built from, and that copy is as old as
    # the tab. What decides whether to ask is the account as it stands at the
    # moment of the press, not as it stood when somebody opened the page.
    test "somebody who locks their account while the page is open is asked", %{
      signed_in: conn,
      subject: subject,
      reader: reader
    } do
      {:ok, live, _html} = live(conn, "/@bob")
      {:ok, subject} = Accounts.update_account(subject, %{locked: true})

      live |> element("button[phx-click='follow']") |> render_click()

      refute Relationships.following?(reader, subject)
      assert Relationships.get_follow_request(reader, subject)
    end

    test "blocking", %{signed_in: conn, subject: subject, reader: reader} do
      {:ok, live, _html} = live(conn, "/@bob")

      live |> element("button[phx-click='block']") |> render_click()

      assert Relationships.blocking?(reader, subject)
    end

    test "blocking somebody stops following them", %{
      signed_in: conn,
      subject: subject,
      reader: reader
    } do
      {:ok, _} = Relationships.follow(reader, subject)
      {:ok, live, _html} = live(conn, "/@bob")

      live |> element("button[phx-click='block']") |> render_click()

      refute Relationships.following?(reader, subject)
    end

    test "muting", %{signed_in: conn, subject: subject, reader: reader} do
      {:ok, live, _html} = live(conn, "/@bob")

      live |> element("button[phx-click='mute']") |> render_click()

      assert Relationships.muting?(reader, subject)
    end

    test "a note only its author reads", %{signed_in: conn, subject: subject, reader: reader} do
      {:ok, live, _html} = live(conn, "/@bob")

      live
      |> element("form[phx-submit='save_note']")
      |> render_submit(%{"note" => "met at the conference"})

      assert Relationships.get_note(reader, subject).comment == "met at the conference"
    end

    test "offers a passer-by nothing to press", %{conn: conn} do
      html = conn |> get("/@bob") |> html_response(200)

      refute html =~ "phx-click=\"follow\""
      refute html =~ "save_note"
    end

    test "offers no way to follow yourself", %{signed_in: conn} do
      html = conn |> get("/@alice") |> html_response(200)

      refute html =~ "phx-click=\"follow\""
    end
  end

  describe "featuring somebody on your own profile" do
    test "is offered once you follow them, and not before", %{
      signed_in: conn,
      subject: subject,
      reader: reader
    } do
      {:ok, live, html} = live(conn, "/@bob")

      # An endorsement needs a follow, so offering the button to somebody who
      # cannot use it is a button that answers with an error.
      refute html =~ "phx-click=\"endorse\""

      live |> element("button[phx-click='follow']") |> render_click()

      assert render(live) =~ "phx-click=\"endorse\""
      refute Relationships.endorsed?(reader, subject)
    end

    test "puts them on the profile and takes them back off", %{
      signed_in: conn,
      subject: subject,
      reader: reader
    } do
      {:ok, _follow} = Relationships.follow(reader, subject)
      {:ok, live, _html} = live(conn, "/@bob")

      live |> element("button[phx-click='endorse']") |> render_click()
      assert Relationships.endorsed?(reader, subject)

      live |> element("button[phx-click='unendorse']") |> render_click()
      refute Relationships.endorsed?(reader, subject)
    end

    test "shows a stranger who somebody has featured", %{conn: conn, reader: reader} do
      featured = account_fixture(%{username: "carol", display_name: "Carol"})
      {:ok, _follow} = Relationships.follow(reader, featured)
      :ok = Relationships.endorse(reader, featured)

      html = conn |> get("/@alice") |> html_response(200)

      # Public, because a recommendation nobody can see recommends nothing.
      assert html =~ "Carol"
      assert html =~ "Featured"
    end

    test "leaves the section out when there is nobody in it", %{conn: conn} do
      refute conn |> get("/@alice") |> html_response(200) =~ "Featured accounts"
    end

    test "drops the feature when the follow goes", %{
      signed_in: conn,
      subject: subject,
      reader: reader
    } do
      {:ok, _follow} = Relationships.follow(reader, subject)
      :ok = Relationships.endorse(reader, subject)

      {:ok, live, _html} = live(conn, "/@bob")
      live |> element("button[phx-click='unfollow']") |> render_click()

      # The context takes it down with the follow; the page must not go on
      # offering "stop featuring" for something that is no longer featured.
      refute Relationships.endorsed?(reader, subject)
      refute render(live) =~ "phx-click=\"unendorse\""
    end

    test "refuses to feature somebody you do not follow, however the event arrives", %{
      signed_in: conn,
      subject: subject,
      reader: reader
    } do
      {:ok, live, _html} = live(conn, "/@bob")

      # The button is not on the page, so this is the raw event a crafted
      # client would send.
      render_click(live, "endorse", %{})

      refute Relationships.endorsed?(reader, subject)
      assert render(live) =~ "Bob"
    end

    test "does nothing at all for a visitor who is not signed in", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/@bob")

      # There is no viewer to act as, and `unendorse` has no check of its own,
      # so the guard in the page is the only thing between a crafted event and
      # a call with nil for the account. Without it this crashes the socket.
      render_click(live, "unendorse", %{})
      render_click(live, "endorse", %{})

      assert render(live) =~ "Bob"
    end
  end

  describe "subscribing by email from a profile" do
    setup %{subject: subject} do
      Abuuba.Settings.put("email_subscriptions", true)

      user =
        user_fixture(%{account_id: subject.id, approved: true, confirmed_at: DateTime.utc_now()})

      {:ok, user} =
        user
        |> Ecto.Changeset.change(
          settings: Map.put(user.settings || %{}, "email_subscriptions", true)
        )
        |> Abuuba.Repo.update()

      on_exit(fn -> Abuuba.Settings.put("email_subscriptions", false) end)

      %{subject_user: user}
    end

    test "is offered on a profile that takes subscribers", %{conn: conn} do
      html = conn |> get("/@bob") |> html_response(200)

      assert html =~ "email-subscription-form"
    end

    test "records the address and asks it to confirm", %{conn: conn, subject: subject} do
      {:ok, live, _html} = live(conn, "/@bob")

      html =
        live
        |> element("#email-subscription-form")
        |> render_submit(%{"email" => "reader@example.com"})

      assert html =~ "Check that address"

      assert Abuuba.Repo.get_by!(Abuuba.EmailSubscriptions.Subscription,
               email: "reader@example.com"
             ).account_id ==
               subject.id
    end

    test "answers a repeat the same way, whatever the address already is", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/@bob")

      first =
        live
        |> element("#email-subscription-form")
        |> render_submit(%{"email" => "r@example.com"})

      second =
        live
        |> element("#email-subscription-form")
        |> render_submit(%{"email" => "r@example.com"})

      # Saying "already subscribed" would let somebody type addresses in until
      # one came back, which is a way to find out who reads whom.
      assert first =~ "Check that address"
      assert second =~ "Check that address"
    end

    test "says so when the address is not one", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/@bob")

      html =
        live |> element("#email-subscription-form") |> render_submit(%{"email" => "nonsense"})

      assert html =~ "valid email address"
      assert Abuuba.Repo.aggregate(Abuuba.EmailSubscriptions.Subscription, :count) == 0
    end

    test "is not offered by an account that has not turned it on", %{conn: conn} do
      html = conn |> get("/@alice") |> html_response(200)

      refute html =~ "email-subscription-form"
    end

    test "refuses a crafted submission to an account that has not", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/@alice")

      render_submit(live, "subscribe_by_email", %{"email" => "reader@example.com"})

      assert Abuuba.Repo.aggregate(Abuuba.EmailSubscriptions.Subscription, :count) == 0
    end

    test "stops somebody using the form as a megaphone", %{conn: conn} do
      {:ok, live, _html} = live(conn, "/@bob")

      answers =
        for n <- 1..8 do
          live
          |> element("#email-subscription-form")
          |> render_submit(%{"email" => "person#{n}@example.com"})
        end

      # Five an hour per address, the same budget the API endpoint spends.
      assert Enum.any?(answers, &(&1 =~ "Too many"))
      assert Enum.any?(answers, &(&1 =~ "Check that address"))
    end
  end

  describe "the reader's own filters on a profile" do
    setup %{reader: reader} do
      {:ok, _filter} =
        Abuuba.Filters.create(reader, %{
          title: "No spoilers",
          context: ["account"],
          filter_action: "warn",
          keywords_attributes: [%{keyword: "ending", whole_word: true}]
        })

      :ok
    end

    test "fold a matching post and leave the rest", %{signed_in: conn, subject: subject} do
      status_fixture(%{account_id: subject.id, text: "the ending was good"})
      status_fixture(%{account_id: subject.id, text: "nothing in particular"})

      {:ok, _live, html} = live(conn, "/@bob")

      assert html =~ "No spoilers"
      assert html =~ "nothing in particular"
    end

    test "apply to nobody else's reading", %{conn: conn, subject: subject} do
      status_fixture(%{account_id: subject.id, text: "the ending was good"})

      # A filter is one person's rule. A passer-by sees the post.
      html = conn |> get("/@bob") |> html_response(200)

      refute html =~ "No spoilers"
      assert html =~ "the ending was good"
    end

    test "remove a post a hide rule matched", %{signed_in: conn, reader: reader, subject: subject} do
      {:ok, _hide} =
        Abuuba.Filters.create(reader, %{
          title: "Never again",
          context: ["account"],
          filter_action: "hide",
          keywords_attributes: [%{keyword: "elections", whole_word: true}]
        })

      status_fixture(%{account_id: subject.id, text: "about the elections"})

      {:ok, _live, html} = live(conn, "/@bob")

      refute html =~ "about the elections"
    end
  end

  describe "featured accounts and hiding your follows" do
    setup %{reader: reader} do
      featured = account_fixture(%{username: "carol", display_name: "Carol"})
      {:ok, _follow} = Relationships.follow(reader, featured)
      :ok = Relationships.endorse(reader, featured)

      %{featured: featured}
    end

    test "the strip goes when the follows are hidden", %{conn: conn, reader: reader} do
      # Everybody in the strip is somebody the account follows, so publishing
      # it beside a follows tab that refuses to answer would make the setting
      # quietly untrue.
      assert conn |> get("/@alice") |> html_response(200) =~ "Carol"

      {:ok, _account} = Accounts.update_account(reader, %{hide_collections: true})

      refute conn |> get("/@alice") |> html_response(200) =~ "Carol"
    end

    test "its owner still sees it", %{signed_in: conn, reader: reader} do
      {:ok, _account} = Accounts.update_account(reader, %{hide_collections: true})

      # The same rule the follows tabs already follow: a setting that hid the
      # list from the person who set it looks like a bug the first time they
      # check it worked.
      assert conn |> get("/@alice") |> html_response(200) =~ "Carol"
    end

    test "is not asked for on the tabs that never show it", %{conn: conn} do
      # One query per tab switch, on four tabs that cannot render it, is the
      # mistake the pinned list two lines away already avoids.
      queries = count_endorsement_queries(fn -> get(conn, "/@alice/media") end)

      assert queries == 0
      assert count_endorsement_queries(fn -> get(conn, "/@alice") end) == 1
    end
  end

  defp count_endorsement_queries(fun) do
    parent = self()
    handler = "endorsement-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:abuuba, :repo, :query],
      fn _event, _measures, %{query: query}, _config ->
        if String.contains?(query, "endorsements"), do: send(parent, :endorsement_query)
      end,
      nil
    )

    fun.()
    :telemetry.detach(handler)

    drain_endorsement_queries(0)
  end

  defp drain_endorsement_queries(count) do
    receive do
      :endorsement_query -> drain_endorsement_queries(count + 1)
    after
      0 -> count
    end
  end
end
