defmodule AbuubaWeb.API.TranslationAPITest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.OAuth
  alias Abuuba.Translation
  alias Abuuba.Translation.Fake

  setup %{conn: conn} do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    on_exit(fn -> Application.delete_env(:abuuba, :translation_provider) end)

    %{conn: put_req_header(conn, "authorization", "Bearer " <> raw), account: account}
  end

  defp with_provider(fun) do
    Application.put_env(:abuuba, :translation_provider, Fake)

    Fake.set(fn texts, _source, target, _opts ->
      {:ok, Enum.map(texts, &("[#{target}] " <> &1))}
    end)

    fun.()
  end

  test "translating a post answers with the translation", %{conn: conn, account: account} do
    status = status_fixture(%{account_id: account.id, text: "hello there", language: "en"})

    with_provider(fn ->
      body =
        json_response(
          post(conn, "/api/v1/statuses/#{status.id}/translate", %{"lang" => "de"}),
          200
        )

      assert body["content"] =~ "[de]"
      assert body["detected_source_language"] == "en"
      assert body["provider"] == "Fake"
    end)
  end

  test "a server with no provider says so rather than failing oddly", %{
    conn: conn,
    account: account
  } do
    status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})

    conn = post(conn, "/api/v1/statuses/#{status.id}/translate", %{"lang" => "de"})

    assert json_response(conn, 501)["error"] =~ "not enabled"
  end

  test "a post nobody outside its audience may read is refused", %{conn: conn, account: account} do
    status =
      status_fixture(%{
        account_id: account.id,
        text: "quiet",
        language: "en",
        visibility: :private
      })

    with_provider(fn ->
      conn = post(conn, "/api/v1/statuses/#{status.id}/translate", %{"lang" => "de"})

      assert json_response(conn, 422)["error"] =~ "cannot be translated"
    end)
  end

  test "a quota that has run out says which problem it is", %{conn: conn, account: account} do
    # "Something went wrong" is the one answer an admin cannot act on.
    status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})

    Application.put_env(:abuuba, :translation_provider, Fake)
    Fake.set(fn _texts, _source, _target, _opts -> {:error, :quota_exceeded} end)

    conn = post(conn, "/api/v1/statuses/#{status.id}/translate", %{"lang" => "de"})

    assert json_response(conn, 503)["error"] =~ "quota"
  end

  test "the instance document says whether translation is on", %{conn: conn} do
    assert json_response(get(conn, "/api/v2/instance"), 200)["configuration"]["translation"][
             "enabled"
           ] == false

    with_provider(fn ->
      assert json_response(get(conn, "/api/v2/instance"), 200)["configuration"]["translation"][
               "enabled"
             ] == true
    end)
  end

  test "and which languages it can manage", %{conn: conn} do
    Application.put_env(:abuuba, :translation_provider, Fake)
    Fake.set_languages(fn _opts -> {:ok, %{"en" => ["de"]}} end)
    Translation.expire_all()

    assert json_response(get(conn, "/api/v1/instance/translation_languages"), 200) == %{
             "en" => ["de"]
           }
  end
end
