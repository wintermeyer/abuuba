defmodule AbuubaWeb.StatusComponent do
  @moduledoc """
  One post, as a timeline draws it.

  ## The content warning folds rather than hides

  A post behind a warning is still in the timeline, still counted, and still
  something the reader can choose to open. Removing it would mean a reader
  cannot tell that a conversation has a gap in it, and the warning exists so
  that somebody decides for themselves rather than having it decided for them.

  Folded with `details`/`summary` rather than JavaScript, so it works before
  any script has loaded and a screen reader announces it as the disclosure it
  is.

  ## Actions are rendered as buttons

  Not links. A favourite is something that happens rather than somewhere to go,
  and a link would be followed by a crawler, prefetched by a browser, and
  announced wrongly by a screen reader.
  """

  use AbuubaWeb, :html

  alias AbuubaWeb.Formats

  attr :status, :map, required: true, doc: "the rendered status entity"
  attr :id, :string, default: nil
  attr :interactive, :boolean, default: true

  attr :menu, :boolean,
    default: false,
    doc: "the overflow menu, for screens that handle the events it raises"

  attr :viewer_id, :string, default: nil, doc: "the reader's account id, for their own posts"

  attr :nested, :boolean,
    default: false,
    doc: "inside a filter fold, so the fold is the post as far as anything outside is concerned"

  def status(assigns) do
    # `shown` is an assign rather than a template variable on purpose: HEEx
    # tracks changes per assign, and a `<% shown = ... %>` in the template
    # would make every expression touching it untrackable, so the whole post
    # body — content HTML included — would be re-sent on every diff.
    assigns =
      assigns
      |> assign_new(:id, fn -> "status-#{assigns.status["id"]}" end)
      |> assign(:shown, assigns.status["reblog"] || assigns.status)
      |> assign(:filtered_by, filtered_by(assigns.status))

    ~H"""
    <%!-- `tabindex` because the keyboard walks `[data-post]` and calls
    `focus()` on what it finds: `details` is not focusable on its own, so
    without this `j` stopped at the first folded post and went no further. --%>
    <details
      :if={@filtered_by}
      id={@id}
      class="border-b border-base-300 p-4 focus-within:bg-base-200/40"
      data-post={@status["id"]}
      tabindex="-1"
    >
      <summary class="flex flex-wrap items-center gap-2 rounded bg-base-200 px-3 py-2">
        <span class="text-sm">
          {gettext("Filtered: %{title}", title: @filtered_by)}
        </span>
        <span class="link link-hover ml-auto text-sm">{gettext("Show anyway")}</span>
      </summary>

      <%!-- Without dropping the key the post inside the fold would fold
      again, and again. --%>
      <.status
        status={Map.delete(@status, "filtered")}
        id={"#{@id}-shown"}
        interactive={@interactive}
        viewer_id={@viewer_id}
        nested={true}
      />
    </details>

    <%!-- Inside a fold the surrounding `details` is already the post that the
    keyboard and anything else counting posts should see, so this one carries
    neither the marker nor a place in the focus order. --%>
    <article
      :if={is_nil(@filtered_by)}
      id={@id}
      class="border-b border-base-300 p-4 focus-within:bg-base-200/40"
      aria-labelledby={"#{@id}-author"}
      data-post={not @nested && @status["id"]}
      tabindex={not @nested && "-1"}
    >
      <.boost_line :if={@status["reblog"]} status={@status} id={@id} />

      <div class="flex gap-3">
        <%!-- The element is drawn either way, empty where somebody has not set
        a picture: `size-10 shrink-0` is what holds the text beside it in line,
        and an `<img>` with an empty `src` is a broken image in every browser.
        Every post by every account that has not uploaded one carried that
        glyph, which on a new server is every post. --%>
        <img
          :if={@shown["account"]["avatar"] not in [nil, ""]}
          src={@shown["account"]["avatar"]}
          alt=""
          class="size-10 shrink-0 rounded bg-base-300"
        />
        <div
          :if={@shown["account"]["avatar"] in [nil, ""]}
          class="size-10 shrink-0 rounded bg-base-300"
          aria-hidden="true"
        >
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-baseline gap-x-2 text-sm">
            <span id={"#{@id}-author"} class="font-semibold">
              {display_name(@shown["account"])}
            </span>
            <span class="text-base-content/60">@{@shown["account"]["acct"]}</span>
            <%!-- The permalink lives on the timestamp, which is where every
            fediverse client puts it and where a reader looks for it. It is
            also what the "open" shortcut follows. --%>
            <a
              href={@shown["url"]}
              data-post-link
              class="ml-auto text-base-content/60 hover:underline"
            >
              <time datetime={@shown["created_at"]}>{posted_at(@shown["created_at"])}</time>
            </a>
          </div>

          <.content status={@shown} id={@id} />

          <.media :if={@shown["media_attachments"] != []} attachments={@shown["media_attachments"]} />

          <.poll
            :if={@shown["poll"]}
            poll={@shown["poll"]}
            status_id={@shown["id"]}
            interactive={@interactive}
          />

          <%!-- Named rather than silent: a reader deciding whether to trust the
                words needs to know a machine wrote them and which one. Drawn
                here rather than by the screen, so it travels with the post to
                whichever list it is put back into. --%>
          <p :if={@shown["translated_by"]} class="mt-2 text-sm text-base-content/60">
            {gettext("Translated by %{provider}. Reload the page for the original.",
              provider: @shown["translated_by"]
            )}
          </p>

          <.card :if={card?(@shown)} card={@shown["card"]} />

          <.quoted_post :if={@shown["quote"]} quoted={@shown["quote"]} />

          <.actions :if={@interactive} status={@shown} viewer_id={@viewer_id} menu={@menu} />
        </div>
      </div>
    </article>
    """
  end

  attr :status, :map, required: true
  attr :id, :string, required: true

  defp boost_line(assigns) do
    ~H"""
    <p class="mb-2 flex items-center gap-2 pl-13 text-sm text-base-content/60">
      <span class="hero-arrow-path size-4" aria-hidden="true" />
      {gettext("%{name} boosted", name: display_name(@status["account"]))}
    </p>
    """
  end

  # Which of the reader's own rules matched, where the rule asked to be warned.
  #
  # `nil` for a post nothing matched, and also for one a `hide` rule matched —
  # that post is not rendered at all, and the caller drops it before it reaches
  # here. The two are the same answer on purpose: this component decides
  # between folded and plain, and never between shown and gone.
  defp filtered_by(status) do
    status
    |> Map.get("filtered", [])
    |> List.wrap()
    |> Enum.find_value(fn matched ->
      filter = matched["filter"] || %{}

      if filter["filter_action"] == "warn", do: filter["title"]
    end)
  end

  @doc """
  Whether a post is one the reader's rules said to remove.

  Asked by the timelines rather than by this component: a post that is not
  rendered has no markup to hang a decision on, and a component that returned
  nothing would still be a row in whatever stream inserted it.
  """
  @spec hidden?(map()) :: boolean()
  def hidden?(status) do
    status
    |> Map.get("filtered", [])
    |> List.wrap()
    |> Enum.any?(fn matched -> (matched["filter"] || %{})["filter_action"] == "hide" end)
  end

  attr :status, :map, required: true
  attr :id, :string, required: true

  # Folded rather than removed: a reader has to be able to tell that there is
  # something there and decide for themselves.
  #
  # Written out as markup rather than escaped, which is the only way a post's
  # own links and paragraphs reach the reader. What makes that safe is that
  # neither source of this HTML is a stranger: ours comes from
  # `Abuuba.Statuses.Formatter`, which escapes what somebody typed before linking
  # it, and another server's was cleaned when the post arrived rather than
  # here. Anything that starts storing post content from a third source has to
  # clean it on the way in too.
  defp content(assigns) do
    ~H"""
    <details :if={@status["spoiler_text"] not in [nil, ""]} class="mt-2">
      <summary class="cursor-pointer rounded bg-base-200 px-3 py-2">
        {@status["spoiler_text"]}
      </summary>
      <div class="mt-2 break-words">{raw(@status["content"])}</div>
    </details>

    <div :if={@status["spoiler_text"] in [nil, ""]} class="mt-2 break-words">
      {raw(@status["content"])}
    </div>
    """
  end

  attr :attachments, :list, required: true

  # A grid rather than a carousel. Everything attached is visible at once, which
  # is what somebody scanning a timeline needs, and nothing is hidden behind an
  # interaction a keyboard user has to discover.
  defp media(assigns) do
    ~H"""
    <ul class={[
      "mt-3 grid gap-1 overflow-hidden rounded",
      length(@attachments) == 1 && "grid-cols-1",
      length(@attachments) > 1 && "grid-cols-2"
    ]}>
      <li :for={attachment <- @attachments} class="relative">
        <img
          :if={attachment["type"] == "image"}
          src={attachment["preview_url"]}
          alt={attachment["description"] || ""}
          class="h-full w-full object-cover"
        />
        <p :if={attachment["type"] != "image"} class="p-4 text-sm">
          {attachment["description"] || gettext("Attachment")}
        </p>
      </li>
    </ul>
    """
  end

  attr :poll, :map, required: true
  attr :status_id, :string, required: true
  attr :interactive, :boolean, default: true

  # The result is shown to somebody who already voted or whose poll has closed,
  # and the choices to everybody else. Showing the tally before a vote would
  # change the vote, which is the one thing a poll must not do.
  defp poll(assigns) do
    ~H"""
    <div class="mt-3 space-y-2">
      <%!-- A screen that draws posts without their actions -- the logged-out
            front page -- has nobody to vote and nothing to answer the event.
            Drawing the form there gives a visitor a button that cannot work,
            so they see the tally instead. --%>
      <form
        :if={@interactive and not @poll["voted"] and not @poll["expired"]}
        phx-submit="vote"
        class="space-y-2"
      >
        <input type="hidden" name="poll_id" value={@poll["id"]} />
        <fieldset class="space-y-2">
          <legend class="sr-only">{gettext("Poll")}</legend>
          <label :for={{option, index} <- Enum.with_index(@poll["options"])} class="flex gap-2">
            <input
              type={if @poll["multiple"], do: "checkbox", else: "radio"}
              name="choices[]"
              value={index}
            />
            {option["title"]}
          </label>
        </fieldset>
        <button type="submit" class="btn btn-sm">{gettext("Vote")}</button>
      </form>

      <div :if={@poll["voted"] or @poll["expired"] or not @interactive} class="space-y-1">
        <div :for={{option, index} <- Enum.with_index(@poll["options"])}>
          <div class="flex justify-between text-sm">
            <span>
              {option["title"]}
              <span :if={index in (@poll["own_votes"] || [])} aria-label={gettext("Your choice")}>
                ✓
              </span>
            </span>
            <span>{percentage(option, @poll)}%</span>
          </div>
          <div
            class="h-1 rounded bg-primary"
            style={"width: #{percentage(option, @poll)}%"}
            role="presentation"
          />
        </div>
      </div>

      <p class="text-sm text-base-content/60">
        {ngettext("%{count} vote", "%{count} votes", @poll["votes_count"] || 0)}
        <%!-- Answers and people are different numbers on a poll that takes
              more than one answer, and a reader deciding what the result means
              needs both: three people who each picked two options are six
              votes. On a single-answer poll they are the same number written
              twice, so only the first is shown. --%>
        <span :if={@poll["multiple"] and @poll["voters_count"]}>
          · {ngettext("%{count} person", "%{count} people", @poll["voters_count"])}
        </span>
        <span :if={@poll["expired"]}>· {gettext("Closed")}</span>
      </p>
    </div>
    """
  end

  attr :card, :map, required: true

  defp card(assigns) do
    ~H"""
    <a
      href={@card["url"]}
      rel="nofollow noopener"
      class="mt-2 flex gap-3 overflow-hidden rounded-box border border-base-300 hover:bg-base-200"
    >
      <img
        :if={@card["image"]}
        src={@card["image"]}
        alt={@card["image_description"]}
        class="h-24 w-32 shrink-0 object-cover"
        loading="lazy"
      />

      <div class="min-w-0 p-3">
        <p class="text-xs text-base-content/60">{@card["provider_name"]}</p>
        <p class="truncate font-semibold">{@card["title"]}</p>
        <p :if={@card["description"] != ""} class="line-clamp-2 text-sm text-base-content/70">
          {@card["description"]}
        </p>
        <p :if={@card["authors"] != []} class="mt-1 text-xs text-base-content/60">
          {gettext("by %{name}", name: author_name(@card))}
        </p>
      </div>
    </a>
    """
  end

  # Somebody else's post, and somebody signed in to say so. Reporting your own
  # is a report a moderator can do nothing with.
  defp reportable?(status, viewer_id), do: not is_nil(viewer_id) and not own?(status, viewer_id)

  defp report_path(status) do
    "/report/@#{status["account"]["acct"]}?status=#{status["id"]}"
  end

  # Which controls are the author's own. Once, rather than on each button that
  # asks: two spellings of "is this mine" in one template is two to keep in
  # step. What it decides is what is drawn; whether the event is allowed is
  # answered again where it is acted on, because the event can be sent without
  # the button ever existing.
  defp own?(_status, nil), do: false
  defp own?(%{"account" => %{"id" => id}}, viewer_id), do: id == viewer_id
  defp own?(_status, _viewer_id), do: false

  # A card with nothing to say is worse than no card: an empty box under a post
  # tells a reader the link is broken when it is only uninformative.
  defp card?(%{"card" => %{"title" => title}}) when title != "", do: true
  defp card?(_status), do: false

  defp author_name(%{"authors" => [%{"account" => account} | _rest]}) do
    account["display_name"] |> then(&if(&1 in [nil, ""], do: "@" <> account["acct"], else: &1))
  end

  defp author_name(card), do: card["author_name"]

  attr :quoted, :map, required: true

  defp quoted_post(assigns) do
    ~H"""
    <blockquote class="mt-3 rounded border border-base-300 p-3 text-sm">
      <p class="font-semibold">@{@quoted["account"]["acct"]}</p>
      <div class="mt-1 break-words">{raw(@quoted["content"])}</div>
    </blockquote>
    """
  end

  attr :status, :map, required: true
  attr :viewer_id, :string, default: nil
  attr :menu, :boolean, default: false

  # Buttons, not links. A favourite is something that happens rather than
  # somewhere to go, and a link would be followed by a crawler, prefetched by a
  # browser, and announced wrongly by a screen reader.
  defp actions(assigns) do
    ~H"""
    <div class="mt-3 flex gap-6 text-sm text-base-content/60">
      <button
        type="button"
        phx-click="reply"
        phx-value-id={@status["id"]}
        class="flex items-center gap-1"
      >
        <span class="hero-chat-bubble-left size-4" aria-hidden="true" />
        <span>{@status["replies_count"]}</span>
        <span class="sr-only">{gettext("Reply")}</span>
      </button>

      <button
        type="button"
        phx-click="boost"
        phx-value-id={@status["id"]}
        aria-pressed={to_string(@status["reblogged"] == true)}
        class={["flex items-center gap-1", @status["reblogged"] && "text-success"]}
      >
        <span class="hero-arrow-path size-4" aria-hidden="true" />
        <span>{@status["reblogs_count"]}</span>
        <span class="sr-only">{gettext("Boost")}</span>
      </button>

      <button
        type="button"
        phx-click="favourite"
        phx-value-id={@status["id"]}
        aria-pressed={to_string(@status["favourited"] == true)}
        class={["flex items-center gap-1", @status["favourited"] && "text-warning"]}
      >
        <span class="hero-star size-4" aria-hidden="true" />
        <span>{@status["favourites_count"]}</span>
        <span class="sr-only">{gettext("Favourite")}</span>
      </button>

      <button
        type="button"
        phx-click="bookmark"
        phx-value-id={@status["id"]}
        aria-pressed={to_string(@status["bookmarked"] == true)}
        class={["flex items-center gap-1", @status["bookmarked"] && "text-info"]}
      >
        <span class="hero-bookmark size-4" aria-hidden="true" />
        <span class="sr-only">{gettext("Bookmark")}</span>
      </button>

      <button
        :if={own?(@status, @viewer_id)}
        type="button"
        phx-click="edit"
        phx-value-id={@status["id"]}
        class="flex items-center gap-1"
      >
        <span class="hero-pencil-square size-4" aria-hidden="true" />
        <span class="sr-only">{gettext("Edit")}</span>
      </button>

      <%!-- Your own posts only, and asked about first: a delete goes out to
      every server that has a copy and nothing brings it back. --%>
      <button
        :if={own?(@status, @viewer_id)}
        type="button"
        phx-click="delete"
        phx-value-id={@status["id"]}
        data-confirm={gettext("Delete this post? Other servers are told to forget it too.")}
        class="flex items-center gap-1"
      >
        <span class="hero-trash size-4" aria-hidden="true" />
        <span class="sr-only">{gettext("Delete")}</span>
      </button>

      <%!-- Only where the server can actually translate and the post is in
      another language. A button that answers "not enabled" is worse than no
      button. --%>
      <button
        :if={translatable?(@status)}
        type="button"
        phx-click="translate"
        phx-value-id={@status["id"]}
        class="flex items-center gap-1"
      >
        <span class="hero-language size-4" aria-hidden="true" />
        <span class="sr-only">{gettext("Translate")}</span>
      </button>

      <%!-- Drawn whenever it would hold something. `@menu` is a screen saying
      it answers the events in here, which only the two with a composer do;
      reporting is a link and needs no answering, so it appears on every
      screen that draws a post. --%>
      <.overflow
        :if={(@menu and in_a_thread?(@status)) or reportable?(@status, @viewer_id)}
        status={@status}
        menu={@menu}
        viewer_id={@viewer_id}
      />
    </div>
    """
  end

  attr :status, :map, required: true

  # `details` rather than a scripted popover: it opens, closes on a second
  # press and reaches by keyboard with nothing of ours running, which is three
  # behaviours not to write or to break.
  attr :viewer_id, :any, default: nil
  attr :menu, :boolean, default: false

  defp overflow(assigns) do
    ~H"""
    <details class="dropdown dropdown-end ml-auto">
      <summary class="cursor-pointer list-none">
        <span class="hero-ellipsis-horizontal size-4" aria-hidden="true" />
        <span class="sr-only">{gettext("More")}</span>
      </summary>

      <div class="dropdown-content z-10 w-56 rounded-box bg-base-200 p-2 shadow">
        <button
          :if={@menu and in_a_thread?(@status)}
          type="button"
          phx-click={if @status["muted"], do: "unmute_thread", else: "mute_thread"}
          phx-value-id={@status["id"]}
          class="btn btn-ghost btn-sm btn-block justify-start"
        >
          {if @status["muted"],
            do: gettext("Unmute this conversation"),
            else: gettext("Mute this conversation")}
        </button>

        <%!-- Said here rather than in a tooltip, because "mute" next to
        somebody's post reads as muting the person, and that is a much bigger
        thing to do by accident. --%>
        <p :if={@menu and in_a_thread?(@status)} class="px-2 pt-1 text-xs text-base-content/60">
          {gettext("Stops its notifications and takes it out of your timeline. Nobody is told.")}
        </p>

        <%!-- A link rather than an event: the questions a report asks do not
        fit in a dropdown, and every screen that draws a post would otherwise
        have to answer them. --%>
        <.link
          :if={reportable?(@status, @viewer_id)}
          navigate={report_path(@status)}
          class="btn btn-ghost btn-sm btn-block justify-start"
        >
          {gettext("Report this post")}
        </.link>
      </div>
    </details>
    """
  end

  # A post nobody has replied to and that replies to nothing has no
  # conversation to mute, and `Statuses.mute_thread/2` answers
  # `{:error, :no_conversation}` for it. Offering the control anyway would be
  # a menu item that fails.
  defp in_a_thread?(status) do
    status["in_reply_to_id"] != nil or (status["replies_count"] || 0) > 0
  end

  defp translatable?(status) do
    Abuuba.Translation.enabled?() and
      status["language"] not in [nil, ""] and
      status["visibility"] in ["public", "unlisted"] and
      status["language"] != Gettext.get_locale(AbuubaWeb.Gettext)
  end

  # The entity carries ISO 8601 because that is what the API hands a client, and
  # this printed that string where every other fediverse client shows an age.
  # A timeline is read in the present tense, so the reader gets the age and the
  # machine-readable form stays in `datetime`, which is what the attribute is
  # for.
  defp posted_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> Formats.relative_time(at)
      # Unparseable is still better shown than swallowed: the permalink this
      # sits on has to keep something clickable.
      {:error, _reason} -> value
    end
  end

  defp posted_at(value), do: value

  @doc """
  The `viewer_id` this component wants, from the reader or from nobody.

  Here rather than in each screen because the attribute is this component's
  idea: it compares against string ids inside already-rendered entities, so
  every screen drawing a post had the same two-line conversion privately, five
  times over, purely to satisfy it.
  """
  @spec viewer_id(map() | nil) :: String.t() | nil
  def viewer_id(nil), do: nil
  def viewer_id(viewer), do: to_string(viewer.id)

  defp display_name(account) do
    case account["display_name"] do
      name when is_binary(name) and name != "" -> name
      _ -> account["username"]
    end
  end

  defp percentage(_option, %{"votes_count" => 0}), do: 0
  defp percentage(_option, %{"votes_count" => nil}), do: 0

  defp percentage(option, poll) do
    round(option["votes_count"] / poll["votes_count"] * 100)
  end
end
