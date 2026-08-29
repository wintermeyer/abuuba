defmodule AbuubaWeb.SessionController do
  @moduledoc """
  Signing in and out.

  Every failure answers the same way. "No such account" and "wrong password"
  told apart would turn this form into a way to find out who has an account
  here, which for a social server is a list of people worth phishing.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.LoginActivities
  alias Abuuba.Accounts.Registration
  alias Abuuba.Accounts.TwoFactor
  alias Abuuba.Accounts.User
  alias AbuubaWeb.ClientIP
  alias AbuubaWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email, "password" => password} = params}) do
    cond do
      Registration.bot?(params) ->
        # Answered exactly like a wrong password, so a bot cannot tell that the
        # honeypot is what gave it away.
        deny(conn)

      user = Auth.get_user_by_email_and_password(email, password) ->
        case Auth.check_sign_in(user) do
          :ok ->
            continue_or_challenge(conn, user, params)

          {:error, reason} ->
            note(conn, user, success: false, reason: to_string(reason))
            refuse(conn, reason)
        end

      true ->
        # Noted against the account the address belongs to, where there is one.
        # A password attempt on somebody's account is exactly what they need to
        # be able to see, and it is invisible everywhere else on the server.
        note(conn, Auth.get_user_by_email(email), success: false, reason: "bad_password")
        deny(conn)
    end
  end

  def create(conn, _params), do: deny(conn)

  @doc """
  The second step, where the account has a second factor.
  """
  def two_factor(conn, %{"user" => %{"code" => code}}) do
    case pending_user(conn) do
      %User{} = user -> check_second_factor(conn, user, code)
      nil -> deny(conn)
    end
  end

  def two_factor(conn, _params), do: deny(conn)

  # The password alone gets you no session. The pending id is held in the
  # session rather than in the form, so a half-finished sign-in cannot be
  # completed by somebody who only knows the account id.
  defp continue_or_challenge(conn, user, params) do
    if TwoFactor.required?(user) do
      conn
      |> put_session(:pending_user_id, user.id)
      |> put_session(:pending_remember_me, params["remember_me"])
      |> redirect(to: ~p"/login/two-factor")
    else
      note(conn, user, success: true)
      UserAuth.log_in_user(conn, user, params)
    end
  end

  defp check_second_factor(conn, user, code) do
    case verify_second_factor(user, code) do
      :ok ->
        note(conn, user, success: true, method: "two_factor")

        conn
        |> delete_session(:pending_user_id)
        |> UserAuth.log_in_user(user, %{"remember_me" => get_session(conn, :pending_remember_me)})

      :error ->
        note(conn, user, success: false, method: "two_factor", reason: "bad_code")

        conn
        |> put_flash(:error, gettext("That code is not right. Try the next one."))
        |> redirect(to: ~p"/login/two-factor")
    end
  end

  # An authenticator code or a recovery code, in that order. Both are accepted
  # at the same prompt, because somebody reaching for a recovery code has
  # already lost their phone and should not have to find a second form.
  defp verify_second_factor(user, code) do
    case TwoFactor.verify_totp(user, code) do
      {:ok, _user} -> :ok
      {:error, _reason} -> recovery_or_error(user, code)
    end
  end

  defp recovery_or_error(user, code) do
    case TwoFactor.use_recovery_code(user, code) do
      :ok -> :ok
      {:error, _} -> :error
    end
  end

  defp pending_user(conn) do
    case get_session(conn, :pending_user_id) do
      nil -> nil
      id -> Abuuba.Repo.get(User, id)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("You are signed out."))
    |> UserAuth.log_out_user()
  end

  # A note in the margin of signing in. It never raises and its answer is never
  # checked, because a table that could not be written to must not be the
  # reason somebody cannot get in.
  defp note(conn, user, opts) do
    LoginActivities.record(
      user,
      Keyword.merge(
        [ip: ClientIP.of(conn), user_agent: List.first(get_req_header(conn, "user-agent"))],
        opts
      )
    )
  end

  defp deny(conn) do
    conn
    |> put_flash(:error, gettext("That email and password do not match an account."))
    |> redirect(to: ~p"/login")
  end

  # These two are safe to say out loud: both are about an account the person
  # has just proved they hold the password to.
  defp refuse(conn, :unconfirmed) do
    conn
    |> put_flash(:error, gettext("Confirm your email address first. Check your inbox."))
    |> redirect(to: ~p"/login")
  end

  # Deliberately without a reason. A moderator disabled this account, and the
  # place to hear why is the appeal, not a flash message that would also tell
  # somebody trying passwords which accounts are worth their time.
  defp refuse(conn, :disabled) do
    conn
    |> put_flash(:error, gettext("This account has been disabled. Contact the moderators."))
    |> redirect(to: ~p"/login")
  end

  # Same reasoning as `:disabled`, and the same words: a suspension is a
  # moderator's decision to explain in the appeal rather than at the door, and
  # telling somebody which of the two happened tells anybody trying passwords
  # the same thing.
  defp refuse(conn, :suspended), do: refuse(conn, :disabled)

  defp refuse(conn, :pending_approval) do
    conn
    |> put_flash(
      :info,
      gettext("A moderator still has to look at your registration. We will email you.")
    )
    |> redirect(to: ~p"/login")
  end
end
