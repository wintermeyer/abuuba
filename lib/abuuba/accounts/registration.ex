defmodule Abuuba.Accounts.Registration do
  @moduledoc """
  Signing up, as one transaction.

  A registration is three rows that only make sense together: the account other
  servers will see, the user behind it, and the keypair it signs with. Written
  one at a time, a failure part way through leaves an account nobody can log in
  to, or one that federates but cannot sign anything, and neither announces
  itself. So all three go in together or none do.

  The form is also validated as one thing, because a person filling in a signup
  form should be told about every problem at once rather than one per attempt.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.I18n
  alias Abuuba.Settings

  # The reference implementation's limit for the same box.
  @reason_max 420

  @primary_key false

  embedded_schema do
    field :username, :string
    field :email, :string
    field :password, :string, redact: true
    field :locale, :string
    field :invite_reason, :string
    field :invite_code, :string
    field :agreement, :boolean, default: false

    # Not a real field. Browsers fill it in, people do not, so anything in it
    # is a bot. Named plausibly rather than "honeypot" for the same reason.
    field :website, :string
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Validates a signup form.

  Pass `rules_required: false` where there are no server rules to agree to,
  so that an empty rules list does not produce a checkbox with nothing above it
  that nobody can satisfy.
  """
  def changeset(attrs, opts \\ []) do
    %__MODULE__{}
    |> cast(
      attrs,
      ~w(username email password locale invite_reason agreement website invite_code)a
    )
    |> validate_required([:username, :email, :password])
    |> validate_username()
    |> validate_email()
    |> validate_password()
    |> validate_locale()
    |> validate_agreement(opts)
    |> validate_invite_reason(opts)
    |> validate_honeypot()
  end

  defp validate_username(changeset) do
    changeset
    |> validate_format(:username, Account.username_format(),
      message: "may only contain letters, numbers and underscores"
    )
    |> validate_length(:username, min: 1, max: Account.username_max())
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, &String.trim/1)
    |> validate_format(:email, ~r/^[^\s@,]+@[^\s@,]+\.[^\s@,]+$/,
      message: "must be an email address"
    )
    |> validate_length(:email, max: 254)
  end

  defp validate_password(changeset) do
    validate_length(changeset, :password, min: 12, max: 72)
  end

  # Whatever is here decides which language every mail this person is ever sent
  # goes out in, so it is one of ours or it is nothing. Blanked rather than
  # refused: a client sending a language this server does not have is asking
  # for something reasonable, and the answer is the default, not an error.
  defp validate_locale(changeset) do
    case get_field(changeset, :locale) do
      nil -> changeset
      locale -> if I18n.known?(locale), do: changeset, else: put_change(changeset, :locale, nil)
    end
  end

  defp validate_agreement(changeset, opts) do
    if Keyword.get(opts, :rules_required, true) do
      validate_acceptance(changeset, :agreement, message: "you have to agree to the server rules")
    else
      changeset
    end
  end

  # Not asked of somebody arriving on an invite. The question exists so a
  # moderator can decide whether to let a stranger in, and an invite is a
  # person here having already decided.
  defp validate_invite_reason(changeset, opts) do
    invited? = get_field(changeset, :invite_code) not in [nil, ""]

    # `reason_required: false` is for an admin making an account at a shell.
    # The question "why would you like to join" is asked of a stranger by a
    # moderator who will read the answer, and there is neither here.
    asked? =
      Keyword.get(opts, :reason_required, true) and
        Settings.registration_mode() == :approved and not invited?

    changeset
    |> require_reason(asked?)
    # Bounded whether or not it was asked for, because it is kept whether or
    # not it was asked for: a length check that lives inside the "we asked"
    # branch is no check at all on the path that did not ask. The limit is the
    # reference implementation's, so a form built against that fits here.
    |> validate_length(:invite_reason, max: @reason_max)
  end

  defp require_reason(changeset, false), do: changeset

  defp require_reason(changeset, true) do
    validate_required(changeset, [:invite_reason],
      message: "tell the moderators a little about why you would like to join"
    )
  end

  # Rejected as an ordinary validation failure rather than with its own error,
  # so that a bot learns nothing about which field gave it away.
  defp validate_honeypot(changeset) do
    case get_field(changeset, :website) do
      value when value in [nil, ""] -> changeset
      _ -> add_error(changeset, :email, "is invalid")
    end
  end

  @doc """
  Whether a validated form was filled in by something that is not a person.
  """
  @spec bot?(map()) :: boolean()
  def bot?(attrs) do
    case attrs["website"] || attrs[:website] do
      value when value in [nil, ""] -> false
      _ -> true
    end
  end

  @doc """
  The attributes for the `users` row, given a validated form.
  """
  def user_attrs(%Ecto.Changeset{} = changeset, account_id, invite \\ nil) do
    approved = Settings.registration_mode() == :open or invite != nil

    %{
      account_id: account_id,
      email: get_field(changeset, :email),
      locale: get_field(changeset, :locale),
      # Somebody vouched for by a person here has already been through the
      # check that approval exists to make. Recorded with a time as well as a
      # flag, because the pair is what tells an approved account apart from a
      # disabled one later; see `Abuuba.Accounts.User.disabled?/1`.
      approved: approved,
      approved_at: if(approved, do: DateTime.utc_now()),
      invite_id: invite && invite.id,
      # Kept, not merely required. A server that asks a stranger to explain
      # themselves and then throws the answer away has put a hurdle in front of
      # the applicant and given the moderator nothing.
      sign_up_reason: get_field(changeset, :invite_reason)
    }
  end

  @doc """
  The email address from a validated form.
  """
  def email(%Ecto.Changeset{} = changeset), do: get_field(changeset, :email)

  @doc """
  The username from a validated form.
  """
  def username(%Ecto.Changeset{} = changeset), do: get_field(changeset, :username)

  @doc """
  The invite code somebody typed, or `nil`.
  """
  def invite_code(%Ecto.Changeset{} = changeset), do: get_field(changeset, :invite_code)

  @doc """
  The attributes for the `accounts` row.
  """
  def account_attrs(%Ecto.Changeset{} = changeset) do
    %{username: get_field(changeset, :username)}
  end

  @doc """
  The password from a validated form.
  """
  def password(%Ecto.Changeset{} = changeset), do: get_field(changeset, :password)
end
