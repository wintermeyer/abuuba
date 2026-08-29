defmodule AbuubaWeb.API.QuotesTest do
  @moduledoc """
  Quoting, and the consent that decides whether a quote is presented as one.

  abuuba could already read a quote another server sent and check the approval
  riding on it. It could not make one, list one, revoke one, or tell anybody
  who was allowed to quote what.
  """

  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Federation.Quotes
  alias Abuuba.Federation.Serializer
  alias Abuuba.OAuth
  alias Abuuba.Statuses

  setup do
    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    author = account_fixture(%{username: "author"})
    quoter = account_fixture(%{username: "quoter"})
    quoted = status_fixture(%{account_id: author.id, text: "the original"})

    %{
      author: author,
      quoter: quoter,
      quoted: quoted,
      tokens: %{
        author.id => token_for(application, author),
        quoter.id => token_for(application, quoter)
      }
    }
  end

  defp token_for(application, account) do
    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    raw
  end

  # A fresh conn each time, carrying that account's token. Reusing one conn
  # across two requests in the same test would carry the first response's state
  # into the second.
  defp as(%{tokens: tokens}, account) do
    put_req_header(build_conn(), "authorization", "Bearer " <> Map.fetch!(tokens, account.id))
  end

  describe "making a quote" do
    test "one post can quote another", %{quoter: quoter, quoted: quoted} = ctx do
      body =
        ctx
        |> as(quoter)
        |> post(~p"/api/v1/statuses", %{"text" => "look at this", "quote_id" => "#{quoted.id}"})
        |> json_response(200)

      assert body["quote"]["state"] == "accepted"
      assert body["quote"]["quoted_status"]["id"] == "#{quoted.id}"
    end

    test "and the quoted post counts it", %{quoter: quoter, quoted: quoted} = ctx do
      ctx
      |> as(quoter)
      |> post(~p"/api/v1/statuses", %{"text" => "look", "quote_id" => "#{quoted.id}"})
      |> json_response(200)

      body = ctx |> as(quoter) |> get(~p"/api/v1/statuses/#{quoted.id}") |> json_response(200)

      assert body["quotes_count"] == 1
    end

    test "quoting a post that does not exist is a 404", %{quoter: quoter} = ctx do
      assert ctx
             |> as(quoter)
             |> post(~p"/api/v1/statuses", %{"text" => "x", "quote_id" => "999999999"})
             |> json_response(404)
    end
  end

  describe "who may quote" do
    test "nobody, when the author says so",
         %{author: author, quoter: quoter, quoted: quoted} = ctx do
      {:ok, _updated} = Statuses.set_quote_policy(quoted, :nobody)

      # Refused rather than quietly posted without the quote: a post that came
      # out as an ordinary one would look to the writer as though it worked.
      assert ctx
             |> as(quoter)
             |> post(~p"/api/v1/statuses", %{"text" => "x", "quote_id" => "#{quoted.id}"})
             |> json_response(422)

      # The positive control: the author may always quote their own.
      assert ctx
             |> as(author)
             |> post(~p"/api/v1/statuses", %{"text" => "x", "quote_id" => "#{quoted.id}"})
             |> json_response(200)
    end

    test "followers only, when the author says that",
         %{author: author, quoter: quoter, quoted: quoted} = ctx do
      {:ok, _updated} = Statuses.set_quote_policy(quoted, :followers)

      assert ctx
             |> as(quoter)
             |> post(~p"/api/v1/statuses", %{"text" => "x", "quote_id" => "#{quoted.id}"})
             |> json_response(422)

      {:ok, _follow} = Abuuba.Relationships.follow(quoter, author)

      assert ctx
             |> as(quoter)
             |> post(~p"/api/v1/statuses", %{"text" => "x", "quote_id" => "#{quoted.id}"})
             |> json_response(200)
    end

    test "is published on the post, so a client can grey out the button",
         %{quoter: quoter, quoted: quoted} = ctx do
      {:ok, _updated} = Statuses.set_quote_policy(quoted, :nobody)

      body = ctx |> as(quoter) |> get(~p"/api/v1/statuses/#{quoted.id}") |> json_response(200)

      assert body["quote_approval"]["automatic"] == []
    end
  end

  describe "the interaction policy endpoint" do
    test "sets who may quote", %{author: author, quoted: quoted} = ctx do
      body =
        ctx
        |> as(author)
        |> put(~p"/api/v1/statuses/#{quoted.id}/interaction_policy", %{
          "quotes" => %{"automatic_approval" => "nobody"}
        })
        |> json_response(200)

      assert body["quote_approval"]["automatic"] == []
    end

    test "is nobody else's to set", %{quoter: quoter, quoted: quoted} = ctx do
      assert ctx
             |> as(quoter)
             |> put(~p"/api/v1/statuses/#{quoted.id}/interaction_policy", %{
               "quote_policy" => "nobody"
             })
             |> json_response(403)
    end
  end

  describe "listing and revoking" do
    setup %{quoter: quoter, quoted: quoted} = ctx do
      body =
        ctx
        |> as(quoter)
        |> post(~p"/api/v1/statuses", %{"text" => "look", "quote_id" => "#{quoted.id}"})
        |> json_response(200)

      %{quoting_id: body["id"]}
    end

    test "the quoted author can see what quotes them",
         %{author: author, quoted: quoted, quoting_id: quoting_id} = ctx do
      body =
        ctx |> as(author) |> get(~p"/api/v1/statuses/#{quoted.id}/quotes") |> json_response(200)

      assert [%{"id" => ^quoting_id}] = body
    end

    test "and can withdraw their approval",
         %{author: author, quoted: quoted, quoting_id: quoting_id} = ctx do
      ctx
      |> as(author)
      |> post(~p"/api/v1/statuses/#{quoted.id}/quotes/#{quoting_id}/revoke")
      |> json_response(200)

      # The post still exists; it simply stops being presented as agreed to.
      assert ctx
             |> as(author)
             |> get(~p"/api/v1/statuses/#{quoted.id}/quotes")
             |> json_response(200) == []

      body = ctx |> as(author) |> get(~p"/api/v1/statuses/#{quoting_id}") |> json_response(200)

      assert body["quote"] == nil
      assert body["id"] == quoting_id
    end

    test "the count comes back down with it",
         %{author: author, quoted: quoted, quoting_id: quoting_id} = ctx do
      ctx
      |> as(author)
      |> post(~p"/api/v1/statuses/#{quoted.id}/quotes/#{quoting_id}/revoke")
      |> json_response(200)

      body = ctx |> as(author) |> get(~p"/api/v1/statuses/#{quoted.id}") |> json_response(200)

      assert body["quotes_count"] == 0
    end

    test "nobody else may revoke it",
         %{quoter: quoter, quoted: quoted, quoting_id: quoting_id} = ctx do
      assert ctx
             |> as(quoter)
             |> post(~p"/api/v1/statuses/#{quoted.id}/quotes/#{quoting_id}/revoke")
             |> json_response(403)
    end

    test "and not for a post that does not quote this one",
         %{author: author, quoted: quoted} = ctx do
      unrelated = status_fixture(%{account_id: author.id})

      assert ctx
             |> as(author)
             |> post(~p"/api/v1/statuses/#{quoted.id}/quotes/#{unrelated.id}/revoke")
             |> json_response(404)
    end
  end

  describe "what the network sees" do
    setup %{quoter: quoter, quoted: quoted} do
      {:ok, quoting} = Statuses.create_status(%{account_id: quoter.id, text: "look"})
      :ok = Quotes.record_local(quoting, quoted)

      %{quoting: quoting}
    end

    test "the Note carries the quote in every spelling servers read", %{
      conn: conn,
      quoting: quoting,
      quoted: quoted
    } do
      body =
        conn
        |> get(~p"/users/quoter/statuses/#{quoting.id}")
        |> json_response(200)

      uri = Serializer.status_uri(quoted)

      assert body["quote"] == uri
      assert body["quoteUri"] == uri
      assert body["_misskey_quote"] == uri
      assert body["quoteAuthorization"] =~ "/quote_authorizations/#{quoting.id}"
    end

    test "and the authorization is served where it says it is", %{
      conn: conn,
      quoting: quoting,
      quoted: quoted
    } do
      path =
        URI.parse(Serializer.status_uri(quoted)).path <> "/quote_authorizations/#{quoting.id}"

      body = conn |> get(path) |> json_response(200)

      assert body["type"] == "QuoteAuthorization"
      assert body["interactingObject"] == Serializer.status_uri(quoting)
      assert body["interactionTarget"] == Serializer.status_uri(quoted)
    end

    test "an authorization is not issued for a quote that was never made", %{
      conn: conn,
      quoted: quoted,
      author: author
    } do
      unrelated = status_fixture(%{account_id: author.id})

      path =
        URI.parse(Serializer.status_uri(quoted)).path <> "/quote_authorizations/#{unrelated.id}"

      assert conn |> get(path) |> json_response(404)
    end

    test "a revoked quote leaves the Note", %{conn: conn, quoting: quoting} do
      :ok = Quotes.revoke(quoting.id)

      body = conn |> get(~p"/users/quoter/statuses/#{quoting.id}") |> json_response(200)

      refute Map.has_key?(body, "quote")
    end
  end

  describe "being quoted" do
    test "tells the person whose post it is", %{} do
      # The type existed, the notifications screen knew how to draw it, and
      # the filtering policy had an axis for it. Nothing ever wrote the row,
      # so quoting somebody was silent -- everything about it looked finished
      # from the outside.
      author = account_fixture()
      quoter = account_fixture()

      quoted = status_fixture(%{account_id: author.id, text: "the original"})
      quoting = status_fixture(%{account_id: quoter.id, text: "look at this"})

      :ok = Quotes.record_local(quoting, quoted)

      assert [notification] = Abuuba.Notifications.list(author, %{})
      assert notification.type == "quote"
      assert notification.from_account_id == quoter.id
      assert notification.status_id == quoting.id
    end

    test "and quoting yourself tells nobody", %{} do
      author = account_fixture()

      quoted = status_fixture(%{account_id: author.id})
      quoting = status_fixture(%{account_id: author.id})

      :ok = Quotes.record_local(quoting, quoted)

      assert Abuuba.Notifications.list(author, %{}) == []
    end

    test "and a quote recorded twice tells them once", %{} do
      author = account_fixture()
      quoter = account_fixture()

      quoted = status_fixture(%{account_id: author.id})
      quoting = status_fixture(%{account_id: quoter.id})

      :ok = Quotes.record_local(quoting, quoted)
      :ok = Quotes.record_local(quoting, quoted)

      assert length(Abuuba.Notifications.list(author, %{})) == 1
    end
  end
end
