defmodule Abuuba.RolesTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Roles
  alias Abuuba.Roles.Role

  defp role(attrs) do
    {:ok, role} =
      Roles.create(Enum.into(attrs, %{name: "Role #{System.unique_integer([:positive])}"}))

    role
  end

  defp user_with(role) do
    user = user_fixture(%{approved: true, confirmed_at: DateTime.utc_now()})
    {:ok, user} = Roles.assign(user, role)

    user
  end

  describe "what the flags are" do
    test "there is one for every job an admin actually does" do
      names = Roles.permissions()

      for wanted <- ~w(administrator manage_reports manage_users manage_federation manage_roles) do
        assert wanted in names
      end
    end

    test "each has a bit of its own" do
      values = Enum.map(Roles.permissions(), &Roles.bit/1)

      assert length(Enum.uniq(values)) == length(values)
      assert Enum.all?(values, &(&1 > 0))
    end

    test "a name nobody defined has no bit" do
      assert Roles.bit("manage_the_weather") == 0
    end
  end

  describe "what somebody may do" do
    test "nothing, by default" do
      user = user_fixture()

      refute Roles.can?(user, "manage_users")
      refute Roles.can?(user, "administrator")
    end

    test "whatever their role says" do
      user = user_with(role(permissions: Roles.mask(["manage_reports"])))

      assert Roles.can?(user, "manage_reports")
      refute Roles.can?(user, "manage_users")
    end

    test "an administrator may do everything, without being granted it" do
      # Otherwise adding a permission means finding every administrator role
      # and remembering to grant it.
      user = user_with(role(permissions: Roles.mask(["administrator"])))

      assert Roles.can?(user, "manage_users")
      assert Roles.can?(user, "delete_user_data")
    end

    test "the role everybody has applies on top of their own" do
      # An admin who grants something to everybody has granted it to everybody,
      # including people who also hold a narrow role.
      {:ok, _} = Roles.put_everyone(Roles.mask(["invite_users"]))

      user = user_with(role(permissions: Roles.mask(["manage_reports"])))

      assert Roles.can?(user, "invite_users")
      assert Roles.can?(user, "manage_reports")
    end

    test "and to somebody with no role of their own" do
      {:ok, _} = Roles.put_everyone(Roles.mask(["invite_users"]))

      assert Roles.can?(user_fixture(), "invite_users")
    end

    test "nobody at all may do anything" do
      # A signed-out request has no user, and every check has to answer that
      # without being asked twice.
      refute Roles.can?(nil, "manage_users")
    end

    test "a permission nobody defined is refused" do
      user = user_with(role(permissions: Roles.mask(["administrator"])))

      refute Roles.can?(user, "manage_the_weather")
    end
  end

  describe "acting on other people" do
    setup do
      %{
        senior: user_with(role(position: 100, permissions: Roles.mask(["manage_users"]))),
        peer: user_with(role(position: 100, permissions: Roles.mask(["manage_users"]))),
        junior: user_with(role(position: 10, permissions: Roles.mask(["manage_reports"]))),
        nobody: user_fixture()
      }
    end

    test "somebody above may", %{senior: senior, junior: junior} do
      assert Roles.can_act_on?(senior, junior)
    end

    test "a peer may not", %{senior: senior, peer: peer} do
      # Otherwise two moderators can unmake each other, which is a fight rather
      # than a hierarchy.
      refute Roles.can_act_on?(senior, peer)
    end

    test "somebody below may not", %{senior: senior, junior: junior} do
      refute Roles.can_act_on?(junior, senior)
    end

    test "nobody may act on themselves", %{senior: senior} do
      refute Roles.can_act_on?(senior, senior)
    end

    test "anybody with a role outranks somebody with none", %{junior: junior, nobody: nobody} do
      assert Roles.can_act_on?(junior, nobody)
      refute Roles.can_act_on?(nobody, junior)
    end

    test "an administrator outranks everybody, whatever the positions say", %{peer: peer} do
      boss = user_with(role(position: 1, permissions: Roles.mask(["administrator"])))

      assert Roles.can_act_on?(boss, peer)
    end
  end

  describe "managing roles" do
    setup do
      %{
        manager:
          user_with(
            role(position: 100, permissions: Roles.mask(["manage_roles", "manage_reports"]))
          )
      }
    end

    test "needs the permission", %{} do
      user = user_with(role(position: 100, permissions: Roles.mask(["manage_users"])))

      refute Roles.can_manage?(user, role(position: 10, permissions: 0))
    end

    test "only for a role below your own", %{manager: manager} do
      refute Roles.can_manage?(manager, role(position: 100, permissions: 0))
      assert Roles.can_manage?(manager, role(position: 10, permissions: 0))
    end

    test "never your own role", %{manager: manager} do
      # Editing the role you hold is how somebody grants themselves anything.
      own = Roles.of(manager)

      refute Roles.can_manage?(manager, own)
    end

    test "cannot grant what you do not hold", %{manager: manager} do
      # A moderator who can edit roles must not be able to make one that can do
      # more than they can, and then hand it to themselves through somebody
      # else.
      wanted = role(position: 10, permissions: Roles.mask(["manage_users"]))

      refute Roles.can_manage?(manager, wanted)
    end

    test "can grant what you do hold", %{manager: manager} do
      wanted = role(position: 10, permissions: Roles.mask(["manage_reports"]))

      assert Roles.can_manage?(manager, wanted)
    end

    test "an administrator may grant anything", %{} do
      boss = user_with(role(position: 200, permissions: Roles.mask(["administrator"])))

      assert Roles.can_manage?(
               boss,
               role(position: 10, permissions: Roles.mask(["manage_users"]))
             )
    end
  end

  describe "the roles themselves" do
    test "are listed highest first" do
      low = role(position: 10)
      high = role(position: 100)

      assert [first, second | _] = Roles.all()
      assert first.id == high.id
      assert second.id == low.id
    end

    test "refuse two of the same name" do
      role(name: "Moderator")

      assert {:error, changeset} = Roles.create(%{name: "Moderator"})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "refuse a position at or below the one everybody has" do
      # The implicit role sits below every real one, and a role level with it
      # could not be acted on by anybody.
      assert {:error, changeset} =
               Roles.create(%{name: "Sunken", position: Role.everyone_position()})

      assert %{position: [_]} = errors_on(changeset)
    end

    test "can be taken off somebody" do
      user = user_with(role(permissions: Roles.mask(["manage_users"])))

      {:ok, user} = Roles.assign(user, nil)

      refute Roles.can?(user, "manage_users")
    end
  end
end
