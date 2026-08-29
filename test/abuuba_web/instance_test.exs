defmodule AbuubaWeb.InstanceTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Admin
  alias Abuuba.Federation.URIs
  alias Abuuba.Instance
  alias Abuuba.Media.Attachment
  alias Abuuba.Roles
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll

  setup do
    Settings.put_registration_mode(:open)
    :ok
  end

  describe "NodeInfo discovery" do
    test "points at the real document", %{conn: conn} do
      body = conn |> get(~p"/.well-known/nodeinfo") |> json_response(200)

      assert [link] = body["links"]
      assert link["rel"] == "http://nodeinfo.diaspora.software/ns/schema/2.0"
      assert link["href"] == "#{URIs.base_url()}/nodeinfo/2.0"
    end
  end

  describe "GET /nodeinfo/2.0" do
    test "says what it actually is", %{conn: conn} do
      # Claiming to be Mastodon would send abuuba's bug reports to Mastodon's
      # tracker and make abuuba invisible in fediverse statistics.
      body = conn |> get(~p"/nodeinfo/2.0") |> json_response(200)

      assert body["software"]["name"] == "abuuba"
      assert body["software"]["version"] == Instance.version()
      assert body["protocols"] == ["activitypub"]
      assert body["version"] == "2.0"
    end

    test "reports whether anybody can sign up", %{conn: conn} do
      assert conn |> get(~p"/nodeinfo/2.0") |> json_response(200) |> Map.get("openRegistrations")

      Settings.put_registration_mode(:approved)

      refute build_conn()
             |> get(~p"/nodeinfo/2.0")
             |> json_response(200)
             |> Map.get("openRegistrations"),
             "a server that queues registrations is not open"

      Settings.put_registration_mode(:closed)

      refute build_conn()
             |> get(~p"/nodeinfo/2.0")
             |> json_response(200)
             |> Map.get("openRegistrations")
    end

    test "counts local users and posts", %{conn: conn} do
      account = account_fixture()
      user_fixture(%{account_id: account.id})
      status_fixture(%{account_id: account.id})
      status_fixture(%{account_id: account.id, local: false, uri: "https://r.example/s/1"})

      body = conn |> get(~p"/nodeinfo/2.0") |> json_response(200)

      assert body["usage"]["users"]["total"] == 1
      assert body["usage"]["localPosts"] == 1, "a remote post is not a local post"
    end

    test "counts somebody who posted this month as active", %{conn: conn} do
      account = account_fixture()
      user_fixture(%{account_id: account.id})
      status_fixture(%{account_id: account.id})

      body = conn |> get(~p"/nodeinfo/2.0") |> json_response(200)

      assert body["usage"]["users"]["activeMonth"] == 1
    end

    test "is cached, because crawlers ask often and the answer barely moves", %{conn: conn} do
      conn = get(conn, ~p"/nodeinfo/2.0")

      assert conn |> get_resp_header("cache-control") |> hd() =~ "max-age=3600"
    end
  end

  describe "GET /api/v2/instance" do
    test "tells a client the limits to enforce in its own compose box", %{conn: conn} do
      # So somebody finds out their post is too long while writing it, rather
      # than when they press send.
      body = conn |> get(~p"/api/v2/instance") |> json_response(200)

      assert body["configuration"]["statuses"]["max_characters"] == 500
      assert body["configuration"]["statuses"]["max_media_attachments"] == 4
      assert body["configuration"]["statuses"]["characters_reserved_per_url"] == 23
      assert body["configuration"]["media_attachments"]["supported_mime_types"] != []
      assert body["configuration"]["polls"]["max_options"] == 4
      assert Map.has_key?(body["configuration"], "translation")
      assert Map.has_key?(body["configuration"], "vapid")
    end

    test "and the limits it enforces rather than numbers written twice", %{conn: conn} do
      body = conn |> get(~p"/api/v2/instance") |> json_response(200)

      assert body["configuration"]["polls"]["max_options"] == Poll.max_options()
      assert body["configuration"]["accounts"]["max_pinned_statuses"] == Statuses.max_pins()

      assert body["configuration"]["media_attachments"]["description_limit"] ==
               Attachment.max_description()
    end

    test "and the status page, when a server runs one", %{conn: conn} do
      # Somewhere an operator says what is broken and when it will be back.
      # Clients link to it from their server-information screen, and there was
      # no way to give them one.
      assert conn
             |> get(~p"/api/v2/instance")
             |> json_response(200)
             |> get_in(["configuration", "urls", "status"]) == nil

      :ok =
        Admin.put_settings(account_fixture(), %{
          "site_status_page_url" => "https://status.example.com"
        })

      assert conn
             |> get(~p"/api/v2/instance")
             |> json_response(200)
             |> get_in(["configuration", "urls", "status"]) == "https://status.example.com"
    end

    test "and refuses one that is not an address", %{conn: conn} do
      # Stored as typed and handed to every client, so a value that is not a
      # URL is a broken link on somebody else's screen rather than ours.
      :ok = Admin.put_settings(account_fixture(), %{"site_status_page_url" => "not a url"})

      assert conn
             |> get(~p"/api/v2/instance")
             |> json_response(200)
             |> get_in(["configuration", "urls", "status"]) == nil
    end

    test "and where to read the pages a client links to", %{conn: conn} do
      body = conn |> get(~p"/api/v2/instance") |> json_response(200)

      assert body["configuration"]["urls"]["about"] =~ "/about"
      assert body["configuration"]["urls"]["privacy_policy"] =~ "/privacy"

      # Null rather than a link to a page that says nothing: there are no terms
      # until somebody writes them.
      assert Map.has_key?(body["configuration"]["urls"], "terms_of_service")
    end

    test "names the domain and the API level apps feature-detect on", %{conn: conn} do
      body = conn |> get(~p"/api/v2/instance") |> json_response(200)

      assert body["domain"] == URIs.local_domain()
      assert body["api_versions"]["mastodon"]
      assert body["version"] =~ "abuuba"
    end

    test "reports registration state in both halves", %{conn: conn} do
      Settings.put_registration_mode(:approved)

      body = conn |> get(~p"/api/v2/instance") |> json_response(200)

      assert body["registrations"]["enabled"]

      assert body["registrations"]["approval_required"],
             "open and approval-required are different answers and a client shows different copy"
    end

    test "lists the server rules people agreed to", %{conn: conn} do
      {:ok, _} = Settings.create_rule(%{text: "Be kind", hint: "Really"})

      body = conn |> get(~p"/api/v2/instance") |> json_response(200)

      assert [%{"text" => "Be kind", "hint" => "Really", "id" => "1"}] = body["rules"]
    end

    test "lists the languages it can answer in", %{conn: conn} do
      body = conn |> get(~p"/api/v2/instance") |> json_response(200)

      assert "en" in body["languages"]
      assert "de" in body["languages"]
    end
  end

  describe "GET /api/v1/instance" do
    test "is still served, because installed clients still ask for it", %{conn: conn} do
      body = conn |> get(~p"/api/v1/instance") |> json_response(200)

      assert body["uri"] == URIs.local_domain()
      assert body["stats"]["user_count"] >= 0
      assert body["configuration"]["statuses"]["max_characters"] == 500
    end

    test "carries the flags v1 clients read", %{conn: conn} do
      Settings.put_registration_mode(:approved)

      body = conn |> get(~p"/api/v1/instance") |> json_response(200)

      assert body["registrations"]
      assert body["approval_required"]
    end

    test "and names the account an admin put forward", %{conn: conn} do
      # Upstream lets an admin name an account as the one to write to, and
      # clients show it beside the address on their server-information screen.
      # This answered null whatever an admin wanted, because there was nothing
      # to set.
      contact = account_fixture(%{username: "steward", display_name: "The Steward"})
      :ok = Admin.put_settings(account_fixture(), %{"site_contact_account" => "steward"})

      v1 = conn |> get(~p"/api/v1/instance") |> json_response(200)
      v2 = conn |> get(~p"/api/v2/instance") |> json_response(200)

      assert v1["contact_account"]["id"] == to_string(contact.id)
      assert v1["contact_account"]["username"] == "steward"
      assert v2["contact"]["account"]["display_name"] == "The Steward"
    end

    test "and answers null when nobody has been named", %{conn: conn} do
      # Null rather than a missing key or a made-up account: a client reads it
      # to decide whether to show the line at all.
      assert conn
             |> get(~p"/api/v1/instance")
             |> json_response(200)
             |> Map.fetch!("contact_account") == nil
    end

    test "and null when the name does not belong to anybody here", %{conn: conn} do
      :ok = Admin.put_settings(account_fixture(), %{"site_contact_account" => "nobody"})

      assert conn
             |> get(~p"/api/v1/instance")
             |> json_response(200)
             |> Map.fetch!("contact_account") == nil
    end

    test "and the three fields v1 carries that v2 puts elsewhere", %{conn: conn} do
      # This endpoint exists here for clients too old to read v2, so what it
      # leaves out is invisible to exactly the clients that cannot look
      # anywhere else. All three have been in the v1 shape for years, and the
      # answers were already being assembled for v2.
      body = conn |> get(~p"/api/v1/instance") |> json_response(200)

      # A string here, where v2 nests it under an object.
      assert is_binary(body["thumbnail"])
      assert body["thumbnail"] =~ "thumbnail"

      assert Map.has_key?(body, "invites_enabled")
      assert Map.has_key?(body, "contact_account")
    end

    test "and says whether anybody may write an invite", %{conn: conn} do
      # A server-wide answer, so it reads what everybody may do rather than
      # what this reader may: a client shows or hides the invite screen from
      # it before anybody has signed in.
      refute conn
             |> get(~p"/api/v1/instance")
             |> json_response(200)
             |> Map.get("invites_enabled"),
             "nobody holds the permission, so this cannot be true"

      {:ok, _} = Roles.put_everyone(Roles.mask(["invite_users"]))

      assert conn |> get(~p"/api/v1/instance") |> json_response(200) |> Map.get("invites_enabled")
    end

    test "and the address an admin actually filled in", %{conn: conn} do
      account = account_fixture()

      # The admin screen writes `site_contact_email` and both payloads read
      # `contact_email`, so the address an admin typed reached nobody: the
      # endpoint answered the empty default however carefully it was set. It
      # is the one way to reach whoever runs a server, printed on the about
      # page and in every client's server information.
      :ok = Admin.put_settings(account, %{"site_contact_email" => "hello@example.com"})

      assert conn |> get(~p"/api/v1/instance") |> json_response(200) |> Map.get("email") ==
               "hello@example.com"

      assert conn
             |> get(~p"/api/v2/instance")
             |> json_response(200)
             |> get_in(["contact", "email"]) == "hello@example.com"
    end

    test "and what a closed server tells somebody who tries to join", %{conn: conn} do
      account = account_fixture()

      # Same shape: written as `closed_registration_message`, read as
      # `registration_message`. A client shows this to somebody who has just
      # been turned away, which is the moment an admin wrote it for.
      :ok =
        Admin.put_settings(account, %{
          "closed_registration_message" => "We open again in March."
        })

      assert conn
             |> get(~p"/api/v2/instance")
             |> json_response(200)
             |> get_in(["registrations", "message"]) == "We open again in March."
    end

    test "counts the domains this server has seen", %{conn: conn} do
      remote_account_fixture(%{domain: "one.example"})
      remote_account_fixture(%{username: "b", domain: "two.example"})
      remote_account_fixture(%{username: "c", domain: "two.example"})

      body = conn |> get(~p"/api/v1/instance") |> json_response(200)

      assert body["stats"]["domain_count"] == 2, "a domain seen twice is one domain"
    end
  end
end
