defmodule Abuuba.EmailSubscriptions.Notifier do
  @moduledoc """
  What goes to an address on somebody's list.

  Two messages: the one an unconfirmed address is allowed to receive, and the
  updates that follow once it has confirmed. Both carry the link that stops
  them, because a subscription that cannot be undone from inside its own mail
  is one somebody has to write to an admin about.
  """

  use Gettext, backend: AbuubaWeb.Gettext

  alias Abuuba.Accounts.Account
  alias Abuuba.EmailSubscriptions.Message
  alias Abuuba.EmailSubscriptions.Subscription
  alias Abuuba.Mail

  @doc """
  Asks an address whether it really wants this.
  """
  @spec deliver_confirmation(Account.t(), Subscription.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_confirmation(%Account{} = account, %Subscription{} = subscription) do
    Mail.deliver_in_locale(subscription.email, subscription.locale, fn ->
      name = display_name(account)

      {gettext("Confirm that you want updates from %{name}", name: name),
       """
       #{gettext("Hi,")}

       #{gettext("somebody gave this address to receive updates from %{name} on %{site}. If that was you, confirm it here:", name: name, site: Mail.site_title())}

       #{url(subscription)}

       #{gettext("If it was not you, you can ignore this message. Nothing else will be sent to this address.")}
       """}
    end)
  end

  @doc """
  One update, to an address that confirmed it wanted them.

  The way out rides along in two places: as a link in the text, for somebody
  reading, and as `List-Unsubscribe`, for the mail client that offers its own
  button. Either one has to be enough on its own.
  """
  @spec deliver_update(Account.t(), Subscription.t(), Message.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_update(%Account{} = account, %Subscription{} = subscription, %Message{} = message) do
    Mail.deliver_in_locale(
      subscription.email,
      subscription.locale,
      fn ->
        {message.subject,
         """
         #{message.body}

         --
         #{gettext("You are receiving this because you asked for updates from %{name} on %{site}.", name: display_name(account), site: Mail.site_title())}

         #{gettext("To stop them, open this link:")}

         #{url(subscription)}
         """}
      end,
      unsubscribe_url: url(subscription)
    )
  end

  defp display_name(%Account{display_name: name, username: username}) do
    if name in [nil, ""], do: "@" <> username, else: name
  end

  # The one link the message needs. It is the same page for confirming and for
  # unsubscribing, so somebody who opens an old message still lands somewhere
  # that can act on it.
  defp url(%Subscription{token: token}) do
    AbuubaWeb.Endpoint.url() <> "/email_subscriptions/" <> token
  end
end
