defmodule AbuubaWeb.EmailSubscriptionController do
  @moduledoc """
  The page at the end of the link in every subscription email.

  One page for both confirming and stopping, because somebody who opens an old
  message should land somewhere that can act on it rather than on an error
  about which link they clicked.

  ## Why the link does not do the thing

  Following the link only shows the page; confirming and unsubscribing are
  buttons that POST. Mail clients and security scanners fetch every link in a
  message before a person sees it, so a `GET` that confirmed would confirm
  addresses nobody read the mail at, and a `GET` that unsubscribed would
  unsubscribe people who never clicked. One extra click is the price of the
  outcome matching what somebody actually did.
  """

  use AbuubaWeb, :controller

  alias Abuuba.EmailSubscriptions

  def show(conn, %{"token" => token}) do
    with_subscription(conn, token, fn subscription ->
      render(conn, :show,
        subscription: subscription,
        account: subscription.account,
        page_title: gettext("Email updates")
      )
    end)
  end

  def confirm(conn, %{"token" => token}) do
    with_subscription(conn, token, fn subscription ->
      case EmailSubscriptions.confirm(subscription) do
        {:ok, _confirmed} ->
          conn
          |> put_flash(:info, gettext("Your address is confirmed."))
          |> redirect(to: ~p"/")

        # The row went between the page loading and the button being pressed:
        # the other tab unsubscribed, or the sweep took it. Either way the link
        # has stopped being valid, which the page already knows how to say.
        {:error, :gone} ->
          invalid_link(conn)
      end
    end)
  end

  def unsubscribe(conn, %{"token" => token}) do
    with_subscription(conn, token, fn subscription ->
      :ok = EmailSubscriptions.unsubscribe(subscription)

      conn
      |> put_flash(:info, gettext("That address will not get any more updates."))
      |> redirect(to: ~p"/")
    end)
  end

  # A token that is not one and a token that has been unsubscribed already look
  # the same on purpose: a stopped subscription is a row that is gone, and
  # saying so would confirm the address had been subscribed to somebody who
  # only has the link.
  defp with_subscription(conn, token, run) do
    case EmailSubscriptions.by_token(token) do
      nil -> invalid_link(conn)
      subscription -> run.(subscription)
    end
  end

  defp invalid_link(conn) do
    conn
    |> put_flash(:error, gettext("That link is not valid any more."))
    |> redirect(to: ~p"/")
  end
end
