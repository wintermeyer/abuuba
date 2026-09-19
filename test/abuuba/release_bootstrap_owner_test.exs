defmodule Abuuba.ReleaseBootstrapOwnerTest do
  @moduledoc """
  The first admin on a server that has no Mix.

  Everything else an operator does at a shell goes through a mix task, and a
  release has none, so this is the one route to an account that can open the
  admin area on a fresh production server.
  """

  use Abuuba.DataCase, async: false

  import ExUnit.CaptureIO

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Release
  alias Abuuba.Roles

  describe "bootstrap_owner/1" do
    test "prints the password that works, because `bin/abuuba eval` throws the return value away" do
      # A password handed back as a return value reached nobody: `eval`
      # evaluates the expression and prints nothing of it.
      output = bootstrap("founder")

      assert output =~ "Created @founder"
      assert [_line, password] = Regex.run(~r/Password: (\S+)/, output)
      assert byte_size(password) > 16
      assert User.valid_password?(user_named("founder"), password)
      refute User.valid_password?(user_named("founder"), password <> "x")
    end

    test "makes an account that can administer" do
      bootstrap("founder")

      assert Roles.can?(user_named("founder"), :administrator)
    end

    test "the account can sign in straight away" do
      # No confirmation link and no approval queue: there is nobody to send the
      # link to a mail server that may not be configured yet, and nobody to
      # approve it but itself.
      bootstrap("founder")

      assert :ok = Auth.check_sign_in(user_named("founder"))
    end

    test "running it twice does not make a second administrator role" do
      bootstrap("one")
      bootstrap("two")

      administrators =
        Enum.filter(Roles.all(), &(Bitwise.band(&1.permissions, Roles.bit(:administrator)) != 0))

      assert length(administrators) == 1
    end

    test "an existing administrator role is reused rather than replaced" do
      {:ok, existing} =
        Roles.create(%{name: "Chief", position: 900, permissions: Roles.mask([:administrator])})

      bootstrap("founder")

      assert user_named("founder").role_id == existing.id
    end

    test "a name already taken raises, so `bin/abuuba eval` exits non-zero and says why" do
      bootstrap("taken", "one@example.com")

      assert_raise RuntimeError, ~r/Could not create that account: .*already been taken/, fn ->
        bootstrap("taken", "two@example.com")
      end

      assert Accounts.get_account_by_handle("taken", nil)
    end

    test "the refusal names the limit rather than a placeholder" do
      too_long = String.duplicate("a", Account.username_max() + 1)

      assert_raise RuntimeError, ~r/username should be at most \d+ character/, fn ->
        bootstrap(too_long)
      end
    end

    test "string keys work too, because they are what a shell hands you" do
      capture_io(fn ->
        Release.bootstrap_owner(%{"username" => "founder", "email" => "founder@example.com"})
      end)

      assert user_named("founder")
    end
  end

  defp bootstrap(username, email \\ nil) do
    capture_io(fn ->
      Release.bootstrap_owner(%{username: username, email: email || "#{username}@example.com"})
    end)
  end

  defp user_named(username) do
    username |> Accounts.get_account_by_handle(nil) |> Accounts.get_user_by_account()
  end
end
