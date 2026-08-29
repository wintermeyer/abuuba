defmodule Abuuba.Accounts.Auth do
  @moduledoc """
  Registering, signing in, and confirming an address.

  Kept beside `Abuuba.Accounts` rather than inside it because these functions
  answer a different question. `Abuuba.Accounts` is about actors, which are a
  federation concept; this is about credentials, which never leave the server.
  """

  import Ecto.Query

  require Logger

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Registration
  alias Abuuba.Accounts.User
  alias Abuuba.Accounts.UserNotifier
  alias Abuuba.Accounts.UserToken
  alias Abuuba.Invites
  alias Abuuba.Moderation.Signup
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings
  alias Abuuba.Webhooks
  alias Ecto.Multi

  @doc """
  Registers somebody.

  The account, the user and the signing keypair go in as one transaction. Any
  two of the three without the third is an account that federates but cannot
  sign, or one that exists but cannot be logged in to, and neither says so.
  """
  @spec register(map(), keyword()) ::
          {:ok, %{account: Account.t(), user: User.t()}}
          | {:error, :registration_closed | Ecto.Changeset.t()}
  def register(attrs, opts \\ []) do
    changeset = Registration.changeset(attrs, opts)

    # The invite is claimed before anything is written, because a closed server
    # has to answer "may this person sign up at all" before it starts making
    # rows, and the claim is what answers it.
    case invite_for(changeset) do
      {:error, reason} ->
        {:error, reason}

      {:ok, invite} ->
        cond do
          is_nil(invite) and not Settings.registration_open?() ->
            {:error, :registration_closed}

          not changeset.valid? ->
            {:error, Map.put(changeset, :action, :insert)}

          true ->
            screened(changeset, invite, opts)
        end
    end
  end

  @doc """
  Makes an account on an admin's say-so.

  Skips the two gates `register/2` exists to enforce: whether the server is
  open to sign-ups, and the sign-up block lists. Both answer the question "may
  this stranger make an account here", and somebody at a shell on this server
  is not that stranger — an admin who has to open registrations to add one
  account has to open them to everybody for as long as it takes.

  The account is confirmed and approved on the way in for the same reason:
  nobody is going to send a confirmation link to an address the admin just
  typed, and an account waiting for approval that the approver just created is
  a queue entry for nothing.
  """
  @spec create_by_admin(map()) ::
          {:ok, %{account: Account.t(), user: User.t()}} | {:error, Ecto.Changeset.t()}
  def create_by_admin(attrs) do
    changeset = Registration.changeset(attrs, rules_required: false, reason_required: false)

    if changeset.valid? do
      insert_registration(changeset, nil, [],
        approved: true,
        approved_at: DateTime.utc_now(),
        confirmed_at: DateTime.utc_now()
      )
    else
      {:error, Map.put(changeset, :action, :insert)}
    end
  end

  # The block lists are asked after the form is valid and before anything is
  # written. A refusal comes back on the field it is about, because "your email
  # address cannot be used here" is an answer somebody can act on and "computer
  # says no" is not.
  defp screened(changeset, invite, opts) do
    attrs = %{
      email: Registration.email(changeset),
      username: Registration.username(changeset),
      ip: Keyword.get(opts, :ip)
    }

    case Signup.check(attrs, opts) do
      :ok ->
        insert_registration(changeset, invite, opts)

      # `approved_at` has to go with it. The pair is what tells an account
      # waiting for a moderator apart from one whose login was taken away, and
      # a false flag with a time still on it is the second: invisible to the
      # pending queue, unapprovable, and told at sign-in that it is disabled.
      {:approval, _reason} ->
        insert_registration(changeset, invite, opts, approved: false, approved_at: nil)

      {:error, reason} ->
        {:error, refusal(changeset, reason)}
    end
  end

  defp refusal(changeset, reason) do
    {field, message} = refusal_message(reason)

    changeset
    |> Ecto.Changeset.add_error(field, message)
    |> Map.put(:action, :insert)
  end

  defp refusal_message(:username_blocked), do: {:username, "cannot be used on this server"}

  # Deliberately not "that account was deleted". The name belonged to somebody,
  # and whether they left is theirs to say rather than this form's.
  defp refusal_message(:username_taken), do: {:username, "has already been taken"}

  defp refusal_message(:email_blocked), do: {:email, "cannot be used on this server"}
  defp refusal_message(:email_domain_blocked), do: {:email, "cannot be used on this server"}
  defp refusal_message(_reason), do: {:email, "cannot be used from here"}

  @doc """
  Sends what somebody who has just signed up is owed.

  Two front doors reach this — the web form and the API — and they were sending
  different mail: the flag they each branched on disagreed about somebody
  invited onto a moderated server, who was let straight in and told anyway that
  a moderator would read their registration. One function, so the next mail
  added here is added once.

  A delivery that fails does not fail the sign-up. The account exists, the
  username is taken and the token is issued; raising here would leave all three
  behind with no answer to the caller and no way to try again.
  """
  @spec deliver_signup_mail(User.t(), (String.t() -> String.t())) :: :ok
  def deliver_signup_mail(%User{} = user, confirm_url) do
    with {:ok, token} <- create_confirmation_token(user) do
      UserNotifier.deliver_confirmation(user, confirm_url.(token))
    end

    if not user.approved, do: UserNotifier.deliver_pending_approval(user)

    :ok
  rescue
    error ->
      Logger.error("sign-up mail for #{user.id} could not be sent: #{inspect(error)}")

      :ok
  end

  # An invite is a named person vouching, which is what a closed or moderated
  # sign-up leaves room for. A code that is wrong is refused outright rather
  # than quietly ignored: somebody who typed one meant to use it.
  defp invite_for(changeset) do
    case Registration.invite_code(changeset) do
      code when code in [nil, ""] ->
        {:ok, nil}

      code ->
        case Invites.claim(code) do
          {:ok, invite} -> {:ok, invite}
          {:error, _reason} -> {:error, :invalid_invite}
        end
    end
  end

  defp insert_registration(changeset, invite, opts, overrides \\ []) do
    Multi.new()
    |> Multi.insert(
      :account,
      Account.changeset(%Account{}, Registration.account_attrs(changeset))
    )
    |> Multi.insert(:user, fn %{account: account} ->
      attrs =
        changeset
        |> Registration.user_attrs(account.id, invite)
        |> Map.put(:sign_up_ip, Keyword.get(opts, :ip))
        # Recorded so that resending the confirmation mail can be limited to
        # the app that made the account. Absent for a browser sign-up, which
        # reads as "no app may do this on their behalf".
        |> Map.put(:created_by_application_id, Keyword.get(opts, :application_id))
        |> Map.merge(Map.new(overrides))

      %User{}
      |> User.changeset(attrs)
      |> User.password_changeset(%{password: Registration.password(changeset)})
    end)
    |> Multi.run(:keypair, fn _repo, %{account: account} ->
      Accounts.create_keypair(account)
    end)
    |> Multi.run(:founder, fn _repo, %{user: user} -> maybe_found_server(user) end)
    |> Repo.transaction()
    |> case do
      # `:founder` rather than `:user`: the row was updated after it was
      # inserted, and the struct under `:user` is the one from before that.
      # Handing it back would tell the caller the founder is still waiting for
      # approval, and the caller decides from it which mail to send.
      {:ok, %{account: account, founder: user}} ->
        autofollow(account, invite)

        # After the transaction, so a webhook receiver taking four seconds is
        # not four seconds this transaction stays open.
        announce("account.created", user)

        {:ok, %{account: account, user: user}}

      {:error, _step, %Ecto.Changeset{} = failed, _changes} ->
        {:error, merge_errors(changeset, failed)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # The first account on a development server is the one that sets the server
  # up, so it gets two things: a role that can administer, and a way past the
  # approval queue. A server with a fresh database is otherwise an admin area
  # nobody can open, and on a server that moderates sign-ups the founder is the
  # only account that could approve the queue it is sitting in — which it
  # cannot do, because it is waiting in it.
  #
  # Confirming the address still happens. That is a different question from
  # whether a moderator wants you here, and the link is in the development
  # mailbox.
  #
  # Off unless the setting says otherwise, and it is set in `config/dev.exs`
  # alone. On a public server this would mean whoever registers first owns it,
  # which is a takeover by whoever is quickest.
  #
  # Two sign-ups racing could both read a count of one and both be granted it.
  # Left as it is: the branch only runs where the setting is on, which is one
  # person at one keyboard, and the fix would be a lock held across every
  # registration on servers that never take this branch at all.
  defp maybe_found_server(user) do
    if Application.get_env(:abuuba, :first_user_is_admin, false) and first_user?() do
      with {:ok, role} <- Roles.administrator_role(),
           {:ok, user} <- Roles.assign(user, role),
           do: approve(user)
    else
      {:ok, user}
    end
  end

  # `approved_at` goes with `approved` for the reason `screened/3` gives about
  # the opposite case: the pair is what tells these two states apart, and a flag
  # without a time on it is the other one.
  defp approve(user) do
    user
    |> Ecto.Changeset.change(approved: true, approved_at: DateTime.utc_now())
    |> Repo.update()
  end

  # Inside the transaction, so the account being asked about is already there
  # and "first" means this one and no other.
  defp first_user?, do: Repo.aggregate(User, :count) == 1

  # The point of an invite is usually that the two people already know each
  # other, so a new account arrives with somebody to read. Outright even for an
  # account that approves its followers: whoever turned this on for their own
  # invite has already said yes to whoever redeems it.
  defp autofollow(_account, nil), do: :ok
  defp autofollow(_account, %{autofollow: false}), do: :ok

  defp autofollow(account, invite) do
    Relationships.follow(account.id, invite.account_id)

    :ok
  end

  # A uniqueness clash only surfaces at the insert, so the form has to be told
  # about it in the field the person actually filled in.
  defp merge_errors(form_changeset, %Ecto.Changeset{} = failed) do
    Enum.reduce(failed.errors, Map.put(form_changeset, :action, :insert), fn
      {:username, error}, acc -> add_error(acc, :username, error)
      {:email, error}, acc -> add_error(acc, :email, error)
      {_field, _error}, acc -> acc
    end)
  end

  defp add_error(changeset, field, {message, opts}) do
    Ecto.Changeset.add_error(changeset, field, message, opts)
  end

  @doc """
  Finds the user with this email and password, or `nil`.

  Always costs the same whether or not the address exists: see
  `Abuuba.Accounts.User.valid_password?/2`.
  """
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    if User.valid_password?(user, password), do: user
  end

  def get_user_by_email_and_password(_email, _password) do
    User.valid_password?(nil, "")
    nil
  end

  @doc """
  Finds a user by email, case-insensitively.
  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    User
    |> where([u], fragment("lower(?)", u.email) == ^String.downcase(String.trim(email)))
    |> Repo.one()
  end

  def get_user_by_email(_email), do: nil

  ## Sessions

  @doc """
  Issues a session token.
  """
  @spec create_session_token(User.t()) :: binary()
  def create_session_token(%User{} = user) do
    # Stamped here because this is the one place a session begins. The fan-out
    # uses it to skip feeds nobody is reading, so a stamp that only some sign-in
    # paths set would quietly stop delivering to real people.
    #
    # `update_all` on the id rather than a changeset update: a changeset update
    # of a row this transaction did not read is a row lock taken in whatever
    # order the caller happens to run in, and two of those against the same
    # user is a deadlock nobody can see from here.
    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(set: [last_signed_in_at: DateTime.utc_now()])

    {token, row} = UserToken.build_session_token(user)
    Repo.insert!(row)
    token
  end

  @doc """
  The user a session token belongs to, or `nil`.
  """
  @spec get_user_by_session_token(binary() | nil) :: User.t() | nil
  def get_user_by_session_token(nil), do: nil

  def get_user_by_session_token(token) when is_binary(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def get_user_by_session_token(_token), do: nil

  @doc """
  Ends one session.
  """
  @spec delete_session_token(binary()) :: :ok
  def delete_session_token(token) when is_binary(token) do
    Repo.delete_all(UserToken.by_raw_token_and_context_query(token, "session"))

    :ok
  end

  def delete_session_token(_token), do: :ok

  @doc """
  Ends every session a user has, which is what a password change should do.
  """
  @spec delete_all_session_tokens(User.t()) :: :ok
  def delete_all_session_tokens(%User{} = user) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["session"]))
    :ok
  end

  ## Confirmation

  @doc """
  Builds a confirmation token and records that one was sent.

  Returns the token so the caller can put it in a URL. Nothing here sends mail;
  that is `Abuuba.Accounts.UserNotifier`'s job, and keeping them apart means a
  test can confirm an address without a mailbox.
  """
  @spec create_confirmation_token(User.t()) :: {:ok, String.t()}
  def create_confirmation_token(%User{} = user) do
    {token, row} = UserToken.build_email_token(user, "confirm")

    Repo.insert!(row)
    Repo.update!(Ecto.Changeset.change(user, confirmation_sent_at: DateTime.utc_now()))

    {:ok, token}
  end

  @doc """
  Confirms an address from a token.

  Confirming consumes every confirmation token the user has, so a link cannot
  be replayed and an older link cannot be used later.
  """
  @spec confirm_user(String.t()) :: {:ok, User.t()} | :error
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_multi(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp confirm_multi(user) do
    Multi.new()
    |> Multi.update(:user, User.confirm_changeset(user))
    |> Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, ["confirm"]))
  end

  ## Password reset

  @doc """
  Builds a reset token for somebody who says they cannot get in.

  Nothing here sends mail: that is `Abuuba.Accounts.PasswordResetWorker`, and
  keeping them apart means a test can reset a password without a mailbox.

  Issuing one retires any link already outstanding. Otherwise asking twice
  because the first mail was slow leaves two live links and a row per ask,
  and somebody who can make the form fire repeatedly can fill the table.
  """
  @spec create_reset_token(User.t()) :: {:ok, String.t()}
  def create_reset_token(%User{} = user) do
    {token, row} = UserToken.build_email_token(user, "reset_password")

    Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["reset_password"]))
    Repo.insert!(row)

    {:ok, token}
  end

  @doc """
  The user a reset token belongs to, or `nil`.

  For the form that asks for the new password: it has to know the link is
  good before showing the field, or somebody types a password into a page
  that then tells them the link expired.
  """
  @spec get_user_by_reset_token(String.t()) :: User.t() | nil
  def get_user_by_reset_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  def get_user_by_reset_token(_token), do: nil

  @doc """
  Sets a new password from a reset token.

  Everything that could still be somebody else goes in the same transaction:
  every reset token, so the link is single-use and any older link is dead;
  every session; and every OAuth token, because an app that stayed signed in
  keeps whoever installed it signed in too. Somebody resetting a password is
  usually somebody who believes another person is in their account, and
  leaving them there would make the reset theatre.

  A second factor is deliberately untouched. A reset proves control of the
  mailbox, and a mailbox is exactly what the second factor exists to survive.

  An unconfirmed address becomes confirmed. Following the link is the same
  proof that confirmation asks for, and leaving somebody with a working
  password they still cannot sign in with helps nobody.
  """
  @spec reset_password(String.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()} | :error
  def reset_password(token, attrs) do
    case get_user_by_reset_token(token) do
      %User{} = user -> write_new_password(user, attrs)
      nil -> :error
    end
  end

  defp write_new_password(user, attrs) do
    Multi.new()
    |> Multi.update(:user, User.password_changeset(user, attrs))
    |> Multi.update(:confirmed, fn %{user: user} -> confirm_if_new(user) end)
    |> Multi.delete_all(
      :tokens,
      UserToken.by_user_and_contexts_query(user, ["reset_password", "session"])
    )
    |> OAuth.revoke_all_multi(user)
    |> Repo.transaction()
    |> case do
      {:ok, %{confirmed: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
      _ -> :error
    end
  end

  defp confirm_if_new(%User{confirmed_at: nil} = user), do: User.confirm_changeset(user)
  defp confirm_if_new(%User{} = user), do: Ecto.Changeset.change(user)

  @doc """
  Approves a pending registration.
  """
  @spec approve_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def approve_user(%User{} = user) do
    with {:ok, approved} <- user |> User.approve_changeset() |> Repo.update() do
      announce("account.approved", approved)

      {:ok, approved}
    end
  end

  # What a moderation tool listens for. The account rather than the user, and
  # nothing about the address: a webhook receiver is another system with its
  # own logs, and an email address that leaves here does not come back.
  defp announce(event, %User{} = user) do
    case Accounts.get_account(user.account_id) do
      nil ->
        :ok

      account ->
        Webhooks.announce(event, %{
          "id" => to_string(account.id),
          "username" => account.username,
          "created_at" => DateTime.to_iso8601(account.inserted_at)
        })
    end
  end

  @doc """
  Registrations waiting for a moderator, oldest first.
  """
  @spec pending_approval() :: [User.t()]
  def pending_approval do
    # Not simply "not approved": somebody a moderator disabled is also not
    # approved, and listing them here would offer a moderator the chance to
    # approve away another moderator's decision.
    User.pending()
    |> order_by([u], asc: u.id)
    |> Repo.all()
  end

  @doc """
  Why a user may not use this server, or `:ok`.

  Answers in a shape the caller can turn into a message, rather than a bare
  boolean that leaves the caller guessing which of the gates was shut.

  Asked when somebody signs in and again on every request that carries a
  session, because all four answers can change while somebody is signed in and
  three of them are a moderator deciding they should stop. Checking only at
  the door meant a suspension took effect whenever the person next happened to
  sign out.

  Suspension is read from the account rather than the user: it is the one that
  hides the posts as well, and it left the website open while the API had
  refused it from the start.
  """
  @spec check_sign_in(User.t()) ::
          :ok | {:error, :unconfirmed | :pending_approval | :disabled | :suspended}
  def check_sign_in(%User{} = user) do
    cond do
      User.disabled?(user) -> {:error, :disabled}
      suspended?(user) -> {:error, :suspended}
      not User.confirmed?(user) -> {:error, :unconfirmed}
      not user.approved -> {:error, :pending_approval}
      true -> :ok
    end
  end

  defp suspended?(%User{account: %Account{suspended_at: %DateTime{}}}), do: true
  defp suspended?(%User{account: %Account{}}), do: false

  # An account that could not be loaded is one we cannot vouch for, and the
  # API has always answered that the same way: "we could not check" means no.
  defp suspended?(%User{account_id: account_id}) do
    case Repo.get(Account, account_id) do
      %Account{suspended_at: nil} -> false
      _suspended_or_missing -> true
    end
  end
end
