defmodule AbuubaWeb.ComposeComponent do
  @moduledoc """
  The box somebody writes a post in.

  ## One component, every way of posting

  A new post, a reply, and an edit are the same box in three states rather than
  three boxes. They share a character counter, a content warning, an audience,
  a language and a poll, and every place those were written twice is a place
  they drifted apart.

  ## The preview is the post

  What the box shows underneath is produced by `Abuuba.Statuses.Formatter`, the
  same function that renders the post for readers here and for every other
  server. A preview built by a second, client-side renderer is a preview that
  eventually lies: it shows a mention as a link and the post goes out with
  nothing linked, and the author has no way to see that before pressing send.

  ## Nothing typed is lost

  The box autosaves. A draft is written a couple of seconds after somebody
  stops typing rather than on every keystroke, and it is written to the same
  row each time, so a paragraph is one draft rather than two hundred. Drafts
  and posts waiting to go out are listed here too, because the place somebody
  looks for a half-finished post is the box they were writing it in.

  ## Pictures upload as soon as they are chosen

  Not on send. Alt text, a focal point and a still for a video are all things
  somebody writes while looking at the picture, and none of them can be written
  against a file that has not been uploaded yet. So a chosen file becomes an
  attachment immediately and the post picks up the ones it still holds when it
  is sent; anything abandoned is swept later as an unattached upload.

  ## The caret comes from the browser, the suggestions from the server

  Autosuggest needs to know which word is being typed, and only the browser
  knows where the caret is. So the browser reports one number, and the server
  decides what that word is and what to offer for it. The alternative is a
  client-side index of accounts, tags and emoji, which is a second copy of the
  database and stale the moment somebody registers.
  """

  use AbuubaWeb, :live_component

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.PostingDefaults
  alias Abuuba.Accounts.Preferences
  alias Abuuba.ActionLimits
  alias Abuuba.Instance
  alias Abuuba.Media
  alias Abuuba.Media.Attachment
  alias Abuuba.Media.Blurhash
  alias Abuuba.Media.Upload
  alias Abuuba.Search
  alias Abuuba.Snowflake
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Formatter
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Statuses.Status
  alias AbuubaWeb.Formats
  alias AbuubaWeb.Params

  # Endonyms, so somebody looking for their own language reads it in their own
  # language. Not a full ISO-639 list: a picker of nine thousand entries is one
  # nobody can use, and the ones people actually post in are few.
  @languages [
    {"English", "en"},
    {"Deutsch", "de"},
    {"Español", "es"},
    {"Français", "fr"},
    {"Italiano", "it"},
    {"Nederlands", "nl"},
    {"Polski", "pl"},
    {"Português", "pt"},
    {"Svenska", "sv"},
    {"Türkçe", "tr"},
    {"Русский", "ru"},
    {"Українська", "uk"},
    {"日本語", "ja"},
    {"中文", "zh"},
    {"한국어", "ko"},
    {"العربية", "ar"}
  ]

  # Long enough that a sentence is one write rather than twenty, short enough
  # that a closed tab loses a few words rather than a paragraph.
  @autosave_ms 2_000
  @max_suggestions 6

  # Narrower wins. A reply that reaches a wider audience than the post it
  # answers carries somebody else's words out of the room they said them in.
  @audience_rank %{public: 0, unlisted: 1, private: 2, limited: 2, direct: 3}

  @empty_draft %{
    "text" => "",
    "spoiler_text" => "",
    "warn" => false,
    "visibility" => "public",
    "quote_policy" => "public",
    "language" => "en",
    "caret" => "0",
    "poll_options" => ["", ""],
    "poll_multiple" => false,
    "poll_expires_in" => "86400",
    "scheduled_at" => ""
  }

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:draft, fn -> Map.merge(@empty_draft, chosen_defaults(assigns)) end)
      |> assign_new(:reply_to, fn -> nil end)
      |> assign_new(:editing, fn -> nil end)
      |> assign_new(:poll?, fn -> false end)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:suggestions, fn -> [] end)
      |> assign_new(:token, fn -> nil end)
      |> assign_new(:draft_id, fn -> nil end)
      |> assign_new(:scheduling?, fn -> false end)
      |> assign_new(:timer, fn -> nil end)
      # The browser's own offset, in the minutes it reports. Zero until it says
      # otherwise, which is UTC: a picker read in the wrong zone would send
      # somebody's post out hours early without ever saying so.
      |> assign_new(:tz_offset, fn -> 0 end)
      |> assign_new(:attachment_ids, fn -> [] end)
      |> assign_new(:alt_warned?, fn -> false end)
      |> assign_new(:thumbnail_for, fn -> nil end)
      |> assign_new(:attachments, fn -> [] end)
      |> allow_media()

    {:ok,
     socket |> apply_context(assigns) |> maybe_autosave(assigns) |> ensure_lists() |> derive()}
  end

  # `update/2` runs every time the parent re-renders — every arriving post on
  # a live timeline — and the drafts, the scheduled posts and the media
  # library only change through this component's own events, each of which
  # calls `refresh_lists/1` itself. So they are read once, not per render.
  defp ensure_lists(socket) do
    if Map.has_key?(socket.assigns, :drafts), do: socket, else: refresh_lists(socket)
  end

  # `update/2` runs on every message the component is sent, and calling this
  # twice would throw away entries that are mid-flight.
  defp allow_media(socket) do
    if socket.assigns[:uploads][:media] do
      socket
    else
      socket
      |> allow_upload(:media,
        accept: Upload.accepted_extensions(),
        max_entries: Instance.max_media_attachments(),
        max_file_size: Upload.max_bytes(),
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> allow_upload(:thumbnail,
        accept: ~w(.jpg .jpeg .png .gif .webp .avif),
        max_entries: 1,
        max_file_size: Upload.max_bytes(),
        auto_upload: true,
        progress: &handle_progress/3
      )
    end
  end

  # Uploaded the moment it lands, so that the description editor below has
  # something real to describe.
  defp handle_progress(:media, entry, socket) do
    if entry.done? do
      account = socket.assigns.account

      attachment =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok,
           Media.upload(account, %{
             path: path,
             filename: entry.client_name,
             content_type: entry.client_type
           })}
        end)

      {:noreply, add_attachment(socket, attachment)}
    else
      {:noreply, socket}
    end
  end

  defp handle_progress(:thumbnail, entry, socket) do
    if entry.done? and socket.assigns.thumbnail_for do
      attachment = own_attachment(socket, socket.assigns.thumbnail_for)

      consume_uploaded_entry(socket, entry, &store_thumbnail(attachment, entry, &1))

      {:noreply, socket |> assign(thumbnail_for: nil) |> refresh_media() |> derive()}
    else
      {:noreply, socket}
    end
  end

  defp store_thumbnail(nil, _entry, _uploaded), do: {:ok, :ignored}

  defp store_thumbnail(attachment, entry, %{path: path}) do
    Media.put_thumbnail(attachment, %{
      path: path,
      filename: entry.client_name,
      content_type: entry.client_type
    })

    {:ok, :done}
  end

  # The upload limit bounds what is in flight at once, and a finished file
  # clears its entry, so uploading one at a time walks straight past it. The
  # one over the line is removed rather than left as an orphan on disk.
  defp add_attachment(socket, {:ok, attachment}) do
    if length(socket.assigns.attachment_ids) >= Instance.max_media_attachments() do
      Media.delete_attachment(attachment)

      assign(socket,
        error:
          gettext("That is as many pictures as one post carries (%{count}).",
            count: Instance.max_media_attachments()
          )
      )
    else
      socket
      |> assign(attachment_ids: socket.assigns.attachment_ids ++ [attachment.id], error: nil)
      |> refresh_media()
      |> derive()
    end
  end

  defp add_attachment(socket, _result) do
    assign(socket, error: gettext("That file could not be uploaded."))
  end

  # A reply and an edit arrive as messages rather than as mount arguments,
  # because they happen while the box is already on screen.
  defp apply_context(socket, %{reply_to: %Status{} = parent}) do
    handles = reply_handles(parent, socket.assigns.account)

    socket
    |> assign(reply_to: parent, editing: nil, poll?: false, error: nil)
    |> assign(
      draft: %{
        socket.assigns.draft
        | "text" => prefix(handles),
          "visibility" => to_string(narrower(parent.visibility)),
          "spoiler_text" => "",
          "warn" => false
      }
    )
  end

  defp apply_context(socket, %{editing: %Status{} = status}) do
    socket
    |> assign(editing: status, reply_to: nil, poll?: false, error: nil)
    |> assign(
      draft: %{
        socket.assigns.draft
        | "text" => status.text,
          "spoiler_text" => status.spoiler_text || "",
          "warn" => status.spoiler_text not in [nil, ""],
          "visibility" => to_string(status.visibility),
          "quote_policy" => to_string(status.quote_policy),
          "language" => status.language || socket.assigns.draft["language"]
      }
    )
  end

  # Handed in by the share page, which is the only caller that starts the box
  # with something somebody did not type.
  defp apply_context(socket, %{shared_text: text}) when is_binary(text) and text != "" do
    assign(socket, draft: %{socket.assigns.draft | "text" => text})
  end

  defp apply_context(socket, _assigns), do: socket

  # Fired by a timer the parent holds, a couple of seconds after the last
  # keystroke. Failures are shown rather than swallowed: an autosave that
  # quietly stopped working is the same as no autosave at all.
  defp maybe_autosave(socket, %{autosave: true}) do
    account = socket.assigns.account
    params = savable(socket.assigns)

    case Statuses.save_draft(account, params, current_draft(socket)) do
      {:ok, draft} ->
        assign(socket, draft_id: draft.id, error: nil)

      {:error, :empty} ->
        socket

      {:error, :too_many} ->
        assign(socket,
          error: gettext("You have too many drafts to start another. Discard one first.")
        )

      {:error, _changeset} ->
        assign(socket, error: gettext("That draft could not be saved."))
    end
  end

  defp maybe_autosave(socket, _assigns), do: socket

  # Scoped to the poster's own unattached uploads in the query rather than
  # checked afterwards: one that cannot return a stranger's row cannot leak
  # one, and an id in an event payload is written by whoever is at the other
  # end of the socket.
  defp own_attachment(socket, id) do
    with {:ok, id} <- Snowflake.cast(id) do
      if id in socket.assigns.attachment_ids do
        Media.get_own_unattached(socket.assigns.account, id)
      end
    end
  end

  defp without(socket, id) do
    case Snowflake.cast(id) do
      {:ok, id} -> socket.assigns.attachment_ids -- [id]
      _ -> socket.assigns.attachment_ids
    end
  end

  # Up and down rather than dragging. A drag reorder cannot be done from a
  # keyboard, and these are the same operation with a button somebody can
  # actually reach.
  defp move_earlier(socket, id) do
    ids = socket.assigns.attachment_ids

    with {:ok, id} <- Snowflake.cast(id),
         index when is_integer(index) and index > 0 <- Enum.find_index(ids, &(&1 == id)) do
      ids |> List.delete_at(index) |> List.insert_at(index - 1, id)
    else
      _ -> ids
    end
  end

  defp clamp(value), do: value |> max(-1) |> min(1) |> :erlang.float()

  # Read when they can have changed rather than on every keystroke. `derive/1`
  # runs per keystroke, and two queries a character is two queries a character.
  defp refresh_lists(socket) do
    socket
    |> assign(
      drafts: Statuses.drafts(socket.assigns.account),
      scheduled: Statuses.scheduled(socket.assigns.account)
    )
    |> refresh_media()
  end

  # An id in an event payload is written by whoever is at the other end of the
  # socket, not by the button this server drew. A `Repo.get` on "../etc/passwd"
  # raises rather than returning nothing.
  defp find_draft(socket, id) do
    with {:ok, id} <- Snowflake.cast(id), do: Statuses.get_draft(socket.assigns.account, id)
  end

  defp find_scheduled(socket, id) do
    with {:ok, id} <- Snowflake.cast(id), do: Statuses.get_scheduled(socket.assigns.account, id)
  end

  defp current_draft(%{assigns: %{draft_id: nil}}), do: nil

  defp current_draft(%{assigns: %{draft_id: id, account: account}}) do
    Statuses.get_draft(account, id)
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="border-b border-base-300 p-4" phx-drop-target={@uploads.media.ref}>
      <div :if={@reply_to} class="mb-2 flex items-center gap-2 text-sm text-base-content/70">
        <span class="hero-arrow-uturn-left size-4" aria-hidden="true" />
        <span>{gettext("Replying to %{name}", name: reply_name(@reply_to))}</span>
        <button
          type="button"
          phx-click="reply_cancel"
          phx-target={@myself}
          class="btn btn-ghost btn-xs"
        >
          {gettext("Cancel")}
        </button>
      </div>

      <div :if={@editing} class="mb-2 flex items-center gap-2 text-sm text-base-content/70">
        <span class="hero-pencil-square size-4" aria-hidden="true" />
        <span>{gettext("Editing a post")}</span>
        <button
          type="button"
          phx-click="edit_cancel"
          phx-target={@myself}
          class="btn btn-ghost btn-xs"
        >
          {gettext("Cancel")}
        </button>
      </div>

      <.form
        for={@form}
        id="compose-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        phx-hook="Compose"
      >
        <div :if={@mentions != []} class="mb-2 flex flex-wrap gap-1">
          <button
            :for={handle <- @mentions}
            type="button"
            phx-click="mention_remove"
            phx-value-handle={handle}
            phx-target={@myself}
            class="badge badge-ghost gap-1"
          >
            @{handle}
            <span class="hero-x-mark size-3" aria-hidden="true" />
            <span class="sr-only">{gettext("Do not reply to this person")}</span>
          </button>
        </div>

        <label class={["mb-2 block", !@draft["warn"] && "hidden"]}>
          <span class="sr-only">{gettext("Content warning")}</span>
          <input
            type="text"
            name="draft[spoiler_text]"
            value={@draft["spoiler_text"]}
            placeholder={gettext("What should people be warned about?")}
            class="input input-sm w-full"
          />
        </label>

        <label class="block">
          <span class="sr-only">{gettext("What is on your mind?")}</span>
          <textarea
            id="compose-text"
            name="draft[text]"
            rows="3"
            phx-debounce="200"
            placeholder={gettext("What is on your mind?")}
            class="textarea w-full"
          >{@draft["text"]}</textarea>
        </label>

        <ul
          :if={@suggestions != []}
          id="compose-suggestions"
          class="menu menu-sm mt-1 w-full rounded-box bg-base-200"
          role="listbox"
          aria-label={gettext("Suggestions")}
        >
          <li :for={suggestion <- @suggestions}>
            <button
              type="button"
              class="compose-suggestion"
              phx-click="suggest_pick"
              phx-value-suggestion={suggestion.value}
              phx-target={@myself}
            >
              <img :if={suggestion.image} src={suggestion.image} alt="" class="size-5" />
              <span>{suggestion.label}</span>
              <span :if={suggestion.hint} class="text-base-content/60">{suggestion.hint}</span>
            </button>
          </li>
        </ul>

        <div class="mt-3 flex items-center gap-2 text-sm">
          <label class="btn btn-ghost btn-sm">
            {gettext("Add a picture, video or sound")}
            <.live_file_input upload={@uploads.media} class="sr-only" />
          </label>
          <span class="text-base-content/60">
            {gettext("or drop one on the box, or paste it")}
          </span>
        </div>

        <p :for={error <- upload_errors(@uploads.media)} class="mt-1 text-sm text-error">
          {upload_message(error)}
        </p>

        <ul :if={@uploads.media.entries != []} class="mt-2 space-y-1">
          <li :for={entry <- @uploads.media.entries} class="flex items-center gap-2 text-sm">
            <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
            <progress value={entry.progress} max="100" class="progress w-24">
              {entry.progress}%
            </progress>
            <button
              type="button"
              phx-click="upload_cancel"
              phx-value-ref={entry.ref}
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Stop")}
            </button>
          </li>
        </ul>

        <ul :if={@attachments != []} class="mt-3 space-y-3">
          <li
            :for={{attachment, index} <- Enum.with_index(@attachments)}
            id={"media-attachment-#{attachment.id}"}
            class="media-attachment rounded-box border border-base-300 p-3"
          >
            <div class="flex gap-3">
              <button
                type="button"
                id={"media-focus-#{attachment.id}"}
                phx-hook="FocalPoint"
                phx-target={@myself}
                data-media={attachment.id}
                class="relative size-20 shrink-0 overflow-hidden rounded"
                style={placeholder_style(attachment)}
                title={gettext("Click the part that matters most")}
              >
                <img
                  :if={preview_url(attachment)}
                  src={preview_url(attachment)}
                  alt=""
                  class="size-full object-cover"
                />
                <span
                  class="absolute size-3 -translate-x-1/2 -translate-y-1/2 rounded-full ring-2 ring-white"
                  style={focus_style(attachment)}
                />
                <span class="sr-only">{gettext("Set the focal point")}</span>
              </button>

              <div class="min-w-0 flex-1">
                <label class="block">
                  <span class="sr-only">{gettext("Describe this for people who cannot see it")}</span>
                  <textarea
                    rows="2"
                    phx-blur="media_describe"
                    phx-value-media={attachment.id}
                    phx-target={@myself}
                    name="description"
                    maxlength={Attachment.description_max()}
                    placeholder={gettext("Describe this for people who cannot see it")}
                    class="textarea textarea-sm w-full"
                  >{attachment.description}</textarea>
                </label>

                <div class="mt-1 flex flex-wrap items-center gap-2">
                  <button
                    :if={index > 0}
                    type="button"
                    phx-click="media_up"
                    phx-value-media={attachment.id}
                    phx-target={@myself}
                    class="btn btn-ghost btn-xs"
                  >
                    {gettext("Move earlier")}
                  </button>

                  <button
                    :if={attachment.type in [:video, :audio]}
                    type="button"
                    phx-click="media_thumbnail"
                    phx-value-media={attachment.id}
                    phx-target={@myself}
                    class="btn btn-ghost btn-xs"
                  >
                    {gettext("Add a still")}
                  </button>

                  <label :if={@thumbnail_for == attachment.id} class="btn btn-ghost btn-xs">
                    {gettext("Pick the still")}
                    <.live_file_input upload={@uploads.thumbnail} class="sr-only" />
                  </label>

                  <button
                    type="button"
                    phx-click="media_remove"
                    phx-value-media={attachment.id}
                    phx-target={@myself}
                    class="btn btn-ghost btn-xs"
                  >
                    {gettext("Take off")}
                  </button>
                </div>
              </div>
            </div>
          </li>
        </ul>

        <fieldset :if={@poll?} class="mt-3 rounded-box border border-base-300 p-3">
          <legend class="px-1 text-sm">{gettext("Poll")}</legend>

          <div
            :for={{option, index} <- Enum.with_index(@draft["poll_options"])}
            class="mb-2 flex gap-2"
          >
            <input
              type="text"
              name="draft[poll_options][]"
              value={option}
              maxlength={Poll.max_option_characters()}
              placeholder={gettext("Choice %{number}", number: index + 1)}
              class="input input-sm w-full"
            />
            <button
              :if={length(@draft["poll_options"]) > 2}
              type="button"
              phx-click="poll_option_remove"
              phx-value-index={index}
              phx-target={@myself}
              class="btn btn-ghost btn-sm"
            >
              <span class="hero-x-mark size-4" aria-hidden="true" />
              <span class="sr-only">{gettext("Remove this choice")}</span>
            </button>
          </div>

          <div class="flex flex-wrap items-center gap-3">
            <button
              :if={length(@draft["poll_options"]) < Poll.max_options()}
              type="button"
              phx-click="poll_option_add"
              phx-target={@myself}
              class="btn btn-ghost btn-sm"
            >
              {gettext("Add a choice")}
            </button>

            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name="draft[poll_multiple]" value="false" />
              <input
                type="checkbox"
                name="draft[poll_multiple]"
                value="true"
                checked={@draft["poll_multiple"]}
                class="checkbox checkbox-sm"
              />
              {gettext("Allow more than one choice")}
            </label>

            <label class="flex items-center gap-2 text-sm">
              <span>{gettext("Ends after")}</span>
              <select name="draft[poll_expires_in]" class="select select-sm">
                <option
                  :for={{seconds, label} <- poll_durations()}
                  value={seconds}
                  selected={to_string(seconds) == @draft["poll_expires_in"]}
                >
                  {label}
                </option>
              </select>
            </label>
          </div>
        </fieldset>

        <label class={["mt-3 flex items-center gap-2 text-sm", !@scheduling? && "hidden"]}>
          <span>{gettext("Goes out on")}</span>
          <input
            type="datetime-local"
            name="draft[scheduled_at]"
            value={@draft["scheduled_at"]}
            class="input input-sm"
          />
          <span class="text-base-content/60">{gettext(
            "your own time, at least %{count} minutes from now",
            count: div(ScheduledStatus.minimum_notice_seconds(), 60)
          )}</span>
        </label>

        <div :if={@draft["text"] != ""} class="mt-3 rounded-box bg-base-200 p-3">
          <p class="mb-1 text-xs uppercase text-base-content/60">{gettext("Preview")}</p>
          <div class="prose prose-sm max-w-none break-words">{raw(@preview)}</div>
        </div>

        <p :if={@error} class="mt-2 text-sm text-error" role="alert">{@error}</p>

        <div class="mt-3 flex flex-wrap items-center gap-2">
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="draft[warn]" value="false" />
            <input
              type="checkbox"
              name="draft[warn]"
              value="true"
              checked={@draft["warn"]}
              class="checkbox checkbox-sm"
            />
            {gettext("Content warning")}
          </label>

          <button
            :if={!@poll? and !@editing}
            type="button"
            phx-click="poll_add"
            phx-target={@myself}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Add a poll")}
          </button>

          <button
            :if={@poll?}
            type="button"
            phx-click="poll_remove"
            phx-target={@myself}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Remove the poll")}
          </button>

          <label class="flex items-center gap-2 text-sm">
            <span class="sr-only">{gettext("Language")}</span>
            <select name="draft[language]" class="select select-sm">
              <option
                :for={{name, code} <- languages()}
                value={code}
                selected={code == @draft["language"]}
              >
                {name}
              </option>
            </select>
          </label>

          <details class="dropdown">
            <summary class="btn btn-ghost btn-sm">{audience_label(@draft)}</summary>

            <div class="dropdown-content z-10 w-72 rounded-box bg-base-200 p-3 shadow">
              <p class="mb-1 text-xs uppercase text-base-content/60">{gettext("Who can see this")}</p>

              <button
                :for={{value, label, hint} <- visibilities()}
                type="button"
                phx-click="set_visibility"
                phx-value-visibility={value}
                phx-target={@myself}
                disabled={@editing != nil}
                aria-pressed={to_string(@draft["visibility"] == value)}
                class={[
                  "btn btn-ghost btn-sm btn-block justify-start",
                  @draft["visibility"] == value && "btn-active"
                ]}
              >
                <span class="font-medium">{label}</span>
                <span class="text-base-content/60">{hint}</span>
              </button>

              <p class="mb-1 mt-3 text-xs uppercase text-base-content/60">
                {gettext("Who can quote this")}
              </p>

              <button
                :for={{value, label} <- quote_policies()}
                type="button"
                phx-click="set_quote_policy"
                phx-value-quote-policy={value}
                phx-target={@myself}
                aria-pressed={to_string(@draft["quote_policy"] == value)}
                class={[
                  "btn btn-ghost btn-sm btn-block justify-start",
                  @draft["quote_policy"] == value && "btn-active"
                ]}
              >
                {label}
              </button>
            </div>
          </details>

          <span class={["ml-auto text-sm tabular-nums", @remaining < 0 && "text-error"]}>
            {@remaining}
          </span>

          <button
            :if={!@editing}
            type="button"
            phx-click="schedule_toggle"
            phx-target={@myself}
            aria-pressed={to_string(@scheduling?)}
            class={["btn btn-ghost btn-sm", @scheduling? && "btn-active"]}
          >
            {gettext("Schedule")}
          </button>

          <button type="submit" class="btn btn-primary btn-sm">
            {submit_label(assigns)}
          </button>
        </div>

        <p class="mt-1 text-right text-xs text-base-content/50">
          {gettext("Ctrl + Enter posts")}
        </p>
      </.form>

      <details :if={@drafts != []} class="mt-3">
        <summary class="cursor-pointer text-sm text-base-content/70">
          {ngettext("%{count} draft", "%{count} drafts", length(@drafts))}
        </summary>

        <ul class="mt-2 divide-y divide-base-300">
          <li :for={draft <- @drafts} class="flex items-center gap-2 py-2 text-sm">
            <span class="min-w-0 flex-1 truncate">{summarise(draft.params)}</span>

            <button
              type="button"
              phx-click="draft_restore"
              phx-value-draft={draft.id}
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Open")}
            </button>

            <button
              type="button"
              phx-click="draft_discard"
              phx-value-draft={draft.id}
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Discard")}
            </button>
          </li>
        </ul>
      </details>

      <details :if={@scheduled != []} class="mt-2">
        <summary class="cursor-pointer text-sm text-base-content/70">
          {ngettext(
            "%{count} post waiting to go out",
            "%{count} posts waiting to go out",
            length(@scheduled)
          )}
        </summary>

        <ul class="mt-2 divide-y divide-base-300">
          <li :for={waiting <- @scheduled} class="flex items-center gap-2 py-2 text-sm">
            <span class="min-w-0 flex-1 truncate">{summarise(waiting.params)}</span>
            <time datetime={DateTime.to_iso8601(waiting.scheduled_at)} class="text-base-content/60">
              {local_time(waiting.scheduled_at, @tz_offset)}
            </time>

            <button
              type="button"
              phx-click="schedule_edit"
              phx-value-scheduled={waiting.id}
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Open")}
            </button>

            <button
              type="button"
              phx-click="schedule_cancel"
              phx-value-scheduled={waiting.id}
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Call off")}
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  ## Events

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"draft" => params}, socket) do
    {:noreply,
     socket
     |> assign(draft: merge(socket.assigns.draft, params), error: nil)
     |> restart_autosave()
     |> derive()}
  end

  # Clamped to the range real zones occupy. The number is the browser's to make
  # up, and an unbounded one moves somebody's scheduled post by years.
  def handle_event("timezone", %{"offset" => offset}, socket)
      when is_integer(offset) and offset >= -840 and offset <= 840 do
    {:noreply, socket |> assign(tz_offset: offset) |> derive()}
  end

  def handle_event("timezone", _params, socket), do: {:noreply, socket}

  def handle_event("media_describe", %{"media" => id, "description" => description}, socket) do
    with %Attachment{} = attachment <- own_attachment(socket, id) do
      Media.describe(attachment, description)
    end

    {:noreply, socket |> assign(alt_warned?: false) |> refresh_media() |> derive()}
  end

  # The numbers arrive from a browser, so they are clamped rather than trusted.
  # A focal point outside the picture crops to nothing.
  def handle_event("media_focus", %{"media" => id, "x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    with %Attachment{} = attachment <- own_attachment(socket, id) do
      Media.update_upload(attachment, %{"focus" => "#{clamp(x)},#{clamp(y)}"})
    end

    {:noreply, socket |> refresh_media() |> derive()}
  end

  def handle_event("media_remove", %{"media" => id}, socket) do
    with %Attachment{} = attachment <- own_attachment(socket, id) do
      Media.delete_attachment(attachment)
    end

    {:noreply,
     socket |> assign(attachment_ids: without(socket, id)) |> refresh_media() |> derive()}
  end

  def handle_event("media_up", %{"media" => id}, socket) do
    {:noreply,
     socket |> assign(attachment_ids: move_earlier(socket, id)) |> refresh_media() |> derive()}
  end

  def handle_event("media_thumbnail", %{"media" => id}, socket) do
    case own_attachment(socket, id) do
      nil -> {:noreply, socket}
      attachment -> {:noreply, socket |> assign(thumbnail_for: attachment.id) |> derive()}
    end
  end

  def handle_event("upload_cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media, ref)}
  end

  def handle_event("schedule_toggle", _params, socket) do
    {:noreply, socket |> assign(scheduling?: not socket.assigns.scheduling?) |> derive()}
  end

  def handle_event("draft_restore", %{"draft" => id}, socket) do
    case find_draft(socket, id) do
      nil ->
        {:noreply, socket}

      draft ->
        {:noreply, socket |> load(draft.params) |> assign(draft_id: draft.id) |> derive()}
    end
  end

  def handle_event("draft_discard", %{"draft" => id}, socket) do
    case find_draft(socket, id) do
      nil ->
        {:noreply, socket}

      draft ->
        {:ok, _} = Statuses.discard_draft(draft)

        # The one in the box goes with it, so nothing keeps writing into a row
        # that no longer exists.
        draft_id = if socket.assigns.draft_id == draft.id, do: nil, else: socket.assigns.draft_id

        {:noreply, socket |> assign(draft_id: draft_id) |> refresh_lists() |> derive()}
    end
  end

  # Put back in the box rather than edited in place. A scheduled post is the
  # request that made it, so editing one is writing it again, and leaving the
  # old one waiting would send both.
  def handle_event("schedule_edit", %{"scheduled" => id}, socket) do
    case find_scheduled(socket, id) do
      nil ->
        {:noreply, socket}

      waiting ->
        {:ok, _} = Statuses.cancel_schedule(waiting)

        {:noreply,
         socket
         |> load(waiting.params)
         |> assign(scheduling?: true, draft_id: nil)
         |> put("scheduled_at", local_input(waiting.scheduled_at, socket.assigns.tz_offset))
         |> refresh_lists()}
    end
  end

  def handle_event("schedule_cancel", %{"scheduled" => id}, socket) do
    case find_scheduled(socket, id) do
      nil ->
        {:noreply, socket}

      waiting ->
        {:ok, _} = Statuses.cancel_schedule(waiting)

        {:noreply, socket |> refresh_lists() |> derive()}
    end
  end

  def handle_event("save", %{"draft" => params}, socket) do
    socket = assign(socket, draft: merge(socket.assigns.draft, params))

    case check(socket) do
      :ok ->
        {:noreply, socket |> write() |> derive()}

      {:error, {:alt, message}} ->
        {:noreply, socket |> assign(error: message, alt_warned?: true) |> derive()}

      {:error, message} ->
        {:noreply, socket |> assign(error: message) |> derive()}
    end
  end

  # Reported on its own rather than carried by the form, because it changes
  # when nothing about the form does: an arrow key moves the caret into a
  # different word without touching a character.
  def handle_event("caret", %{"at" => at}, socket) do
    {:noreply, put(socket, "caret", to_string(at))}
  end

  def handle_event("set_visibility", %{"visibility" => value}, socket) do
    {:noreply, put(socket, "visibility", value)}
  end

  def handle_event("set_quote_policy", %{"quote-policy" => value}, socket) do
    {:noreply, put(socket, "quote_policy", value)}
  end

  def handle_event("poll_add", _params, socket) do
    {:noreply, socket |> assign(poll?: true) |> derive()}
  end

  def handle_event("poll_remove", _params, socket) do
    {:noreply, socket |> assign(poll?: false) |> put("poll_options", ["", ""])}
  end

  def handle_event("poll_option_add", _params, socket) do
    options = socket.assigns.draft["poll_options"]

    if length(options) < Poll.max_options() do
      {:noreply, put(socket, "poll_options", options ++ [""])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("poll_option_remove", %{"index" => index}, socket) do
    options = socket.assigns.draft["poll_options"]

    if length(options) > 2 do
      {:noreply, put(socket, "poll_options", List.delete_at(options, Params.to_integer(index)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("suggest_pick", %{"suggestion" => suggestion}, socket) do
    {:noreply, socket |> assign(draft: complete(socket.assigns, suggestion)) |> derive()}
  end

  def handle_event("mention_remove", %{"handle" => handle}, socket) do
    # The trailing space goes with it where there is one, so removing the last
    # of several chips does not leave the box starting with a blank.
    text =
      socket.assigns.draft["text"]
      |> String.replace("@#{handle} ", "")
      |> String.replace("@#{handle}", "")

    {:noreply, put(socket, "text", text)}
  end

  def handle_event("reply_cancel", _params, socket) do
    {:noreply, socket |> assign(reply_to: nil) |> put("text", "")}
  end

  def handle_event("edit_cancel", _params, socket) do
    {:noreply, socket |> assign(editing: nil, error: nil) |> put("text", "")}
  end

  # An event arriving in a shape no handler above expects is one somebody wrote
  # by hand. Ignoring it beats crashing the view the person is typing into.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Writing

  # Everything is checked before anything is written. The post and its poll are
  # two writes, and a refusal after the first one leaves the post up with its
  # question missing and an error saying it was not saved.
  defp check(socket) do
    draft = socket.assigns.draft

    cond do
      String.trim(draft["text"]) == "" and not socket.assigns.poll? ->
        {:error, gettext("Write something first.")}

      length_of(draft) > Instance.max_characters() ->
        {:error,
         gettext("That is too long by %{count} characters.",
           count: length_of(draft) - Instance.max_characters()
         )}

      # Once. Somebody who has been asked and pressed send again has answered,
      # and a dialog that will not take yes for an answer is a dialog people
      # learn to click through without reading.
      warn_missing_alt?(socket) ->
        {:error,
         {:alt,
          gettext("A picture is going out without a description. Send again to post it anyway.")}}

      socket.assigns.scheduling? and is_nil(scheduled_at(socket.assigns)) ->
        {:error, gettext("Say when it should go out.")}

      socket.assigns.poll? ->
        check_poll(usable_options(draft))

      true ->
        :ok
    end
  end

  defp warn_missing_alt?(%{assigns: assigns} = socket) do
    not assigns.alt_warned? and preference(socket, "warn_missing_alt") and
      Enum.any?(assigns.attachments, &(String.trim(&1.description || "") == ""))
  end

  defp preference(socket, key) do
    socket.assigns
    |> Map.get(:user)
    |> Preferences.for_user()
    |> Map.get(key, false)
  end

  defp check_poll(options) do
    cond do
      length(options) < 2 ->
        {:error, gettext("A poll needs at least two options.")}

      Enum.any?(options, &too_long?/1) ->
        {:error,
         gettext("A poll choice is too long. Keep each under %{count} characters.",
           count: Poll.max_option_characters()
         )}

      length(Enum.uniq(options)) != length(options) ->
        {:error, gettext("Two poll choices are the same. Make them different.")}

      true ->
        :ok
    end
  end

  defp write(%{assigns: %{editing: %Status{} = status}} = socket) do
    case Statuses.edit_status(status, edit_attrs(socket.assigns.draft)) do
      {:ok, saved} ->
        send(self(), {:composed, saved})

        socket |> reset() |> refresh_lists()

      {:error, _changeset} ->
        assign(socket, error: gettext("That post could not be saved."))
    end
  end

  defp write(%{assigns: %{scheduling?: true}} = socket) do
    case Statuses.schedule(
           socket.assigns.account,
           post_params(socket.assigns),
           scheduled_at(socket.assigns)
         ) do
      {:ok, _waiting} ->
        send(self(), {:composed, :scheduled})

        socket |> forget_draft() |> reset() |> refresh_lists()

      {:error, changeset} ->
        assign(socket, error: schedule_error(changeset))
    end
  end

  defp write(socket) do
    account = socket.assigns.account

    # One write, with the pictures and the poll in it. Three writes meant
    # `create_status/2` announced the post on commit and the other two ran
    # afterwards, so the streaming API, the live timeline and the outbox were
    # each handed a photo post with no photographs -- and a poll the changeset
    # refused left a published post behind that its author had been told was
    # refused. `Abuuba.Statuses.create_status/2` grew these two options for
    # exactly this, and the API has been calling it that way.
    with :ok <- ActionLimits.take(account, :statuses),
         {:ok, status} <-
           Statuses.create_status(post_attrs(socket.assigns),
             media_ids: socket.assigns.attachment_ids,
             poll: poll_attrs(socket.assigns)
           ) do
      send(self(), {:composed, status})

      socket |> forget_draft() |> reset() |> refresh_lists()
    else
      {:error, :rate_limited} ->
        assign(socket, error: gettext("You have posted a lot just now. Try again in a while."))

      {:error, _reason} ->
        assign(socket, error: gettext("That post could not be saved."))
    end
  end

  defp post_attrs(%{draft: draft, account: account, reply_to: parent}) do
    %{
      account_id: account.id,
      text: String.trim(draft["text"]),
      spoiler_text: warning(draft),
      sensitive: warning(draft) != "",
      language: draft["language"],
      visibility: draft["visibility"],
      quote_policy: draft["quote_policy"],
      in_reply_to_id: parent && parent.id,
      in_reply_to_account_id: parent && parent.account_id,
      conversation_id: parent && parent.conversation_id
    }
  end

  # Visibility is left alone on an edit. Widening it after the fact would carry
  # a post to people the author never chose, and narrowing it cannot take back
  # the copies already delivered, so the honest answer is neither.
  defp edit_attrs(draft) do
    %{
      "text" => String.trim(draft["text"]),
      "spoiler_text" => warning(draft),
      "sensitive" => warning(draft) != "",
      "language" => draft["language"],
      "quote_policy" => draft["quote_policy"]
    }
  end

  defp poll_attrs(%{poll?: false}), do: nil

  defp poll_attrs(%{poll?: true, draft: draft}) do
    options = usable_options(draft)

    %{
      options: options,
      tallies: List.duplicate(0, length(options)),
      multiple: draft["poll_multiple"] == true,
      expires_at:
        DateTime.add(DateTime.utc_now(), Params.to_integer(draft["poll_expires_in"]), :second)
    }
  end

  defp reset(socket) do
    socket
    |> assign(reply_to: nil, editing: nil, poll?: false, error: nil, suggestions: [], token: nil)
    |> assign(draft_id: nil, scheduling?: false, attachment_ids: [], alt_warned?: false)
    |> assign(draft: Map.merge(@empty_draft, chosen_defaults(socket.assigns)))
  end

  # A draft that became a post is not a draft any more, and leaving it behind
  # fills the list with things somebody already sent.
  defp forget_draft(socket) do
    case current_draft(socket) do
      nil ->
        socket

      draft ->
        Statuses.discard_draft(draft)

        assign(socket, draft_id: nil)
    end
  end

  # Everything the box holds, as the plain map a draft and a scheduled post are
  # both stored as. The same shape goes back in through `load/2`, so a draft
  # opened months later comes back with its audience and its poll.
  defp savable(%{draft: draft, poll?: poll?, scheduling?: scheduling?}) do
    draft
    |> Map.take(~w(text spoiler_text warn visibility quote_policy language
                   poll_options poll_multiple poll_expires_in scheduled_at))
    |> Map.merge(%{"poll" => poll?, "schedule" => scheduling?})
  end

  # What `Abuuba.Statuses.schedule/3` keeps, in the shape the publisher reads it
  # back in: it builds a real status from these when the time comes.
  defp post_params(assigns) do
    assigns
    |> post_attrs()
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(["account_id"])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.merge(%{"visibility" => to_string(assigns.draft["visibility"])})
    |> put_scheduled_poll(assigns)
    |> Map.put("media_ids", assigns.attachment_ids)
  end

  defp put_scheduled_poll(params, %{poll?: false}), do: params

  defp put_scheduled_poll(params, %{poll?: true, draft: draft}) do
    Map.put(params, "poll", %{
      "options" => usable_options(draft),
      "multiple" => draft["poll_multiple"] == true,
      "expires_in" => Params.to_integer(draft["poll_expires_in"])
    })
  end

  defp load(socket, params) do
    draft =
      Enum.reduce(~w(text spoiler_text visibility quote_policy language poll_options
                     poll_multiple poll_expires_in), socket.assigns.draft, fn key, acc ->
        case Map.fetch(params, key) do
          {:ok, value} when not is_nil(value) -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    socket
    |> assign(
      draft: %{
        draft
        | "warn" => truthy(params["warn"]) or truthy(params["sensitive"]),
          "scheduled_at" => to_string(params["scheduled_at"] || "")
      }
    )
    |> assign(
      poll?: truthy(params["poll"]) or is_map(params["poll"]),
      scheduling?: truthy(params["schedule"]),
      reply_to: nil,
      editing: nil
    )
  end

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_value), do: false

  # Cancelled and set again on every keystroke, so the write happens once the
  # person stops rather than once per character.
  defp restart_autosave(socket) do
    if socket.assigns.timer, do: Process.cancel_timer(socket.assigns.timer)

    assign(socket,
      timer: Process.send_after(self(), {:compose_autosave, socket.assigns.id}, @autosave_ms)
    )
  end

  ## Time

  # The picker shows local time and sends no zone with it, so the offset the
  # browser reported is what turns one into the other. Read as UTC, a post
  # scheduled for six in the evening in Berlin goes out at eight.
  defp scheduled_at(%{draft: draft, tz_offset: offset}) do
    with text when is_binary(text) and text != "" <- draft["scheduled_at"],
         {:ok, naive} <- NaiveDateTime.from_iso8601(pad_seconds(text)) do
      naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(offset, :minute)
    else
      _ -> nil
    end
  end

  defp pad_seconds(text) do
    if String.length(text) == 16, do: text <> ":00", else: text
  end

  defp local_input(%DateTime{} = at, offset) do
    at
    |> DateTime.add(-offset, :minute)
    |> DateTime.to_naive()
    |> to_string()
    |> String.slice(0, 16)
  end

  defp local_time(%DateTime{} = at, offset) do
    at |> DateTime.add(-offset, :minute) |> Formats.datetime()
  end

  defp schedule_error(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :scheduled_at) and
         changeset |> Ecto.Changeset.get_field(:scheduled_at) |> is_nil() do
      gettext("Say when it should go out.")
    else
      first_error(changeset)
    end
  end

  defp first_error(changeset) do
    case changeset.errors do
      [{_field, {message, _opts}} | _rest] -> message
      [] -> gettext("That post could not be saved.")
    end
  end

  ## Attachments, as they are drawn

  # The average colour a blurhash carries, so the space an image will occupy is
  # roughly its colour before it arrives rather than a white flash that then
  # jumps.
  defp placeholder_style(%Attachment{blurhash: blurhash}) do
    case Blurhash.average_colour(blurhash) do
      nil -> "background-color: var(--fallback-b2, oklch(0.2 0 0 / 0.1))"
      colour -> "background-color: #{colour}"
    end
  end

  defp preview_url(%Attachment{type: :image} = attachment), do: Upload.url(attachment)
  defp preview_url(%Attachment{} = attachment), do: Upload.thumbnail_url(attachment)

  # The focal point is stored in the range the API uses, where the middle is
  # zero and the top is one. CSS counts from the top left in percent.
  defp focus_style(%Attachment{meta: meta}) do
    focus = Map.get(meta || %{}, "focus", %{})
    x = focus |> Map.get("x", 0.0) |> to_number()
    y = focus |> Map.get("y", 0.0) |> to_number()

    "left: #{(x + 1) / 2 * 100}%; top: #{(1 - y) / 2 * 100}%"
  end

  defp to_number(value) when is_number(value), do: value
  defp to_number(_value), do: 0.0

  defp upload_message(:too_large), do: gettext("That file is too big.")
  defp upload_message(:too_many_files), do: gettext("That is more files than a post can carry.")
  defp upload_message(:not_accepted), do: gettext("This server does not take files of that kind.")
  defp upload_message(_error), do: gettext("That file could not be uploaded.")

  defp summarise(params) do
    case String.trim(to_string(params["text"] || "")) do
      "" -> to_string(params["spoiler_text"] || gettext("an empty post"))
      text -> text
    end
  end

  defp submit_label(%{editing: editing}) when not is_nil(editing), do: gettext("Save changes")
  defp submit_label(%{scheduling?: true}), do: gettext("Schedule it")
  defp submit_label(_assigns), do: gettext("Post")

  ## Derived state

  # Everything the box shows about itself is computed from the draft rather
  # than tracked alongside it, so there is no second copy to fall behind.
  defp derive(socket) do
    draft = socket.assigns.draft
    {token, suggestions} = suggest(draft)

    socket
    |> assign(
      form: to_form(draft, as: :draft),
      preview: Formatter.to_html(draft["text"]),
      remaining: Instance.max_characters() - length_of(draft),
      mentions: reply_chips(socket.assigns),
      token: token,
      suggestions: suggestions
    )
  end

  # In the author's order, which lives in the component rather than in the
  # table: the table has no column for an order that only matters until the
  # post is sent.
  defp refresh_media(socket) do
    ids = socket.assigns.attachment_ids
    by_id = Media.own_unattached(socket.assigns.account, ids)

    assign(socket, attachments: Enum.flat_map(ids, &List.wrap(by_id[&1])))
  end

  defp length_of(draft), do: Formatter.length(draft["text"]) + String.length(warning(draft))

  defp warning(%{"warn" => true} = draft), do: String.trim(draft["spoiler_text"])
  defp warning(_draft), do: ""

  defp too_long?(option), do: String.length(option) > Poll.max_option_characters()

  defp usable_options(draft) do
    draft["poll_options"] |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # Only the handles the reply was opened with, and only while they are still
  # in the text: a chip for somebody the author already deleted by hand would
  # be a button that does nothing.
  defp reply_chips(%{reply_to: nil}), do: []

  defp reply_chips(%{reply_to: parent, account: account, draft: draft}) do
    named = Formatter.mentions(draft["text"])

    parent |> reply_handles(account) |> Enum.filter(&(&1 in named))
  end

  ## Suggestions

  defp suggest(draft) do
    case token_at(draft["text"], caret(draft)) do
      nil -> {nil, []}
      {kind, term, from, to} -> {{from, to}, offers(kind, term)}
    end
  end

  # The word the caret sits in, and where it starts and ends. Anchored to the
  # caret rather than to the end of the text, so somebody who went back to fix
  # a handle mid-sentence is offered that handle.
  @token ~r/(?:^|[^\w@#:])([@#:])([\w.@-]*)$/u
  @word ~r/^[\w.@-]*/u

  # Measured in characters throughout. The regex is anchored to the end of what
  # was written, so the word's start is the caret minus its length, and nothing
  # here has to convert a byte offset: "Grüße @bob" is ten characters and
  # eleven bytes, and mixing the two cuts the word in the wrong place.
  #
  # The browser counts the caret in UTF-16 code units, which agrees with this
  # for everything but astral characters. Somebody who has just typed an emoji
  # gets a suggestion for the wrong word until they type one more character.
  defp token_at(text, caret) do
    written = String.slice(text, 0, caret)

    case Regex.run(@token, written) do
      [_whole, sigil, term] when sigil != ":" or term != "" ->
        {kind(sigil), term, caret - String.length(sigil <> term), word_end(text, caret)}

      _ ->
        nil
    end
  end

  defp kind("@"), do: :mention
  defp kind("#"), do: :hashtag
  defp kind(":"), do: :emoji

  # The word runs on past the caret when somebody went back to fix its middle.
  # Stopping at the caret would leave the tail of the old word stuck to the
  # completed one.
  defp word_end(text, caret) do
    rest = String.slice(text, caret, String.length(text) - caret)

    caret + String.length(Regex.run(@word, rest) |> hd())
  end

  defp offers(_kind, ""), do: []

  defp offers(:mention, term) do
    term
    |> Search.accounts(nil, limit: @max_suggestions)
    |> Enum.map(fn account ->
      %{
        value: "@" <> Account.acct(account),
        label: Account.display_name(account),
        hint: "@" <> Account.acct(account),
        image: nil
      }
    end)
  end

  defp offers(:hashtag, term) do
    term
    |> Search.tags(nil, limit: @max_suggestions)
    |> Enum.map(&%{value: "#" <> &1.name, label: "#" <> &1.name, hint: nil, image: nil})
  end

  defp offers(:emoji, term) do
    Instance.offered_custom_emojis()
    |> Enum.filter(&String.starts_with?(&1.shortcode, term))
    |> Enum.take(@max_suggestions)
    |> Enum.map(
      &%{value: ":#{&1.shortcode}:", label: ":#{&1.shortcode}:", hint: nil, image: &1.image_url}
    )
  end

  # A space after the word, unless there already is one. Both halves matter:
  # without the space every completion runs into the next word, and with an
  # unconditional one every completion mid-sentence leaves a double space.
  defp complete(%{draft: draft, token: {from, to}}, suggestion) do
    text = draft["text"]
    tail = String.slice(text, to, String.length(text) - to)
    spacer = if String.starts_with?(tail, " "), do: "", else: " "

    completed = String.slice(text, 0, from) <> suggestion <> spacer

    %{draft | "text" => completed <> tail, "caret" => to_string(String.length(completed))}
  end

  defp complete(%{draft: draft}, _suggestion), do: draft

  ## Plumbing

  defp merge(draft, params) do
    Map.merge(draft, %{
      "text" => Map.get(params, "text", draft["text"]),
      "spoiler_text" => Map.get(params, "spoiler_text", draft["spoiler_text"]),
      "warn" => Map.get(params, "warn", to_string(draft["warn"])) == "true",
      "language" => Map.get(params, "language", draft["language"]),
      "poll_options" => Map.get(params, "poll_options", draft["poll_options"]),
      "poll_multiple" =>
        Map.get(params, "poll_multiple", to_string(draft["poll_multiple"])) == "true",
      "poll_expires_in" => Map.get(params, "poll_expires_in", draft["poll_expires_in"]),
      "scheduled_at" => Map.get(params, "scheduled_at", draft["scheduled_at"])
    })
  end

  defp put(socket, key, value) do
    socket |> assign(draft: Map.put(socket.assigns.draft, key, value)) |> derive()
  end

  # Out of range is treated as the end of the text. The number comes from a
  # browser and a stale one would otherwise cut a word in half.
  defp caret(draft) do
    length = String.length(draft["text"])

    case Params.to_integer(draft["caret"]) do
      caret when caret >= 0 and caret <= length -> caret
      _ -> length
    end
  end

  defp reply_handles(%Status{} = parent, %Account{} = account) do
    author = Accounts.get_account(parent.account_id)

    ([author && Account.acct(author)] ++ Formatter.mentions(parent.text))
    |> Enum.reject(&(&1 in [nil, Account.acct(account)]))
    |> Enum.uniq()
  end

  defp prefix([]), do: ""
  defp prefix(handles), do: Enum.map_join(handles, " ", &("@" <> &1)) <> " "

  defp narrower(visibility) do
    if Map.get(@audience_rank, visibility, 0) > 0, do: visibility, else: :public
  end

  defp reply_name(%Status{account_id: account_id}) do
    case Accounts.get_account(account_id) do
      nil -> gettext("somebody")
      account -> Account.display_name(account)
    end
  end

  # What the person chose in their settings, rather than what this module would
  # have guessed. A default audience is the setting people most regret not
  # having, and honouring it only in the API would be honouring it nowhere.
  defp chosen_defaults(assigns) do
    posting = PostingDefaults.for_user(Map.get(assigns, :user))

    %{
      "visibility" => posting["visibility"],
      "quote_policy" => posting["quote_policy"],
      "language" => posting["language"],
      "warn" => false
    }
  end

  defp languages, do: @languages

  # Mastodon's ladder, which is what other servers and clients expect to see.
  # Written once, translated where it is written: the list used to be an
  # attribute of English labels that this threw away and replaced clause by
  # clause, so an eighth rung added above raised inside `render/1`.
  defp poll_durations do
    [
      {300, gettext("5 minutes")},
      {1800, gettext("30 minutes")},
      {3600, gettext("1 hour")},
      {21_600, gettext("6 hours")},
      {86_400, gettext("1 day")},
      {259_200, gettext("3 days")},
      {604_800, gettext("7 days")}
    ]
  end

  defp visibilities do
    [
      {"public", gettext("Public"), gettext("Anyone, and listed everywhere")},
      {"unlisted", gettext("Quiet public"), gettext("Anyone, but not in public timelines")},
      {"private", gettext("Followers"), gettext("Only the people who follow you")},
      {"direct", gettext("Mentioned people"), gettext("Only the people you name")}
    ]
  end

  defp quote_policies do
    [
      {"public", gettext("Anyone")},
      {"followers", gettext("People who follow you")},
      {"nobody", gettext("Nobody")}
    ]
  end

  defp audience_label(draft) do
    case Enum.find(visibilities(), fn {value, _label, _hint} -> value == draft["visibility"] end) do
      {_value, label, _hint} -> label
      nil -> gettext("Public")
    end
  end
end
