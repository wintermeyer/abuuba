defmodule Abuuba.Accounts.UserToken do
  @moduledoc """
  Session and email tokens.

  Two rules run through this module.

  **What is stored is not what is handed out.** A session token is a bearer
  credential: whoever holds it is signed in. Storing the raw value would mean a
  database leak, or a read-only injection, hands the reader every live session
  on the server. Email tokens are stored hashed for the same reason, and are
  additionally sent as URL-safe base64 rather than raw bytes.

  **A token is bound to what it was issued for.** The `context` keeps a
  confirmation link from working as a session, and `sent_to` records the
  address a confirmation was sent to, so that changing an email address after
  requesting one does not let the old link confirm the new address.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Abuuba.Accounts.User
  alias Abuuba.Accounts.UserToken

  # 32 bytes from a cryptographic source. Long enough that guessing is not a
  # strategy, and the same size the hash below produces.
  @rand_size 32
  @hash_algorithm :sha256

  @session_validity_days 60
  @confirm_validity_days 7

  # Hours rather than days. A reset link is the one credential that lets
  # somebody take over an account outright, and it sits in a mailbox that may
  # itself be shared, forwarded or backed up somewhere. Long enough to walk to
  # another machine and read the mail, short enough that a link found later is
  # worth nothing.
  @reset_validity_hours 6

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @doc """
  Builds a session token: the raw value for the cookie, and the row to store.
  """
  @spec build_session_token(User.t()) :: {binary(), t()}
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {token, %UserToken{token: hash(token), context: "session", user_id: user.id}}
  end

  @doc """
  The query finding the user a session token belongs to.
  """
  @spec verify_session_token_query(binary()) :: {:ok, Ecto.Query.t()}
  def verify_session_token_query(token) do
    # The account rides along. Every page a signed-in person renders needs it,
    # and loading it here — one join in a query that runs anyway — is what
    # spares each LiveView its own lookup on every mount.
    query =
      from user in User,
        join: token in ^by_token_and_context_query(hash(token), "session"),
        on: token.user_id == user.id,
        join: account in assoc(user, :account),
        where: token.inserted_at > ago(@session_validity_days, "day"),
        preload: [account: account]

    {:ok, query}
  end

  @doc """
  Builds an email token. The value handed out is URL-safe, because it goes in a
  link; the value stored is its hash.
  """
  @spec build_email_token(User.t(), String.t()) :: {String.t(), t()}
  def build_email_token(user, context) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hash(token),
       context: context,
       sent_to: user.email,
       user_id: user.id
     }}
  end

  @doc """
  The query finding the user an email token belongs to.

  Requires that the address the token was sent to is still the user's address.
  Without that, somebody could request a confirmation, change their email to
  one they do not own, and confirm it with the old link.
  """
  @spec verify_email_token_query(String.t(), String.t()) :: {:ok, Ecto.Query.t()} | :error
  def verify_email_token_query(token, context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> {:ok, valid_token_query(hash(decoded), context)}
      :error -> :error
    end
  end

  # One query per lifetime rather than one query with the interval
  # interpolated: the unit and the number both go into the SQL, so they have to
  # be literals here.
  defp valid_token_query(hashed, "reset_password" = context) do
    from [token: token, user: user] in bound_query(hashed, context),
      where: token.inserted_at > ago(@reset_validity_hours, "hour"),
      select: user
  end

  defp valid_token_query(hashed, context) do
    from [token: token, user: user] in bound_query(hashed, context),
      where: token.inserted_at > ago(@confirm_validity_days, "day"),
      select: user
  end

  defp bound_query(hashed, context) do
    from token in by_token_and_context_query(hashed, context),
      as: :token,
      join: user in assoc(token, :user),
      as: :user,
      where: token.sent_to == user.email
  end

  @doc """
  Every token belonging to a user in the given contexts, for deleting.
  """
  @spec by_user_and_contexts_query(User.t(), [String.t()] | :all) :: Ecto.Query.t()
  def by_user_and_contexts_query(user, :all) do
    from t in UserToken, where: t.user_id == ^user.id
  end

  def by_user_and_contexts_query(user, contexts) when is_list(contexts) do
    from t in UserToken, where: t.user_id == ^user.id and t.context in ^contexts
  end

  @doc """
  The query matching one token row by its already-hashed value.
  """
  @spec by_token_and_context_query(binary(), String.t()) :: Ecto.Query.t()
  def by_token_and_context_query(hashed_token, context) do
    from UserToken, where: [token: ^hashed_token, context: ^context]
  end

  @doc """
  The query matching one token row, given the raw value a client presented.

  Hashing happens here rather than at the call site, because the raw value is
  the only thing a caller ever holds and the stored value is the only thing the
  table ever contains.
  """
  @spec by_raw_token_and_context_query(binary(), String.t()) :: Ecto.Query.t()
  def by_raw_token_and_context_query(raw_token, context) do
    by_token_and_context_query(hash(raw_token), context)
  end

  @doc """
  How long a password reset link lasts, in hours.
  """
  def reset_validity_hours, do: @reset_validity_hours

  defp hash(token), do: :crypto.hash(@hash_algorithm, token)
end
