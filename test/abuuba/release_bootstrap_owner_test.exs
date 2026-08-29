defmodule Abuuba.ReleaseBootstrapOwnerTest do
  @moduledoc """
  The first admin on a server that has no Mix.

  Everything else an operator does at a shell goes through a mix task, and a
  release has none, so this is the one route to an account that can open the
  admin area on a fresh production server.
  """

  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Release
  alias Abuuba.Repo
  alias Abuuba.Roles

  describe "bootstrap_owner/1" do
    test "makes an account that can administer" do
      {:ok, %{account: account, user: user, password: password}} =
        Release.bootstrap_owner(%{username: "founder", email: "founder@example.com"})

      assert account.username == "founder"
      assert Roles.can?(reload(user), :administrator)
      assert is_binary(password) and byte_size(password) > 16
    end

    test "the account can sign in straight away" do
      # No confirmation link and no approval queue: there is nobody to send the
      # link to a mail server that may not be configured yet, and nobody to
      # approve it but itself.
      {:ok, %{user: user}} =
        Release.bootstrap_owner(%{username: "founder", email: "founder@example.com"})

      assert :ok = Auth.check_sign_in(reload(user))
    end

    test "the password it prints is the password that works" do
      {:ok, %{user: user, password: password}} =
        Release.bootstrap_owner(%{username: "founder", email: "founder@example.com"})

      assert User.valid_password?(reload(user), password)
      refute User.valid_password?(reload(user), password <> "x")
    end

    test "running it twice does not make a second administrator role" do
      {:ok, _first} = Release.bootstrap_owner(%{username: "one", email: "one@example.com"})
      {:ok, _second} = Release.bootstrap_owner(%{username: "two", email: "two@example.com"})

      administrators =
        Enum.filter(Roles.all(), &(Bitwise.band(&1.permissions, Roles.bit(:administrator)) != 0))

      assert length(administrators) == 1
    end

    test "an existing administrator role is reused rather than replaced" do
      {:ok, existing} =
        Roles.create(%{name: "Chief", position: 900, permissions: Roles.mask([:administrator])})

      {:ok, %{user: user}} =
        Release.bootstrap_owner(%{username: "founder", email: "founder@example.com"})

      assert reload(user).role_id == existing.id
    end

    test "a name already taken is refused rather than half-done" do
      {:ok, _first} = Release.bootstrap_owner(%{username: "taken", email: "one@example.com"})

      assert {:error, _reason} =
               Release.bootstrap_owner(%{username: "taken", email: "two@example.com"})

      assert Accounts.get_account_by_handle("taken", nil)
    end

    test "string keys work too, because they are what a shell hands you" do
      {:ok, %{account: account}} =
        Release.bootstrap_owner(%{"username" => "founder", "email" => "founder@example.com"})

      assert account.username == "founder"
    end
  end

  defp reload(user), do: Repo.get!(User, user.id)
end
