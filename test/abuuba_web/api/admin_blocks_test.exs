defmodule AbuubaWeb.API.AdminBlocksTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Moderation.Signup
  alias Abuuba.OAuth
  alias Abuuba.Roles

  defp signed_in_with(conn, permissions) do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 10,
        permissions: Roles.mask(permissions)
      })

    {:ok, user} = Roles.assign(user, role)

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} =
      OAuth.issue_token(application, user, ["read", "write", "admin:read", "admin:write"])

    %{conn: put_req_header(conn, "authorization", "Bearer " <> raw), account: account}
  end

  setup %{conn: conn} do
    %{conn: federation, account: moderator} =
      signed_in_with(conn, ["manage_federation", "manage_blocks"])

    %{conn: plain} = signed_in_with(build_conn(), [])

    %{conn: federation, plain: plain, moderator: moderator}
  end

  describe "domains this server will talk to" do
    test "adds one, reads it back, and takes it off", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v1/admin/domain_allows", %{"domain" => "good.example"}),
          200
        )

      assert created["domain"] == "good.example"
      assert is_binary(created["id"])
      assert created["created_at"]

      assert [listed] = json_response(get(conn, "/api/v1/admin/domain_allows"), 200)
      assert listed["id"] == created["id"]

      assert json_response(get(conn, "/api/v1/admin/domain_allows/#{created["id"]}"), 200) ==
               created

      assert json_response(delete(conn, "/api/v1/admin/domain_allows/#{created["id"]}"), 200) ==
               %{}

      assert json_response(get(conn, "/api/v1/admin/domain_allows"), 200) == []
    end

    test "an id nobody has is a miss rather than a crash", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/admin/domain_allows/999999"), 404)
      assert json_response(get(conn, "/api/v1/admin/domain_allows/not-a-number"), 404)
    end
  end

  describe "email domains nobody may sign up with" do
    test "adds one, reads it back, and takes it off", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v1/admin/email_domain_blocks", %{"domain" => "spam.example"}),
          200
        )

      assert created["domain"] == "spam.example"
      # What a moderation client renders as a sparkline. Empty rather than
      # invented: nothing here counts attempts per domain.
      assert created["history"] == []

      assert [_one] = json_response(get(conn, "/api/v1/admin/email_domain_blocks"), 200)

      assert json_response(
               delete(conn, "/api/v1/admin/email_domain_blocks/#{created["id"]}"),
               200
             )

      assert json_response(get(conn, "/api/v1/admin/email_domain_blocks"), 200) == []
    end

    test "and the block actually works", %{conn: conn} do
      # The positive control: the endpoint writes the same row the sign-up path
      # reads, rather than a row of its own that nothing consults.
      json_response(
        post(conn, "/api/v1/admin/email_domain_blocks", %{"domain" => "spam.example"}),
        200
      )

      assert {:error, :email_domain_blocked} =
               Signup.check(%{email: "somebody@spam.example", username: "x"})
    end
  end

  describe "address ranges" do
    test "adds one, changes it, and takes it off", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v1/admin/ip_blocks", %{
            "ip" => "203.0.113.0/24",
            "severity" => "no_access",
            "comment" => "a bad neighbourhood"
          }),
          200
        )

      # The API calls the range `ip`; the column has to say `cidr` because a
      # single address is a /32.
      assert created["ip"] == "203.0.113.0/24"
      assert created["severity"] == "no_access"
      assert created["comment"] == "a bad neighbourhood"

      updated =
        json_response(
          put(conn, "/api/v1/admin/ip_blocks/#{created["id"]}", %{
            "severity" => "sign_up_requires_approval"
          }),
          200
        )

      # Softened rather than removed and rewritten, which would be two audit
      # entries for one decision.
      assert updated["severity"] == "sign_up_requires_approval"
      assert updated["ip"] == "203.0.113.0/24"

      assert json_response(delete(conn, "/api/v1/admin/ip_blocks/#{created["id"]}"), 200) == %{}
      assert json_response(get(conn, "/api/v1/admin/ip_blocks"), 200) == []
    end

    test "refuses a range that is not one", %{conn: conn} do
      assert json_response(post(conn, "/api/v1/admin/ip_blocks", %{"ip" => "nowhere"}), 422)
    end
  end

  describe "addresses blocked by their canonical form" do
    test "blocks one, and never hands the address back", %{conn: conn} do
      created =
        json_response(
          post(conn, "/api/v1/admin/canonical_email_blocks", %{
            "email" => "Some.Body+tag@gmail.com"
          }),
          200
        )

      # The point of storing the canonical form is that the address is not
      # kept, and an entity that returned it would undo that.
      assert is_binary(created["canonical_email_hash"])
      refute Map.has_key?(created, "email")
      refute created["canonical_email_hash"] =~ "gmail"

      assert [_one] = json_response(get(conn, "/api/v1/admin/canonical_email_blocks"), 200)

      assert json_response(
               delete(conn, "/api/v1/admin/canonical_email_blocks/#{created["id"]}"),
               200
             )
    end

    test "says which blocks an address would trip, without writing one", %{conn: conn} do
      json_response(
        post(conn, "/api/v1/admin/canonical_email_blocks", %{"email" => "somebody@gmail.com"}),
        200
      )

      # The same canonicalisation the block itself uses: dots and a plus tag
      # are the same address to Gmail, so they are the same block here.
      assert [_match] =
               json_response(
                 post(conn, "/api/v1/admin/canonical_email_blocks/test", %{
                   "email" => "some.body+news@gmail.com"
                 }),
                 200
               )

      assert json_response(
               post(conn, "/api/v1/admin/canonical_email_blocks/test", %{
                 "email" => "somebody.else@example.com"
               }),
               200
             ) == []

      # Nothing was written by asking.
      assert [_still_one] = json_response(get(conn, "/api/v1/admin/canonical_email_blocks"), 200)
    end
  end

  describe "who may reach any of this" do
    test "a moderator with no permission is refused everywhere", %{plain: plain} do
      for path <- [
            "/api/v1/admin/domain_allows",
            "/api/v1/admin/email_domain_blocks",
            "/api/v1/admin/ip_blocks",
            "/api/v1/admin/canonical_email_blocks"
          ] do
        assert json_response(get(plain, path), 403), "reachable: #{path}"
      end
    end

    test "somebody signed out is refused too", %{} do
      assert json_response(get(build_conn(), "/api/v1/admin/ip_blocks"), 422)
    end
  end
end
