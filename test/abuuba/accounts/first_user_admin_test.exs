defmodule Abuuba.Accounts.FirstUserAdminTest do
  @moduledoc """
  The first account on a development server can reach the admin area.

  Both sides of the switch are tested here. A feature that reads its
  environment and is only ever exercised on the side that is on will pass every
  day and be wrong on the one server where being wrong matters.
  """

  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.User
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Roles.Role
  alias Abuuba.Settings

  setup do
    Settings.put_registration_mode(:open)
    on_exit(fn -> Application.delete_env(:abuuba, :first_user_is_admin) end)

    :ok
  end

  defp with_flag(value, fun) do
    Application.put_env(:abuuba, :first_user_is_admin, value)

    fun.()
  end

  defp register(username) do
    {:ok, %{user: user}} =
      Auth.register(
        %{
          "username" => username,
          "email" => "#{username}@example.com",
          "password" => "correct horse battery"
        },
        rules_required: false
      )

    user
  end

  describe "when the server is set up to do it" do
    test "the first account gets a role that can administer" do
      with_flag(true, fn ->
        user = register("first")

        assert Roles.can?(reload(user), :administrator)
      end)
    end

    test "the second does not" do
      with_flag(true, fn ->
        register("first")
        second = register("second")

        refute Roles.can?(reload(second), :administrator)
      end)
    end

    test "and the role it made is a real one an admin can see and edit" do
      with_flag(true, fn ->
        register("first")

        assert [role] = Roles.all()
        assert role.name != ""
        assert role.position > Role.everyone_position()
      end)
    end

    test "an existing role that can administer is used rather than a second one made" do
      {:ok, existing} =
        Roles.create(%{name: "Owner", position: 100, permissions: Roles.mask([:administrator])})

      with_flag(true, fn ->
        user = register("first")

        assert Roles.can?(reload(user), :administrator)
        assert [%{id: id}] = Roles.all()
        assert id == existing.id
      end)
    end
  end

  describe "when it is not" do
    test "the first account is an ordinary one" do
      with_flag(false, fn ->
        user = register("first")

        refute Roles.can?(reload(user), :administrator)
        assert Roles.all() == []
      end)
    end

    test "which is what a server with no setting at all does" do
      # The production case: nothing configured, so nothing granted. A public
      # server where whoever registers first owns it is a server anybody can
      # take over by being quick.
      Application.delete_env(:abuuba, :first_user_is_admin)

      user = register("first")

      refute Roles.can?(reload(user), :administrator)
    end
  end

  defp reload(user), do: Repo.get!(User, user.id)
end
