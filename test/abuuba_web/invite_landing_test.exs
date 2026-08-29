defmodule AbuubaWeb.InviteLandingTest do
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Invites
  alias Abuuba.Repo
  alias Abuuba.Settings

  setup do
    inviter = account_fixture(%{username: "alice"})
    invite = invite_fixture(inviter)

    on_exit(fn -> Settings.put_registration_mode(:approved) end)

    %{inviter: inviter, invite: invite}
  end

  # Written directly rather than through `Invites.create/2`, which asks whether
  # the account may invite at all. Who may write one is a different question
  # from what happens when somebody follows one.
  defp invite_fixture(inviter, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Abuuba.Invites.Invite{account_id: inviter.id, code: Invites.code()},
        attrs
      )
    )
  end

  describe "GET /invite/:code" do
    test "lands on the sign-up form with the code applied", %{conn: conn, invite: invite} do
      assert conn
             |> get(~p"/invite/#{invite.code}")
             |> redirected_to() =~ "/register?invite=#{invite.code}"
    end

    test "sends somebody with a typo to the form and says so", %{conn: conn} do
      conn = get(conn, ~p"/invite/NOTACODE")

      # Not a 404: somebody who was invited and mistyped a character should
      # land somewhere that explains itself, not on an error page that leaves
      # them wondering whether they were invited at all.
      assert redirected_to(conn) =~ "/register"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not one we know"
    end

    test "answers a client with the invite itself", %{conn: conn, invite: invite} do
      body =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/invite/#{invite.code}")
        |> json_response(200)

      assert body["code"] == invite.code
      assert body["expired"] == false
      assert body["used_up"] == false
    end

    test "answers a client 404 for a code that is not one", %{conn: conn} do
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/invite/NOTACODE")
      |> json_response(404)
    end
  end

  describe "the sign-up form on an invitation" do
    test "says the invitation means no approval is needed", %{conn: conn, invite: invite} do
      {:ok, _live, html} = live(conn, ~p"/register?invite=#{invite.code}")

      assert html =~ "signing up on an invitation"
      assert html =~ invite.code
    end

    test "says so when the code has expired", %{conn: conn, invite: invite} do
      invite
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :day))
      |> Repo.update!()

      {:ok, _live, html} = live(conn, ~p"/register?invite=#{invite.code}")

      assert html =~ "has expired"
      refute html =~ "signing up on an invitation"
    end

    test "says so when the code is used up", %{conn: conn, inviter: inviter} do
      invite = invite_fixture(inviter, %{max_uses: 1})
      {:ok, _spent} = Invites.claim(invite.code)

      {:ok, _live, html} = live(conn, ~p"/register?invite=#{invite.code}")

      # Three different things to the person holding the link, and they should
      # be able to tell which happened without asking whoever invited them.
      assert html =~ "has been used up"
      refute html =~ "has expired"
    end

    test "says so when the code is not one at all", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/register?invite=NOTACODE")

      assert html =~ "not one we know"
    end

    test "is quiet when no code was given at all", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/register")

      refute html =~ "not one we know"
      refute html =~ "has expired"
    end
  end

  describe "signing up on one" do
    setup do
      Settings.put_registration_mode(:closed)

      :ok
    end

    test "gets in on a closed server, and spends the invite", %{invite: invite} do
      assert {:ok, _user} =
               Auth.register(%{
                 "username" => "newcomer",
                 "email" => "newcomer@example.com",
                 "password" => "a passphrase nobody guesses",
                 "agreement" => "true",
                 "invite_code" => invite.code
               })

      assert Repo.reload!(invite).uses == 1
    end

    test "is refused on a closed server without one" do
      # The positive control above is what makes this refutation mean
      # something: without it a broken registration would pass this test.
      assert {:error, _changeset} =
               Auth.register(%{
                 "username" => "stranger",
                 "email" => "stranger@example.com",
                 "password" => "a passphrase nobody guesses",
                 "agreement" => "true"
               })
    end

    test "is refused on an expired code", %{invite: invite} do
      invite
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :day))
      |> Repo.update!()

      assert {:error, _changeset} =
               Auth.register(%{
                 "username" => "latecomer",
                 "email" => "latecomer@example.com",
                 "password" => "a passphrase nobody guesses",
                 "agreement" => "true",
                 "invite_code" => invite.code
               })

      assert Repo.reload!(invite).uses == 0
    end
  end
end
