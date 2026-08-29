defmodule AbuubaWeb.API.TrendsControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts
  alias Abuuba.PreviewCards.Card
  alias Abuuba.Repo
  alias Abuuba.Statuses
  alias Abuuba.Trends

  setup do
    author = account_fixture()
    {:ok, author} = Accounts.update_profile(author, %{"discoverable" => true})

    %{author: author, moderator: account_fixture()}
  end

  test "the tags list is what was approved and ranked", %{conn: conn, moderator: mod} do
    {:ok, tag} = Statuses.upsert_tag("caturday")
    :ok = Trends.approve(mod, "tag", tag.name)
    Trends.put_counts("tag", "caturday", Date.utc_today(), accounts: 30)
    :ok = Trends.rank()

    assert [entry] = json_response(get(conn, "/api/v1/trends/tags"), 200)
    assert entry["name"] == "caturday"
  end

  test "and is empty while nobody has reviewed anything", %{conn: conn} do
    # The default answer for an unreviewed trend is no, so a fresh server shows
    # nothing rather than whatever was posted most in the last hour.
    {:ok, _} = Statuses.upsert_tag("unseen")
    Trends.put_counts("tag", "unseen", Date.utc_today(), accounts: 30)
    :ok = Trends.rank()

    assert json_response(get(conn, "/api/v1/trends/tags"), 200) == []
  end

  test "the statuses list carries whole posts", %{conn: conn, author: author, moderator: mod} do
    status = status_fixture(%{account_id: author.id, text: "something people liked"})
    :ok = Trends.approve_author(mod, author)
    Trends.put_counts("status", to_string(status.id), Date.utc_today(), accounts: 30)
    :ok = Trends.rank()

    assert [entry] = json_response(get(conn, "/api/v1/trends/statuses"), 200)
    assert entry["id"] == to_string(status.id)
    assert entry["content"] =~ "people liked"
  end

  test "a deleted post drops out of it", %{conn: conn, author: author, moderator: mod} do
    # The ranking is written every five minutes and a post can go in between.
    status = status_fixture(%{account_id: author.id})
    :ok = Trends.approve_author(mod, author)
    Trends.put_counts("status", to_string(status.id), Date.utc_today(), accounts: 30)
    :ok = Trends.rank()
    {:ok, _} = Statuses.delete_status(status)

    assert json_response(get(conn, "/api/v1/trends/statuses"), 200) == []
  end

  test "a trending link carries its card once one exists", %{conn: conn, moderator: mod} do
    # A link trends because posts carried it, and attaching a card is what put
    # it in the count, so the title is nearly always there to be shown.
    url = "https://news.example/a-story"

    {:ok, _card} =
      %Card{}
      |> Card.changeset(%{
        url: url,
        title: "A Story",
        type: "link",
        provider_name: "news.example",
        fetched_at: DateTime.utc_now()
      })
      |> Repo.insert()

    Trends.put_counts("link", url, Date.utc_today(), accounts: 30)
    :ok = Trends.approve(mod, "link", url)
    :ok = Trends.rank()

    assert [entry] = json_response(get(conn, "/api/v1/trends/links"), 200)
    assert entry["title"] == "A Story"
    assert [%{"accounts" => "30"}] = entry["history"]
  end

  test "the links list is in the shape a client renders", %{conn: conn, moderator: mod} do
    url = "https://news.example/a-story"
    Trends.put_counts("link", url, Date.utc_today(), accounts: 30)
    :ok = Trends.approve(mod, "link", url)

    :ok = Trends.rank()

    assert [entry] = json_response(get(conn, "/api/v1/trends/links"), 200)
    assert entry["url"] == url
    assert entry["provider_name"] == "news.example"
    assert [%{"accounts" => "30"}] = entry["history"]
  end

  test "asking for one language leaves the others out", %{conn: conn, moderator: mod} do
    {:ok, tag} = Statuses.upsert_tag("hallo")
    :ok = Trends.approve(mod, "tag", tag.name)
    Trends.put_counts("tag", "hallo", Date.utc_today(), accounts: 30, language: "de")
    :ok = Trends.rank()

    assert [_] = json_response(get(conn, "/api/v1/trends/tags", %{"language" => "de"}), 200)
    assert json_response(get(conn, "/api/v1/trends/tags", %{"language" => "fr"}), 200) == []
  end
end
