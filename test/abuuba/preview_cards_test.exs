defmodule Abuuba.PreviewCardsTest do
  use Abuuba.DataCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  import Phoenix.LiveViewTest, only: [render_component: 2]

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.Federation.URIs
  alias Abuuba.PreviewCards
  alias Abuuba.PreviewCards.FetchWorker
  alias Abuuba.Repo
  alias Abuuba.Trends
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.StatusComponent

  # Nothing here touches the network. The hardened HTTP layer takes a transport
  # for the request and a resolver for the address check, and both are the
  # seams that make an SSRF-guarded fetcher testable at all.
  defp fetch_opts(pages), do: [transport: responder(pages), resolver: resolver()]

  defp resolver do
    fn _host -> {:ok, [{93, 184, 216, 34}]} end
  end

  # Matched on the address without its query, because the oEmbed URL is built
  # by appending parameters and a test that only matched the exact string would
  # pass by falling back rather than by working.
  defp responder(pages) do
    fn _method, url, _headers, _body ->
      # `:error` from `Map.fetch/2` is truthy, so the two lookups are tried in
      # order rather than with `||`, which would always take the first.
      case Map.get(pages, url) || Map.get(pages, without_query(url)) do
        {status, headers, body} -> {:ok, status, headers, body}
        body when is_binary(body) -> {:ok, 200, [{"content-type", "text/html"}], body}
        nil -> {:ok, 404, [], ""}
      end
    end
  end

  defp without_query(url), do: url |> String.split("?", parts: 2) |> hd()

  defp html(opts) do
    """
    <html><head>
      <meta property="og:title" content="#{opts[:title] || "A Story"}">
      <meta property="og:description" content="#{opts[:description] || "What happened"}">
      #{opts[:extra] || ""}
    </head><body></body></html>
    """
  end

  describe "finding the link in a post" do
    test "takes the first one" do
      # One card per post, and the first link is the one somebody meant.
      text = "read https://news.example/one and https://news.example/two"

      assert PreviewCards.first_url(text) == "https://news.example/one"
    end

    test "ignores a mention" do
      assert PreviewCards.first_url("hello @somebody@other.example") == nil
    end

    test "ignores a hashtag" do
      assert PreviewCards.first_url("about #gardening") == nil
    end

    test "and a post with no link at all" do
      assert PreviewCards.first_url("just words") == nil
    end

    test "reads a link out of rendered HTML" do
      # A post from another server arrives as HTML rather than as text.
      html = ~s|<p>read <a href="https://news.example/story">this</a></p>|

      assert PreviewCards.first_url(html) == "https://news.example/story"
    end
  end

  describe "reading a page" do
    test "takes what OpenGraph says", %{} do
      pages = %{"https://news.example/story" => html(title: "A Story")}

      assert {:ok, card} =
               PreviewCards.fetch("https://news.example/story", fetch_opts(pages))

      assert card.title == "A Story"
      assert card.description == "What happened"
      assert card.type == "link"
    end

    test "records the site it came from" do
      pages = %{"https://news.example/story" => html([])}

      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))

      assert card.provider_name == "news.example"
    end

    test "a page that says nothing about itself is still a card" do
      # A bare link with a title is more use to a reader than no card at all.
      pages = %{"https://news.example/bare" => "<html><head><title>Bare</title></head></html>"}

      {:ok, card} = PreviewCards.fetch("https://news.example/bare", fetch_opts(pages))

      assert card.title == "Bare"
    end

    test "a page that cannot be read is not a card" do
      assert {:error, _reason} =
               PreviewCards.fetch("https://news.example/gone", fetch_opts(%{}))
    end

    test "is keyed on where the address ended up" do
      # Two shortened links to one story are one story, and keying on what
      # somebody typed would make a card per shortener.
      pages = %{
        "https://short.example/abc" => {301, [{"location", "https://news.example/story"}], ""},
        "https://news.example/story" => html(title: "A Story")
      }

      {:ok, card} = PreviewCards.fetch("https://short.example/abc", fetch_opts(pages))

      assert card.url == "https://news.example/story"
    end
  end

  describe "oEmbed" do
    test "is preferred over OpenGraph" do
      # The site's own description of how to embed it beats what we can guess
      # from its markup.
      pages = %{
        "https://video.example/watch" =>
          html(
            title: "Guessed",
            extra:
              ~s|<link rel="alternate" type="application/json+oembed" href="https://video.example/oembed?url=watch">|
          ),
        "https://video.example/oembed?url=watch" =>
          {200, [{"content-type", "application/json"}],
           ~s|{"type":"video","title":"From oEmbed","provider_name":"Video","html":"<iframe src=\\"https://video.example/embed\\"></iframe>","width":640,"height":360}|}
      }

      {:ok, card} = PreviewCards.fetch("https://video.example/watch", fetch_opts(pages))

      assert card.title == "From oEmbed"
      assert card.type == "video"
      assert card.width == 640
    end

    test "a rich embed is refused" do
      # `rich` means arbitrary HTML with no shape anybody can check, which is
      # somebody else's markup running in our readers' pages.
      pages = %{
        "https://widget.example/thing" =>
          html(
            title: "Fallback",
            extra:
              ~s|<link rel="alternate" type="application/json+oembed" href="https://widget.example/oembed">|
          ),
        "https://widget.example/oembed" =>
          {200, [{"content-type", "application/json"}],
           ~s|{"type":"rich","title":"Rich","html":"<script>alert(1)</script>"}|}
      }

      {:ok, card} = PreviewCards.fetch("https://widget.example/thing", fetch_opts(pages))

      assert card.title == "Fallback"
      assert card.type == "link"
      assert card.html == ""
    end

    test "the embed HTML is sanitised" do
      pages = %{
        "https://video.example/watch" =>
          html(
            extra:
              ~s|<link rel="alternate" type="application/json+oembed" href="https://video.example/oembed">|
          ),
        "https://video.example/oembed" =>
          {200, [{"content-type", "application/json"}],
           ~s|{"type":"video","html":"<iframe src=\\"https://video.example/embed\\"></iframe><script>alert(1)</script>","width":640,"height":360}|}
      }

      {:ok, card} = PreviewCards.fetch("https://video.example/watch", fetch_opts(pages))

      refute card.html =~ "script"
      assert card.html =~ "iframe"
    end
  end

  describe "the endpoint cache" do
    test "means a second link to the same site skips the HTML" do
      # Discovery is a property of the site, not of the article. Paying for it
      # per link is what makes unfurling slow.
      me = self()

      transport = fn _method, url, _headers, _body ->
        send(me, {:fetched, url})

        case url do
          "https://news.example/oembed" <> _rest ->
            {:ok, 200, [{"content-type", "application/json"}],
             ~s|{"type":"link","title":"From oEmbed"}|}

          _ ->
            {:ok, 200, [{"content-type", "text/html"}],
             html(
               extra:
                 ~s|<link rel="alternate" type="application/json+oembed" href="https://news.example/oembed">|
             )}
        end
      end

      {:ok, _} = PreviewCards.fetch("https://news.example/one", opts_with(transport))
      {:ok, _} = PreviewCards.fetch("https://news.example/two", opts_with(transport))

      fetched = collect_fetches()

      # The second article's HTML is never read: the endpoint was already known.
      refute "https://news.example/two" in fetched
    end

    test "a site with no oEmbed is remembered as having none" do
      # Otherwise every link to it pays for the discovery again.
      pages = %{"https://plain.example/one" => html([]), "https://plain.example/two" => html([])}

      {:ok, _} = PreviewCards.fetch("https://plain.example/one", fetch_opts(pages))

      assert PreviewCards.endpoint_known?("plain.example")
    end

    test "and is forgotten after a day" do
      pages = %{"https://plain.example/one" => html([])}

      {:ok, _} = PreviewCards.fetch("https://plain.example/one", fetch_opts(pages))

      PreviewCards.expire_endpoint("plain.example")

      refute PreviewCards.endpoint_known?("plain.example")
    end
  end

  describe "reusing what is already known" do
    test "a link somebody already shared is not fetched again" do
      pages = %{"https://news.example/story" => html(title: "A Story")}

      {:ok, first} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))

      # No transport at all: reaching the network here would raise.
      {:ok, second} = PreviewCards.fetch("https://news.example/story", opts_with(nil_transport()))

      assert second.id == first.id
    end

    test "unless it is a fortnight old" do
      # A card believed forever is a headline that changed and a title nobody
      # updated.
      pages = %{"https://news.example/story" => html(title: "A Story")}
      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))

      age(card, 20)

      fresh = %{"https://news.example/story" => html(title: "A Newer Story")}

      {:ok, refreshed} =
        PreviewCards.fetch("https://news.example/story", fetch_opts(fresh))

      assert refreshed.id == card.id
      assert refreshed.title == "A Newer Story"
    end
  end

  describe "attaching one to a post" do
    setup do
      %{account: account_fixture()}
    end

    test "is queued when a post carries a link", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "look https://news.example/story"})

      assert [job] = all_enqueued(worker: FetchWorker)
      assert job.args["status_id"] == status.id
      assert job.args["url"] == "https://news.example/story"
    end

    test "and not when it does not", %{account: account} do
      status_fixture(%{account_id: account.id, text: "no links here"})

      assert all_enqueued(worker: FetchWorker) == []
    end

    test "the card ends up on the post", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "look https://news.example/story"})
      pages = %{"https://news.example/story" => html(title: "A Story")}

      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))
      :ok = PreviewCards.attach(status, card)

      assert PreviewCards.for_status(status).title == "A Story"
    end

    test "and counts towards what is trending", %{account: account} do
      # A link nobody has attached to a post is a link nobody shared.
      {:ok, account} = Abuuba.Accounts.update_profile(account, %{"discoverable" => true})
      status = status_fixture(%{account_id: account.id, text: "look https://news.example/story"})
      pages = %{"https://news.example/story" => html(title: "A Story")}

      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))
      :ok = PreviewCards.attach(status, card)

      assert Trends.counts("link", "https://news.example/story").accounts >= 1
    end

    test "an edit that changes the link takes the old card off", %{account: account} do
      pages = %{
        "https://news.example/one" => html(title: "The First"),
        "https://news.example/two" => html(title: "The Second")
      }

      status = status_fixture(%{account_id: account.id, text: "look https://news.example/one"})
      {:ok, first} = PreviewCards.fetch("https://news.example/one", fetch_opts(pages))
      :ok = PreviewCards.attach(status, first)
      assert PreviewCards.for_status(status).title == "The First"

      {:ok, status} =
        Abuuba.Statuses.edit_status(status, %{"text" => "look https://news.example/two"})

      # The old card is off it straight away rather than when the fetch lands:
      # a headline belonging to a link that is no longer in the text is worse
      # than no headline.
      refute PreviewCards.for_status(status)

      # The create's own job is still queued, so this looks for the edit's
      # rather than for the only one.
      assert Enum.any?(
               all_enqueued(worker: FetchWorker),
               &(&1.args["url"] == "https://news.example/two")
             )
    end

    test "and an edit that removes the link takes it off and fetches nothing", %{
      account: account
    } do
      pages = %{"https://news.example/one" => html(title: "The First")}
      status = status_fixture(%{account_id: account.id, text: "look https://news.example/one"})
      {:ok, card} = PreviewCards.fetch("https://news.example/one", fetch_opts(pages))
      :ok = PreviewCards.attach(status, card)

      before = length(all_enqueued(worker: FetchWorker))
      {:ok, status} = Abuuba.Statuses.edit_status(status, %{"text" => "never mind"})

      refute PreviewCards.for_status(status)
      # Nothing new asked for: there is no link left to unfurl.
      assert length(all_enqueued(worker: FetchWorker)) == before
    end

    test "and an edit that leaves the link alone leaves the card alone", %{account: account} do
      # The positive control for the two above: they assert a card went, which
      # a version that always removed the card would satisfy too.
      pages = %{"https://news.example/one" => html(title: "The First")}
      status = status_fixture(%{account_id: account.id, text: "look https://news.example/one"})
      {:ok, card} = PreviewCards.fetch("https://news.example/one", fetch_opts(pages))
      :ok = PreviewCards.attach(status, card)

      {:ok, status} =
        Abuuba.Statuses.edit_status(status, %{"text" => "look at this https://news.example/one"})

      assert PreviewCards.for_status(status).title == "The First"
    end

    test "one card serves every post that links it", %{account: account} do
      # A news story shared by two hundred people is one card.
      pages = %{"https://news.example/story" => html(title: "A Story")}
      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))

      first = status_fixture(%{account_id: account.id, text: "https://news.example/story"})
      second = status_fixture(%{account_id: account.id, text: "https://news.example/story"})

      :ok = PreviewCards.attach(first, card)
      :ok = PreviewCards.attach(second, card)

      assert PreviewCards.for_status(first).id == PreviewCards.for_status(second).id
      assert Repo.aggregate(Abuuba.PreviewCards.Card, :count) == 1
    end
  end

  describe "who wrote it" do
    test "a fediverse:creator naming somebody real is resolved" do
      # Somebody's claim about themselves in their own markup, checked against
      # an account that actually exists -- and against that account having said
      # this site may credit them.
      author = account_fixture(%{username: "writer"})
      {:ok, _} = Accounts.update_profile(author, %{"attribution_domains" => ["news.example"]})

      pages = %{
        "https://news.example/story" =>
          html(
            extra: ~s|<meta name="fediverse:creator" content="@writer@#{URIs.local_domain()}">|
          )
      }

      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))

      assert card.author_account_id == author.id
    end

    test "but a site claiming somebody who never named it is refused" do
      # The whole point of the list. Without it any site could put a handle in
      # its markup and be credited to that person: their name and their face on
      # a page they have never heard of, in front of everybody who shares the
      # link. Existing is not consent.
      author = account_fixture(%{username: "writer"})

      pages = %{
        "https://impostor.example/story" =>
          html(
            extra: ~s|<meta name="fediverse:creator" content="@writer@#{URIs.local_domain()}">|
          )
      }

      {:ok, card} = PreviewCards.fetch("https://impostor.example/story", fetch_opts(pages))

      assert card.author_account_id == nil
      assert Repo.reload(author).id == author.id
    end

    test "a domain that is not one is refused rather than stored" do
      # `com` would match every address on the internet, and a pasted sentence
      # matches nothing while looking as though it were saved.
      author = account_fixture(%{username: "writer"})

      assert {:error, changeset} =
               Accounts.update_profile(author, %{"attribution_domains" => ["com"]})

      assert %{attribution_domains: [_message]} = errors_on(changeset)
      assert Repo.reload(author).attribution_domains == []
    end

    test "a subdomain counts when the parent domain was named" do
      # `*.example` is how the reference implementation writes it, and the
      # prefix is stripped on the way in, so the stored form covers both.
      author = account_fixture(%{username: "writer"})
      {:ok, _} = Accounts.update_profile(author, %{"attribution_domains" => ["*.news.example"]})

      pages = %{
        "https://blog.news.example/story" =>
          html(
            extra: ~s|<meta name="fediverse:creator" content="@writer@#{URIs.local_domain()}">|
          )
      }

      {:ok, card} = PreviewCards.fetch("https://blog.news.example/story", fetch_opts(pages))

      assert card.author_account_id == author.id
    end

    test "and one naming nobody is left alone" do
      pages = %{
        "https://news.example/story" =>
          html(extra: ~s|<meta name="fediverse:creator" content="@nobody@nowhere.example">|)
      }

      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))

      assert card.author_account_id == nil
    end
  end

  describe "the worker" do
    setup do
      %{account: account_fixture()}
    end

    test "attaches the card to the post", %{account: account} do
      # The card is already known here, which is the ordinary case for a
      # popular link and the one that reaches no network at all.
      status = status_fixture(%{account_id: account.id, text: "https://news.example/story"})
      pages = %{"https://news.example/story" => html(title: "A Story")}
      {:ok, _} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))

      assert :ok =
               FetchWorker.perform(%Oban.Job{
                 args: %{"status_id" => status.id, "url" => "https://news.example/story"},
                 attempt: 1,
                 max_attempts: 3
               })

      assert PreviewCards.for_status(status).title == "A Story"
    end

    test "a post deleted while queued is not an error", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "https://news.example/story"})
      id = status.id
      {:ok, _} = Abuuba.Statuses.delete_status(status)

      assert :ok =
               FetchWorker.perform(%Oban.Job{
                 args: %{"status_id" => id, "url" => "https://news.example/story"},
                 attempt: 1,
                 max_attempts: 3
               })
    end
  end

  describe "what a client is told" do
    test "the card travels with the post" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id, text: "https://news.example/story"})
      pages = %{"https://news.example/story" => html(title: "A Story")}

      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))
      :ok = PreviewCards.attach(status, card)

      entity = Entities.status(Abuuba.Repo.reload(status), nil)

      assert entity["card"]["title"] == "A Story"
      assert entity["card"]["type"] == "link"
      assert entity["card"]["url"] == "https://news.example/story"
    end

    test "the card is rendered under the post" do
      # The API carrying a card and the page not showing it is the card not
      # existing as far as a reader is concerned.
      account = account_fixture()
      status = status_fixture(%{account_id: account.id, text: "https://news.example/story"})
      pages = %{"https://news.example/story" => html(title: "A Story")}

      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))
      :ok = PreviewCards.attach(status, card)

      entity = Entities.status(Abuuba.Repo.reload(status), nil)

      rendered =
        render_component(&StatusComponent.status/1,
          status: entity,
          id: "test-card",
          interactive: false
        )

      assert rendered =~ "A Story"
      assert rendered =~ "news.example"
    end

    test "a post with no card carries none" do
      account = account_fixture()
      status = status_fixture(%{account_id: account.id, text: "no links"})

      assert Entities.status(status, nil)["card"] == nil
    end

    test "an author the server could resolve travels as an account" do
      # A handle in somebody's markup is a claim. An account is a fact -- and
      # the account having named the site is what turns the one into the other.
      author = account_fixture(%{username: "writer"})
      {:ok, _} = Accounts.update_profile(author, %{"attribution_domains" => ["news.example"]})
      account = account_fixture()
      status = status_fixture(%{account_id: account.id, text: "https://news.example/story"})

      pages = %{
        "https://news.example/story" =>
          html(
            extra: ~s|<meta name="fediverse:creator" content="@writer@#{URIs.local_domain()}">|
          )
      }

      {:ok, card} = PreviewCards.fetch("https://news.example/story", fetch_opts(pages))
      :ok = PreviewCards.attach(status, card)

      entity = Entities.status(Abuuba.Repo.reload(status), nil)

      assert [%{"account" => %{"id" => id}}] = entity["card"]["authors"]
      assert id == to_string(author.id)
    end
  end

  defp collect_fetches(acc \\ []) do
    receive do
      {:fetched, url} -> collect_fetches([url | acc])
    after
      0 -> acc
    end
  end

  defp opts_with(transport), do: [transport: transport, resolver: resolver()]

  defp nil_transport do
    fn _method, _url, _headers, _body -> raise "no fetch should happen here" end
  end

  defp age(card, days) do
    when_fetched = DateTime.add(DateTime.utc_now(), -days, :day)

    {:ok, aged} =
      card |> Ecto.Changeset.change(fetched_at: when_fetched) |> Repo.update()

    aged
  end
end
