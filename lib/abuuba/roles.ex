defmodule Abuuba.Roles do
  @moduledoc """
  Who may do what, and to whom.

  ## Two questions, not one

  "May this person do X" and "may this person do X *to that person*" are
  different, and conflating them is how an interface ends up letting one
  moderator suspend another. `can?/2` answers the first, `can_act_on?/2` the
  second, and every admin surface has to ask both.

  ## Three rules that exist to stop self-promotion

  A role cannot be edited by somebody holding it, a role cannot be given
  permissions its editor does not have, and nobody may act on a peer. Take any
  one away and there is a path from "can edit roles" to "can do everything":
  edit your own role, or make a role that can do more than you and hand it to a
  friend who hands it back, or demote the person who would have stopped you.

  ## Administrator is a short circuit, not a flag with twenty friends

  It answers yes to every permission and outranks every position. The
  alternative is granting twenty flags to every administrator role and
  remembering to grant the twenty-first when it is added.
  """

  import Ecto.Query

  alias Abuuba.Accounts.User
  alias Abuuba.Repo
  alias Abuuba.Roles.Role
  alias Abuuba.Settings
  alias Abuuba.Snowflake

  # The reference implementation's flags and its bit positions. Its admin API
  # hands these numbers to clients, so they are part of the protocol rather
  # than something to choose.
  @permissions %{
    "administrator" => 0x1,
    "devops" => 0x2,
    "view_audit_log" => 0x4,
    "view_dashboard" => 0x8,
    "manage_reports" => 0x10,
    "manage_federation" => 0x20,
    "manage_settings" => 0x40,
    "manage_blocks" => 0x80,
    "manage_taxonomies" => 0x100,
    "manage_appeals" => 0x200,
    "manage_users" => 0x400,
    "manage_invites" => 0x800,
    "manage_rules" => 0x1000,
    "manage_announcements" => 0x2000,
    "manage_custom_emojis" => 0x4000,
    "manage_webhooks" => 0x8000,
    "invite_users" => 0x10000,
    "manage_roles" => 0x20000,
    "manage_user_access" => 0x40000,
    "delete_user_data" => 0x80000
  }

  @administrator @permissions["administrator"]
  @everyone_setting "everyone_permissions"

  ## The flags

  @doc """
  Every permission there is, in the order the interface lists them.
  """
  @spec permissions() :: [String.t()]
  def permissions,
    do: @permissions |> Map.to_list() |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  @doc """
  The bit one permission occupies, or zero for a name nobody defined.

  Zero rather than an error: a name arrives from a request body as often as
  from our own code, and an unknown one is a permission somebody does not have
  rather than something to crash over.
  """
  @spec bit(String.t() | atom()) :: non_neg_integer()
  def bit(name), do: Map.get(@permissions, to_string(name), 0)

  @doc """
  The mask for a list of names.
  """
  @spec mask([String.t() | atom()]) :: non_neg_integer()
  def mask(names), do: Enum.reduce(names, 0, &Bitwise.bor(bit(&1), &2))

  @doc """
  Which names a mask carries.
  """
  @spec names(non_neg_integer()) :: [String.t()]
  def names(mask), do: Enum.filter(permissions(), &(Bitwise.band(mask, bit(&1)) != 0))

  ## Asking

  @doc """
  Everything somebody may do: their own role, plus what everybody may do.
  """
  @spec permissions_of(User.t() | nil) :: non_neg_integer()
  def permissions_of(nil), do: 0

  def permissions_of(%User{} = user) do
    Bitwise.bor(everyone_mask(), own_mask(user))
  end

  @doc """
  Whether somebody may do one thing.
  """
  @spec can?(User.t() | nil, String.t() | atom()) :: boolean()
  def can?(nil, _permission), do: false

  def can?(%User{} = user, permission), do: allows?(permissions_of(user), permission)

  @doc """
  Whether a mask of held permissions covers one thing.

  The same question as `can?/2` with the reading already done, for a screen
  that asks it many times over one render: the admin area's own navigation
  asks it once per section and its permission form twice per permission, and
  each of those went to the database for the same role row.

  Use `can?/2` to decide anything. This answers from a mask somebody read
  earlier, which is right for drawing a page and wrong for allowing an action:
  a permission taken away should stop the next click, not the next page load.
  """
  @spec allows?(integer(), String.t() | atom()) :: boolean()
  def allows?(held, permission) do
    wanted = bit(permission)

    # An unknown permission is zero, and zero must never be "yes". Checked
    # before the administrator short circuit for exactly that reason.
    wanted != 0 and
      (Bitwise.band(held, @administrator) != 0 or Bitwise.band(held, wanted) != 0)
  end

  @doc """
  Whether somebody may act on somebody else.

  Never on themselves and never on a peer. An administrator outranks everybody
  whatever the positions say, which is what makes them able to fix a hierarchy
  somebody else has tangled.
  """
  @spec can_act_on?(User.t() | nil, User.t() | nil) :: boolean()
  def can_act_on?(nil, _target), do: false
  def can_act_on?(_actor, nil), do: false

  def can_act_on?(%User{id: id}, %User{id: id}), do: false

  def can_act_on?(%User{} = actor, %User{} = target) do
    if administrator?(actor), do: true, else: position_of(actor) > position_of(target)
  end

  @doc """
  Whether somebody may create or change a role.

  Three conditions, and every one of them exists to close a path from "can edit
  roles" to "can do everything": the permission itself, a role strictly below
  their own, and no permission on it that they do not already hold.
  """
  @spec can_manage?(User.t() | nil, Role.t()) :: boolean()
  def can_manage?(nil, _role), do: false

  def can_manage?(%User{} = user, %Role{} = role) do
    can?(user, "manage_roles") and not own_role?(user, role) and
      outranks?(user, role) and grants_only_held?(user, role)
  end

  @doc """
  The role somebody holds, or `nil`.
  """
  @spec of(User.t() | nil) :: Role.t() | nil
  def of(nil), do: nil
  def of(%User{role_id: nil}), do: nil
  def of(%User{role_id: id}), do: Repo.get(Role, id)

  @doc """
  Roles by id, for rendering a list of people at once.
  """
  @spec by_ids([integer()]) :: %{integer() => Role.t()}
  def by_ids([]), do: %{}

  def by_ids(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Role |> where([r], r.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
  end

  ## Keeping them

  @doc """
  Every role, the highest first.
  """
  @spec all() :: [Role.t()]
  def all do
    Role |> order_by([r], desc: r.position, asc: r.id) |> Repo.all()
  end

  @doc """
  One role, or `nil`.
  """
  @spec get(integer() | String.t()) :: Role.t() | nil
  def get(id) do
    case Snowflake.cast(id) do
      {:ok, id} -> Repo.get(Role, id)
      _ -> nil
    end
  end

  @doc """
  Creates one.
  """
  @spec create(map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Role{} |> Role.changeset(attrs) |> Repo.insert()

  @doc """
  A role that can administer, making one if the server has none.

  Reuses an existing one rather than adding a second, because two roles that
  both mean "can do everything" is the state where taking somebody's access
  away appears to work and does not.

  The one it makes is an ordinary role: it appears in the admin area under the
  name below and can be renamed, edited or given to somebody else from there.
  """
  @spec administrator_role() :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def administrator_role do
    case Enum.find(all(), &(Bitwise.band(&1.permissions, bit(:administrator)) != 0)) do
      %Role{} = role -> {:ok, role}
      nil -> create(%{name: "Owner", position: 1000, permissions: mask(permissions())})
    end
  end

  @doc """
  Changes one.
  """
  @spec update(Role.t(), map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def update(%Role{} = role, attrs), do: role |> Role.changeset(attrs) |> Repo.update()

  @doc """
  Removes one. Whoever held it falls back to what everybody may do.
  """
  @spec delete(Role.t()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Role{} = role), do: Repo.delete(role)

  @doc """
  Gives somebody a role, or takes theirs away.
  """
  @spec assign(User.t(), Role.t() | nil) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def assign(%User{} = user, nil) do
    user |> Ecto.Changeset.change(role_id: nil) |> Repo.update()
  end

  def assign(%User{} = user, %Role{id: id}) do
    user |> Ecto.Changeset.change(role_id: id) |> Repo.update()
  end

  ## What everybody may do

  @doc """
  The permissions every account has, whatever role they hold.
  """
  @spec everyone_mask() :: non_neg_integer()
  def everyone_mask do
    case Settings.get(@everyone_setting) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> 0
    end
  end

  @doc """
  Whether everybody holds one permission, whatever role they have.

  For the questions a server answers about itself rather than about a reader:
  the instance metadata says whether invites may be written at all, and a
  client reads that before anybody has signed in.
  """
  @spec everyone_can?(String.t() | atom()) :: boolean()
  def everyone_can?(permission) do
    Bitwise.band(everyone_mask(), bit(permission)) != 0
  end

  @doc """
  Sets them.
  """
  @spec put_everyone(non_neg_integer()) :: {:ok, non_neg_integer()} | :ok
  def put_everyone(mask) when is_integer(mask) and mask >= 0 do
    Settings.put(@everyone_setting, mask)

    {:ok, mask}
  end

  ## Plumbing

  defp own_mask(%User{role_id: nil}), do: 0

  defp own_mask(%User{} = user) do
    case of(user) do
      nil -> 0
      role -> role.permissions
    end
  end

  defp administrator?(user), do: Bitwise.band(permissions_of(user), @administrator) != 0

  # Somebody with no role sits below every real one, which is what makes any
  # role at all enough to act on somebody who has none.
  defp position_of(%User{role_id: nil}), do: Role.everyone_position()

  defp position_of(%User{} = user) do
    case of(user) do
      nil -> Role.everyone_position()
      role -> role.position
    end
  end

  defp own_role?(%User{role_id: id}, %Role{id: id}) when not is_nil(id), do: true
  defp own_role?(_user, _role), do: false

  defp outranks?(user, role) do
    administrator?(user) or position_of(user) > role.position
  end

  # An administrator may grant anything, which is the same short circuit as
  # everywhere else. Everybody else may grant only what they already hold.
  defp grants_only_held?(user, role) do
    administrator?(user) or
      Bitwise.band(role.permissions, Bitwise.bnot(permissions_of(user))) == 0
  end
end
