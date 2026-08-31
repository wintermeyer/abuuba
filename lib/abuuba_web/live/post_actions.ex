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

  use Gettext, backend: AbuubaWeb.Gettext

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.Status
  alias Abuuba.Translation
  alias AbuubaWeb.API.Entities

  @toggles ~w(favourite boost bookmark)

  # What a screen with no composer can ask a post's page to open on arrival.
  @composers ~w(reply edit)

  @doc """
  The events this handles.
  """
  @spec toggles() :: [String.t()]
  def toggles, do: @toggles

  @doc """
  Every event `attach/2` answers.

  Stated rather than implied so the sweep in
  `AbuubaWeb.StatusComponentEventsTest` can hold this list against the one the
  component raises. Without it, attaching the hook counts as answering
  everything, and a clause dropped from `handle/4` later would leave every
  attached screen passing a check that is no longer true.
  """
  @spec answers() :: [String.t()]
  def answers, do: Enum.sort(@toggles ++ ~w(delete edit reply translate vote))

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
        {:ok, Statuses.actionable(status.id, viewer)}
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
    # Through the post rather than the poll alone: a poll is reachable exactly
    # when the post carrying it is, and asking the poll separately would be a
    # second set of rules to keep in step with the first.
    with %Poll{} = poll <- Statuses.fetch_poll(poll_id),
         %Status{} = status <- Statuses.readable(poll.status_id, viewer),
         {:ok, _voted} <- Statuses.vote(poll, viewer, to_indexes(choices)) do
      {:ok, Statuses.readable(status.id, viewer)}
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
  Takes back a post the reader wrote, answering with the one that is gone.

  Ownership is asked here rather than trusted from the button, for the reason
  in "Read, then decide" above and one more: the event can be sent without the
  button ever being drawn, so the only place the question can be answered is
  the one that acts on it.

  `:error` where there is nobody signed in, the id names nothing they can see,
  or the post is somebody else's -- all three mean the same thing to a caller,
  which is that nothing has left the screen.
  """
  @spec delete(Account.t() | nil, String.t() | integer()) :: {:ok, Status.t()} | :error
  def delete(viewer, id)

  def delete(%Account{} = viewer, id) do
    status = find(viewer, id)

    if own?(status, viewer), do: Statuses.delete_status(status), else: :error
  end

  def delete(_viewer, _id), do: :error

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

  `:compose` says what the reader came to do, and the post's page opens the box
  on arrival. Without it the button sent them to a page with a closed composer,
  so "Reply" did nothing once they got there and "Edit" showed an empty box on
  the post they meant to change. The accepted values are `composers/0`, which
  is what `AbuubaWeb.StatusLive` matches on, so the two ends cannot drift.
  """
  @spec page_of(Account.t() | nil, String.t() | integer(), keyword()) :: String.t() | nil
  def page_of(viewer, id, opts \\ []) do
    with %Status{} = status <- find(viewer, id),
         %Account{} = account <- Abuuba.Repo.get(Account, status.account_id) do
      "/@#{Account.acct(account)}/#{status.id}#{compose_query(opts[:compose])}"
    else
      _nothing -> nil
    end
  end

  @doc """
  What `:compose` accepts, and what a post's page answers.
  """
  @spec composers() :: [String.t()]
  def composers, do: @composers

  defp compose_query(nil), do: ""

  defp compose_query(what) do
    case to_string(what) do
      known when known in @composers -> "?compose=#{known}"
      _unknown -> ""
    end
  end

  @doc """
  Whether this post is the reader's own.

  Asked of the `%Status{}` rather than of the button that raised the event: the
  event can be sent without the button ever being drawn, so the only place the
  question can be answered is the one that acts on it.
  """
  @spec own?(Status.t(), Account.t() | nil) :: boolean()
  def own?(%Status{account_id: account_id}, %Account{id: account_id}), do: true
  def own?(_status, _viewer), do: false

  # `actionable/2`: readable, or a post this reader has already marked. The
  # bookmarks and favourites screens list what somebody saved whatever they
  # have done about the author since, so the button drawn over a row has to
  # reach it -- and nothing else does, so a made-up id cannot favourite a post
  # from an account that blocked them and draw it into their timeline.
  #
  # `Snowflake.cast/1` rather than `Integer.parse/1`, which reads a number too
  # big for the column and hands it to Ecto, where it is a cast error that
  # takes the socket down. Every button on the action bar comes through here,
  # so one id nobody could have meant emptied the page.
  defp find(viewer, id) do
    case Snowflake.cast(id) do
      {:ok, number} -> Statuses.actionable(number, viewer)
      :error -> nil
    end
  end

  @doc """
  Answers every event the action bar raises, for a screen that keeps its posts
  in plain lists.

  ## Why the wiring moved here too

  The work behind these events came here first and the wiring did not, so the
  same fifty-four lines sat in four screens: identical in three of them, and
  identical apart from one list name in the fourth. That is the shape the
  moduledoc above describes, one level up — the copies were what disagreed.
  Search's translate put the fresh post into an assign that screen never had,
  so the button raised on every result, and nothing said so until somebody
  pressed it.

  `:lists` names the assigns holding the posts, so a screen that keeps two of
  them (a profile, with its pinned posts above the rest) says so rather than
  writing the loop again.

  ## What a screen keeps for itself

  Replying and editing here go to the post's own page, because these screens
  have no composer. A screen that has one — the home timeline, a post's own
  page — answers those two itself and does not attach this.
  """
  @spec attach(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def attach(socket, opts) do
    ways = ways(opts)

    Phoenix.LiveView.attach_hook(socket, :post_actions, :handle_event, fn event, params, socket ->
      handle(event, params, socket, ways)
    end)
  end

  # `:lists` covers every screen that keeps posts in plain lists, which is most
  # of them. `:put_back` and `:remove` are for the one that does not — the
  # notifications page holds each post inside the group of notifications about
  # it — and are the same division of labour the moduledoc describes: this
  # decides what an action does, the screen decides where the answer goes.
  #
  # Two ways rather than one because the actions divide in two: everything but
  # a delete redraws a post where it was, and a delete takes it off the screen.
  defp ways(opts) do
    %{
      put_back: way(opts, :put_back, &lists_put_back/1),
      remove: way(opts, :remove, &lists_remove/1)
    }
  end

  defp way(opts, key, from_lists) do
    case Keyword.fetch(opts, key) do
      {:ok, fun} when is_function(fun, 2) -> fun
      :error -> opts |> Keyword.fetch!(:lists) |> List.wrap() |> from_lists.()
    end
  end

  defp lists_put_back(lists), do: &update_lists(&1, lists, fn posts -> swap(posts, &2) end)

  defp lists_remove(lists),
    do: &update_lists(&1, lists, fn posts -> Enum.reject(posts, fn p -> about?(p, &2) end) end)

  @doc """
  Whether a drawn post is the one with this id, boost included.

  A boost is drawn as the boost row, and the action bar on it acts on the
  post inside (`@status["reblog"] || @status`). So the id a delete answers
  with is the original's, while the row it has to come off is the boost's --
  and matching only the row's own id left the words of a deleted post sitting
  on screen under a flash saying it was gone.
  """
  @spec about?(map(), String.t()) :: boolean()
  def about?(post, id), do: post["id"] == id or get_in(post, ["reblog", "id"]) == id

  defp update_lists(socket, lists, fun) do
    Enum.reduce(lists, socket, fn list, acc -> Phoenix.Component.update(acc, list, fun) end)
  end

  defp handle(event, %{"id" => id}, socket, ways) when event in @toggles do
    case toggle(socket.assigns.viewer, event, id) do
      {:ok, status} -> {:halt, rendered_back(socket, status, ways.put_back)}
      :error -> {:halt, socket}
    end
  end

  defp handle("vote", %{"poll_id" => poll_id} = params, socket, ways) do
    choices = params |> Map.get("choices", []) |> List.wrap()

    case vote(socket.assigns.viewer, poll_id, choices) do
      {:ok, status} -> {:halt, rendered_back(socket, status, ways.put_back)}
      :error -> {:halt, socket}
    end
  end

  defp handle(event, %{"id" => id}, socket, _ways) when event in @composers do
    case page_of(socket.assigns.viewer, id, compose: event) do
      nil -> {:halt, socket}
      path -> {:halt, Phoenix.LiveView.push_navigate(socket, to: path)}
    end
  end

  defp handle("translate", %{"id" => id}, socket, ways) do
    case translate(socket.assigns.viewer, id, locale(socket)) do
      {:ok, rendered} ->
        {:halt, ways.put_back.(socket, rendered)}

      :error ->
        {:halt,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("That could not be translated just now.")
         )}
    end
  end

  defp handle("delete", %{"id" => id}, socket, ways) do
    case delete(socket.assigns.viewer, id) do
      {:ok, status} ->
        {:halt,
         socket
         |> ways.remove.(to_string(status.id))
         |> Phoenix.LiveView.put_flash(:info, gone())}

      :error ->
        {:halt, socket}
    end
  end

  defp handle(_event, _params, socket, _ways), do: {:cont, socket}

  # Rendered the way the screen rendered the rest of them, then handed back.
  defp rendered_back(socket, %Status{} = status, put_back) do
    put_back.(socket, Entities.status(status, socket.assigns.viewer))
  end

  @doc """
  What a screen says once a post is gone.

  Public because the two screens with a composer answer `delete` themselves --
  one has a stream to take a row out of, the other may have to leave the page
  -- and a delete that reports nothing looks like a button that did nothing.
  """
  @spec gone() :: String.t()
  def gone, do: gettext("That post is gone.")

  @doc """
  The language to translate into for this reader.

  Their own where the locale hook has set one, and the request's otherwise.
  Public because the two screens with a composer answer `translate` themselves
  and still have to pick the same target; it was a private one-liner in six
  screens, one of which had drifted to a different name.
  """
  @spec locale(Phoenix.LiveView.Socket.t()) :: String.t()
  def locale(socket) do
    socket.assigns[:locale] || Gettext.get_locale(AbuubaWeb.Gettext)
  end
end
