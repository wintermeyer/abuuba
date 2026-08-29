defmodule Abuuba.Accounts.User do
  @moduledoc """
  The local half of an account: what a person has and a remote actor does not.

  Kept in its own table rather than as columns on `accounts`, because the
  account row is the one that gets serialised and handed to other servers. An
  email address that lives one table away cannot be leaked by a serialiser that
  forgot to exclude it.

  Credentials themselves arrive with the authentication work; this is the row
  they will hang off.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Abuuba.Accounts.Account

  @email_format ~r/^[^\s@,]+@[^\s@,]+\.[^\s@,]+$/

  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime_usec
    # When somebody last started a session. What the fan-out reads to decide
    # whether writing a feed for them is work anybody will benefit from.
    field :last_signed_in_at, :utc_datetime_usec
    # What this person may do. Null is the role everybody has; see
    # `Abuuba.Roles`.
    field :role_id, :id
    field :approved, :boolean, default: false
    # Which invite let somebody in, or null for somebody who arrived on their
    # own. See `Abuuba.Invites`.
    field :invite_id, :id
    # Where somebody signed up from, so an address block written later means
    # something and a wave of registrations can be seen for what it is.
    field :sign_up_ip, :string
    field :sign_up_reason, :string
    # The app that signed somebody up, where an app did. Only that app may ask
    # for their confirmation mail to be sent again.
    field :created_by_application_id, :id
    field :locale, :string
    field :settings, :map, default: %{}

    # Somebody's standing instruction to delete their own old posts. Columns
    # rather than a corner of `settings`, so the worker can find the accounts
    # that asked for it without reading every user row. See
    # `Abuuba.Statuses.Cleanup`.
    field :cleanup_after_days, :integer
    field :cleanup_keep_pinned, :boolean, default: true
    field :cleanup_keep_media, :boolean, default: false
    field :cleanup_min_favourites, :integer
    field :cleanup_min_boosts, :integer
    field :cleanup_last_run_at, :utc_datetime_usec
    field :confirmation_sent_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec

    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true

    field :otp_secret, Abuuba.Encrypted.Binary, redact: true
    field :otp_required_at, :utc_datetime_usec
    field :otp_last_used_at, :utc_datetime_usec

    belongs_to :account, Account, type: Abuuba.Snowflake

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Changeset for creating or updating a user.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :account_id,
      :email,
      :confirmed_at,
      :approved,
      # Carried with the flag rather than set afterwards, because the two
      # together are what says whether somebody was ever let in. Never taken
      # from a request: every caller builds this map itself.
      :approved_at,
      :locale,
      :settings,
      :invite_id,
      :sign_up_ip,
      # What somebody wrote when they asked to join, on a server that asks. The
      # moderator deciding on the account reads it; nothing else does.
      :sign_up_reason,
      :created_by_application_id
    ])
    |> validate_required([:account_id, :email])
    # `approved` and `settings` are NOT NULL: an explicit null in a request
    # body would otherwise reach Postgres and crash rather than validate.
    # Checked as changes rather than with validate_required/2, which would also
    # reject the perfectly valid empty settings map.
    |> reject_null_changes([:approved, :settings])
    |> update_change(:email, &String.trim/1)
    |> validate_format(:email, @email_format)
    |> validate_length(:email, max: 254)
    |> unique_constraint(:email, name: :users_email_index)
    |> unique_constraint(:account_id)
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Changeset for the language preference alone.
  """
  def locale_changeset(user, attrs) do
    user
    |> cast(attrs, [:locale])
    |> validate_inclusion(:locale, Abuuba.I18n.known_locales())
  end

  defp reject_null_changes(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case fetch_change(acc, field) do
        {:ok, nil} -> add_error(acc, field, "can't be null")
        _ -> acc
      end
    end)
  end

  @doc """
  Changeset for setting or changing a password.

  The minimum is 12 characters and there is no composition rule. Requiring a
  digit and a symbol pushes people towards `Password1!`, which is shorter and
  more guessable than a passphrase they can actually remember; length is the
  property that makes a password expensive to attack.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> maybe_hash_password(opts)
  end

  # 72 bytes, because bcrypt silently ignores anything past that. A password
  # longer than the limit would appear to be accepted while only its first 72
  # bytes were ever checked, which is worse than refusing it.
  defp maybe_hash_password(changeset, opts) do
    hash? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash? && password && changeset.valid? do
      changeset
      |> validate_length(:password, max: 72, count: :bytes)
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Verifies a password against a user, in constant time even when there is no
  user.

  The dummy check matters: without it, a missing account answers faster than a
  wrong password, and the difference tells an attacker which email addresses
  are registered here.
  """
  @spec valid_password?(t() | nil, String.t()) :: boolean()
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_user, _password) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  Marks the address as confirmed.
  """
  def confirm_changeset(user) do
    change(user, confirmed_at: DateTime.utc_now())
  end

  @doc """
  Records a moderator's approval.
  """
  def approve_changeset(user) do
    change(user, approved: true, approved_at: DateTime.utc_now())
  end

  @doc """
  Shuts somebody out of their own account.

  Both columns, always. `approved_at` is what tells a disabled account apart
  from a registration nobody has looked at yet, so a disable that left it empty
  would put the account in the approval queue, where the next moderator could
  let them back in while the sign-in page told them their registration was
  pending.
  """
  def disable_changeset(user) do
    change(user, approved: false, approved_at: user.approved_at || DateTime.utc_now())
  end

  @doc """
  Lets them back in.
  """
  def enable_changeset(user) do
    change(user, approved: true, approved_at: user.approved_at || DateTime.utc_now())
  end

  @doc """
  Accounts somebody was let into and then shut out of.
  """
  @spec disabled(Ecto.Queryable.t()) :: Ecto.Query.t()
  def disabled(query \\ __MODULE__) do
    from(u in query, where: u.approved == false and not is_nil(u.approved_at))
  end

  @doc """
  Registrations nobody has looked at yet.
  """
  @spec pending(Ecto.Queryable.t()) :: Ecto.Query.t()
  def pending(query \\ __MODULE__) do
    from(u in query, where: u.approved == false and is_nil(u.approved_at))
  end

  @doc """
  Whether the user may actually sign in: confirmed, approved if this server
  approves registrations, and not disabled.
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{} = user),
    do: confirmed?(user) and user.approved and not disabled?(user)

  @doc """
  Whether somebody has been shut out of their own account.

  Read from the same two columns as approval rather than from a flag of its
  own, because "approved once and not approved now" is exactly what a
  moderator disabling somebody does, and it is the shape the admin area and
  the admin API already report. A registration nobody has looked at yet has
  never been approved, so the two are told apart by whether that ever
  happened.

  Distinct from suspension, which is about the posts and federates. This one
  leaves everything where it is and closes the door.
  """
  @spec disabled?(t()) :: boolean()
  def disabled?(%__MODULE__{approved: false, approved_at: %DateTime{}}), do: true
  def disabled?(%__MODULE__{}), do: false

  @doc """
  Whether the user has confirmed their email address.
  """
  def confirmed?(%__MODULE__{confirmed_at: nil}), do: false
  def confirmed?(%__MODULE__{}), do: true

  @doc """
  Changeset for somebody's own post-cleanup settings.

  Its own changeset rather than a corner of a wider one, because these five
  fields between them delete posts and nothing else on this schema should be
  reachable from the form that sets them.
  """
  @spec cleanup_changeset(t(), map()) :: Ecto.Changeset.t()
  def cleanup_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :cleanup_after_days,
      :cleanup_keep_pinned,
      :cleanup_keep_media,
      :cleanup_min_favourites,
      :cleanup_min_boosts
    ])
    # A week is the shortest that is not a mistake, and anything under it is
    # much more likely to be a typo than an intention.
    |> validate_number(:cleanup_after_days, greater_than_or_equal_to: 7)
    |> validate_number(:cleanup_min_favourites, greater_than_or_equal_to: 0)
    |> validate_number(:cleanup_min_boosts, greater_than_or_equal_to: 0)
  end
end
