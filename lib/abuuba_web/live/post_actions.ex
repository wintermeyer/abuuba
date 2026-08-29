defmodule AbuubaWeb.PostActions do
  @moduledoc """
  Favourite, boost and bookmark, for any screen that draws a post.

  ## Why this is not in each screen

  It was, in two of them. `AbuubaWeb.StatusComponent` draws the same action bar
  wherever a post appears, and only the home timeline and a post's own page
  ever implemented the events it raises; profile, explore, tag and search drew
  the buttons and swallowed the clicks in a catch-all. Nothing was written,
  nothing was drawn, and no error appeared, which is the worst way for a button
  to be broken.

  Two copies is how the four came to disagree, so this is the copy there is.

  ## What it does not decide

  Where the answer goes. A screen holds its posts as a stream, a list, or three
  lists making up a thread, and putting one back is the part each one knows and
  this cannot. So the answer is the post as it now stands, and the caller puts
  it where it keeps things.

  ## Read, then decide

  Whether something is already favourited is asked of the database rather than
  taken from what the click assumed. The two disagree exactly when it matters —
  a second tab, a refusal, a stale page — and taking the screen's word for it
  turns a correction into a silent no-op.
  """

  alias Abuuba.Accounts.Account
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.Status
  alias Abuuba.Translation
  alias AbuubaWeb.API.Entities

  @toggles ~w(favourite boost bookmark)

  @doc """
  The events this handles.
  """
  @spec toggles() :: [String.t()]
  def toggles, do: @toggles

  @doc """
  Performs one, answering with the post as it now stands.

  `:error` where there is nobody signed in, the id names nothing, or the event
  is not one of these — all three mean the same thing to a caller, which is
  that there is nothing to redraw.
  """
  @spec toggle(Account.t() | nil, String.t(), String.t() | integer()) ::
          {:ok, Status.t()} | :error
  def toggle(viewer, event, id)

  def toggle(%Account{} = viewer, event, id) when event in @toggles do
    case find(viewer, id) do
      nil ->
        :error

      status ->
        apply_toggle(viewer, event, status)

        # Re-read rather than returning what the write handed back: the
        # counters live on another row, and the caller is about to draw them.
        {:ok, Statuses.get_status(status.id, viewer)}
    end
  end

  def toggle(_viewer, _event, _id), do: :error

  @doc """
  Records a vote, answering with the post the poll belongs to.

  Here for the same reason the toggles are. `AbuubaWeb.StatusComponent` draws the
  poll form wherever a post appears, and only the home timeline answered the
  event: everywhere else the choices were live, the button did nothing and
  nothing said so. The sweep that moved the action bar here did not move this.

  `:error` where there is nobody signed in, the id names no poll, or the vote
  is refused -- a closed poll, the author's own, a second submission. All of
  them mean the same thing to a caller, which is that there is nothing new to
  draw.
  """
  @spec vote(Account.t() | nil, String.t() | integer(), [String.t()]) ::
          {:ok, Status.t()} | :error
  def vote(viewer, poll_id, choices)

  def vote(%Account{} = viewer, poll_id, choices) when is_list(choices) do
    with %Poll{} = poll <- Statuses.fetch_poll(poll_id),
         {:ok, _voted} <- Statuses.vote(poll, viewer, to_indexes(choices)) do
      {:ok, Statuses.get_status(poll.status_id, viewer)}
    else
      _refused -> :error
    end
  end

  def vote(_viewer, _poll_id, _choices), do: :error

  @doc """
  Translates one post, answering with it as it should now be drawn.

  Here for the same reason the toggles and the vote are: the button is drawn by
  `AbuubaWeb.StatusComponent` on every screen that shows a post, and only a
  post's own page answered it.

  A translation is not a change to the post, so unlike everything else here
  there is nothing to re-read: the answer is the rendered map with the
  translated words in it and the provider named, and the caller puts it back
  where it keeps things. Reloading the screen brings the original text back,
  which is what somebody expects of a translation they asked for once.
  """
  @spec translate(Account.t() | nil, String.t() | integer(), String.t()) ::
          {:ok, map()} | :error
  def translate(viewer, id, target)

  def translate(%Account{} = viewer, id, target) do
    with %Status{} = status <- find(viewer, id),
         {:ok, translation} <- Translation.translate(status, target) do
      rendered =
        status
        |> Entities.status(viewer)
        |> Map.put("content", translation.content)
        |> Map.put("spoiler_text", translation.spoiler_text)
        |> Map.put("translated_by", translation.provider)

      {:ok, rendered}
    else
      _refused -> :error
    end
  end

  def translate(_viewer, _id, _target), do: :error

  # The form sends strings, and a choice that is not a number is not a choice.
  defp to_indexes(choices) do
    Enum.flat_map(choices, fn choice ->
      case Integer.parse(to_string(choice)) do
        {index, ""} -> [index]
        _ -> []
      end
    end)
  end

  defp apply_toggle(viewer, "favourite", status) do
    if Statuses.favourited?(viewer.id, status.id) do
      Statuses.unfavourite(viewer, status)
    else
      Statuses.favourite(viewer, status)
    end
  end

  defp apply_toggle(viewer, "boost", status) do
    if Statuses.boosted?(viewer.id, status.id) do
      Statuses.unboost(viewer, status)
    else
      Statuses.boost(viewer, status)
    end
  end

  defp apply_toggle(viewer, "bookmark", status) do
    if Statuses.bookmarked?(viewer.id, status.id) do
      Statuses.unbookmark(viewer, status)
    else
      Statuses.bookmark(viewer, status)
    end
  end

  @doc """
  Puts a freshly rendered post in place of the one it supersedes.

  For the screens that hold their posts in a plain list. A stream has its own
  way of saying this and does not come here.
  """
  @spec swap([map()], map()) :: [map()]
  def swap(posts, rendered) do
    Enum.map(posts, fn post ->
      if post["id"] == rendered["id"], do: rendered, else: post
    end)
  end

  @doc """
  Where a post is read on its own, or `nil` if there is no such post to read.

  For the screens with no composer: replying there goes to the post rather than
  opening a box, which is the same answer on all of them.
  """
  @spec page_of(Account.t() | nil, String.t() | integer()) :: String.t() | nil
  def page_of(viewer, id) do
    with %Status{} = status <- find(viewer, id),
         %Account{} = account <- Abuuba.Repo.get(Account, status.account_id) do
      "/@#{Account.acct(account)}/#{status.id}"
    else
      _nothing -> nil
    end
  end

  # `get_status/2` is what applies the viewer's own visibility, so a post
  # somebody cannot see answers nil here rather than being acted on.
  defp find(viewer, id) do
    case Integer.parse(to_string(id)) do
      {number, ""} -> Statuses.get_status(number, viewer)
      _not_a_number -> nil
    end
  end
end
