defmodule Abuuba.WebPush do
  @moduledoc """
  Telling a browser something happened while nobody was looking at it.

  ## The payload is small on purpose

  Enough to draw the notification and nothing more: who, what type, a title and
  a body cut at 140 characters. A push service is somebody else's server and
  the browser may keep the message on disk, so the less that travels the less
  there is to leak if the encryption is ever wrong. The notification's id goes
  along so the app can fetch the whole thing when somebody taps it.

  ## A refusal destroys the subscription

  A 4xx from a push service means the endpoint is gone, and it does not come
  back: browsers renew subscriptions rather than repairing them. Retrying is
  how a server ends up pushing to thousands of dead endpoints forever. The
  exceptions are 408 and 429, which mean "not now" rather than "not ever".
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Notifications.Notification
  alias Abuuba.OAuth.AccessToken
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Statuses.Formatter
  alias Abuuba.WebPush.Subscription

  @body_limit 140

  @doc """
  What one device asked for, or `nil`.
  """
  @spec get_subscription(AccessToken.t() | integer() | nil) :: Subscription.t() | nil
  def get_subscription(nil), do: nil
  def get_subscription(%AccessToken{id: id}), do: get_subscription(id)

  def get_subscription(access_token_id) do
    Repo.get_by(Subscription, access_token_id: access_token_id)
  end

  @doc """
  Records where a device wants to be reached.

  Replaces whatever that token had before rather than adding to it. One token
  is one app on one device, and a device that re-subscribes is telling us its
  old endpoint is dead.
  """
  @spec subscribe(AccessToken.t(), Account.t(), map()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(%AccessToken{id: token_id}, %Account{id: account_id}, attrs) do
    attrs =
      attrs
      |> Map.merge(%{"access_token_id" => token_id, "account_id" => account_id})

    case get_subscription(token_id) do
      nil -> %Subscription{}
      existing -> existing
    end
    |> Subscription.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Changes which types a device wants without re-registering it.
  """
  @spec update_subscription(Subscription.t(), map()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def update_subscription(%Subscription{} = subscription, attrs) do
    subscription |> Subscription.changeset(attrs) |> Repo.update()
  end

  @doc """
  Forgets one.
  """
  @spec unsubscribe(Subscription.t()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def unsubscribe(%Subscription{} = subscription), do: Repo.delete(subscription)

  @doc """
  Forgets whatever a token had registered, because the token is going.

  Revoking is somebody taking an app's access away, and a push subscription is
  the one thing that keeps working afterwards without anybody looking at it:
  the app is not asking for anything, the server is sending. The foreign key
  cannot do this, because revoking marks the token rather than deleting it.
  """
  @spec forget_token(AccessToken.t() | integer()) :: :ok
  def forget_token(%AccessToken{id: id}), do: forget_token(id)

  def forget_token(access_token_id), do: forget_tokens([access_token_id])

  @doc """
  The same for several at once, for the paths that revoke in bulk.

  Signing an app out and resetting a password both mark rows with `update_all`
  rather than going through `revoke_token/1`, and a password reset is the case
  that matters most: somebody doing that usually believes another person is in
  their account, and a registered device is the quietest thing to leave behind.
  """
  @spec forget_tokens([integer()]) :: :ok
  def forget_tokens([]), do: :ok

  def forget_tokens(access_token_ids) do
    Subscription
    |> where([s], s.access_token_id in ^access_token_ids)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Every subscription registered by any of somebody's tokens, as a query.

  A query rather than a call, so a password reset can delete these inside the
  same transaction that revokes the tokens: doing it afterwards means a crash
  in between leaves the password changed and the devices still registered.
  """
  @spec of_user_query(integer()) :: Ecto.Query.t()
  def of_user_query(user_id) do
    tokens = from(t in AccessToken, where: t.user_id == ^user_id, select: t.id)

    from(s in Subscription, where: s.access_token_id in subquery(tokens))
  end

  @doc """
  Every device that asked to hear about this notification.
  """
  @spec subscriptions_for(Notification.t()) :: [Subscription.t()]
  def subscriptions_for(%Notification{} = notification) do
    Subscription
    |> where([s], s.account_id == ^notification.account_id)
    # A subscription that outlives its token must fail closed. `forget_token/1`
    # is what removes these, and this is the backstop for anything that ever
    # revokes a token without going through it: the alternative to a join here
    # is a server that keeps pushing to an app whose access is gone, which is
    # the exact thing revoking was for.
    |> join(:inner, [s], t in AccessToken, on: t.id == s.access_token_id)
    |> where([_s, t], is_nil(t.revoked_at))
    |> Repo.all()
    |> Enum.filter(fn subscription ->
      Subscription.wants?(subscription, notification.type) and
        allowed_by_policy?(subscription, notification)
    end)
  end

  # The policy on a subscription, which was stored and validated and read
  # nowhere -- so every device behaved as `all`, and somebody who asked for no
  # pushes at all got every one of them.
  #
  # Absent means `all`, deliberately: a device that never named a policy did
  # not ask to be filtered, and defaulting the other way would silence every
  # subscription that already exists.
  defp allowed_by_policy?(%Subscription{policy: policy}, %Notification{} = notification) do
    case policy do
      nil ->
        true

      "all" ->
        true

      "none" ->
        false

      "followed" ->
        Relationships.following?(notification.account_id, notification.from_account_id)

      "follower" ->
        Relationships.following?(notification.from_account_id, notification.account_id)

      _unknown ->
        true
    end
  end

  @doc """
  What travels to the browser.

  Deliberately thin. The id is what lets the app fetch the whole notification
  when somebody taps it, so nothing else has to be here.
  """
  @spec payload(Notification.t(), Subscription.t(), String.t()) :: map()
  def payload(%Notification{} = notification, %Subscription{}, raw_token) do
    from = Repo.get(Account, notification.from_account_id)
    name = display_name(from)

    %{
      "access_token" => raw_token,
      "notification_id" => to_string(notification.id),
      "notification_type" => notification.type,
      "preferred_locale" => "en",
      "title" => title(notification.type, name),
      "body" => body(notification),
      "icon" => nil
    }
  end

  @doc """
  How much of a post travels.
  """
  @spec body_limit() :: pos_integer()
  def body_limit, do: @body_limit

  defp title("mention", name), do: "#{name} mentioned you"
  defp title("reblog", name), do: "#{name} boosted your post"
  defp title("favourite", name), do: "#{name} favourited your post"
  defp title("follow", name), do: "#{name} followed you"
  defp title("follow_request", name), do: "#{name} asked to follow you"
  defp title("poll", _name), do: "A poll you voted in has ended"
  defp title("update", name), do: "#{name} edited a post"
  defp title(type, name), do: "#{name}: #{type}"

  # Cut at 140 characters, because a notification is a nudge rather than the
  # post. Whoever taps it gets the whole thing from the API.
  defp body(%Notification{status_id: nil}), do: ""

  defp body(%Notification{status_id: status_id}) do
    case Repo.get(Abuuba.Statuses.Status, status_id) do
      nil ->
        ""

      status ->
        # The words rather than the markup. A post that arrived from another
        # server keeps its HTML in `text`, so slicing the column put "<p>" and
        # a half-closed tag on somebody's lock screen.
        Formatter.plain_text(status.text, limit: @body_limit)
    end
  end

  defp display_name(nil), do: "Somebody"
  defp display_name(%Account{} = account), do: Account.display_name(account)
end
