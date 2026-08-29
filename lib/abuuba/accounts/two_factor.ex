defmodule Abuuba.Accounts.TwoFactor do
  @moduledoc """
  A second factor: an authenticator app, a recovery code, or a security key.

  ## Enrolment is two steps on purpose

  `begin_totp_enrolment/1` creates a secret and hands back the QR code.
  `confirm_totp_enrolment/2` switches the requirement on, and only a correct
  code from the app does that. Turning it on at the first step would lock
  somebody out of their own account for mis-scanning a QR code, which is the
  one failure this feature must not have.

  ## Codes cannot be replayed

  A TOTP code stays valid for its whole 30-second window, so somebody who reads
  one over a shoulder or off a phished form has the rest of that window to use
  it too. The last accepted timestamp is stored and a code from a window that
  has already been used is refused.
  """

  import Ecto.Query

  alias Abuuba.Accounts.RecoveryCode
  alias Abuuba.Accounts.User
  alias Abuuba.Accounts.WebauthnCredential
  alias Abuuba.Repo

  @issuer "abuuba"

  # One window either side, because phone clocks drift and people start typing
  # a code at 29 seconds. Wider than that starts to matter: each extra window
  # is another 30 seconds in which a stolen code still works.
  @window_tolerance 1
  @period 30

  @doc """
  Whether the user has to present a second factor.
  """
  @spec required?(User.t()) :: boolean()
  def required?(%User{otp_required_at: nil}), do: false
  def required?(%User{}), do: true

  @doc """
  Starts enrolment. Returns the secret, the URI an authenticator app scans, and
  that URI as an SVG QR code.

  Nothing is required of the user yet: see `confirm_totp_enrolment/2`.
  """
  @spec begin_totp_enrolment(User.t()) ::
          {:ok, %{secret: binary(), uri: String.t(), qr_code: String.t()}}
  def begin_totp_enrolment(%User{} = user) do
    secret = NimbleTOTP.secret()

    {:ok, _} =
      user
      |> Ecto.Changeset.change(otp_secret: secret, otp_required_at: nil)
      |> Repo.update()

    uri = NimbleTOTP.otpauth_uri("#{@issuer}:#{user.email}", secret, issuer: @issuer)

    {:ok, %{secret: secret, uri: uri, qr_code: qr_svg(uri)}}
  end

  @doc """
  Finishes enrolment if the code proves the app is set up, and issues the
  recovery codes.

  The plain codes come back exactly once. They are stored hashed, so this is
  the only moment they can be shown.
  """
  @spec confirm_totp_enrolment(User.t(), String.t()) ::
          {:ok, User.t(), [String.t()]} | {:error, :invalid_code | :not_enrolling}
  def confirm_totp_enrolment(%User{otp_secret: nil}, _code), do: {:error, :not_enrolling}

  def confirm_totp_enrolment(%User{} = user, code) do
    if valid_totp?(user, code) do
      {:ok, user} =
        user
        |> Ecto.Changeset.change(
          otp_required_at: DateTime.utc_now(),
          otp_last_used_at: DateTime.utc_now()
        )
        |> Repo.update()

      {:ok, codes} = regenerate_recovery_codes(user)

      {:ok, user, codes}
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  Turns the second factor off and throws away everything belonging to it.
  """
  @spec disable(User.t()) :: {:ok, User.t()}
  def disable(%User{} = user) do
    Repo.delete_all(from c in RecoveryCode, where: c.user_id == ^user.id)
    Repo.delete_all(from c in WebauthnCredential, where: c.user_id == ^user.id)

    user
    |> Ecto.Changeset.change(otp_secret: nil, otp_required_at: nil, otp_last_used_at: nil)
    |> Repo.update()
  end

  @doc """
  Checks a code from the authenticator app, without consuming it.
  """
  @spec valid_totp?(User.t(), String.t()) :: boolean()
  def valid_totp?(%User{otp_secret: secret}, code) when is_binary(secret) and is_binary(code) do
    normalised = String.replace(code, ~r/\s/, "")

    Enum.any?(-@window_tolerance..@window_tolerance, fn offset ->
      NimbleTOTP.valid?(secret, normalised, time: System.os_time(:second) + offset * @period)
    end)
  end

  def valid_totp?(_user, _code), do: false

  @doc """
  Checks a code and consumes its window, so the same code cannot be used twice.
  """
  @spec verify_totp(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_code | :already_used}
  def verify_totp(%User{} = user, code) do
    cond do
      not valid_totp?(user, code) ->
        {:error, :invalid_code}

      replayed?(user) ->
        {:error, :already_used}

      true ->
        user
        |> Ecto.Changeset.change(otp_last_used_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  # Same 30-second window as the last accepted code means the same code.
  defp replayed?(%User{otp_last_used_at: nil}), do: false

  defp replayed?(%User{otp_last_used_at: last}) do
    div(DateTime.to_unix(last), @period) == div(System.os_time(:second), @period)
  end

  ## Recovery codes

  @doc """
  Issues a fresh set of recovery codes, retiring any that came before.

  Returns the plain codes, which is the only time they exist in readable form.
  """
  @spec regenerate_recovery_codes(User.t()) :: {:ok, [String.t()]}
  def regenerate_recovery_codes(%User{} = user) do
    {codes, rows} = RecoveryCode.generate(user)

    Repo.delete_all(from c in RecoveryCode, where: c.user_id == ^user.id)
    Repo.insert_all(RecoveryCode, rows)

    {:ok, codes}
  end

  @doc """
  Spends a recovery code. Each one works once.
  """
  @spec use_recovery_code(User.t(), String.t()) :: :ok | {:error, :invalid_code}
  def use_recovery_code(%User{} = user, code) do
    hashed = RecoveryCode.hash(code)

    query =
      from c in RecoveryCode,
        where: c.user_id == ^user.id and c.hashed_code == ^hashed and is_nil(c.used_at)

    case Repo.update_all(query, set: [used_at: DateTime.utc_now()]) do
      {1, _} -> :ok
      {0, _} -> {:error, :invalid_code}
    end
  end

  @doc """
  How many recovery codes the user has left.
  """
  @spec unused_recovery_code_count(User.t()) :: non_neg_integer()
  def unused_recovery_code_count(%User{} = user) do
    RecoveryCode
    |> where([c], c.user_id == ^user.id and is_nil(c.used_at))
    |> Repo.aggregate(:count)
  end

  ## Security keys

  @doc """
  Stores a registered security key.
  """
  @spec add_webauthn_credential(User.t(), map()) ::
          {:ok, WebauthnCredential.t()} | {:error, Ecto.Changeset.t()}
  def add_webauthn_credential(%User{} = user, attrs) do
    %WebauthnCredential{}
    |> WebauthnCredential.changeset(Map.put(attrs, :user_id, user.id))
    |> Repo.insert()
  end

  @doc """
  A user's registered security keys.
  """
  @spec webauthn_credentials(User.t()) :: [WebauthnCredential.t()]
  def webauthn_credentials(%User{} = user) do
    WebauthnCredential
    |> where([c], c.user_id == ^user.id)
    |> order_by([c], asc: c.id)
    |> Repo.all()
  end

  @doc """
  Records a successful use of a security key.

  A sign count that has not moved forward means the authenticator has been
  cloned, because a real one only ever counts up. The assertion is refused
  rather than merely logged: a cloned key is the one thing the counter exists
  to detect, and accepting it anyway would make storing it pointless.
  """
  @spec record_webauthn_use(WebauthnCredential.t(), non_neg_integer()) ::
          {:ok, WebauthnCredential.t()} | {:error, :possible_clone}
  def record_webauthn_use(%WebauthnCredential{} = credential, sign_count) do
    # A key that always reports zero is not counting at all, which the spec
    # permits; only a counter that moves backwards is evidence of a clone.
    if sign_count == 0 or sign_count > credential.sign_count do
      credential
      |> Ecto.Changeset.change(sign_count: sign_count, last_used_at: DateTime.utc_now())
      |> Repo.update()
    else
      {:error, :possible_clone}
    end
  end

  @doc """
  Removes a security key.
  """
  @spec remove_webauthn_credential(WebauthnCredential.t()) :: :ok
  def remove_webauthn_credential(%WebauthnCredential{} = credential) do
    Repo.delete(credential)
    :ok
  end

  defp qr_svg(uri) do
    uri |> EQRCode.encode() |> EQRCode.svg(width: 240, background_color: :transparent)
  end
end
