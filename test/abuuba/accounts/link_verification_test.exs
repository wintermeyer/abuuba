defmodule Abuuba.Accounts.LinkVerificationTest do
  use Abuuba.DataCase, async: false
  use Oban.Testing, repo: Abuuba.Repo

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.LinkVerification
  alias Abuuba.Accounts.LinkVerificationWorker
  alias Abuuba.Federation.URIs
  alias Abuuba.RateLimit
  alias Abuuba.Repo

  setup do
    RateLimit.reset()
    :ok
  end

  # Nothing here touches the network. The hardened HTTP layer takes a transport
  # for the request and a resolver for the address check, and both are the
  # seams that make a fetcher with SSRF guards testable at all.
  defp opts(pages), do: [transport: responder(pages), resolver: resolver()]

  defp resolver, do: fn _host -> {:ok, [{93, 184, 216, 34}]} end

  defp responder(pages) do
    fn _method, url, _headers, _body ->
      case Map.get(pages, url) do
        {status, headers, body} -> {:ok, status, headers, body}
        body when is_binary(body) -> {:ok, 200, [{"content-type", "text/html"}], body}
        nil -> {:ok, 404, [{"content-type", "text/html"}], ""}
      end
    end
  end

  defp page(body), do: "<html><head></head><body>#{body}</body></html>"

  defp with_fields(account, fields) do
    account
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(
      :fields,
      Enum.map(fields, &struct(Abuuba.Accounts.Account.Field, &1))
    )
    |> Repo.update!()
  end

  defp verified_ats(account) do
    account |> Repo.reload!() |> Map.fetch!(:fields) |> Enum.map(& &1.verified_at)
  end

  describe "a link that points back" do
    test "is stamped verified" do
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])
      back = URIs.profile_url(account)

      pages = %{"https://me.example/" => page(~s|<a rel="me" href="#{back}">abuuba</a>|)}

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%DateTime{}] = verified_ats(account)
    end

    test "counts a rel=me in a link element in the head" do
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])
      back = URIs.profile_url(account)

      pages = %{"https://me.example/" => page(~s|<link rel="me" href="#{back}">|)}

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%DateTime{}] = verified_ats(account)
    end

    test "counts rel=me among several tokens, and matches the case-folded URL" do
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])
      back = account |> URIs.profile_url() |> String.upcase()

      pages = %{
        "https://me.example/" => page(~s|<a rel="nofollow me noopener" href="#{back}">x</a>|)
      }

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%DateTime{}] = verified_ats(account)
    end

    test "counts the actor id as well as the profile page" do
      # Some people link the ActivityPub actor rather than the human-readable
      # profile. Both name the same account, so both count.
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])

      pages = %{
        "https://me.example/" =>
          page(~s|<a rel="me" href="#{URIs.actor_uri(account)}">abuuba</a>|)
      }

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%DateTime{}] = verified_ats(account)
    end

    test "follows a rel=me that redirects to the profile" do
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])
      back = URIs.profile_url(account)

      pages = %{
        "https://me.example/" => page(~s|<a rel="me" href="https://links.example/s/1">x</a>|),
        "https://links.example/s/1" => {302, [{"location", back}], ""},
        back => page("a profile")
      }

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%DateTime{}] = verified_ats(account)
    end
  end

  describe "a link that does not point back" do
    test "is left unverified" do
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])

      pages = %{
        "https://me.example/" => page(~s|<a rel="me" href="https://elsewhere.example/">x</a>|)
      }

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert verified_ats(account) == [nil]
    end

    test "survives a page full of nonsense hrefs" do
      # Somebody else's markup, so anything at all can be in it.
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])

      pages = %{
        "https://me.example/" =>
          page("""
          <a rel="me" href="">empty</a>
          <a rel="me" href="http://[not-an-address">broken</a>
          <a rel="me" href="javascript:alert(1)">nope</a>
          <link rel="me">
          """)
      }

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert verified_ats(account) == [nil]
    end

    test "loses a stamp it used to have" do
      account = account_fixture()

      account =
        with_fields(account, [
          %{name: "Website", value: "https://me.example/", verified_at: DateTime.utc_now()}
        ])

      pages = %{"https://me.example/" => page("nothing here")}

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert verified_ats(account) == [nil]
    end

    test "does not keep asking a host that is down for good" do
      # The stamp survives an outage, but the clock still moves: otherwise
      # every sweep, forever, queues another fetch at a host that never answers.
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://gone.example/"}])

      pages = %{"https://gone.example/" => {500, [], ""}}

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%{checked_at: %DateTime{}}] = Repo.reload!(account).fields
      assert LinkVerification.due() == []
    end

    test "keeps its stamp when the site is merely unreachable" do
      # A site being down for an afternoon is not evidence that somebody has
      # taken their link back down. Only an answer we could read counts.
      stamped = DateTime.utc_now()
      account = account_fixture()

      account =
        with_fields(account, [
          %{name: "Website", value: "https://me.example/", verified_at: stamped}
        ])

      pages = %{"https://me.example/" => {500, [], ""}}

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%DateTime{}] = verified_ats(account)
    end
  end

  describe "what is worth fetching at all" do
    test "http, credentials in the URL, and a non-ASCII host are never fetched" do
      for value <- [
            "http://me.example/",
            "https://user:pw@me.example/",
            "https://mé.example/",
            "not a url at all",
            "https:///nohost"
          ] do
        account = account_fixture()
        account = with_fields(account, [%{name: "Website", value: value}])

        # A transport that refuses to be called: the assertion is that no
        # request is made at all, not merely that none of them succeeded.
        never = fn _method, url, _headers, _body -> flunk("fetched #{url}") end

        assert {:ok, _account} =
                 LinkVerification.verify(account, transport: never, resolver: resolver())

        assert verified_ats(account) == [nil], "verified #{value}"
      end
    end

    test "a value that stops being verifiable loses its stamp" do
      account = account_fixture()

      account =
        with_fields(account, [
          %{name: "Website", value: "http://me.example/", verified_at: DateTime.utc_now()}
        ])

      assert {:ok, _account} = LinkVerification.verify(account, opts(%{}))
      assert verified_ats(account) == [nil]
    end

    test "a link looked at this morning is not fetched again" do
      # The save is the trigger, but the clock is the budget: somebody who
      # edits their display name twice must not send two rounds of requests at
      # every site they link to.
      account = account_fixture()

      account =
        with_fields(account, [
          %{name: "Website", value: "https://me.example/", checked_at: DateTime.utc_now()}
        ])

      never = fn _method, url, _headers, _body -> flunk("fetched #{url}") end

      assert {:ok, _account} =
               LinkVerification.verify(account, transport: never, resolver: resolver())
    end

    test "a link last looked at long ago is fetched again" do
      account = account_fixture()
      long_ago = DateTime.add(DateTime.utc_now(), -365, :day)

      account =
        with_fields(account, [
          %{name: "Website", value: "https://me.example/", checked_at: long_ago}
        ])

      pages = %{
        "https://me.example/" => page(~s|<a rel="me" href="#{URIs.profile_url(account)}">x</a>|)
      }

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%DateTime{}] = verified_ats(account)
    end

    test "a remote account is never verified by us" do
      # Another server's verification is that server's to assert; fetching on
      # their behalf would let any remote actor point us at any URL.
      stamped = DateTime.utc_now()
      account = remote_account_fixture()

      account =
        with_fields(account, [
          %{name: "Website", value: "https://me.example/", verified_at: stamped}
        ])

      pages = %{"https://me.example/" => page("nothing here")}

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%DateTime{}] = verified_ats(account)
    end
  end

  describe "a page whose rel=me is a redirect" do
    test "skips a mailto and takes the first link it could actually follow" do
      # `<a rel="me" href="mailto:...">` is an ordinary thing to have on a
      # personal page, and spending the one hop on it would fail the shortlink
      # underneath it.
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])
      back = URIs.profile_url(account)

      pages = %{
        "https://me.example/" =>
          page("""
          <a rel="me" href="mailto:me@me.example">mail</a>
          <a rel="me" href="https://links.example/s/1">me</a>
          """),
        "https://links.example/s/1" => {302, [{"location", back}], ""}
      }

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert [%DateTime{}] = verified_ats(account)
    end

    test "charges the hop to the host in the markup, not to the one on the profile" do
      # Otherwise a page under somebody's control names any third party it
      # likes and this server becomes an unmetered HEAD reflector at it.
      RateLimit.reset()

      for _ <- 1..LinkVerification.per_host_limit() do
        RateLimit.hit("rel_me:links.example",
          limit: LinkVerification.per_host_limit(),
          window_ms: 60_000
        )
      end

      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])

      pages = %{
        "https://me.example/" => page(~s|<a rel="me" href="https://links.example/s/1">me</a>|),
        "https://links.example/s/1" => {302, [{"location", URIs.profile_url(account)}], ""}
      }

      assert {:ok, _account} = LinkVerification.verify(account, opts(pages))
      assert verified_ats(account) == [nil]
    end
  end

  describe "one host at a time" do
    test "defers the fields it is not allowed to fetch yet" do
      back = fn account -> URIs.profile_url(account) end

      accounts =
        for _ <- 1..(LinkVerification.per_host_limit() + 1) do
          account_fixture() |> with_fields([%{name: "Website", value: "https://me.example/"}])
        end

      results =
        Enum.map(accounts, fn account ->
          pages = %{"https://me.example/" => page(~s|<a rel="me" href="#{back.(account)}">x</a>|)}

          LinkVerification.verify(account, opts(pages))
        end)

      assert {:defer, _} = List.last(results)
      assert verified_ats(List.last(accounts)) == [nil]
      # The positive control: the ones inside the budget did get verified, so
      # the deferral above is the limit working rather than the fetch failing.
      assert [%DateTime{}] = verified_ats(List.first(accounts))
    end
  end

  describe "the worker" do
    test "checks the account it names" do
      # A plain-HTTP link is decided without a fetch, which is what lets this
      # exercise the whole worker without a network of any kind.
      account = account_fixture()

      account =
        with_fields(account, [
          %{name: "Website", value: "http://me.example/", verified_at: DateTime.utc_now()}
        ])

      assert :ok = perform_job(LinkVerificationWorker, %{"account_id" => account.id})
      assert verified_ats(account) == [nil]
    end

    test "shrugs off an account deleted while the job was queued" do
      assert :ok = perform_job(LinkVerificationWorker, %{"account_id" => -999_999})
    end

    test "snoozes rather than losing the work when a host is busy" do
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "https://me.example/"}])

      for _ <- 1..LinkVerification.per_host_limit() do
        RateLimit.hit("rel_me:me.example",
          limit: LinkVerification.per_host_limit(),
          window_ms: 60_000
        )
      end

      assert {:snooze, _seconds} =
               perform_job(LinkVerificationWorker, %{"account_id" => account.id})
    end

    test "the sweep enqueues the accounts whose links are due a re-check" do
      due = account_fixture() |> with_fields([%{name: "Website", value: "https://me.example/"}])
      no_fields = account_fixture()

      recent =
        account_fixture()
        |> with_fields([
          %{name: "Website", value: "https://fresh.example/", checked_at: DateTime.utc_now()}
        ])

      assert :ok = perform_job(LinkVerificationWorker, %{})

      assert_enqueued(worker: LinkVerificationWorker, args: %{account_id: due.id})
      refute_enqueued(worker: LinkVerificationWorker, args: %{account_id: no_fields.id})
      refute_enqueued(worker: LinkVerificationWorker, args: %{account_id: recent.id})
    end

    test "the sweep leaves a suspended account alone" do
      # Nobody reads their profile, so nobody is owed a badge on it, and their
      # links are not worth a request to somebody else's server.
      account =
        account_fixture() |> with_fields([%{name: "Website", value: "https://me.example/"}])

      {:ok, account} = Accounts.update_moderation(account, %{suspended_at: DateTime.utc_now()})

      assert :ok = perform_job(LinkVerificationWorker, %{})
      refute_enqueued(worker: LinkVerificationWorker, args: %{account_id: account.id})
    end

    test "asks to be run again when a link appeared while it was working" do
      # The unique key collapses an edit made mid-check into the job already
      # running, which started from the old fields. Noticing here is what keeps
      # the new link from waiting for the weekly sweep.
      account = account_fixture()
      account = with_fields(account, [%{name: "Website", value: "http://plain.example/"}])

      # The snapshot the run works from is the one taken before the edit.
      snapshot = account

      {:ok, _} =
        Accounts.update_profile(account, %{
          "fields" => [%{"name" => "Blog", "value" => "http://also-plain.example/"}]
        })

      assert {:defer, _account} = LinkVerification.verify(snapshot, opts(%{}))

      # And the edit survived: writing the snapshot back would have undone it.
      assert [%{value: "http://also-plain.example/"}] = Repo.reload!(account).fields
    end

    test "is queued when somebody edits their profile" do
      account = account_fixture()

      {:ok, _account} =
        Accounts.update_profile(account, %{
          "fields" => [%{"name" => "Website", "value" => "https://me.example/"}]
        })

      assert_enqueued(worker: LinkVerificationWorker, args: %{account_id: account.id})
    end
  end

  describe "editing a profile" do
    test "keeps the stamp on a field whose value did not change" do
      # Re-saving a display name must not cost somebody the tick beside a link
      # that is still there. Mastodon carries it over the same way.
      account = account_fixture()

      account =
        with_fields(account, [
          %{name: "Website", value: "https://me.example/", verified_at: DateTime.utc_now()}
        ])

      {:ok, updated} =
        Accounts.update_profile(account, %{
          "display_name" => "Renamed",
          "fields" => [%{"name" => "Homepage", "value" => "https://me.example/"}]
        })

      assert [%{name: "Homepage", verified_at: %DateTime{}}] = updated.fields
    end

    test "keeps the clock too, so an unchanged link is not refetched on every save" do
      checked = DateTime.utc_now()
      account = account_fixture()

      account =
        with_fields(account, [
          %{name: "Website", value: "https://me.example/", checked_at: checked}
        ])

      {:ok, updated} =
        Accounts.update_profile(account, %{
          "display_name" => "Renamed",
          "fields" => [%{"name" => "Website", "value" => "https://me.example/"}]
        })

      assert [%{checked_at: %DateTime{}}] = updated.fields
    end

    test "drops the stamp when the value itself changes" do
      account = account_fixture()

      account =
        with_fields(account, [
          %{name: "Website", value: "https://me.example/", verified_at: DateTime.utc_now()}
        ])

      {:ok, updated} =
        Accounts.update_profile(account, %{
          "fields" => [%{"name" => "Website", "value" => "https://other.example/"}]
        })

      assert [%{verified_at: nil}] = updated.fields
    end

    test "an account cannot award itself a tick" do
      account = account_fixture()

      {:ok, updated} =
        Accounts.update_profile(account, %{
          "fields" => [
            %{
              "name" => "Website",
              "value" => "https://me.example/",
              "verified_at" => DateTime.utc_now()
            }
          ]
        })

      assert [%{verified_at: nil}] = updated.fields
    end
  end
end
