defmodule Abuuba.Accounts.AuthTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Settings

  @valid %{
    "username" => "alice",
    "email" => "alice@example.com",
    "password" => "correct horse battery",
    "agreement" => "true"
  }

  defp register(overrides \\ %{}, opts \\ []) do
    Auth.register(Map.merge(@valid, overrides), Keyword.put_new(opts, :rules_required, false))
  end

  # The shipped default is `approved`, which is the right default for a server
  # but makes every unrelated test carry an invite reason. Tests about the
  # modes themselves set their own.
  setup do
    Settings.put_registration_mode(:open)
    :ok
  end

  describe "register/2" do
    test "creates the account, the user and the signing key together" do
      assert {:ok, %{account: account, user: user}} = register()

      assert account.username == "alice"
      assert user.account_id == account.id
      assert user.email == "alice@example.com"

      assert Accounts.active_keypair(account),
             "an account that federates but cannot sign is worse than no account"
    end

    test "leaves nothing behind when any part of it fails" do
      account_fixture(%{username: "alice"})

      assert {:error, changeset} = register()
      assert errors_on(changeset).username != []

      # The user row would otherwise be an orphan nobody can log in as.
      assert Auth.get_user_by_email("alice@example.com") == nil
    end

    test "stores the password hashed, and never the password" do
      {:ok, %{user: user}} = register()

      reloaded = Repo.get!(User, user.id)

      assert is_binary(reloaded.hashed_password)
      refute reloaded.hashed_password =~ "correct horse"
      assert reloaded.password == nil
    end

    test "requires a password long enough to be worth having" do
      assert {:error, changeset} = register(%{"password" => "short"})
      assert errors_on(changeset).password != []
    end

    test "refuses a username that would break a federation handle" do
      for bad <- ["with space", "a.b", "a/b", "a@b"] do
        assert {:error, changeset} = register(%{"username" => bad})
        assert errors_on(changeset).username != [], "accepted #{bad}"
      end
    end

    test "reports every problem at once rather than one per attempt" do
      assert {:error, changeset} =
               register(%{"username" => "not valid", "email" => "nope", "password" => "x"})

      errors = errors_on(changeset)

      assert errors.username != []
      assert errors.email != []
      assert errors.password != []
    end

    test "a filled honeypot fails like an ordinary validation error" do
      # A bot must not learn which field gave it away.
      assert {:error, changeset} = register(%{"website" => "https://spam.example"})

      assert errors_on(changeset).email != []
      assert Auth.get_user_by_email("alice@example.com") == nil
    end
  end

  describe "registration modes" do
    test "an open server approves immediately" do
      Settings.put_registration_mode(:open)

      {:ok, %{user: user}} = register()

      assert user.approved
    end

    test "an approving server leaves the registration pending" do
      Settings.put_registration_mode(:approved)

      {:ok, %{user: user}} = register(%{"invite_reason" => "I like it here"})

      refute user.approved
      assert user.id in Enum.map(Auth.pending_approval(), & &1.id)
    end

    test "an approving server asks why somebody wants to join" do
      Settings.put_registration_mode(:approved)

      assert {:error, changeset} = register()
      assert errors_on(changeset).invite_reason != []
    end

    test "a closed server takes nobody" do
      Settings.put_registration_mode(:closed)

      assert {:error, :registration_closed} = register()
    end
  end

  describe "signing in" do
    setup do
      Settings.put_registration_mode(:open)
      {:ok, %{user: user}} = register()
      %{user: user}
    end

    test "accepts the right password", %{user: user} do
      assert Auth.get_user_by_email_and_password("alice@example.com", "correct horse battery").id ==
               user.id
    end

    test "is case-insensitive about the address", %{user: user} do
      assert Auth.get_user_by_email_and_password("ALICE@Example.COM", "correct horse battery").id ==
               user.id
    end

    test "refuses the wrong password" do
      refute Auth.get_user_by_email_and_password("alice@example.com", "wrong")
    end

    test "refuses an address nobody has" do
      refute Auth.get_user_by_email_and_password("nobody@example.com", "correct horse battery")
    end

    test "costs the same whether or not the address exists" do
      # Without the dummy hash, a missing account answers faster than a wrong
      # password, and the difference says which addresses are registered here.
      #
      # Measured as a median of several runs after warming both paths. A single
      # sample each makes the first one pay for module loading and a cold
      # connection, which reads as a 60x difference and is a fact about the
      # first call rather than about the code.
      warm = fn ->
        Auth.get_user_by_email_and_password("nobody@example.com", "whatever")
        Auth.get_user_by_email_and_password("alice@example.com", "whatever")
      end

      warm.()
      warm.()

      missing =
        median(fn -> Auth.get_user_by_email_and_password("nobody@example.com", "whatever") end)

      wrong =
        median(fn -> Auth.get_user_by_email_and_password("alice@example.com", "whatever") end)

      ratio = missing / max(wrong, 1)

      assert ratio > 0.25 and ratio < 4,
             "missing #{missing}µs vs wrong #{wrong}µs is a usable oracle"
    end

    test "refuses an empty password", %{user: _user} do
      refute Auth.get_user_by_email_and_password("alice@example.com", "")
      refute Auth.get_user_by_email_and_password(nil, nil)
    end
  end

  describe "sessions" do
    setup do
      Settings.put_registration_mode(:open)
      {:ok, %{user: user}} = register()
      %{user: user, token: Auth.create_session_token(user)}
    end

    test "a token identifies its user", %{user: user, token: token} do
      assert Auth.get_user_by_session_token(token).id == user.id
    end

    test "the raw token is never what is stored", %{token: token} do
      %{rows: [[stored]]} = Repo.query!("SELECT token FROM user_tokens LIMIT 1")

      refute stored == token
    end

    test "signing out invalidates just that session", %{user: user, token: token} do
      other = Auth.create_session_token(user)

      :ok = Auth.delete_session_token(token)

      refute Auth.get_user_by_session_token(token)
      assert Auth.get_user_by_session_token(other)
    end

    test "every session can be ended at once", %{user: user, token: token} do
      other = Auth.create_session_token(user)

      :ok = Auth.delete_all_session_tokens(user)

      refute Auth.get_user_by_session_token(token)
      refute Auth.get_user_by_session_token(other)
    end

    test "nonsense is not a session" do
      refute Auth.get_user_by_session_token("not a token")
      refute Auth.get_user_by_session_token(nil)
    end
  end

  describe "confirmation" do
    setup do
      Settings.put_registration_mode(:open)
      {:ok, %{user: user}} = register()
      {:ok, token} = Auth.create_confirmation_token(user)
      %{user: user, token: token}
    end

    test "a token confirms its user", %{user: user, token: token} do
      refute User.confirmed?(Repo.get!(User, user.id))

      assert {:ok, confirmed} = Auth.confirm_user(token)
      assert User.confirmed?(confirmed)
    end

    test "a token works once", %{token: token} do
      {:ok, _} = Auth.confirm_user(token)

      assert Auth.confirm_user(token) == :error
    end

    test "a token stops working if the address changes", %{user: user, token: token} do
      # Otherwise: ask for a confirmation, change your email to one you do not
      # own, and confirm it with the old link.
      Repo.update!(Ecto.Changeset.change(user, email: "somebody.else@example.com"))

      assert Auth.confirm_user(token) == :error
    end

    test "a token is not a session token", %{token: token} do
      refute Auth.get_user_by_session_token(token)
    end

    test "nonsense confirms nothing" do
      assert Auth.confirm_user("nope") == :error
      assert Auth.confirm_user("!!!not base64!!!") == :error
    end
  end

  describe "check_sign_in/1" do
    setup do
      Settings.put_registration_mode(:approved)
      {:ok, %{user: user}} = register(%{"invite_reason" => "hello"})
      %{user: user}
    end

    test "names which gate is shut, rather than a bare no", %{user: user} do
      assert Auth.check_sign_in(user) == {:error, :unconfirmed}

      {:ok, token} = Auth.create_confirmation_token(user)
      {:ok, confirmed} = Auth.confirm_user(token)

      assert Auth.check_sign_in(confirmed) == {:error, :pending_approval}

      {:ok, approved} = Auth.approve_user(confirmed)

      assert Auth.check_sign_in(approved) == :ok
      assert User.active?(approved)
    end

    test "approval is recorded with a time, not just a flag", %{user: user} do
      {:ok, approved} = Auth.approve_user(user)

      assert approved.approved
      refute is_nil(approved.approved_at)
    end

    test "a disabled account is shut even when both other gates are open", %{user: user} do
      # Disabling is the quiet counterpart to suspension: the posts stay, the
      # person does not get back in. It is told apart from a registration
      # nobody has looked at yet by whether approval ever happened, which is
      # the same pair of columns the admin area reads.
      {:ok, token} = Auth.create_confirmation_token(user)
      {:ok, confirmed} = Auth.confirm_user(token)
      {:ok, approved} = Auth.approve_user(confirmed)

      disabled = %{approved | approved: false}

      assert Auth.check_sign_in(disabled) == {:error, :disabled}
      refute User.active?(disabled)
    end
  end

  # The median of nine, so one scheduler hiccup cannot decide the outcome.
  defp median(fun) do
    1..9
    |> Enum.map(fn _ -> elem(:timer.tc(fun), 0) end)
    |> Enum.sort()
    |> Enum.at(4)
  end
end
