defmodule AbuubaWeb.Streaming.Filter do
  @moduledoc """
  Whether one socket's reader may see what was just published.

  Applied here rather than at publish time, because the answer differs per
  person: one reader has blocked the author, another has muted the thread, a
  third cannot see a followers-only post at all. Deciding centrally would mean
  one message per subscriber and the same visibility rules written twice.

  Anything that cannot be established is skipped. A stream is a place where a
  mistake shows somebody a post that was never addressed to them, so silence is
  the safe direction.
  """

  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status
  alias Abuuba.Timelines.Broadcast
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Streaming.Payload

  @doc """
  A frame to push, or `:skip`.
  """
  @spec for_viewer(String.t(), term(), map()) :: {:ok, String.t()} | :skip
  def for_viewer("update", %Status{} = status, state) do
    streams = matching_streams(status, state)

    cond do
      streams == [] -> :skip
      not visible?(status, state) -> :skip
      # Through the broadcast layer rather than rendering here. One post
      # reaching a thousand sockets is one render and a thousand patches, and
      # the interface reads the same payload through the same path.
      true -> {:ok, Payload.envelope(streams, "update", Broadcast.render(status, state.account))}
    end
  end

  # Only where the socket asked for its messages. The payload is the inbox row,
  # rendered here rather than at the broadcast so one write reaching several of
  # somebody's connections is one row and several renders of it.
  def for_viewer("conversation", %{} = row, state) when not is_struct(row) do
    if Enum.any?(state.topics, fn {stream, _topic} -> stream == "direct" end) and state.account do
      {:ok,
       Payload.envelope(["direct"], "conversation", Entities.conversation(row, state.account))}
    else
      :skip
    end
  end

  def for_viewer("delete", %Status{} = status, state) do
    case matching_streams(status, state) do
      [] ->
        :skip

      # A delete carries only an id: a client removes the post from its list,
      # and sending the post back would be sending what was just deleted.
      streams ->
        {:ok, Payload.envelope(streams, "delete", to_string(status.id))}
    end
  end

  # An edit is the same post with different words, so it goes to the same
  # streams under the name a client watches for.
  def for_viewer("status.update", %Status{} = status, state) do
    streams = matching_streams(status, state)

    cond do
      streams == [] ->
        :skip

      not visible?(status, state) ->
        :skip

      true ->
        {:ok, Payload.envelope(streams, "status.update", Broadcast.render(status, state.account))}
    end
  end

  def for_viewer("notification", notification, state) do
    cond do
      is_nil(state.account) -> :skip
      notification.account_id != state.account.id -> :skip
      # A filtered notification belongs in the requests inbox, and pushing it
      # would put it in front of somebody who asked for it not to be.
      notification.filtered -> :skip
      not subscribed?(state, "user:notification") -> :skip
      true -> {:ok, notification_frame(notification, state)}
    end
  end

  # Nothing about the change travels: a client re-reads the filters itself, and
  # sending them here would mean rendering somebody's whole filter set on every
  # keystroke of an edit. Without it a client goes on hiding by the rules it
  # fetched when it connected, so a word somebody just added keeps appearing in
  # the timeline they are watching.
  def for_viewer("filters_changed", _payload, state) do
    if subscribed?(state, "user") do
      {:ok, Payload.envelope(["user"], "filters_changed")}
    else
      :skip
    end
  end

  # Named on the user stream, which is where the reference implementation puts
  # them, and only for a socket that has one: an announcement is published per
  # account there, so a connection with no account never sees one.
  def for_viewer("announcement", announcement, state) do
    if state.account do
      {:ok,
       Payload.envelope(
         ["user"],
         "announcement",
         Entities.announcement(announcement, state.account)
       )}
    else
      :skip
    end
  end

  def for_viewer("announcement.delete", %{id: id}, state) do
    if state.account do
      {:ok, Payload.envelope(["user"], "announcement.delete", to_string(id))}
    else
      :skip
    end
  end

  def for_viewer("announcement.reaction", %{announcement_id: id} = reaction, state) do
    if state.account do
      payload = %{
        "announcement_id" => to_string(id),
        "name" => reaction.name,
        "count" => reaction.count
      }

      {:ok, Payload.envelope(["user"], "announcement.reaction", payload)}
    else
      :skip
    end
  end

  def for_viewer(_event, _payload, _state), do: :skip

  defp notification_frame(notification, state) do
    Payload.envelope(
      ["user:notification"],
      "notification",
      Entities.notification(notification, state.account)
    )
  end

  # Which of this socket's streams this post belongs on. One post can match
  # several, and a client is told all of them so it can put it in each list it
  # is showing.
  defp matching_streams(%Status{} = status, state) do
    state.topics
    |> Enum.filter(fn {stream, _topic} -> belongs_on?(stream, status) end)
    |> Enum.map(fn {stream, _topic} -> stream end)
    |> Enum.uniq()
  end

  defp belongs_on?("direct", %Status{visibility: :direct}), do: true
  defp belongs_on?("direct", _status), do: false
  defp belongs_on?("user", %Status{visibility: visibility}), do: visibility != :direct
  defp belongs_on?("user:notification", _status), do: false

  defp belongs_on?(stream, status)
       when stream in ["public:media", "public:local:media", "public:remote:media"] do
    status.ordered_media_attachment_ids != []
  end

  defp belongs_on?("public:local", status), do: status.local
  defp belongs_on?("public:remote", status), do: not status.local
  defp belongs_on?("hashtag:local", status), do: status.local
  defp belongs_on?(_stream, _status), do: true

  # The same rules a timeline applies, asked one post at a time. An anonymous
  # socket sees public posts and nothing else.
  defp visible?(%Status{} = status, %{account: nil}), do: status.visibility == :public

  defp visible?(%Status{} = status, %{account: account}),
    do: Statuses.readable?(status, account)

  defp subscribed?(state, stream) do
    Enum.any?(state.topics, fn {name, _topic} -> name == stream end)
  end
end
