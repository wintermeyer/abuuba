defmodule Abuuba.Streaming do
  @moduledoc """
  Pushing what just happened to whoever is watching.

  ## One process, no Redis

  Phoenix.PubSub inside the same VM as the web server, which is the whole point
  of the architecture: a fediverse server usually runs a separate streaming
  process with a Redis between it and the app, and the reason is that the
  language the app is written in cannot hold tens of thousands of idle
  connections. This one can.

  ## Fan-out is by topic, filtering is per viewer

  A post is published once, to a topic. Every socket subscribed to that topic
  then decides for itself whether its own reader may see it, because the answer
  differs per person: one has blocked the author, another has muted the thread,
  a third cannot see a followers-only post at all. Deciding at publish time
  would mean one message per subscriber and the same visibility rules written
  a second time in the publisher.

  The cost of that is a check per socket rather than per topic, and it is the
  right trade: the check is cheap and getting it wrong shows somebody a post
  that was never addressed to them.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Notifications.Notification
  alias Abuuba.Statuses.Status
  alias Abuuba.Timelines.Broadcast

  @doc """
  Topics a connection may listen on.
  """
  @spec channels() :: [String.t()]
  def channels do
    ~w(
      user user:notification
      public public:local public:remote public:media public:local:media public:remote:media
      hashtag hashtag:local
      direct list
    )
  end

  @doc """
  Announces a new post to everybody who might want it.

  The author's own timeline topic, the public ones where it is public, and one
  per hashtag. A followers-only post is published only to the author's topic,
  and the sockets listening there filter it: publishing it to a public topic
  and relying on the filter would put it one bug away from a stranger.
  """
  @spec publish_status(Status.t()) :: :ok
  def publish_status(%Status{} = status) do
    Enum.each(status_topics(status), &broadcast(&1, "update", status))
  end

  @doc """
  Announces that a post has changed, so nobody is shown the old words.
  """
  @spec publish_update(Status.t()) :: :ok
  def publish_update(%Status{} = status) do
    Broadcast.forget(status)

    Enum.each(status_topics(status), &broadcast(&1, "status.update", status))
  end

  @doc """
  Announces that a post is gone.
  """
  @spec publish_delete(Status.t()) :: :ok
  def publish_delete(%Status{} = status) do
    # Forgotten from the render cache first. A payload that outlived the post
    # it describes would be pushed to whoever asks in the seconds after.
    Broadcast.forget(status)

    Enum.each(status_topics(status), &broadcast(&1, "delete", status))
  end

  @doc """
  Tells one person something happened.
  """
  @spec publish_notification(Notification.t()) :: :ok
  def publish_notification(%Notification{} = notification) do
    broadcast(account_topic(notification.account_id), "notification", notification)
  end

  @doc """
  Says somebody's inbox has changed.

  On their own topic, and read by the `direct` stream. This is what a client
  watching its messages column listens for: upstream sends a `conversation`
  event there and nothing else, and a client given only the post would have the
  message without the thread it belongs to.

  abuuba keeps sending `update` on that stream as well, which upstream does not.
  A client that ignores it is no worse off, and one that wants the post itself
  no longer has to ask for it.
  """
  @spec publish_conversation(integer(), map()) :: :ok
  def publish_conversation(account_id, row) do
    broadcast(account_topic(account_id), "conversation", row)
  end

  @doc """
  Says an announcement has gone up.

  On the public topic, because an announcement is for everybody: a client
  watching any timeline should show it without having subscribed to a stream of
  its own.
  """
  @spec publish_announcement(struct()) :: :ok
  def publish_announcement(announcement) do
    broadcast(announcement_topic(), "announcement", announcement)
  end

  @doc """
  Says an announcement has been taken down.
  """
  @spec publish_announcement_delete(struct()) :: :ok
  def publish_announcement_delete(announcement) do
    broadcast(announcement_topic(), "announcement.delete", announcement)
  end

  @doc """
  Says how many people have now reacted to an announcement with one emoji.

  The count rather than who: one payload goes to everybody, so it cannot say
  whether the reader is among them. A client that reacted knows it did.
  """
  @spec publish_announcement_reaction(integer(), String.t(), non_neg_integer()) :: :ok
  def publish_announcement_reaction(announcement_id, name, count) do
    broadcast(announcement_topic(), "announcement.reaction", %{
      announcement_id: announcement_id,
      name: name,
      count: count
    })
  end

  @doc """
  The topic announcements travel on.

  Not the public one. A client watching only its own timeline is subscribed to
  no public stream at all, and it is exactly the client a server notice has to
  reach -- which is why the reference implementation publishes these to every
  connected account rather than to a public channel. One topic that every
  signed-in socket listens on does the same job without a publish per
  connection.
  """
  @spec announcement_topic() :: String.t()
  def announcement_topic, do: "streaming:announcements"

  @doc """
  Says somebody's filters have changed.

  On their own stream and to them alone. A client applies filters itself,
  against the set it fetched when it connected, so without this it goes on
  hiding by the old rules until it reconnects: a word somebody adds keeps
  appearing in the timeline they are watching, and one they remove stays
  hidden.

  Nothing about the change travels. The client re-reads the filters, which is
  what the reference implementation does and what keeps a filter edit from
  rendering somebody's whole rule set on every keystroke.
  """
  @spec publish_filters_changed(Account.t() | integer()) :: :ok
  def publish_filters_changed(account) do
    broadcast(account_topic(account), "filters_changed", nil)
  end

  @doc """
  The topic one account's own stream lives on.
  """
  @spec account_topic(Account.t() | integer()) :: String.t()
  def account_topic(%Account{id: id}), do: account_topic(id)
  def account_topic(account_id), do: "streaming:account:#{account_id}"

  @doc """
  The topic a hashtag's stream lives on.
  """
  @spec hashtag_topic(String.t()) :: String.t()
  def hashtag_topic(name), do: "streaming:hashtag:#{String.downcase(name)}"

  @doc """
  The public topics.
  """
  @spec public_topic(keyword()) :: String.t()
  def public_topic(opts \\ []) do
    case {Keyword.get(opts, :local, false), Keyword.get(opts, :remote, false)} do
      {true, _} -> "streaming:public:local"
      {_, true} -> "streaming:public:remote"
      _ -> "streaming:public"
    end
  end

  @doc """
  The topic a live connection listens on for its own token being revoked.

  One per token rather than one per account: revoking a single app's access
  must close that app's stream and leave the person's other clients running,
  and an account-wide broadcast could not tell them apart.
  """
  @spec token_topic(integer()) :: String.t()
  def token_topic(token_id), do: "streaming:token:#{token_id}"

  @doc """
  Subscribes a new connection to everything that is about the connection
  itself rather than about a timeline it asked for.

  Both transports call this, and that is the point. abuuba has two -- a
  websocket and a server-sent-events endpoint -- and each is a separate file
  with its own setup. Four things had been added to one and not the other
  before anybody noticed: a reader's blocks and mutes, the timeline-access
  setting, closing on a revoked token, and announcements. Each was invisible
  from the file it was missing from.

  So the two things every connection needs regardless of its stream live here.
  A fifth reaches both transports or neither.
  """
  @spec subscribe_connection(%{
          optional(:token_id) => integer() | nil,
          optional(:account) => struct() | nil
        }) :: :ok
  def subscribe_connection(state) do
    # Whether this token is still any good, for as long as the connection
    # lives. Authentication happens once, at connect, and nothing afterwards
    # re-reads the token -- so without this a revoked one goes on delivering
    # until the client happens to disconnect, and "sign out everywhere" would
    # not include the connection most likely to still be open.
    if state[:token_id], do: subscribe(token_topic(state[:token_id]))

    # Server notices, which belong to whoever is signed in rather than to any
    # one timeline: a client watching only its own stream still has to be told
    # about one, and it subscribes to nothing public.
    if state[:account], do: subscribe(announcement_topic())

    :ok
  end

  @doc """
  Tells every connection holding a token that it is no longer any good.

  The socket authenticates once, when it connects, and nothing afterwards
  re-reads the token -- so without this a revoked one goes on delivering posts
  and notifications until the client happens to disconnect. "Sign out
  everywhere" has to mean the stream too, and the stream is the one connection
  that can outlive the decision by hours.
  """
  @spec revoked(integer()) :: :ok
  def revoked(token_id) do
    Broadcast.announce(token_topic(token_id), {:streaming, :revoked})

    :ok
  end

  @doc """
  Subscribes the calling process to a topic.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic), do: Broadcast.subscribe(topic)

  @doc """
  Unsubscribes it.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic), do: Broadcast.unsubscribe(topic)

  # A post reaches the author's own topic always, the public ones only when it
  # is public, and one topic per hashtag it carries. A followers-only post is
  # never put on a public topic: relying on the per-socket filter to hold it
  # back would put it one bug away from a stranger.
  defp status_topics(%Status{} = status) do
    # The author's own topic, and the topic of everybody here who follows them.
    # A reader's stream is their own topic, so without this a post would reach
    # only the person who wrote it: the socket has no way to subscribe to a
    # follow set that changes while it is open.
    #
    # Queried per post for now. The materialised feed makes this a read of the
    # same set it is already writing, which is what it is for.
    own = [account_topic(status.account_id) | follower_topics(status)]

    public =
      if status.visibility == :public do
        [
          public_topic(),
          if(status.local, do: public_topic(local: true), else: public_topic(remote: true))
        ]
      else
        []
      end

    tags =
      if status.visibility in [:public, :unlisted] do
        Enum.map(tag_names(status), &hashtag_topic/1)
      else
        []
      end

    own ++ public ++ tags
  end

  # Local followers only. A remote follower's stream is their own server's
  # problem, and they hear about the post through delivery instead.
  defp follower_topics(%Status{} = status) do
    import Ecto.Query

    Abuuba.Relationships.Follow
    |> join(:inner, [f], a in Abuuba.Accounts.Account, on: a.id == f.account_id)
    |> where([f, a], f.target_account_id == ^status.account_id and is_nil(a.domain))
    |> select([f], f.account_id)
    |> Abuuba.Repo.all()
    |> Enum.map(&account_topic/1)
  end

  defp tag_names(%Status{id: status_id}) do
    import Ecto.Query

    Abuuba.Statuses.Tag
    |> join(:inner, [t], st in "statuses_tags", on: st.tag_id == t.id)
    |> where([_t, st], st.status_id == ^status_id)
    |> select([t], t.name)
    |> Abuuba.Repo.all()
  end

  # Through `Abuuba.Timelines.Broadcast`, which drops a publish to a topic nobody
  # is listening on before it costs anything, and which is where a subscriber
  # gets the rendered payload from.
  defp broadcast(topic, event, payload) do
    Broadcast.publish(topic, event, payload)
  end
end
