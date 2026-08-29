defmodule Abuuba.Accounts.UserNotifier do
  @moduledoc """
  The mail a person gets while signing up.

  Every message is written in the recipient's language, which means the locale
  has to be applied before the text is built rather than taken from whatever
  the sending process happened to be set to. A confirmation email arriving in
  English after somebody has signed up in German is a small thing that reads as
  carelessness.
  """

  use Gettext, backend: AbuubaWeb.Gettext

  alias Abuuba.Accounts.User
  alias Abuuba.Accounts.UserToken
  alias Abuuba.Exports.Export
  alias Abuuba.Mail

  @doc """
  Asks somebody to confirm the address they signed up with.
  """
  @spec deliver_confirmation(User.t(), String.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_confirmation(%User{} = user, url) do
    in_locale(user, fn ->
      deliver(user, gettext("Confirm your email address"), """
      #{gettext("Hi,")}

      #{gettext("somebody signed up for %{site} with this address. If it was you, confirm it here:", site: site_title())}

      #{url}

      #{gettext("The link is good for %{days} days.", days: 7)}

      #{gettext("If it was not you, you can ignore this message and nothing will happen.")}
      """)
    end)
  end

  @doc """
  Tells somebody their registration is waiting for a moderator.
  """
  @spec deliver_pending_approval(User.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_pending_approval(%User{} = user) do
    in_locale(user, fn ->
      deliver(user, gettext("Your registration is being reviewed"), """
      #{gettext("Hi,")}

      #{gettext("thanks for signing up for %{site}. A moderator reads every registration here, so there is a wait before you can sign in.", site: site_title())}

      #{gettext("We will email you as soon as somebody has looked at it.")}
      """)
    end)
  end

  @doc """
  Tells somebody they have been let in.
  """
  @spec deliver_approved(User.t(), String.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_approved(%User{} = user, url) do
    in_locale(user, fn ->
      deliver(user, gettext("Your registration was approved"), """
      #{gettext("Hi,")}

      #{gettext("you can now sign in to %{site}:", site: site_title())}

      #{url}
      """)
    end)
  end

  @doc """
  Sends somebody the link that lets them set a new password.

  Says how long the link is good for, because the most common way a reset
  goes wrong is somebody coming back to it the next morning.
  """
  @spec deliver_reset_password(User.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_reset_password(%User{} = user, url) do
    in_locale(user, fn ->
      deliver(user, gettext("Set a new password"), """
      #{gettext("Hi,")}

      #{gettext("somebody asked to set a new password for your account on %{site}. If it was you, do it here:", site: site_title())}

      #{url}

      #{gettext("The link is good for %{hours} hours and works once.", hours: UserToken.reset_validity_hours())}

      #{gettext("If it was not you, you can ignore this message. Your password has not changed.")}
      """)
    end)
  end

  @doc """
  Tells somebody their password has just been changed.

  The whole reset design rests on control of a mailbox being proof, so this is
  the one message that reaches somebody whose mailbox is the thing that was
  taken. Sent after the fact and on purpose: there is nothing they can click
  to undo it, but knowing an hour after rather than a month after is the
  difference between a bad afternoon and a lost account.
  """
  @spec deliver_password_changed(User.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_password_changed(%User{} = user) do
    in_locale(user, fn ->
      deliver(user, gettext("Your password was changed"), """
      #{gettext("Hi,")}

      #{gettext("the password on your %{site} account was just changed, and everywhere you were signed in has been signed out.", site: site_title())}

      #{gettext("If that was you, there is nothing to do.")}

      #{gettext("If it was not, ask for a new password straight away and tell the people who run this server.")}
      """)
    end)
  end

  @doc """
  Tells somebody the copy of their account they asked for is ready.
  """
  @spec deliver_export_ready(User.t(), String.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_export_ready(%User{} = user, url) do
    in_locale(user, fn ->
      deliver(user, gettext("Your archive is ready"), """
      #{gettext("Hi,")}

      #{gettext("the copy of your %{site} account you asked for is built. Download it here:", site: site_title())}

      #{url}

      #{gettext("The file is deleted after %{days} days, because it holds your whole account.", days: Export.lifetime_days())}
      """)
    end)
  end

  defp in_locale(%User{locale: locale}, build), do: Mail.in_locale(locale, build)

  defp deliver(user, subject, body), do: Mail.deliver(user.email, subject, body)

  defp site_title, do: Mail.site_title()
end
