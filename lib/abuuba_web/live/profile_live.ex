defmodule AbuubaWeb.ProfileLive do
  @moduledoc """
  Somebody's page.

  ## Rendered by the server, for everybody

  Like a post's page, this is an address the whole fediverse links to, and most
  arrivals are neither signed in nor people. The finished HTML and the tags a
  link preview reads come from the first response.

  ## Three tabs, three addresses

  Posts, posts and replies, and media are separate routes rather than a
  parameter, so each is a link somebody can send, a back button can return to,
  and a crawler can index.

  ## The banner for somebody who left

  An account that moved says so at the top. Without it a visitor follows an
  account that will never post again and never finds out why nothing arrives.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.EmailSubscriptions
  alias Abuuba.Federation.URIs
  alias Abuuba.I18n
  alias Abuuba.Media.ProfileImages
  alias Abuuba.RateLimit
  alias Abuuba.Relationships
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Formatter
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Meta
  alias AbuubaWeb.PostActions

  @page_size 20

  # Enough to be a recommendation and not a directory. The API pages through
  # the whole list for a client that wants it.
  @featured_limit 20

  # The API endpoint's bucket, to the number: five an hour from one address.
  # A second door with its own budget is not a limit, it is a workaround.
  @subscribe_limit 5
  @subscribe_window_ms 60 * 60 * 1000

  @impl Phoenix.LiveView
  def mount(%{"username" => username}, _session, socket) do
    viewer = current_account(socket)

    case Accounts.lookup(username) do
      %Account{suspended_at: nil} = subject ->
        {:ok,
         socket
         |> assign(
           subject: subject,
           viewer: viewer,
           # Read at mount because that is the only place the socket can be
           # asked. See `AbuubaWeb.ClientIP.of_socket/1`.
           client_ip: AbuubaWeb.ClientIP.of_socket(socket),
           email_subscription_said: nil
         )
         |> PostActions.attach(lists: [:posts, :pinned])
         |> load_profile()}

      _ ->
        raise AbuubaWeb.NotFound, "no such account"
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(tab: socket.assigns.live_action, tag: params["tag"])
     |> load_tab()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <div :if={@moved_to} class="border-b border-base-300 bg-warning/10 p-4" role="status">
        <p>
          {gettext("This account has moved to %{handle}.", handle: "@" <> Account.acct(@moved_to))}
        </p>
        <.link navigate={~p"/@#{@moved_to.username}"} class="link">
          {gettext("Go to the new account")}
        </.link>
      </div>

      <div
        :if={header_url(@subject) != ""}
        class="h-32 bg-cover bg-center sm:h-48"
        style={"background-image: url('#{header_url(@subject)}')"}
        role="presentation"
      >
      </div>

      <header class="border-b border-base-300 p-4">
        <img
          :if={avatar_url(@subject) != ""}
          src={avatar_url(@subject)}
          alt=""
          class="mb-3 size-20 rounded bg-base-300 object-cover"
        />
        <h1 class="text-2xl font-semibold">{Account.display_name(@subject)}</h1>
        <p class="text-base-content/60">@{Account.acct(@subject)}</p>

        <div :if={@subject.note not in [nil, ""]} class="mt-3 break-words">
          {raw(@note_html)}
        </div>

        <dl :if={@fields != []} class="mt-3 grid gap-1 sm:grid-cols-2">
          <div :for={field <- @fields} class="rounded bg-base-200 p-2">
            <dt class="text-xs uppercase text-base-content/60">{field["name"]}</dt>
            <dd class="break-words">
              {raw(field["value"])}
              <.verified_badge verified={field["verified_at"] != nil} />
            </dd>
          </div>
        </dl>

        <ul :if={@featured_tags != []} class="mt-3 flex flex-wrap gap-2">
          <li :for={tag <- @featured_tags}>
            <.link navigate={featured_tag_url(@subject, tag)} class="badge badge-ghost">
              #{tag.name}
            </.link>
          </li>
        </ul>

        <div :if={@actionable?} class="mt-4 flex flex-wrap items-center gap-2">
          <button
            :if={!@relationship.following and not @relationship.requested}
            type="button"
            phx-click="follow"
            class="btn btn-primary btn-sm"
          >
            {gettext("Follow")}
          </button>

          <button
            :if={@relationship.requested}
            type="button"
            phx-click="unfollow"
            class="btn btn-sm"
          >
            {gettext("Cancel follow request")}
          </button>

          <button
            :if={@relationship.following}
            type="button"
            phx-click="unfollow"
            class="btn btn-sm"
          >
            {gettext("Unfollow")}
          </button>

          <button
            :if={@relationship.following and not @relationship.endorsed}
            type="button"
            phx-click="endorse"
            class="btn btn-ghost btn-sm"
          >
            {gettext("Feature on my profile")}
          </button>

          <button
            :if={@relationship.endorsed}
            type="button"
            phx-click="unendorse"
            class="btn btn-ghost btn-sm"
          >
            {gettext("Stop featuring")}
          </button>

          <button
            type="button"
            phx-click={if @relationship.muting, do: "unmute", else: "mute"}
            class="btn btn-ghost btn-sm"
          >
            {if @relationship.muting, do: gettext("Unmute"), else: gettext("Mute")}
          </button>

          <button
            type="button"
            phx-click={if @relationship.blocking, do: "unblock", else: "block"}
            class="btn btn-ghost btn-sm"
          >
            {if @relationship.blocking, do: gettext("Unblock"), else: gettext("Block")}
          </button>

          <%!-- Beside mute and block because it is the third answer to the same
          question, and the one that involves somebody else. --%>
          <.link navigate={~p"/report/@#{Account.acct(@subject)}"} class="btn btn-ghost btn-sm">
            {gettext("Report")}
          </.link>
        </div>

        <div
          :if={@actionable? and @relationship.following}
          id="follow-options"
          class="mt-3 rounded bg-base-200 p-3 text-sm"
        >
          <p class="font-medium">{gettext("What you see from them")}</p>

          <div class="mt-2 flex flex-col gap-2">
            <button
              type="button"
              phx-click="toggle_boosts"
              class="flex items-center gap-2 text-left"
              aria-pressed={to_string(@relationship.show_reblogs)}
            >
              <input
                type="checkbox"
                checked={@relationship.show_reblogs}
                class="checkbox checkbox-sm"
                tabindex="-1"
              />
              {gettext("Their boosts of other people")}
            </button>

            <button
              type="button"
              phx-click="toggle_notify"
              class="flex items-center gap-2 text-left"
              aria-pressed={to_string(@relationship.notify)}
            >
              <input
                type="checkbox"
                checked={@relationship.notify}
                class="checkbox checkbox-sm"
                tabindex="-1"
              />
              {gettext("Tell me when they post")}
            </button>
          </div>

          <form :if={@subject_languages != []} phx-submit="set_languages" class="mt-3">
            <label class="block">
              <span class="block">{gettext("Only these languages")}</span>
              <span class="block text-xs text-base-content/60">
                {gettext("Choose none to read everything they write.")}
              </span>

              <select
                name="follow[languages][]"
                multiple
                size={min(length(@subject_languages), 5)}
                class="mt-1 w-full select"
              >
                <option
                  :for={code <- @subject_languages}
                  value={code}
                  selected={code in @relationship.languages}
                >
                  {I18n.language_name(code)}
                </option>
              </select>
            </label>

            <button type="submit" class="btn btn-sm mt-2">{gettext("Save")}</button>
          </form>
        </div>

        <form
          :if={@email_subscriptions_open?}
          id="email-subscription-form"
          phx-submit="subscribe_by_email"
          class="mt-4 rounded bg-base-200 p-3"
        >
          <label class="block">
            <span class="font-medium">
              {gettext("Get updates from %{name} by email", name: Account.display_name(@subject))}
            </span>
            <span class="mt-1 block text-sm text-base-content/60">
              {gettext(
                "No account needed. We write to the address once to check it is yours, and every message has a link that stops them."
              )}
            </span>
            <input
              type="email"
              name="email"
              required
              autocomplete="email"
              placeholder={gettext("you@example.com")}
              class="input input-sm mt-2 w-full sm:max-w-xs"
            />
          </label>

          <p :if={@email_subscription_said} class="mt-2 text-sm">{@email_subscription_said}</p>

          <button type="submit" class="btn btn-sm mt-2">{gettext("Send me updates")}</button>
        </form>

        <form :if={@actionable?} phx-submit="save_note" class="mt-3">
          <label class="block">
            <span class="text-xs uppercase text-base-content/60">
              {gettext("A note only you can read")}
            </span>
            <textarea name="note" rows="2" class="textarea textarea-sm mt-1 w-full">{@note}</textarea>
          </label>
          <button type="submit" class="btn btn-ghost btn-sm mt-1">{gettext("Save the note")}</button>
        </form>
      </header>

      <nav class="flex border-b border-base-300" aria-label={gettext("What to show")}>
        <.link
          :for={{action, label} <- tabs()}
          navigate={tab_path(@subject, action)}
          aria-current={@tab == action && "page"}
          class={["px-4 py-2", @tab == action && "border-b-2 border-primary font-semibold"]}
        >
          {label}
        </.link>
      </nav>

      <section
        :if={@featured != [] and @tab == :posts}
        aria-label={gettext("Featured accounts")}
        class="border-b border-base-300"
      >
        <p class="px-4 pt-3 text-xs uppercase text-base-content/60">
          {gettext("Featured accounts")}
        </p>
        <ul id="profile-featured" class="flex flex-wrap gap-3 p-4">
          <li :for={person <- @featured}>
            <.link
              navigate={~p"/@#{Account.acct(person)}"}
              class="flex items-center gap-2 rounded bg-base-200 px-2 py-1"
            >
              <img
                :if={avatar_url(person) != ""}
                src={avatar_url(person)}
                alt=""
                class="size-6 rounded"
              />
              <span class="font-medium">{Account.display_name(person)}</span>
              <span class="text-sm text-base-content/60">@{Account.acct(person)}</span>
            </.link>
          </li>
        </ul>
      </section>

      <section :if={@pinned != [] and @tab == :posts} aria-label={gettext("Pinned")}>
        <p class="px-4 pt-3 text-xs uppercase text-base-content/60">{gettext("Pinned")}</p>
        <.status
          :for={post <- @pinned}
          id={"pinned-#{post["id"]}"}
          status={post}
          viewer_id={viewer_id(@viewer)}
          interactive={@viewer != nil}
        />
      </section>

      <div :if={not collection?(@tab)} id="profile-posts">
        <.status
          :for={post <- @posts}
          id={"post-#{post["id"]}"}
          status={post}
          viewer_id={viewer_id(@viewer)}
          interactive={@viewer != nil}
        />
      </div>

      <p
        :if={not collection?(@tab) and @posts == []}
        class="p-8 text-center text-base-content/60"
      >
        {gettext("Nothing here yet.")}
      </p>

      <p :if={collection?(@tab) and @hidden?} class="p-8 text-center text-base-content/60">
        {gettext("This account keeps its follows to itself.")}
      </p>

      <ul
        :if={collection?(@tab) and not @hidden?}
        id="profile-people"
        class="divide-y divide-base-300"
      >
        <li :for={person <- @people} class="flex items-center gap-3 p-4">
          <img :if={avatar_url(person) != ""} src={avatar_url(person)} alt="" class="size-10 rounded" />
          <span class="min-w-0 flex-1">
            <.link navigate={~p"/@#{Account.acct(person)}"} class="font-medium">
              {Account.display_name(person)}
            </.link>
            <span class="block truncate text-sm text-base-content/60">@{Account.acct(person)}</span>
          </span>
        </li>
      </ul>

      <p
        :if={collection?(@tab) and not @hidden? and @people == []}
        class="p-8 text-center text-base-content/60"
      >
        {gettext("Nobody yet.")}
      </p>
    </Layouts.app>
    """
  end

  ## Events

  @impl Phoenix.LiveView
  # Following spends a daily allowance and the others do not, so this one
  # cannot go through `act/2`: a refusal has to be said out loud, or the button
  # looks broken.
  def handle_event("follow", _params, socket) do
    case Relationships.take_follow_budget(socket.assigns.viewer) do
      :ok ->
        {:noreply, socket} = act(socket, &Relationships.follow_or_request/2)

        {:noreply, explain_request(socket)}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, follow_limit_message())}
    end
  end

  def handle_event("unfollow", _params, socket), do: act(socket, &Relationships.unfollow/2)
  def handle_event("mute", _params, socket), do: act(socket, &Relationships.mute/2)
  def handle_event("unmute", _params, socket), do: act(socket, &Relationships.unmute/2)
  def handle_event("unblock", _params, socket), do: act(socket, &Relationships.unblock/2)

  # These three change an existing follow rather than making one, which is why
  # they go through `follow/3`: a repeat follow carrying options is how the
  # options are set, and it is the same call the API makes.
  def handle_event("toggle_boosts", _params, socket) do
    set_follow(socket, %{show_reblogs: not socket.assigns.relationship.show_reblogs})
  end

  def handle_event("toggle_notify", _params, socket) do
    set_follow(socket, %{notify: not socket.assigns.relationship.notify})
  end

  def handle_event("set_languages", params, socket) do
    # An unticked multi-select sends no key at all, which is the same request a
    # form with nothing chosen makes. Both mean "all of them".
    languages = get_in(params, ["follow", "languages"]) || []

    set_follow(socket, %{languages: Enum.filter(languages, &I18n.known?/1)})
  end

  # Blocking stops the following too. Somebody who blocks and still follows has
  # a timeline full of the person they just blocked.
  def handle_event("block", _params, socket) do
    act(socket, fn viewer, subject ->
      Relationships.unfollow(viewer, subject)

      Relationships.block(viewer, subject)
    end)
  end

  # `endorse/2` refuses when the follow is not there, so a crafted event
  # arriving without one changes nothing and the page simply re-reads itself.
  def handle_event("endorse", _params, socket), do: act(socket, &Relationships.endorse/2)
  def handle_event("unendorse", _params, socket), do: act(socket, &Relationships.unendorse/2)

  # One answer for every outcome the submitter is not entitled to tell apart.
  # "Already subscribed" would let somebody type addresses in until one came
  # back, which is a way to find out who reads whom.
  def handle_event("subscribe_by_email", %{"email" => email}, socket) do
    {:noreply, assign(socket, email_subscription_said: subscribe(socket, email))}
  end

  def handle_event("save_note", %{"note" => note}, socket) do
    act(socket, fn viewer, subject -> Relationships.put_note(viewer, subject, note) end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Plumbing

  # The same budget the API endpoint spends, under the same key, so the form
  # and the endpoint cannot be used to work around each other.
  defp subscribe(socket, email) do
    cond do
      not socket.assigns.email_subscriptions_open? ->
        nil

      rate_limited?(socket) ->
        gettext("Too many tries from here just now. Try again later.")

      true ->
        record_subscription(socket.assigns.subject, email)
    end
  end

  defp record_subscription(subject, email) do
    case EmailSubscriptions.subscribe(subject, email, Gettext.get_locale(AbuubaWeb.Gettext)) do
      :ok ->
        gettext("Check that address for a message asking you to confirm.")

      {:error, %Ecto.Changeset{}} ->
        gettext("That does not look like a valid email address.")

      {:error, :closed} ->
        nil
    end
  end

  defp rate_limited?(socket) do
    case socket.assigns[:client_ip] do
      nil ->
        false

      address ->
        match?(
          {:error, _reason},
          RateLimit.hit("email_subscription:address:" <> address,
            limit: @subscribe_limit,
            window_ms: @subscribe_window_ms
          )
        )
    end
  end

  # Only what the button changed is re-read. The posts, the pinned list and
  # the header do not move when somebody follows or mutes, and reloading them
  # made every button press cost a whole page build.
  # Only on a follow that already exists: these settings are about somebody you
  # follow, and `follow/3` would otherwise make the follow as a side effect of
  # pressing a checkbox.
  defp set_follow(socket, attrs) do
    if socket.assigns.actionable? and socket.assigns.relationship.following do
      Relationships.follow(socket.assigns.viewer, socket.assigns.subject, attrs)
    end

    {:noreply, assign_relationship(socket)}
  end

  defp follow_limit_message do
    gettext("Too many follows today. Try again tomorrow.")
  end

  # The button turning into "Cancel follow request" is the whole answer for
  # anybody who knew the account was locked. For everybody else, pressing
  # Follow and not following is a surprise that needs a sentence.
  defp explain_request(%{assigns: %{relationship: %{requested: true}}} = socket) do
    put_flash(
      socket,
      :info,
      gettext("This account approves its followers. Your request is waiting for an answer.")
    )
  end

  defp explain_request(socket), do: socket

  defp act(socket, fun) do
    if socket.assigns.actionable? do
      fun.(socket.assigns.viewer, socket.assigns.subject)
    end

    {:noreply, assign_relationship(socket)}
  end

  defp assign_relationship(socket) do
    assign(socket,
      relationship: relationship(socket.assigns.viewer, socket.assigns.subject),
      note: note_of(socket.assigns.viewer, socket.assigns.subject),
      subject_languages: subject_languages(socket)
    )
  end

  # Only for somebody who can act on the follow, because it is a query and the
  # list is only ever rendered inside the follow options.
  defp subject_languages(%{assigns: %{actionable?: true, viewer: viewer, subject: subject}}) do
    if Relationships.following?(viewer, subject) do
      Statuses.languages_used_by(subject)
    else
      []
    end
  end

  defp subject_languages(_socket), do: []

  defp load_profile(socket) do
    subject = socket.assigns.subject
    viewer = socket.assigns.viewer
    rendered = Entities.account(subject, viewer)

    socket
    |> assign(
      page_title: Account.display_name(subject),
      note_html: Formatter.note_html(subject),
      fields: rendered["fields"] || [],
      featured_tags: Statuses.featured_tag_names(subject),
      moved_to: moved_to(subject),
      actionable?: actionable?(viewer, subject),
      email_subscriptions_open?: EmailSubscriptions.open?(subject)
    )
    |> assign_relationship()
    |> put_meta()
  end

  defp load_posts(socket) do
    subject = socket.assigns.subject
    viewer = socket.assigns.viewer

    page =
      %{limit: @page_size}
      |> Map.merge(filters(socket.assigns.tab))
      |> Map.merge(tag_filter(socket.assigns[:tag]))

    statuses = Statuses.account_timeline(subject, viewer, page)

    # Only the posts tab shows the pinned block, and both lists go through one
    # rendering batch: rendering them separately doubled the page's queries.
    pinned = if socket.assigns.tab == :posts, do: Statuses.pinned(subject, viewer), else: []

    {posts, pinned} =
      (statuses ++ pinned)
      |> Entities.statuses(viewer, filter_context: "account")
      |> Enum.split(length(statuses))

    socket
    |> assign(posts: Enum.reject(posts, &hidden?/1), pinned: Enum.reject(pinned, &hidden?/1))
    |> assign_featured()
  end

  # Every account here is one the subject follows, so this list is a slice of
  # the follows list — and hiding that list while publishing a slice of it on
  # the tab next to it would be the setting quietly not meaning what it says.
  # The same question, then, and not a fourth spelling of it. Only the first
  # tab shows the strip, so only that tab asks.
  defp assign_featured(socket) do
    subject = socket.assigns.subject

    featured =
      if socket.assigns.tab == :posts and
           Relationships.collections_visible?(subject, socket.assigns.viewer) do
        Relationships.endorsements(subject, %{limit: @featured_limit})
      else
        []
      end

    assign(socket, featured: featured)
  end

  # A list of people rather than of posts. Loaded here so that the two shapes
  # of this page never both run their queries.
  # One or the other, never both: a page showing followers has no business
  # running the timeline query, and vice versa.
  defp load_tab(socket) do
    if collection?(socket.assigns.tab) do
      socket |> assign(posts: [], pinned: [], featured: []) |> load_people()
    else
      socket |> assign(people: [], hidden?: false) |> load_posts()
    end
  end

  defp load_people(socket) do
    subject = socket.assigns.subject
    viewer = socket.assigns.viewer
    hidden? = not Relationships.collections_visible?(subject, viewer)
    page = %{limit: @page_size}

    people =
      cond do
        hidden? -> []
        socket.assigns.tab == :followers -> Relationships.followers(subject, viewer, page)
        socket.assigns.tab == :following -> Relationships.following(subject, viewer, page)
        true -> []
      end

    assign(socket, people: people, hidden?: hidden?)
  end

  # Somebody may always see their own. `hide_collections` is about strangers,
  # and a setting that hid the lists from the person who set it would look like
  # a bug the first time they checked it worked.
  defp collection?(tab), do: tab in [:followers, :following]

  defp filters(:posts), do: %{exclude_replies: true}
  defp filters(:with_replies), do: %{}
  defp filters(:media), do: %{exclude_replies: true, only_media: true}
  defp filters(:tagged), do: %{}

  defp tag_filter(nil), do: %{}
  defp tag_filter(name), do: %{tagged: name}

  defp put_meta(socket) do
    subject = socket.assigns.subject

    summary = Formatter.plain_text(subject.note, limit: 200)

    socket
    |> assign(:robots, robots(subject, socket.assigns[:live_action]))
    # What another server's fetcher follows when it was handed this page
    # instead of the actor: the way a pasted profile address resolves. For a
    # remote account the href is their origin's, which is where the truth
    # about them lives.
    |> assign(:page_links, [
      %{rel: "alternate", type: "application/activity+json", href: URIs.actor_uri(subject)}
    ])
    |> assign(:page_meta, [
      {"property", "og:type", "profile"},
      {"property", "og:title", "#{Account.display_name(subject)} (@#{Account.acct(subject)})"},
      {"property", "og:description", summary},
      {"property", "og:url", URIs.profile_url(subject)},
      {"name", "description", summary}
    ])
  end

  # The follower lists are a list of other people, so they stay out of a search
  # engine whatever the account itself asked for. `indexable` is off until
  # somebody turns it on, which is the same choice this server makes for
  # everything else a stranger can see.
  # Read from `live_action` rather than from `@tab`, which `handle_params` has
  # not assigned yet when the meta tags are built.
  defp robots(_subject, action) when action in [:followers, :following], do: Meta.noindex()
  defp robots(%Account{indexable: true}, _action), do: nil
  defp robots(_subject, _action), do: Meta.noindex()

  defp relationship(nil, _subject),
    do: %{
      following: false,
      requested: false,
      muting: false,
      blocking: false,
      endorsed: false,
      show_reblogs: true,
      notify: false,
      languages: []
    }

  defp relationship(viewer, subject) do
    follow = Relationships.get_follow(viewer, subject)

    %{
      following: follow != nil,
      # An account that approves its followers leaves the button waiting on
      # somebody else, and a button that says nothing about that reads as one
      # that did not work.
      requested: follow == nil and Relationships.get_follow_request(viewer, subject) != nil,
      muting: Relationships.muting?(viewer, subject),
      blocking: Relationships.blocking?(viewer, subject),
      endorsed: Relationships.endorsed?(viewer, subject),
      # What the follow says, and what it means when it says nothing: a follow
      # with no languages named is a follow that reads all of them.
      show_reblogs: follow == nil or follow.show_reblogs,
      notify: follow != nil and follow.notify,
      languages: (follow && follow.languages) || []
    }
  end

  defp note_of(nil, _subject), do: ""

  defp note_of(viewer, subject) do
    case Relationships.get_note(viewer, subject) do
      nil -> ""
      note -> note.comment || ""
    end
  end

  # Nothing to press for a passer-by, and nothing to press on yourself.
  defp actionable?(nil, _subject), do: false
  defp actionable?(viewer, subject), do: viewer.id != subject.id

  defp moved_to(%Account{moved_to_account_id: nil}), do: nil
  defp moved_to(%Account{moved_to_account_id: id}), do: Accounts.get_account(id)

  defp tabs do
    [
      {:posts, gettext("Posts")},
      {:with_replies, gettext("Posts and replies")},
      {:media, gettext("Media")},
      {:followers, gettext("Followers")},
      {:following, gettext("Follows")}
    ]
  end

  # Into the profile rather than out to the whole server's tag timeline: a
  # featured hashtag answers "what does this person write about", and the
  # server-wide page answers a different question. It is also the address this
  # server publishes for the tag in the API and in the actor document, so the
  # badge and the published link cannot point at different places.
  defp featured_tag_url(subject, tag), do: ~p"/@#{subject.username}/tagged/#{tag.name}"

  defp tab_path(subject, :tagged), do: ~p"/@#{subject.username}"
  defp tab_path(subject, :posts), do: ~p"/@#{subject.username}"
  defp tab_path(subject, :with_replies), do: ~p"/@#{subject.username}/with_replies"
  defp tab_path(subject, :media), do: ~p"/@#{subject.username}/media"
  defp tab_path(subject, :followers), do: ~p"/@#{subject.username}/followers"
  defp tab_path(subject, :following), do: ~p"/@#{subject.username}/following"

  # Empty rather than a placeholder image: the markup leaves the element out
  # entirely, so an account with no picture has no broken frame where one
  # would be.
  defp avatar_url(account), do: ProfileImages.url(account, :avatar)
  defp header_url(account), do: ProfileImages.url(account, :header)

  # Rendered the way this screen renders the rest of them, then swapped in.
  # Both lists, because a pinned post is drawn twice on a profile and updating
  # one copy would leave the other showing the old count.
end
