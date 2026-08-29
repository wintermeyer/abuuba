defmodule Abuuba.OAuth do
  @moduledoc """
  The OAuth2 provider.

  Two grants and no others: authorization code with PKCE, and client
  credentials. The password grant hands somebody's password to a third-party
  app, which is the one thing OAuth exists to avoid, and the implicit grant
  puts the token in a URL where it lands in browser history and referrer
  headers. Neither is offered, and asking for one is refused rather than
  ignored.

  See the migration for why tokens neither expire nor refresh.
  """

  import Ecto.Query

  alias Abuuba.Accounts.User
  alias Abuuba.OAuth.AccessToken
  alias Abuuba.OAuth.Application
  alias Abuuba.OAuth.AuthorizationCode
  alias Abuuba.OAuth.Scopes
  alias Abuuba.Repo
  alias Abuuba.WebPush
  alias Ecto.Multi

  @code_validity_seconds 600
  @token_bytes 32

  ## Applications

  @doc """
  Registers an application. Returns the client secret exactly once, because it
  is stored hashed.
  """
  @spec create_application(map()) ::
          {:ok, Application.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_application(attrs) do
    client_id = random_value()
    client_secret = random_value()

    result =
      %Application{}
      |> Application.changeset(attrs)
      |> Ecto.Changeset.put_change(:client_id, client_id)
      |> Ecto.Changeset.put_change(:hashed_client_secret, hash(client_secret))
      |> Ecto.Changeset.put_change(:vapid_key, vapid_key())
      |> Repo.insert()

    with {:ok, application} <- result do
      {:ok, application, client_secret}
    end
  end

  @doc """
  An application by id, or `nil`.
  """
  @spec get_application(integer() | nil) :: Application.t() | nil
  def get_application(nil), do: nil
  def get_application(id), do: Repo.get(Application, id)

  @doc """
  Finds an application by its client id.
  """
  @spec get_application_by_client_id(String.t() | nil) :: Application.t() | nil
  def get_application_by_client_id(nil), do: nil

  def get_application_by_client_id(client_id) when is_binary(client_id) do
    Repo.get_by(Application, client_id: client_id)
  end

  def get_application_by_client_id(_client_id), do: nil

  @doc """
  Whether a client secret is the one this application was issued.
  """
  @spec valid_client_secret?(Application.t(), String.t() | nil) :: boolean()
  def valid_client_secret?(%Application{hashed_client_secret: stored}, secret)
      when is_binary(secret) do
    Plug.Crypto.secure_compare(stored, hash(secret))
  end

  def valid_client_secret?(_application, _secret), do: false

  ## Authorization codes

  @doc """
  Issues an authorization code after somebody has approved the request.

  `plain` PKCE is refused rather than accepted: it puts the verifier itself in
  the authorize request, so anybody who can see that request can complete the
  exchange, which is exactly what PKCE is for.
  """
  @spec create_authorization_code(Application.t(), User.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_redirect_uri | :unsupported_challenge_method}
  def create_authorization_code(%Application{} = application, %User{} = user, opts) do
    redirect_uri = Keyword.fetch!(opts, :redirect_uri)
    scopes = Keyword.fetch!(opts, :scopes)
    challenge = Keyword.get(opts, :code_challenge)
    method = Keyword.get(opts, :code_challenge_method)

    cond do
      not Application.registered_redirect_uri?(application, redirect_uri) ->
        {:error, :invalid_redirect_uri}

      not is_nil(challenge) and method not in ["S256"] ->
        {:error, :unsupported_challenge_method}

      true ->
        code = random_value()

        Repo.insert!(%AuthorizationCode{
          application_id: application.id,
          user_id: user.id,
          hashed_code: hash(code),
          redirect_uri: redirect_uri,
          scopes: Scopes.to_string(scopes),
          code_challenge: challenge,
          code_challenge_method: method,
          expires_at: DateTime.add(DateTime.utc_now(), @code_validity_seconds)
        })

        {:ok, code}
    end
  end

  @doc """
  Exchanges an authorization code for a token.

  Every check here closes a different way of using a stolen code: the code has
  to be unused and unexpired, it has to belong to this application, the
  redirect URI has to be the one it was issued for, and the PKCE verifier has
  to hash to the challenge that was registered with it.
  """
  @spec exchange_authorization_code(String.t(), keyword()) ::
          {:ok, AccessToken.t(), String.t()}
          | {:error, :invalid_grant | :invalid_client | :invalid_verifier}
  def exchange_authorization_code(code, opts) do
    application = Keyword.fetch!(opts, :application)
    redirect_uri = Keyword.get(opts, :redirect_uri)
    verifier = Keyword.get(opts, :code_verifier)

    with %AuthorizationCode{} = record <- get_usable_code(hash(code)),
         :ok <- check_application(record, application),
         :ok <- check_redirect_uri(record, redirect_uri),
         :ok <- check_verifier(record, verifier) do
      consume_code(record)

      issue_token(application, Repo.get!(User, record.user_id), Scopes.parse!(record.scopes))
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :invalid_grant}
    end
  end

  defp get_usable_code(hashed) do
    case Repo.get_by(AuthorizationCode, hashed_code: hashed) do
      nil -> nil
      record -> if AuthorizationCode.usable?(record), do: record
    end
  end

  defp check_application(%{application_id: id}, %Application{id: id}), do: :ok
  defp check_application(_record, _application), do: {:error, :invalid_client}

  # Absent is fine only if the code was issued without one; otherwise it has to
  # match exactly. A code issued for one callback must not be redeemable
  # against another.
  defp check_redirect_uri(%{redirect_uri: issued}, given) do
    if is_nil(given) or given == issued, do: :ok, else: {:error, :invalid_grant}
  end

  defp check_verifier(%{code_challenge: nil}, _verifier), do: :ok
  defp check_verifier(%{code_challenge: _}, nil), do: {:error, :invalid_verifier}

  defp check_verifier(%{code_challenge: challenge}, verifier) do
    computed =
      :sha256
      |> :crypto.hash(verifier)
      |> Base.url_encode64(padding: false)

    if Plug.Crypto.secure_compare(challenge, computed) do
      :ok
    else
      {:error, :invalid_verifier}
    end
  end

  # Marked used rather than deleted, so that a replay is distinguishable from a
  # code that never existed if anybody ever wants to log the difference.
  defp consume_code(record) do
    Repo.update!(Ecto.Changeset.change(record, used_at: DateTime.utc_now()))
  end

  ## Tokens

  @doc """
  Issues an access token for a person, or hands back the one this application
  already holds for them at these scopes.

  Reusing it is Mastodon's behaviour and clients rely on it: issuing a new one
  every time would strand the previous token and fill the authorised-apps list
  with duplicates of the same app.
  """
  @spec issue_token(Application.t(), User.t(), [String.t()]) ::
          {:ok, AccessToken.t(), String.t()}
  def issue_token(%Application{} = application, %User{} = user, scopes) do
    canonical = Scopes.to_string(scopes)

    case existing_token(application, user, canonical) do
      %AccessToken{} = existing ->
        # The raw token is not recoverable, so a caller reaching this branch is
        # re-authorising and needs a usable value. Rotate the stored hash for
        # the same row rather than creating a second one.
        raw = random_value()
        {:ok, rotated} = rotate(existing, raw)
        {:ok, rotated, raw}

      nil ->
        raw = random_value()

        token =
          Repo.insert!(%AccessToken{
            application_id: application.id,
            user_id: user.id,
            hashed_token: hash(raw),
            scopes: canonical
          })

        {:ok, token, raw}
    end
  end

  @doc """
  Issues a token for the application itself, with no user behind it.
  """
  @spec issue_client_credentials_token(Application.t(), [String.t()]) ::
          {:ok, AccessToken.t(), String.t()}
  def issue_client_credentials_token(%Application{} = application, scopes) do
    raw = random_value()

    token =
      Repo.insert!(%AccessToken{
        application_id: application.id,
        user_id: nil,
        hashed_token: hash(raw),
        scopes: Scopes.to_string(scopes)
      })

    {:ok, token, raw}
  end

  @doc """
  Finds a live token by the value a client presented.
  """
  @spec get_token(String.t() | nil) :: AccessToken.t() | nil
  def get_token(nil), do: nil

  def get_token(raw) when is_binary(raw) do
    AccessToken
    |> where([t], t.hashed_token == ^hash(raw) and is_nil(t.revoked_at))
    # The account comes along because every API request checks whether it is
    # suspended before doing anything, and that is one query either way.
    #
    # Joined rather than preloaded. `preload([:application, user: :account])`
    # is three more round trips after the token itself, and this runs on every
    # authenticated request the server answers. Left joins throughout, because
    # a client-credentials token has no user behind it and must still come back.
    |> join(:left, [t], app in assoc(t, :application))
    |> join(:left, [t], u in assoc(t, :user))
    |> join(:left, [t, _app, u], a in assoc(u, :account))
    |> preload([t, app, u, a], application: app, user: {u, account: a})
    |> Repo.one()
  end

  def get_token(_raw), do: nil

  @doc """
  Revokes a token.

  Also removes anything that was only reachable through it. Push subscriptions
  are the case that matters: leaving one behind means a revoked app keeps being
  told about the person's notifications, which is exactly what revoking was
  meant to stop.
  """
  @spec revoke_token(AccessToken.t()) :: :ok
  def revoke_token(%AccessToken{} = token) do
    delete_push_subscriptions(token)

    Repo.update!(Ecto.Changeset.change(token, revoked_at: DateTime.utc_now()))

    # And the live stream, which authenticates once when it connects and would
    # otherwise go on delivering posts and notifications to a token nobody has
    # any more. It is the one connection that can outlive this decision by
    # hours, and the one somebody signing out everywhere is least likely to
    # think of.
    Abuuba.Streaming.revoked(token.id)

    :ok
  end

  @doc """
  Revokes the token a client presented, if the client owns it.
  """
  @spec revoke_presented_token(Application.t(), String.t()) :: :ok
  def revoke_presented_token(%Application{id: app_id}, raw) do
    case get_token(raw) do
      %AccessToken{application_id: ^app_id} = token -> revoke_token(token)
      # Revocation answers the same way whether or not the token existed, so
      # the endpoint cannot be used to find out whether one is valid.
      _ -> :ok
    end
  end

  @doc """
  The applications a person has authorised, each with what it may do.

  One entry per application and not per token. An app signed in twice holds two
  tokens, and the answer to "what may this app do" is everything either of them
  carries: showing one token's scopes would understate what the app can reach,
  and showing two rows for one app would ask somebody to work out that they are
  the same app.
  """
  @spec authorized_applications(User.t()) :: [{Application.t(), [String.t()]}]
  def authorized_applications(%User{id: user_id}) do
    AccessToken
    |> where([t], t.user_id == ^user_id and is_nil(t.revoked_at))
    |> join(:inner, [t], a in assoc(t, :application))
    |> select([t, a], {a, t.scopes})
    |> Repo.all()
    # The column is one space-separated string per token, so it is split here
    # rather than handed on: a caller that received it whole would describe
    # "read:statuses write:media" as one scope nobody has heard of.
    #
    # Split rather than parsed. `Scopes.parse!/1` raises on a scope it does not
    # know, and this is read by a screen showing somebody what they agreed to —
    # a stored token carrying a scope this build has since renamed would take
    # the whole page down rather than looking odd on one line.
    |> Enum.group_by(fn {application, _scopes} -> application end, fn {_application, scopes} ->
      scopes |> to_string() |> String.split(~r/\s+/, trim: true)
    end)
    |> Enum.map(fn {application, scopes} ->
      {application, scopes |> List.flatten() |> Enum.uniq()}
    end)
    |> Enum.sort_by(fn {application, _scopes} -> application.name end)
  end

  @doc """
  Takes an application back out of somebody's account.

  Every token that application holds for this person, not the one it happens to
  be using: an app signed in twice would otherwise stay signed in once.
  """
  @spec revoke_application_for(User.t(), integer()) :: :ok
  def revoke_application_for(%User{id: user_id}, application_id) do
    # The ids come back so the live streams can be closed. `update_all` does
    # not go through `revoke_token/1`, so this path has to say so itself --
    # an app signed in twice would otherwise keep one stream open after being
    # signed out.
    {_count, ids} =
      AccessToken
      |> where([t], t.user_id == ^user_id and t.application_id == ^application_id)
      |> where([t], is_nil(t.revoked_at))
      |> select([t], t.id)
      |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

    Enum.each(ids || [], &Abuuba.Streaming.revoked/1)
    WebPush.forget_tokens(ids || [])

    :ok
  end

  @doc """
  Every write a password reset has to make to this table, as a multi.

  Somebody resetting their password usually believes another person is in
  their account, and an app that stayed signed in would keep that person
  there: a session cookie is not the only way in.

  Authorization codes go too, and that is the half it is easy to miss. A code
  is a token that has not been collected yet — anybody who approved an app
  before the reset and simply did not redeem the code could redeem it after,
  and be handed a fresh live token by a server that thinks it just locked
  everybody out. They are marked used rather than deleted, which is what the
  exchange already checks.

  A multi rather than a function that does the writes, so the caller can put
  them in the same transaction as the password itself. Revoking after the
  commit means a crash in between leaves the password changed, the link
  burnt, and every app still signed in.
  """
  @spec revoke_all_multi(Multi.t(), User.t()) :: Multi.t()
  def revoke_all_multi(multi, %User{id: user_id}) do
    now = DateTime.utc_now()

    multi
    |> Multi.update_all(
      :oauth_tokens,
      from(t in AccessToken, where: t.user_id == ^user_id and is_nil(t.revoked_at)),
      set: [revoked_at: now]
    )
    |> Multi.update_all(
      :oauth_codes,
      from(c in AuthorizationCode, where: c.user_id == ^user_id and is_nil(c.used_at)),
      set: [used_at: now]
    )
    |> Multi.delete_all(:push_subscriptions, WebPush.of_user_query(user_id))
  end

  @doc """
  The same, on its own.
  """
  @spec revoke_all_for(User.t()) :: :ok
  def revoke_all_for(%User{} = user) do
    # Read before the transaction and announced after it: the rows are about
    # to stop being findable as live tokens, and there is nothing to close if
    # the transaction does not commit.
    ids = live_token_ids(user)

    {:ok, _changes} = Multi.new() |> revoke_all_multi(user) |> Repo.transaction()

    Enum.each(ids, &Abuuba.Streaming.revoked/1)

    :ok
  end

  defp live_token_ids(%User{id: user_id}) do
    AccessToken
    |> where([t], t.user_id == ^user_id and is_nil(t.revoked_at))
    |> select([t], t.id)
    |> Repo.all()
  end

  defp existing_token(application, user, canonical) do
    AccessToken
    |> where([t], t.application_id == ^application.id and t.user_id == ^user.id)
    |> where([t], t.scopes == ^canonical and is_nil(t.revoked_at))
    |> Repo.one()
  end

  defp rotate(token, raw) do
    token
    |> Ecto.Changeset.change(hashed_token: hash(raw))
    |> Repo.update()
  end

  defp delete_push_subscriptions(token), do: WebPush.forget_token(token)

  defp random_value,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  The digest a secret, token or code is stored as.

  Public because the Mastodon import has to write the same digest for the
  credentials it copies. If this were private and changed, every imported token
  would stop authenticating with nothing failing to compile.
  """
  @spec hash(String.t()) :: String.t()
  def hash(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp vapid_key do
    Elixir.Application.get_env(:abuuba, :vapid_public_key) ||
      64 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
