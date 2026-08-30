defmodule AbuubaWeb.SettingsLive do
  @moduledoc """
  Everything somebody can change about their own account, in one place.

  ## One module, one surface

  The reference implementation splits these across two interfaces with a
  visible seam: some pages are part of the app and some are ordinary forms with
  a different layout, different navigation and a full page load between them.
  Somebody changing three settings crosses that seam twice. Here every section
  is an action on this LiveView, so the navigation, the layout and the
  behaviour are the same throughout.

  ## Each section is an address

  `/settings/profile`, `/settings/privacy`, and so on, rather than one page
  with tabs in socket state. A settings page somebody can link a friend to, or
  bookmark, or return to with the back button, is worth the routes.

  ## Nothing here is a moderator's

  Every write goes through a changeset that reaches only what an account's
  owner may change about themselves: `profile_changeset/2` rather than
  `changeset/2`. The wide one casts moderation state and federation endpoints,
  and this module must never be the thing holding it.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.Deletion
  alias Abuuba.Accounts.LoginActivities
  alias Abuuba.Accounts.Migration
  alias Abuuba.Accounts.PostingDefaults
  alias Abuuba.Accounts.Preferences
  alias Abuuba.Accounts.User
  alias Abuuba.EmailSubscriptions
  alias Abuuba.EmailSubscriptions.Message
  alias Abuuba.Exports
  alias Abuuba.Filters
  alias Abuuba.Filters.Filter
  alias Abuuba.Imports
  alias Abuuba.Imports.Run
  alias Abuuba.Invites
  alias Abuuba.Media.ProfileImages
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.Appeal
  alias Abuuba.Moderation.Domains
  alias Abuuba.OAuth
  alias Abuuba.Relationships
  alias Abuuba.Snowflake
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Cleanup
  alias Abuuba.Statuses.Formatter
  alias AbuubaWeb.CoreComponents
  alias AbuubaWeb.Formats
  alias AbuubaWeb.Params
  alias AbuubaWeb.ScopeWords

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    account = Accounts.get_account(user.account_id)

    if connected?(socket), do: Imports.subscribe(account)

    {:ok,
     socket
     |> assign(user: user, account: account, saved?: false, error: nil)
     |> allow_upload(:list,
       accept: ~w(.csv .txt),
       max_entries: 1,
       max_file_size: Imports.max_list_bytes()
     )
     |> allow_upload(:archive,
       # What the exporters produce: current servers write a zip and older ones
       # wrote a gzipped tar. `.tgz` has no MIME type to check against, and the
       # reader tries both formats anyway whatever the name says.
       accept: ~w(.zip .gz),
       max_entries: 1,
       # An archive is somebody's whole posting history with the pictures in
       # it. The importer refuses anything that unpacks larger than this.
       max_file_size: Imports.max_upload_bytes()
     )
     |> allow_upload(:avatar,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 1,
       # Stated here so the browser refuses an oversized file before it is
       # uploaded. A limit somebody learns about after the upload has wasted
       # their time and this server's bandwidth.
       max_file_size: ProfileImages.max_bytes()
     )
     |> allow_upload(:header,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 1,
       max_file_size: ProfileImages.max_bytes()
     )}
  end

  @impl Phoenix.LiveView
  def handle_info({:archive_import, archive_import}, socket) do
    {:noreply, assign(socket, archive_import: archive_import)}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    section = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(section: section, page_title: section_label(section), saved?: false, error: nil)
     |> load(section)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <nav class="border-b border-base-300 p-2" aria-label={gettext("Settings")}>
        <ul class="flex flex-wrap gap-1">
          <li :for={{action, label} <- sections()}>
            <.link
              navigate={section_path(action)}
              aria-current={@section == action && "page"}
              class={["rounded px-3 py-1 text-sm", @section == action && "bg-base-200 font-semibold"]}
            >
              {label}
            </.link>
          </li>
        </ul>
      </nav>

      <div class="p-4">
        <h2 class="text-xl font-semibold">{section_label(@section)}</h2>

        <p :if={@saved?} class="mt-2 text-sm text-success" role="status">{gettext("Saved.")}</p>
        <p :if={@error} class="mt-2 text-sm text-error" role="alert">{@error}</p>

        <.index :if={@section == :index} />
        <.profile
          :if={@section == :profile}
          account={@account}
          fields={@fields}
          featured_tags={@featured_tags}
          tag_suggestions={@tag_suggestions}
          uploads={@uploads}
        />
        <.appearance :if={@section == :appearance} preferences={@preferences} />
        <.posting :if={@section == :posting} posting={@posting} />
        <.housekeeping
          :if={@section == :posting}
          pinned={@pinned}
          cleanup={@user}
          cleanup_due={@cleanup_due}
        />
        <.privacy
          :if={@section == :privacy}
          account={@account}
          email_subscriptions_offered={@email_subscriptions_offered}
          email_subscriptions_on={@email_subscriptions_on}
          email_subscriber_count={@email_subscriber_count}
          email_updates={@email_updates}
          email_update_error={@email_update_error}
        />
        <.filters
          :if={@section == :filters}
          filters={@filters}
          blocked_domains={@blocked_domains}
        />
        <.follows :if={@section == :follows} following={@following} />
        <.security :if={@section == :security} logins={@logins} />
        <.applications :if={@section == :applications} applications={@applications} />
        <.account :if={@section == :account} account={@account} />
        <.invites :if={@section == :invites} invites={@invites} may_invite?={@may_invite?} />
        <.archive_import
          :if={@section == :import}
          archive_import={@archive_import}
          uploads={@uploads}
        />
        <.export
          :if={@section == :export}
          archives={@archives}
          next_archive_at={@next_archive_at}
        />
        <.strikes
          :if={@section == :strikes}
          strikes={@strikes}
          appeals={@appeals}
          severances={@severances}
        />
      </div>
    </Layouts.app>
    """
  end

  ## Sections

  defp index(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext("Everything about your account is here. Pick a section.")}
    </p>

    <ul class="mt-4 divide-y divide-base-300">
      <li :for={{action, label} <- linkable_sections()} class="py-2">
        <.link navigate={section_path(action)} class="font-medium link link-hover">{label}</.link>
        <p class="text-sm text-base-content/60">{section_hint(action)}</p>
      </li>
    </ul>
    """
  end

  attr :account, :map, required: true
  attr :fields, :list, required: true
  attr :featured_tags, :list, required: true
  attr :tag_suggestions, :list, required: true
  attr :uploads, :map, required: true

  defp profile(assigns) do
    ~H"""
    <form id="profile-form" phx-submit="save_profile" class="mt-4 space-y-4">
      <label class="block">
        <span class="label">{gettext("Display name")}</span>
        <input
          type="text"
          name="account[display_name]"
          value={@account.display_name}
          maxlength="30"
          class="input w-full"
        />
      </label>

      <label class="block">
        <span class="label">{gettext("About you")}</span>
        <textarea name="account[note]" rows="4" maxlength="500" class="textarea w-full">{@account.note}</textarea>
      </label>

      <fieldset class="rounded-box border border-base-300 p-3">
        <legend class="px-1">{gettext("Fields")}</legend>
        <p class="mb-2 text-sm text-base-content/60">
          {gettext("Up to four rows shown on your profile. The order here is the order there.")}
        </p>
        <p class="mb-2 text-sm text-base-content/60">
          {gettext(
            "A link gets a checkmark once the page it points at links back to your profile with rel=\"me\". We look again about once a week."
          )}
        </p>

        <div :for={{field, index} <- Enum.with_index(@fields)} class="mb-2 flex flex-wrap gap-2">
          <input
            type="text"
            name={"account[fields][#{index}][name]"}
            value={field.name}
            placeholder={gettext("Label")}
            class="input input-sm"
          />
          <input
            type="text"
            name={"account[fields][#{index}][value]"}
            value={field.value}
            placeholder={gettext("Value")}
            class="input input-sm flex-1"
          />
          <.verified_badge verified={verified?(@account, field)} class="self-center" />
          <button
            :if={index > 0}
            type="button"
            phx-click="move_field"
            phx-value-index={index}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Move up")}
          </button>
          <button
            type="button"
            phx-click="remove_field"
            phx-value-index={index}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Remove")}
          </button>
        </div>

        <button
          :if={length(@fields) < 4}
          type="button"
          phx-click="add_field"
          class="btn btn-ghost btn-sm"
        >
          {gettext("Add a field")}
        </button>
      </fieldset>

      <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
    </form>

    <fieldset class="mt-6 rounded-box border border-base-300 p-3">
      <legend class="px-1">{gettext("Featured hashtags")}</legend>
      <p class="mb-2 text-sm text-base-content/60">
        {gettext("Shown on your profile as a shortcut to what you write about.")}
      </p>

      <ul :if={@featured_tags != []} class="mb-2 flex flex-wrap gap-2">
        <li :for={featured <- @featured_tags} class="flex items-center gap-1">
          <span class="badge badge-ghost">#{featured.tag.name}</span>
          <span class="text-xs text-base-content/60">
            {ngettext("%{count} post", "%{count} posts", featured.statuses_count)}
          </span>
          <button
            type="button"
            phx-click="unfeature_tag"
            phx-value-tag={featured.tag.name}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Remove")}
          </button>
        </li>
      </ul>

      <form id="feature-tag-form" phx-submit="feature_tag" class="flex flex-wrap gap-2">
        <input
          type="text"
          name="tag"
          placeholder={gettext("A hashtag, without the #")}
          class="input input-sm flex-1"
        />
        <button type="submit" class="btn btn-sm">{gettext("Feature it")}</button>
      </form>

      <p :if={@tag_suggestions != []} class="mt-2 flex flex-wrap items-center gap-2 text-sm">
        <span class="text-base-content/60">{gettext("You often write about:")}</span>
        <button
          :for={tag <- @tag_suggestions}
          type="button"
          phx-click="feature_tag"
          phx-value-tag={tag.name}
          class="btn btn-ghost btn-xs"
        >
          #{tag.name}
        </button>
      </p>
    </fieldset>

    <h3 class="mt-8 font-semibold">{gettext("Pictures")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "JPEG, PNG, GIF or WebP, up to %{size}. Bigger ones are refused before they are uploaded rather than after, and what you send is scaled down here so a reader is not fetching a photograph to see it at forty pixels.",
        size: human_bytes(ProfileImages.max_bytes())
      )}
    </p>

    <div class="mt-3 grid gap-6 sm:grid-cols-2">
      <div :for={{kind, upload, label} <- picture_uploads(@uploads)}>
        <p class="font-medium">{label}</p>

        <img
          :if={picture_url(@account, kind) != ""}
          src={picture_url(@account, kind)}
          alt=""
          class={["mt-2 rounded border border-base-300", kind == :avatar && "size-20"]}
        />

        <p :if={picture_url(@account, kind) == ""} class="mt-2 text-sm text-base-content/60">
          {gettext("None yet.")}
        </p>

        <form
          id={"picture-form-#{kind}"}
          phx-submit="save_picture"
          phx-change="validate_picture"
          class="mt-2 space-y-2"
        >
          <input type="hidden" name="kind" value={kind} />
          <.live_file_input upload={upload} class="file-input file-input-sm w-full" />

          <p :for={entry <- upload.entries} class="text-sm text-base-content/60">
            {entry.client_name} — {entry.progress}%
            <span :for={error <- upload_errors(upload, entry)} class="block text-error">
              {picture_upload_message(error)}
            </span>
          </p>

          <p :for={error <- upload_errors(upload)} class="text-sm text-error">
            {picture_upload_message(error)}
          </p>

          <div class="flex flex-wrap gap-2">
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
            <button
              :if={picture_url(@account, kind) != ""}
              type="button"
              phx-click="remove_picture"
              phx-value-kind={kind}
              class="btn btn-ghost btn-sm"
            >
              {gettext("Take it off")}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :preferences, :map, required: true

  defp appearance(assigns) do
    ~H"""
    <form id="appearance-form" phx-submit="save_appearance" class="mt-4 space-y-3">
      <label :for={key <- Preferences.keys()} class="flex items-start gap-3">
        <input type="hidden" name={"preferences[#{key}]"} value="false" />
        <input
          type="checkbox"
          name={"preferences[#{key}]"}
          value="true"
          checked={@preferences[key]}
          class="checkbox checkbox-sm mt-1"
        />
        <span>
          <span class="font-medium">{preference_label(key)}</span>
          <span class="block text-sm text-base-content/60">{preference_hint(key)}</span>
        </span>
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
    </form>
    """
  end

  attr :posting, :map, required: true

  defp posting(assigns) do
    ~H"""
    <form id="posting-form" phx-submit="save_posting" class="mt-4 space-y-4">
      <label class="block">
        <span class="label">{gettext("Who new posts go to")}</span>
        <select name="posting[visibility]" class="select">
          <option
            :for={value <- PostingDefaults.visibilities()}
            value={value}
            selected={@posting["visibility"] == value}
          >
            {visibility_label(value)}
          </option>
        </select>
      </label>

      <p class="text-sm text-base-content/60">
        {gettext(
          "Only the people you name is missing on purpose: as a default it turns every post you forget to change into a message to nobody."
        )}
      </p>

      <label class="block">
        <span class="label">{gettext("Who may quote new posts")}</span>
        <select name="posting[quote_policy]" class="select">
          <option
            :for={value <- PostingDefaults.quote_policies()}
            value={value}
            selected={@posting["quote_policy"] == value}
          >
            {quote_label(value)}
          </option>
        </select>
      </label>

      <label class="block">
        <span class="label">{gettext("The language you usually write in")}</span>
        <input type="text" name="posting[language]" value={@posting["language"]} class="input" />
      </label>

      <label class="flex items-start gap-3">
        <input type="hidden" name="posting[show_application]" value="false" />
        <input
          type="checkbox"
          name="posting[show_application]"
          value="true"
          checked={@posting["show_application"]}
          class="checkbox checkbox-sm mt-1"
        />
        <span>
          <span class="font-medium">{gettext("Say which app you posted from")}</span>
          <span class="block text-sm text-base-content/60">
            {gettext("Shown under your posts to everybody else. You always see it on your own.")}
          </span>
        </span>
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
    </form>
    """
  end

  attr :pinned, :list, required: true
  attr :cleanup, :any, required: true
  attr :cleanup_due, :integer, required: true

  defp housekeeping(assigns) do
    ~H"""
    <h3 class="mt-6 font-semibold">{gettext("Pinned posts")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext("What sits at the top of your profile. Pin a post from the post itself.")}
    </p>

    <ul :if={@pinned != []} class="mt-3 divide-y divide-base-300">
      <li :for={post <- @pinned} class="flex items-center gap-2 py-2">
        <span class="min-w-0 flex-1 truncate text-sm">{plain_text(post.text)}</span>
        <button
          type="button"
          phx-click="unpin"
          phx-value-status={post.id}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Unpin")}
        </button>
      </li>
    </ul>

    <p :if={@pinned == []} class="mt-3 text-sm text-base-content/60">
      {gettext("Nothing pinned.")}
    </p>

    <h3 class="mt-8 font-semibold">{gettext("Delete my old posts")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Off unless you turn it on. Leave the age empty to turn it off again; nothing is deleted until you set one."
      )}
    </p>

    <form id="cleanup-form" phx-submit="save_cleanup" class="mt-3 max-w-md space-y-3">
      <label class="block">
        <span class="label">{gettext("Delete posts older than, in days")}</span>
        <input
          type="number"
          name="cleanup[cleanup_after_days]"
          min="7"
          value={@cleanup.cleanup_after_days}
          class="input"
        />
      </label>

      <label class="flex items-center gap-2">
        <input type="hidden" name="cleanup[cleanup_keep_pinned]" value="false" />
        <input
          type="checkbox"
          name="cleanup[cleanup_keep_pinned]"
          value="true"
          checked={@cleanup.cleanup_keep_pinned}
          class="checkbox checkbox-sm"
        />
        <span>{gettext("Keep pinned posts")}</span>
      </label>

      <label class="flex items-center gap-2">
        <input type="hidden" name="cleanup[cleanup_keep_media]" value="false" />
        <input
          type="checkbox"
          name="cleanup[cleanup_keep_media]"
          value="true"
          checked={@cleanup.cleanup_keep_media}
          class="checkbox checkbox-sm"
        />
        <span>{gettext("Keep posts with pictures or video")}</span>
      </label>

      <label class="block">
        <span class="label">{gettext("Keep posts favourited at least this many times")}</span>
        <input
          type="number"
          name="cleanup[cleanup_min_favourites]"
          min="0"
          value={@cleanup.cleanup_min_favourites}
          class="input"
        />
      </label>

      <label class="block">
        <span class="label">{gettext("Keep posts boosted at least this many times")}</span>
        <input
          type="number"
          name="cleanup[cleanup_min_boosts]"
          min="0"
          value={@cleanup.cleanup_min_boosts}
          class="input"
        />
      </label>

      <p :if={@cleanup.cleanup_after_days} class="text-sm text-base-content/60">
        {ngettext(
          "One post matches these settings right now.",
          "%{count} posts match these settings right now.",
          @cleanup_due
        )}
      </p>

      <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
    </form>
    """
  end

  attr :account, :map, required: true
  attr :email_subscriptions_offered, :boolean, required: true
  attr :email_subscriptions_on, :boolean, required: true
  attr :email_subscriber_count, :integer, required: true
  attr :email_updates, :list, required: true
  attr :email_update_error, :string, default: nil

  defp privacy(assigns) do
    ~H"""
    <form id="privacy-form" phx-submit="save_privacy" class="mt-4 space-y-3">
      <label :for={{key, label, hint} <- privacy_switches()} class="flex items-start gap-3">
        <input type="hidden" name={"account[#{key}]"} value="false" />
        <input
          type="checkbox"
          name={"account[#{key}]"}
          value="true"
          checked={Map.get(@account, key)}
          class="checkbox checkbox-sm mt-1"
        />
        <span>
          <span class="font-medium">{label}</span>
          <span class="block text-sm text-base-content/60">{hint}</span>
        </span>
      </label>

      <label class="block">
        <span class="label">{gettext("Sites that may name me as an author")}</span>
        <textarea
          name="account[attribution_domains]"
          rows="3"
          class="textarea w-full font-mono text-sm"
          placeholder="example.com"
        >{Enum.join(@account.attribution_domains || [], "\n")}</textarea>
        <span class="block text-sm text-base-content/60">
          {gettext(
            "One domain per line. When a link to one of these sites is shared here, the preview credits you as its author. A site you have not listed cannot claim you, however its page is written."
          )}
        </span>
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
    </form>

    <div :if={@email_subscriptions_offered} class="mt-8">
      <h3 class="font-semibold">{gettext("Email updates")}</h3>
      <p class="mt-1 text-sm text-base-content/60">
        {gettext(
          "People who do not want an account here can give an address instead. They confirm it themselves and can stop the updates from any message. Nothing is sent to them yet; this collects the list."
        )}
      </p>

      <form id="email-subscriptions-form" phx-submit="save_email_subscriptions" class="mt-3">
        <label class="flex items-start gap-3">
          <input type="hidden" name="email_subscriptions" value="false" />
          <input
            type="checkbox"
            name="email_subscriptions"
            value="true"
            checked={@email_subscriptions_on}
            class="checkbox checkbox-sm mt-1"
          />
          <span>
            <span class="font-medium">{gettext("Let people subscribe by email")}</span>
            <span class="block text-sm text-base-content/60">
              {ngettext(
                "One address has confirmed.",
                "%{count} addresses have confirmed.",
                @email_subscriber_count
              )}
            </span>
          </span>
        </label>

        <button type="submit" class="btn btn-primary mt-3">{gettext("Save")}</button>
      </form>

      <div :if={@email_subscriptions_on and @email_subscriber_count > 0} class="mt-6">
        <h4 class="font-medium">{gettext("Write to them")}</h4>
        <p class="mt-1 text-sm text-base-content/60">
          {gettext(
            "Goes to every address that has confirmed, with a link that stops the updates. Up to %{count} messages a day.",
            count: EmailSubscriptions.messages_per_day()
          )}
        </p>

        <form id="email-update-form" phx-submit="send_email_update" class="mt-3 grid gap-2">
          <input
            type="text"
            name="message[subject]"
            maxlength={Message.max_subject()}
            placeholder={gettext("Subject")}
            class="input w-full"
          />
          <textarea
            name="message[body]"
            rows="5"
            maxlength={Message.max_body()}
            placeholder={gettext("What you want to tell them")}
            class="textarea w-full"
          ></textarea>

          <p :if={@email_update_error} class="text-sm text-error">{@email_update_error}</p>

          <button type="submit" class="btn btn-primary justify-self-start">
            {gettext("Send it")}
          </button>
        </form>

        <ul :if={@email_updates != []} class="mt-4 divide-y divide-base-300">
          <li :for={update <- @email_updates} class="py-2">
            <span class="font-medium">{update.subject}</span>
            <span class="block text-sm text-base-content/60">
              {if update.finished_at do
                ngettext(
                  "Sent to one address on %{date}.",
                  "Sent to %{count} addresses on %{date}.",
                  update.recipient_count,
                  date: Formats.date(update.inserted_at)
                )
              else
                gettext("On its way.")
              end}
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :filters, :list, required: true
  attr :blocked_domains, :list, required: true

  defp filters(assigns) do
    ~H"""
    <ul :if={@filters != []} class="mt-4 divide-y divide-base-300">
      <li :for={filter <- @filters} class="flex items-center gap-2 py-2">
        <span class="min-w-0 flex-1">
          <span class="font-medium">{filter.title}</span>
          <span class="text-sm text-base-content/70">
            {Enum.map_join(filter.keywords, ", ", & &1.keyword)}
          </span>
          <span class="block text-sm text-base-content/60">
            {Enum.join(filter.context, ", ")} · {filter_action_label(filter.filter_action)}
          </span>
        </span>

        <button
          type="button"
          phx-click="delete_filter"
          phx-value-filter={filter.id}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Delete")}
        </button>
      </li>
    </ul>

    <form id="filter-form" phx-submit="create_filter" class="mt-4 space-y-3">
      <label class="block">
        <span class="label">{gettext("What to call it")}</span>
        <input type="text" name="filter[title]" class="input w-full" />
      </label>

      <fieldset>
        <legend class="label">{gettext("Where it applies")}</legend>
        <label :for={context <- Filter.contexts()} class="mr-4 inline-flex items-center gap-1">
          <input
            type="checkbox"
            name="filter[context][]"
            value={context}
            class="checkbox checkbox-sm"
          />
          {context_label(context)}
        </label>
      </fieldset>

      <label class="block">
        <span class="label">{gettext("Words to look for")}</span>
        <textarea name="filter[keywords]" rows="3" class="textarea w-full"></textarea>
        <span class="label">
          {gettext("One per line. A post matches when it contains any of them.")}
        </span>
      </label>

      <label class="inline-flex items-center gap-2">
        <input type="hidden" name="filter[whole_word]" value="false" />
        <input
          type="checkbox"
          name="filter[whole_word]"
          value="true"
          checked
          class="checkbox checkbox-sm"
        />
        {gettext("Whole words only, so \"cat\" does not match \"concatenate\"")}
      </label>

      <label class="block">
        <span class="label">{gettext("What it does")}</span>
        <select name="filter[filter_action]" class="select">
          <option :for={action <- Filter.actions()} value={action}>
            {filter_action_label(action)}
          </option>
        </select>
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Add a filter")}</button>
    </form>

    <h3 class="mt-8 font-semibold">{gettext("Blocked servers")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Everybody on a blocked server at once: nothing of theirs reaches your timelines, your search, your threads or your notifications. Follows in either direction are undone, as they are when you block one person."
      )}
    </p>

    <ul :if={@blocked_domains != []} class="mt-3 divide-y divide-base-300">
      <li :for={domain <- @blocked_domains} class="flex items-center gap-2 py-2">
        <span class="min-w-0 flex-1 font-mono text-sm">{domain}</span>
        <button
          type="button"
          phx-click="unblock_domain"
          phx-value-domain={domain}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Unblock")}
        </button>
      </li>
    </ul>

    <form id="domain-block-form" phx-submit="block_domain" class="mt-3 flex gap-2">
      <input
        type="text"
        name="domain"
        placeholder="example.com"
        class="input flex-1"
        autocomplete="off"
      />
      <button type="submit" class="btn">{gettext("Block a server")}</button>
    </form>
    """
  end

  attr :following, :list, required: true

  defp follows(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext("Tick anybody you want to stop following, then press the button once.")}
    </p>

    <form id="follows-form" phx-submit="unfollow_selected" class="mt-4">
      <ul class="divide-y divide-base-300">
        <li :for={person <- @following} class="flex items-center gap-3 py-2">
          <input
            type="checkbox"
            name="accounts[]"
            value={person.id}
            class="checkbox checkbox-sm"
            aria-label={Account.display_name(person)}
          />
          <span class="min-w-0 flex-1">
            <a href={"/@" <> Account.acct(person)} class="font-medium">{Account.display_name(person)}</a>
            <span class="block text-sm text-base-content/60">@{Account.acct(person)}</span>
          </span>
        </li>
      </ul>

      <p :if={@following == []} class="py-4 text-base-content/60">
        {gettext("You are not following anybody yet.")}
      </p>

      <button :if={@following != []} type="submit" class="btn btn-primary mt-3">
        {gettext("Unfollow the ticked ones")}
      </button>
    </form>
    """
  end

  attr :logins, :list, required: true

  defp security(assigns) do
    ~H"""
    <form id="password-form" phx-submit="change_password" class="mt-4 space-y-3">
      <label class="block">
        <span class="label">{gettext("Your current password")}</span>
        <input type="password" name="current_password" class="input w-full" />
      </label>

      <label class="block">
        <span class="label">{gettext("A new password")}</span>
        <input type="password" name="user[password]" class="input w-full" />
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Change the password")}</button>
    </form>

    <div class="mt-6 space-y-3">
      <.link navigate={~p"/settings/two-factor"} class="link">
        {gettext("Two-factor authentication")}
      </.link>

      <p class="text-sm text-base-content/60">
        {gettext("Signing out everywhere ends every session, including this one.")}
      </p>

      <button type="button" phx-click="sign_out_everywhere" class="btn">
        {gettext("Sign out everywhere")}
      </button>
    </div>

    <h3 class="mt-8 font-semibold">{gettext("Recent sign-ins")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Attempts that failed are here too. Somebody else trying your password is the thing worth spotting early, and nothing else would tell you."
      )}
    </p>

    <ul :if={@logins != []} class="mt-3 divide-y divide-base-300">
      <li :for={login <- @logins} class="flex flex-wrap items-baseline gap-x-3 py-2 text-sm">
        <span class={["font-medium", not login.success && "text-error"]}>
          {if login.success, do: gettext("Signed in"), else: gettext("Refused")}
        </span>
        <span>{Formats.datetime(login.inserted_at)}</span>
        <span :if={login.ip} class="text-base-content/60">{login.ip}</span>
        <span :if={login.user_agent} class="w-full truncate text-base-content/60">
          {login.user_agent}
        </span>
      </li>
    </ul>

    <p :if={@logins == []} class="mt-3 text-sm text-base-content/60">
      {gettext("Nothing recorded yet.")}
    </p>

    <p class="mt-2 text-sm text-base-content/60">
      {gettext("Kept for %{days} days, then deleted.", days: LoginActivities.keep_days())}
    </p>
    """
  end

  attr :applications, :list, required: true

  defp applications(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext("Apps you have signed in to. Taking one back out signs it out immediately.")}
    </p>

    <ul class="mt-4 divide-y divide-base-300">
      <li :for={{application, scopes} <- @applications} class="flex items-start gap-3 py-2">
        <span class="min-w-0 flex-1">
          <span class="font-medium">{application.name}</span>

          <ul :if={scopes != []} class="mt-1 text-sm text-base-content/60">
            <li :for={sentence <- ScopeWords.describe_all(scopes)}>{sentence}</li>
          </ul>

          <span :if={scopes == []} class="mt-1 block text-sm text-base-content/60">
            {gettext("Nothing. It can tell that you are signed in and no more.")}
          </span>
        </span>

        <button
          type="button"
          phx-click="revoke_application"
          phx-value-application={application.id}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Take it back out")}
        </button>
      </li>
    </ul>

    <p :if={@applications == []} class="py-4 text-base-content/60">
      {gettext("No app has been let in.")}
    </p>
    """
  end

  attr :account, :map, required: true

  defp account(assigns) do
    ~H"""
    <form id="aliases-form" phx-submit="save_aliases" class="mt-4 space-y-3">
      <label class="block">
        <span class="label">{gettext("Your other accounts")}</span>
        <textarea name="aliases" rows="3" class="textarea w-full">{Enum.join(@account.also_known_as, "\n")}</textarea>
        <span class="text-sm text-base-content/60">
          {gettext(
            "One web address per line. Naming an account here is what lets you move to it later, and it has to name this one back."
          )}
        </span>
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
    </form>

    <div :if={@account.moved_to_account_id} class="mt-6 rounded border border-base-300 p-3">
      <p class="font-semibold">{gettext("This account has moved.")}</p>
      <p class="mt-1 text-sm text-base-content/70">
        {gettext(
          "Other servers are being told to follow the new account instead. Anybody who follows you from this server has already been moved over."
        )}
      </p>
      <button type="button" phx-click="cancel_move" class="btn btn-ghost btn-sm mt-2">
        {gettext("I came back")}
      </button>
    </div>

    <form
      :if={is_nil(@account.moved_to_account_id)}
      id="move-form"
      phx-submit="move_account"
      class="mt-6 space-y-2"
    >
      <label class="block">
        <span class="label">{gettext("Move to another account")}</span>
        <input
          type="text"
          name="target"
          placeholder="you@another.example"
          class="input input-bordered w-full"
        />
      </label>

      <p class="text-sm text-base-content/60">
        {gettext(
          "The other account has to name this one in its own aliases first. Your followers here are moved over and every other server is told; an account can only be moved once every %{days} days.",
          days: Migration.cooldown_days()
        )}
      </p>

      <button type="submit" class="btn btn-primary">{gettext("Move")}</button>
    </form>

    <div class="mt-6 rounded border border-base-300 p-3">
      <p class="font-semibold">{gettext("Follow requests waiting")}</p>
      <p class="mt-1 text-sm text-base-content/70">
        {gettext(
          "After a move, everybody who followed you arrives at once. This accepts all of them, which is the same answer you already gave them."
        )}
      </p>
      <button type="button" phx-click="accept_all_requests" class="btn btn-sm mt-2">
        {gettext("Accept all")}
      </button>
    </div>

    <p class="mt-6 text-sm text-base-content/60">
      {gettext("Exporting what you have and deleting the account need work of their own.")}
    </p>
    """
  end

  attr :archives, :list, required: true
  attr :next_archive_at, :any, required: true

  defp export(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext("Everything here is yours to take, and the account is yours to close.")}
    </p>

    <h3 class="mt-6 font-semibold">{gettext("Lists")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "One file each, in the format this server's import reads. An export from here is an import somewhere else."
      )}
    </p>

    <ul class="mt-3 flex flex-wrap gap-2">
      <li :for={kind <- Abuuba.Exports.kinds()}>
        <a href={~p"/settings/export/lists/#{kind}"} class="btn btn-sm">{export_label(kind)}</a>
      </li>
    </ul>

    <h3 class="mt-8 font-semibold">{gettext("A copy of everything")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Your profile and every post, as JSON, with the lists above alongside. Built in the background; we email you when it is ready."
      )}
    </p>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Pictures and video are not in the file. It holds their addresses, which work while this server does."
      )}
    </p>

    <ul :if={@archives != []} class="mt-3 divide-y divide-base-300">
      <li :for={archive <- @archives} class="flex flex-wrap items-center gap-2 py-2">
        <span class="min-w-0 flex-1">
          <span class="font-medium">{archive_state(archive.state)}</span>
          <span class="block text-sm text-base-content/60">
            {Formats.datetime(archive.inserted_at)}
          </span>
        </span>
        <a
          :if={Abuuba.Exports.downloadable?(archive)}
          href={~p"/settings/export/archives/#{archive.id}/download"}
          class="btn btn-sm btn-primary"
        >
          {gettext("Download")}
        </a>
      </li>
    </ul>

    <p :if={@next_archive_at} class="mt-3 text-sm text-base-content/60">
      {gettext("You can ask for another one from %{date}.",
        date: Formats.date(@next_archive_at)
      )}
    </p>

    <button
      :if={is_nil(@next_archive_at)}
      type="button"
      phx-click="request_archive"
      class="btn mt-3"
    >
      {gettext("Build me a copy")}
    </button>

    <h3 class="mt-10 font-semibold text-error">{gettext("Close this account")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Your posts, follows, lists, filters, bookmarks and settings are deleted, and other servers are told to delete their copies. This cannot be undone."
      )}
    </p>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "The account disappears at once. The rows are deleted a little later, so that the message telling other servers can still be signed and sent."
      )}
    </p>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Your username is kept and nobody can ever have it, so that old links and mentions of you never point at somebody else."
      )}
    </p>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext("Take your copy first. There is nothing to export afterwards.")}
    </p>

    <form id="delete-account-form" phx-submit="delete_account" class="mt-3 max-w-sm space-y-2">
      <label class="block">
        <span class="label">{gettext("Your password, to be sure it is you")}</span>
        <input
          type="password"
          name="password"
          autocomplete="current-password"
          required
          class="input w-full"
        />
      </label>
      <button
        type="submit"
        class="btn btn-error"
        data-confirm={gettext("Close the account for good? This cannot be undone.")}
      >
        {gettext("Close the account")}
      </button>
    </form>
    """
  end

  attr :strikes, :list, required: true
  attr :appeals, :map, required: true
  attr :severances, :list, required: true

  defp strikes(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext("What a moderator here has decided about your account, and what you were told.")}
    </p>

    <ul :if={@strikes != []} class="mt-4 space-y-4">
      <li :for={strike <- @strikes} class="rounded-box border border-base-300 p-3">
        <p class="font-medium">{strike_label(strike.action)}</p>
        <p class="text-sm text-base-content/60">
          {Formats.date(strike.inserted_at)}
          <span :if={strike.overruled_at}>· {gettext("since lifted")}</span>
        </p>

        <p :if={strike.text not in [nil, ""]} class="mt-2 whitespace-pre-wrap">{strike.text}</p>

        <p :if={@appeals[strike.id]} class="mt-3 text-sm">{appeal_state(@appeals[strike.id])}</p>

        <form
          :if={appealable?(strike, @appeals[strike.id])}
          phx-submit="appeal"
          class="mt-3 space-y-2"
        >
          <input type="hidden" name="strike" value={strike.id} />
          <label class="block">
            <span class="label">{gettext("Say why you think this was wrong")}</span>
            <textarea name="text" rows="3" class="textarea w-full"></textarea>
          </label>
          <button type="submit" class="btn btn-sm">{gettext("Appeal this")}</button>
        </form>

        <p :if={too_late?(strike, @appeals[strike.id])} class="mt-3 text-sm text-base-content/60">
          {gettext("The window for appealing this has passed.")}
        </p>
      </li>
    </ul>

    <section :if={@severances != []} class="mt-6">
      <h3 class="font-semibold">{gettext("Relationships this server's decisions cost you")}</h3>
      <p class="mt-1 text-sm text-base-content/60">
        {gettext(
          "When this server stops federating with another one, the follows between you and the people there are lost. They cannot be restored from here, because the other side is no longer reachable to ask."
        )}
      </p>

      <ul class="mt-3 divide-y divide-base-300">
        <li :for={%{event: event, count: count} <- @severances} class="py-2">
          <span class="font-medium">{event.target_name}</span>
          <span class="text-sm text-base-content/60">
            · {ngettext("%{count} relationship lost", "%{count} relationships lost", count,
              count: count
            )} · {Formats.date(event.inserted_at)}
          </span>
        </li>
      </ul>
    </section>

    <p :if={@strikes == [] and @severances == []} class="mt-4 text-base-content/70">
      {gettext("Nothing here. No moderator here has taken any action about your account.")}
    </p>
    """
  end

  attr :invites, :list, required: true
  attr :may_invite?, :boolean, required: true

  defp invites(assigns) do
    ~H"""
    <p :if={not @may_invite?} class="mt-4 text-base-content/70">
      {gettext("Inviting people is not something this account can do. Ask whoever runs the server.")}
    </p>

    <div :if={@may_invite?}>
      <p class="mt-2 text-base-content/70">
        {gettext(
          "A code somebody can sign up with, even when sign-ups are closed. Leave the number of uses empty for as many as you like."
        )}
      </p>

      <form id="invite-form" phx-submit="create_invite" class="mt-4 flex flex-wrap items-end gap-2">
        <label class="block">
          <span class="label">{gettext("What it is for")}</span>
          <input type="text" name="comment" class="input" />
        </label>
        <label class="block">
          <span class="label">{gettext("How many people")}</span>
          <input type="number" name="max_uses" min="1" class="input w-32" />
        </label>
        <label class="flex items-center gap-2 pb-2">
          <input type="checkbox" name="autofollow" value="true" class="checkbox" />
          <span>{gettext("They follow you")}</span>
        </label>
        <button type="submit" class="btn btn-primary">{gettext("Make one")}</button>
      </form>

      <ul class="mt-4 divide-y divide-base-300">
        <li :for={invite <- @invites} class="flex flex-wrap items-center gap-2 py-2">
          <code class="font-mono font-semibold">{invite.code}</code>
          <span :if={invite.comment not in [nil, ""]} class="text-sm">{invite.comment}</span>
          <span class="text-sm text-base-content/60">{invite_use_count(invite)}</span>
          <button
            type="button"
            phx-click="delete_invite"
            phx-value-invite={invite.id}
            class="btn btn-sm btn-ghost ml-auto"
          >
            {gettext("Take it back")}
          </button>
        </li>
      </ul>

      <p :if={@invites == []} class="mt-4 text-base-content/70">
        {gettext("You have not made any.")}
      </p>
    </div>
    """
  end

  ## Events

  @impl Phoenix.LiveView
  def handle_event("import_archive", _params, socket) do
    {:noreply, upload(socket, :archive, %{kind: "archive"})}
  end

  def handle_event("import_list", %{"mode" => mode}, socket) do
    {:noreply, upload(socket, :list, %{kind: "list", mode: mode})}
  end

  def handle_event("move_account", %{"target" => target}, socket) do
    {:noreply, moved(socket, Migration.move(socket.assigns.account, target))}
  end

  def handle_event("cancel_move", _params, socket) do
    {:ok, account} = Migration.cancel(socket.assigns.account)

    socket |> assign(account: account, saved?: true) |> then(&{:noreply, &1})
  end

  def handle_event("accept_all_requests", _params, socket) do
    Relationships.accept_all_follow_requests(socket.assigns.account)

    {:noreply, assign(socket, saved?: true, error: nil)}
  end

  def handle_event("save_profile", %{"account" => attrs}, socket) do
    # `profile_changeset/2` rather than `changeset/2`: the wide one casts
    # moderation state and the federation endpoints, and neither is this
    # person's to set about themselves.
    save(socket, Accounts.update_profile(socket.assigns.account, ordered_fields(attrs)))
  end

  def handle_event("save_privacy", %{"account" => attrs}, socket) do
    wanted =
      attrs
      |> Map.take(~w(locked bot discoverable indexable hide_collections))
      |> Map.put("attribution_domains", String.split(Map.get(attrs, "attribution_domains", "")))

    save(socket, Accounts.update_profile(socket.assigns.account, wanted))
  end

  def handle_event("add_field", _params, socket) do
    {:noreply, assign(socket, fields: socket.assigns.fields ++ [%{name: "", value: ""}])}
  end

  def handle_event("remove_field", %{"index" => index}, socket) do
    {:noreply, update(socket, :fields, &List.delete_at(&1, Params.to_integer(index)))}
  end

  def handle_event("move_field", %{"index" => index}, socket) do
    index = Params.to_integer(index)

    {:noreply,
     update(socket, :fields, fn fields ->
       case Enum.at(fields, index) do
         nil -> fields
         field -> fields |> List.delete_at(index) |> List.insert_at(index - 1, field)
       end
     end)}
  end

  def handle_event("save_appearance", %{"preferences" => attrs}, socket) do
    user = socket.assigns.user

    save_user(socket, Preferences.merge(user.settings, attrs))
  end

  def handle_event("save_email_subscriptions", params, socket) do
    on? = Map.get(params, "email_subscriptions") == "true"
    user = socket.assigns.user

    save_user(socket, Map.put(user.settings || %{}, "email_subscriptions", on?))
  end

  def handle_event("send_email_update", %{"message" => attrs}, socket) when is_map(attrs) do
    case EmailSubscriptions.broadcast(socket.assigns.account, attrs) do
      {:ok, _message} ->
        {:noreply, socket |> assign(saved?: true) |> load(:privacy)}

      {:error, :closed} ->
        {:noreply, assign(socket, email_update_error: gettext("This list is not open."))}

      {:error, :rate_limited} ->
        {:noreply,
         assign(socket,
           email_update_error: gettext("You have sent as many messages as you can today.")
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, email_update_error: changeset_message(changeset))}
    end
  end

  def handle_event("request_archive", _params, socket) do
    case Exports.request(socket.assigns.account) do
      {:ok, _export} ->
        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:export)}

      {:error, :in_progress} ->
        {:noreply, assign(socket, error: gettext("One is already being built."))}

      {:error, {:too_soon, at}} ->
        {:noreply,
         assign(socket,
           error:
             gettext("You can ask for another one from %{date}.",
               date: Formats.date(at)
             )
         )}
    end
  end

  @doc """
  Closing the account.

  The password is checked in `Abuuba.Accounts.Deletion` rather than here, next to
  the act it authorises. This is the one thing on the server that cannot be
  undone, and somebody who walked away from a signed-in browser should not have
  the account closed by whoever sits down next.
  """
  def handle_event("delete_account", %{"password" => password}, socket) do
    case Deletion.delete_own_account(socket.assigns.user, password) do
      {:ok, _closed} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("The account is closed. Thank you for having been here."))
         |> redirect(to: ~p"/")}

      {:error, :invalid_password} ->
        {:noreply, assign(socket, error: gettext("That is not your password."))}

      _ ->
        {:noreply, assign(socket, error: gettext("That did not work. Nothing has been deleted."))}
    end
  end

  def handle_event("unpin", %{"status" => id}, socket) do
    account = socket.assigns.account

    # Scoped to the account, so an id somebody types is only ever one of their
    # own posts.
    case Enum.find(Statuses.pinned(account), &(to_string(&1.id) == to_string(id))) do
      nil -> {:noreply, socket}
      status -> unpin(socket, account, status)
    end
  end

  # Its own changeset, because these five fields between them delete posts and
  # nothing else on the user row should be reachable from this form.
  def handle_event("save_cleanup", %{"cleanup" => attrs}, socket) do
    socket.assigns.user
    |> User.cleanup_changeset(blank_to_nil(attrs))
    |> Abuuba.Repo.update()
    |> case do
      {:ok, user} ->
        {:noreply,
         socket |> assign(user: user, saved?: true, error: nil) |> load(socket.assigns.section)}

      {:error, _changeset} ->
        {:noreply,
         assign(socket,
           error: gettext("An age has to be at least 7 days, and the counts cannot be negative.")
         )}
    end
  end

  def handle_event("validate_picture", _params, socket), do: {:noreply, socket}

  # Through `Abuuba.Media.ProfileImages`, the same path the API takes, so a
  # picture set here and one set from an app are stored, scaled and served
  # identically. Two ways of writing the same column would be two sets of rules
  # about what a picture may be.
  def handle_event("save_picture", %{"kind" => kind}, socket) do
    kind = String.to_existing_atom(kind)

    case consume_picture(socket, kind) do
      {:ok, attrs} when attrs != %{} -> write_picture(socket, attrs)
      {:error, reason} -> {:noreply, assign(socket, error: picture_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("remove_picture", %{"kind" => kind}, socket) do
    attrs = ProfileImages.remove(socket.assigns.account, String.to_existing_atom(kind))

    write_picture(socket, attrs)
  end

  def handle_event("save_posting", %{"posting" => attrs}, socket) do
    user = socket.assigns.user

    save_user(socket, PostingDefaults.merge(user.settings, attrs))
  end

  def handle_event("feature_tag", %{"tag" => name}, socket) do
    case Statuses.feature_tag_by_name(socket.assigns.account, name) do
      {:ok, _tag} ->
        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:profile)}

      {:error, :too_many} ->
        {:noreply,
         assign(socket,
           error:
             gettext("A profile can carry %{count} hashtags. Take one off first.",
               count: Statuses.featured_tags_max()
             )
         )}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: gettext("That is not a hashtag anybody can use."))}
    end
  end

  def handle_event("unfeature_tag", %{"tag" => name}, socket) do
    :ok = Statuses.unfeature_tag_by_name(socket.assigns.account, name)

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:profile)}
  end

  def handle_event("create_filter", %{"filter" => attrs}, socket) do
    case keyword_attrs(attrs) do
      # A rule with no words to look for matches nothing. The API allows one,
      # because a client may be building it in two steps; a form has no second
      # step, so here it is simply a rule that would quietly do nothing.
      [] ->
        {:noreply,
         assign(socket, error: gettext("A filter needs at least one word to look for."))}

      keywords ->
        attrs = Map.put(attrs, "keywords_attributes", keywords)

        case Filters.create(socket.assigns.account, attrs) do
          {:ok, _filter} -> {:noreply, socket |> assign(saved?: true) |> load(:filters)}
          {:error, _changeset} -> {:noreply, assign(socket, error: could_not_save())}
        end
    end
  end

  def handle_event("block_domain", %{"domain" => domain}, socket) do
    # Typed by hand, so it arrives as whatever somebody pasted. The context
    # takes a domain; an address with a scheme or a trailing slash is the same
    # intention and should not be a silent no-op.
    case normalise_domain(domain) do
      "" ->
        {:noreply, socket}

      domain ->
        Relationships.block_domain(socket.assigns.account, domain)

        {:noreply, socket |> assign(saved?: true) |> load(:filters)}
    end
  end

  def handle_event("unblock_domain", %{"domain" => domain}, socket) do
    Relationships.unblock_domain(socket.assigns.account, domain)

    {:noreply, socket |> assign(saved?: true) |> load(:filters)}
  end

  def handle_event("delete_filter", %{"filter" => id}, socket) do
    with {:ok, id} <- Snowflake.cast(id),
         filter when not is_nil(filter) <- Filters.get(socket.assigns.account, id) do
      Filters.delete(filter)
    end

    {:noreply, socket |> assign(saved?: true) |> load(:filters)}
  end

  def handle_event("unfollow_selected", params, socket) do
    account = socket.assigns.account

    params
    |> Map.get("accounts", [])
    |> List.wrap()
    |> Enum.flat_map(&List.wrap(account_id(&1)))
    |> Enum.each(&Relationships.unfollow(account, &1))

    {:noreply, socket |> assign(saved?: true) |> load(:follows)}
  end

  def handle_event("change_password", params, socket) do
    user = socket.assigns.user
    current = Map.get(params, "current_password", "")

    if Auth.get_user_by_email_and_password(user.email, current) do
      change_password(socket, get_in(params, ["user", "password"]))
    else
      {:noreply, assign(socket, error: gettext("That current password is not right."))}
    end
  end

  def handle_event("sign_out_everywhere", _params, socket) do
    Auth.delete_all_session_tokens(socket.assigns.user)

    {:noreply, assign(socket, saved?: true)}
  end

  def handle_event("revoke_application", %{"application" => id}, socket) do
    with {:ok, id} <- Snowflake.cast(id) do
      OAuth.revoke_application_for(socket.assigns.user, id)
    end

    {:noreply, socket |> assign(saved?: true) |> load(:applications)}
  end

  def handle_event("save_aliases", %{"aliases" => raw}, socket) do
    lines = raw |> String.split(~r/\R/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if Enum.all?(lines, &web_address?/1) do
      save(socket, Accounts.update_profile(socket.assigns.account, %{"also_known_as" => lines}))
    else
      {:noreply,
       assign(socket, error: gettext("Each line has to be a web address, one per line."))}
    end
  end

  def handle_event("appeal", %{"strike" => strike_id, "text" => text}, socket) do
    account = socket.assigns.account

    # Scoped to the reader in the lookup rather than checked afterwards: the
    # form only offers their own, but the event carries an id and an id can be
    # typed by hand.
    case Actions.own_strike(account, strike_id) do
      nil -> {:noreply, socket}
      strike -> {:noreply, appealed(socket, Actions.appeal(account, strike, text))}
    end
  end

  def handle_event("create_invite", params, socket) do
    attrs = %{
      "comment" => params["comment"],
      "max_uses" => empty_to_nil(params["max_uses"]),
      "autofollow" => params["autofollow"] == "true"
    }

    case Invites.create(socket.assigns.account, attrs) do
      {:ok, _invite} ->
        {:noreply, socket |> assign(saved?: true) |> load(:invites)}

      {:error, :not_allowed} ->
        {:noreply, assign(socket, error: gettext("That is not something your account can do."))}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: could_not_save())}
    end
  end

  def handle_event("delete_invite", %{"invite" => id}, socket) do
    account = socket.assigns.account

    case Invites.get(account, id) do
      nil -> {:noreply, socket}
      invite -> Invites.delete(account, invite)
    end

    {:noreply, socket |> assign(saved?: true) |> load(:invites)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Plumbing

  # The section that was saved, not always the profile: privacy and aliases save
  # through here too, and reloading `:profile` for them redrew the page with
  # another section's data. `save_user/2` below already asks the socket.
  defp save(socket, {:ok, account}) do
    {:noreply,
     socket
     |> assign(account: account, saved?: true, error: nil)
     |> load(socket.assigns.section)}
  end

  defp save(socket, {:error, _changeset}) do
    {:noreply, assign(socket, error: could_not_save())}
  end

  defp save_user(socket, settings) do
    case Accounts.update_user_settings(socket.assigns.user, settings) do
      {:ok, user} ->
        {:noreply,
         socket |> assign(user: user, saved?: true, error: nil) |> load(socket.assigns.section)}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: could_not_save())}
    end
  end

  defp change_password(socket, password) do
    changeset = User.password_changeset(socket.assigns.user, %{password: password})

    case Abuuba.Repo.update(changeset) do
      {:ok, user} -> {:noreply, assign(socket, user: user, saved?: true, error: nil)}
      {:error, _changeset} -> {:noreply, assign(socket, error: could_not_save())}
    end
  end

  # Read from the saved account rather than from the row being edited, because
  # the row is whatever is in the form right now and the badge is a fact about
  # what this server fetched. Matched on the value for the same reason the
  # changeset carries the stamp over on the value: it is the thing that was
  # checked.
  defp verified?(account, field) do
    value = Map.get(field, :value)

    value not in [nil, ""] and
      Enum.any?(account.fields || [], &(&1.value == value and not is_nil(&1.verified_at)))
  end

  # Only the section being looked at asks the database.
  defp load(socket, section) do
    account = socket.assigns.account
    user = socket.assigns.user
    strikes = if section == :strikes, do: Actions.strikes(account), else: []

    socket
    |> assign_new(:fields, fn ->
      Enum.map(account.fields || [], &Map.take(&1, [:name, :value]))
    end)
    |> assign(
      featured_tags: if(section == :profile, do: Statuses.featured_tags(account), else: []),
      tag_suggestions:
        if(section == :profile,
          do: Statuses.featured_tag_suggestions(account, limit: 5),
          else: []
        ),
      preferences: Preferences.for_user(user),
      posting: PostingDefaults.for_user(user),
      strikes: strikes,
      appeals: Actions.appeals_for(strikes)
    )
    |> assign(section_data(section, account, user))
  end

  # Only the section being shown is queried. Everything else is the empty
  # answer, so that opening one page does not read five tables.
  defp section_data(section, account, user) do
    # The count is only read where it is shown. The feature is off by default,
    # so the privacy page would otherwise run a COUNT on every load to render
    # a block that is not there.
    offered? = section == :privacy and EmailSubscriptions.enabled?()

    [
      following:
        if(section == :follows, do: Relationships.following(account, %{limit: 200}), else: []),
      applications:
        if(section == :applications, do: OAuth.authorized_applications(user), else: []),
      severances: if(section == :strikes, do: Domains.severance_summary(account), else: []),
      invites: if(section == :invites, do: Invites.list(account), else: []),
      may_invite?: section == :invites and Invites.allowed?(account),
      archive_import: if(section == :import, do: Imports.latest(account))
    ] ++
      filters_data(section, account) ++
      housekeeping_data(section, account, user) ++
      email_subscription_data(offered?, account, user) ++ export_data(section == :export, account)
  end

  # What the one screen needs, asked once: the word filters and the servers
  # shut out entirely are two answers to "what do I not want to see".
  defp filters_data(:filters, account) do
    [
      filters: Filters.all(account),
      blocked_domains: Relationships.blocked_domains(account, %{limit: 200})
    ]
  end

  defp filters_data(_section, _account), do: [filters: [], blocked_domains: []]

  # The three sections that are about somebody's own housekeeping, each read
  # only where it is shown.
  defp housekeeping_data(:security, _account, user) do
    [logins: LoginActivities.recent(user), pinned: [], cleanup_due: 0]
  end

  defp housekeeping_data(:posting, account, user) do
    [logins: [], pinned: Statuses.pinned(account), cleanup_due: Cleanup.due(user, :count)]
  end

  defp housekeeping_data(_section, _account, _user) do
    [logins: [], pinned: [], cleanup_due: 0]
  end

  defp export_data(false, _account), do: [archives: [], next_archive_at: nil]

  defp export_data(true, account) do
    [archives: Exports.archives(account), next_archive_at: Exports.next_allowed(account)]
  end

  # What is wrong, in the reader's language. Through `translate_error/1` rather
  # than interpolated by hand: Ecto's messages are English literals with a
  # translation waiting in `errors.po`, and a form that reaches around that is
  # the one German screen that answers in English.
  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&CoreComponents.translate_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{field_label(field)} #{&1}")
    end)
    |> Enum.join(", ")
  end

  defp field_label(:subject), do: gettext("Subject")
  defp field_label(:body), do: gettext("Message")
  defp field_label(field), do: to_string(field)

  defp email_subscription_data(offered?, account, user) do
    on? = get_in(user.settings, ["email_subscriptions"]) == true

    [
      email_subscriptions_offered: offered?,
      email_subscriptions_on: on?,
      email_subscriber_count: if(offered?, do: EmailSubscriptions.count(account), else: 0),
      email_updates: if(offered? and on?, do: EmailSubscriptions.messages(account), else: []),
      email_update_error: nil
    ]
  end

  # The form names its rows by position, so the order somebody dragged them
  # into is the order they are saved in. A map with numeric keys does not
  # preserve that on its own.
  defp ordered_fields(attrs) do
    case Map.get(attrs, "fields") do
      fields when is_map(fields) ->
        ordered =
          fields
          |> Enum.sort_by(fn {index, _field} -> Params.to_integer(index) end)
          |> Enum.map(fn {_index, field} -> field end)
          |> Enum.reject(&(String.trim(&1["name"] || "") == ""))

        Map.put(attrs, "fields", ordered)

      _ ->
        attrs
    end
  end

  defp web_address?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        false
    end
  end

  defp appealed(socket, {:ok, _appeal}) do
    socket |> assign(saved?: true, error: nil) |> load(:strikes)
  end

  defp appealed(socket, {:error, :too_late}) do
    assign(socket, error: gettext("The window for appealing this has passed."))
  end

  defp appealed(socket, {:error, _reason}) do
    assign(socket, error: gettext("Say something about why you think it was wrong."))
  end

  # Once, and inside the window.
  defp appealable?(strike, appeal), do: is_nil(appeal) and Appeal.open?(strike)

  defp too_late?(strike, appeal), do: is_nil(appeal) and not Appeal.open?(strike)

  defp appeal_state(appeal) do
    cond do
      appeal.approved_at -> gettext("You appealed this and the appeal was upheld.")
      appeal.rejected_at -> gettext("You appealed this and the appeal was turned down.")
      true -> gettext("You have appealed this. Nobody has decided yet.")
    end
  end

  defp strike_label("none"), do: gettext("A warning")
  defp strike_label("disable"), do: gettext("Your account was disabled")
  defp strike_label("mark_statuses_as_sensitive"), do: gettext("Your posts were marked sensitive")
  defp strike_label("delete_statuses"), do: gettext("Some of your posts were deleted")
  defp strike_label("silence"), do: gettext("Your account was limited")
  defp strike_label("suspend"), do: gettext("Your account was suspended")

  defp empty_to_nil(value) when value in [nil, ""], do: nil
  defp empty_to_nil(value), do: value

  attr :archive_import, :any, required: true
  attr :uploads, :map, required: true

  defp archive_import(assigns) do
    ~H"""
    <div class="mt-4 space-y-4">
      <p class="text-sm text-base-content/70">
        {gettext(
          "Every fediverse server can give you a zip of everything you posted. Upload one here and your posts come back, with their pictures and their original dates."
        )}
      </p>

      <div class="rounded border border-base-300 p-3 text-sm">
        <p class="font-semibold">{gettext("What cannot come with them")}</p>
        <ul class="mt-1 list-disc space-y-1 pl-5 text-base-content/70">
          <li>
            {gettext(
              "The old addresses. Your posts lived on another domain and cannot live there again, so every link to one of them stays broken."
            )}
          </li>
          <li>
            {gettext(
              "Your followers. A follow is an agreement between two servers and one of them is gone; they have to follow this account."
            )}
          </li>
          <li>
            {gettext(
              "Boosts and polls. A boost points at somebody else's post, which the archive does not contain, and a poll's votes could not be true here."
            )}
          </li>
        </ul>
        <p class="mt-2 text-base-content/70">
          {gettext(
            "Imported posts stay off everybody's timeline and off the network. They appear on your profile, in the order you wrote them."
          )}
        </p>
      </div>

      <form
        :if={not running?(@archive_import)}
        id="import-list-form"
        phx-submit="import_list"
        phx-change="validate"
        class="rounded border border-base-300 p-3"
      >
        <p class="font-semibold">{gettext("Lists")}</p>
        <p class="mt-1 text-sm text-base-content/70">
          {gettext(
            "The CSV files your old server gives you: follows, blocks, mutes, domain blocks, lists, bookmarks, filters. Upload one at a time, under the name it came with."
          )}
        </p>

        <.live_file_input upload={@uploads.list} class="file-input file-input-bordered mt-2 w-full" />

        <p :for={entry <- @uploads.list.entries} class="mt-1 text-sm text-base-content/70">
          {entry.client_name}
          <span :for={error <- upload_errors(@uploads.list, entry)} class="text-error">
            {upload_message(error)}
          </span>
        </p>

        <fieldset class="mt-2">
          <legend class="text-sm font-medium">{gettext("What to do with what is here")}</legend>
          <label class="mt-1 flex items-center gap-2 text-sm">
            <input type="radio" name="mode" value="merge" checked class="radio radio-sm" />
            {gettext("Add to it")}
          </label>
          <label class="flex items-center gap-2 text-sm">
            <input type="radio" name="mode" value="overwrite" class="radio radio-sm" />
            {gettext("Replace it with the file")}
          </label>
        </fieldset>

        <button type="submit" class="btn btn-primary mt-3">{gettext("Import list")}</button>
      </form>

      <form
        :if={not running?(@archive_import)}
        id="import-archive-form"
        phx-submit="import_archive"
        phx-change="validate"
        class="rounded border border-base-300 p-3"
      >
        <p class="font-semibold">{gettext("An archive of your posts")}</p>
        <.live_file_input
          upload={@uploads.archive}
          class="file-input file-input-bordered mt-2 w-full"
        />

        <p :for={entry <- @uploads.archive.entries} class="mt-1 text-sm text-base-content/70">
          {entry.client_name}
          <span :for={error <- upload_errors(@uploads.archive, entry)} class="text-error">
            {upload_message(error)}
          </span>
        </p>

        <button type="submit" class="btn btn-primary mt-3">{gettext("Import archive")}</button>
      </form>

      <div :if={@archive_import} class="rounded border border-base-300 p-3">
        <p class="font-semibold">{import_state(@archive_import)}</p>

        <progress
          :if={running?(@archive_import)}
          class="progress progress-primary mt-2 w-full"
          value={@archive_import.done}
          max={max(@archive_import.total, 1)}
        ></progress>

        <p class="mt-1 text-sm text-base-content/70">
          {gettext("%{done} of %{total} read, %{imported} brought over.",
            done: @archive_import.done,
            total: @archive_import.total,
            imported: @archive_import.imported
          )}
        </p>

        <details :if={@archive_import.failures != []} class="mt-2 text-sm">
          <summary class="cursor-pointer">
            {gettext("%{count} could not be brought over", count: length(@archive_import.failures))}
          </summary>
          <ul class="mt-1 space-y-1 pl-4">
            <li :for={failure <- @archive_import.failures} class="text-base-content/70">
              {failure["what"]} — {failure_reason(failure["reason"])}
            </li>
          </ul>
        </details>
      </div>
    </div>
    """
  end

  # The file LiveView wrote is deleted the moment the upload is consumed, and
  # the job that reads it starts after that, so it is copied somewhere that
  # outlives the request.
  defp upload(socket, name, attrs) do
    account = socket.assigns.account

    started =
      consume_uploaded_entries(socket, name, fn %{path: path}, entry ->
        kept = Imports.keep(path, entry.client_name)

        {:ok,
         Imports.start(account, Map.merge(attrs, %{path: kept, filename: entry.client_name}))}
      end)

    started(socket, List.first(started))
  end

  defp moved(socket, {:ok, account}) do
    assign(socket, account: account, saved?: true, error: nil)
  end

  defp moved(socket, {:error, reason}) do
    assign(socket, error: move_error(reason))
  end

  defp move_error(:no_backlink),
    do:
      gettext(
        "That account does not name this one as one of yours. Add this account's address to its aliases first."
      )

  defp move_error(:moved_too_recently),
    do:
      gettext("You moved recently. An account can only be moved once every %{days} days.",
        days: Migration.cooldown_days()
      )

  defp move_error(:unknown_account), do: gettext("Nobody could be found at that address.")
  defp move_error(:same_account), do: gettext("That is this account.")
  defp move_error(_other), do: could_not_save()

  defp started(socket, {:ok, archive_import}) do
    assign(socket, archive_import: archive_import, error: nil)
  end

  defp started(socket, {:error, _reason}) do
    assign(socket,
      error: gettext("That could not be read. Upload the archive your old server gave you.")
    )
  end

  defp started(socket, nil), do: assign(socket, error: gettext("Choose an archive first."))

  # Its own set, because "that is not an archive file" on an avatar field is
  # the kind of message that makes somebody doubt they clicked the right thing.
  defp picture_upload_message(:too_large),
    do: gettext("That picture is too large. The limit is on the line above.")

  defp picture_upload_message(:not_accepted),
    do: gettext("That is not a picture this server can use. Try a JPEG, PNG, GIF or WebP.")

  defp picture_upload_message(:too_many_files), do: gettext("One picture at a time.")
  defp picture_upload_message(_other), do: gettext("That could not be uploaded.")

  defp upload_message(:too_large), do: gettext("That file is too large.")
  defp upload_message(:not_accepted), do: gettext("That is not an archive file.")
  defp upload_message(:too_many_files), do: gettext("One archive at a time.")
  defp upload_message(_other), do: gettext("That could not be uploaded.")

  defp running?(nil), do: false
  defp running?(archive_import), do: Run.running?(archive_import)

  defp import_state(%{state: "pending"}), do: gettext("Waiting to start.")
  defp import_state(%{state: "running"}), do: gettext("Reading your archive.")
  defp import_state(%{state: "finished"}), do: gettext("Finished.")
  defp import_state(%{state: "failed"}), do: gettext("That archive could not be read.")

  defp failure_reason("boosts_are_not_carried"),
    do: gettext("a boost, which cannot come with you")

  defp failure_reason("polls_are_not_carried"), do: gettext("a poll, which cannot come with you")
  defp failure_reason("no_date"), do: gettext("it has no date, so it has nowhere to go")
  defp failure_reason("could_not_be_fetched"), do: gettext("the post could not be found")
  defp failure_reason("could_not_be_saved"), do: gettext("this server would not accept it")
  defp failure_reason("unreadable_archive"), do: gettext("the file is not an archive")
  defp failure_reason(other), do: other

  defp invite_use_count(%{max_uses: nil, uses: uses}),
    do: ngettext("used %{count} time", "used %{count} times", uses, count: uses)

  defp invite_use_count(%{max_uses: max, uses: uses}),
    do: gettext("%{uses} of %{max} used", uses: uses, max: max)

  defp could_not_save, do: gettext("That could not be saved. Check what you typed.")

  defp sections do
    [
      {:index, gettext("Overview")},
      {:profile, gettext("Profile")},
      {:appearance, gettext("Appearance")},
      {:posting, gettext("Posting")},
      {:privacy, gettext("Privacy")},
      {:filters, gettext("Filters")},
      {:follows, gettext("Follows")},
      {:security, gettext("Security")},
      {:applications, gettext("Apps")},
      {:account, gettext("Account")},
      {:strikes, gettext("Moderation")},
      {:invites, gettext("Invites")},
      {:import, gettext("Import")},
      {:export, gettext("Export")}
    ]
  end

  defp linkable_sections, do: Enum.reject(sections(), fn {action, _label} -> action == :index end)

  defp section_label(section) do
    case Enum.find(sections(), fn {action, _label} -> action == section end) do
      {_action, label} -> label
      nil -> gettext("Settings")
    end
  end

  defp section_hint(:profile), do: gettext("Your name, what you say about yourself, your fields.")
  defp section_hint(:appearance), do: gettext("How the interface behaves and reads.")
  defp section_hint(:posting), do: gettext("What the compose box starts with.")
  defp section_hint(:privacy), do: gettext("Who can find you and who has to ask to follow.")
  defp section_hint(:filters), do: gettext("Words and phrases you would rather not see.")
  defp section_hint(:follows), do: gettext("Everybody you follow, and a way to stop.")
  defp section_hint(:security), do: gettext("Your password, two-factor, and signing out.")
  defp section_hint(:applications), do: gettext("Apps that have been let into your account.")
  defp section_hint(:account), do: gettext("Other accounts of yours, and moving between them.")

  defp section_hint(:strikes),
    do: gettext("Anything a moderator here has decided about your account.")

  defp section_hint(:invites), do: gettext("Codes that let somebody you know sign up.")

  defp section_hint(:import),
    do: gettext("Read an archive of your posts from another server back in.")

  defp section_hint(:export),
    do: gettext("Take a copy of everything, or close the account for good.")

  defp section_hint(_section), do: ""

  defp section_path(:index), do: ~p"/settings"
  defp section_path(:profile), do: ~p"/settings/profile"
  defp section_path(:appearance), do: ~p"/settings/appearance"
  defp section_path(:posting), do: ~p"/settings/posting"
  defp section_path(:privacy), do: ~p"/settings/privacy"
  defp section_path(:filters), do: ~p"/settings/filters"
  defp section_path(:follows), do: ~p"/settings/follows"
  defp section_path(:security), do: ~p"/settings/security"
  defp section_path(:applications), do: ~p"/settings/applications"
  defp section_path(:account), do: ~p"/settings/account"
  defp section_path(:strikes), do: ~p"/settings/moderation"
  defp section_path(:invites), do: ~p"/settings/invites"
  defp section_path(:import), do: ~p"/settings/import"
  defp section_path(:export), do: ~p"/settings/export"

  defp unpin(socket, account, status) do
    Statuses.unpin(account, status)

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:posting)}
  end

  # An empty number field means "no rule", not zero. Without this, clearing the
  # age would fail validation instead of turning the whole thing off, and
  # clearing a threshold would silently become "keep nothing".
  defp blank_to_nil(attrs) do
    Map.new(attrs, fn
      {key, ""} -> {key, nil}
      pair -> pair
    end)
  end

  defp plain_text(html), do: Formatter.plain_text(html)

  # `consume_uploaded_entries` hands over a path that is deleted the moment the
  # function returns, which is exactly the shape `ProfileImages.store/3` wants:
  # it copies what it keeps.
  defp consume_picture(socket, kind) do
    account = socket.assigns.account

    case consume_uploaded_entries(socket, kind, fn %{path: path}, entry ->
           {:ok, ProfileImages.store(account, kind, %{path: path, filename: entry.client_name})}
         end) do
      [{:ok, attrs}] -> {:ok, attrs}
      [{:error, reason}] -> {:error, reason}
      [] -> {:ok, %{}}
    end
  end

  # Through `update_account/2` rather than the profile changeset, which is the
  # same split the API makes and for the same reason: the picture columns name
  # a file, and a path this server did not write a moment ago must never be
  # able to reach them.
  defp write_picture(socket, attrs) do
    socket.assigns.account
    |> Accounts.update_account(attrs)
    |> case do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(account: account, saved?: true, error: nil)
         |> load(socket.assigns.section)}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: gettext("That picture could not be saved."))}
    end
  end

  defp picture_error(:unsupported),
    do: gettext("That is not a picture this server can use. Try a JPEG, PNG, GIF or WebP.")

  defp picture_error(_reason), do: gettext("That picture could not be saved.")

  defp picture_uploads(uploads) do
    [
      {:avatar, uploads.avatar, gettext("Avatar")},
      {:header, uploads.header, gettext("Header")}
    ]
  end

  defp picture_url(account, kind), do: ProfileImages.url(account, kind)

  # Megabytes, through the formatter and with the unit translated. Integer
  # division would render a 4.7 MB limit as "4 MB", which is a smaller number
  # than the one the upload actually refuses at, and a bare interpolation
  # would show a German reader "4.7" where they read "4,7".
  defp human_bytes(bytes) do
    case Float.round(bytes / (1024 * 1024), 1) do
      whole when whole == trunc(whole) ->
        gettext("%{size} MB", size: Formats.number(trunc(whole)))

      fraction ->
        gettext("%{size} MB", size: Formats.number(fraction))
    end
  end

  defp export_label("follows"), do: gettext("Follows")
  defp export_label("blocks"), do: gettext("Blocks")
  defp export_label("mutes"), do: gettext("Mutes")
  defp export_label("lists"), do: gettext("Lists")
  defp export_label("domain_blocks"), do: gettext("Blocked servers")
  defp export_label("bookmarks"), do: gettext("Bookmarks")
  defp export_label("filters"), do: gettext("Filters")
  defp export_label(kind), do: kind

  defp archive_state("pending"), do: gettext("Waiting to start")
  defp archive_state("running"), do: gettext("Being built")
  defp archive_state("done"), do: gettext("Ready")
  defp archive_state("failed"), do: gettext("Did not work")
  defp archive_state(state), do: state

  defp normalise_domain(domain) do
    domain
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
    |> String.replace_prefix("*.", "")
    |> String.trim_trailing("/")
    |> String.split("/")
    |> List.first()
    |> to_string()
  end

  defp privacy_switches do
    [
      {:locked, gettext("Ask before letting somebody follow you"),
       gettext("Every follow becomes a request you answer.")},
      {:discoverable, gettext("List me in the directory"),
       gettext("Your account appears on this server's public directory page.")},
      {:indexable, gettext("Let search engines index my posts"),
       gettext("Applies to your public posts only.")},
      {:hide_collections, gettext("Hide who I follow and who follows me"),
       gettext("The lists stop being public; the follows themselves still work.")},
      {:bot, gettext("This account posts automatically"),
       gettext("Marks the account as a bot, which some people filter on.")}
    ]
  end

  defp preference_label("reduce_motion"), do: gettext("Reduce motion")
  defp preference_label("high_contrast"), do: gettext("Higher contrast")
  defp preference_label("system_font"), do: gettext("Use my system's font")
  defp preference_label("disable_autoplay"), do: gettext("Do not play media on its own")
  defp preference_label("warn_missing_alt"), do: gettext("Warn me about missing descriptions")
  defp preference_label(key), do: key

  defp preference_hint("reduce_motion"),
    do: gettext("Overrides your system setting if it is wrong for you.")

  defp preference_hint("warn_missing_alt"),
    do: gettext("Stops the first send when a picture has no description.")

  defp preference_hint(_key), do: ""

  defp visibility_label("public"), do: gettext("Anyone, and listed everywhere")
  defp visibility_label("unlisted"), do: gettext("Anyone, but not in public timelines")
  defp visibility_label("private"), do: gettext("Only the people who follow you")
  defp visibility_label(value), do: value

  defp quote_label("public"), do: gettext("Anyone")
  defp quote_label("followers"), do: gettext("People who follow you")
  defp quote_label("nobody"), do: gettext("Nobody")
  defp quote_label(value), do: value

  defp context_label("home"), do: gettext("Home")
  defp context_label("notifications"), do: gettext("Notifications")
  defp context_label("public"), do: gettext("Public timelines")
  defp context_label("thread"), do: gettext("Threads")
  defp context_label("account"), do: gettext("Profiles")
  defp context_label(context), do: context

  # One word or phrase per line, blanks dropped. A textarea rather than a row
  # of inputs because somebody adding a filter usually has a handful of
  # spellings in mind at once and typing them is faster than adding rows.
  defp keyword_attrs(attrs) do
    whole_word = AbuubaWeb.API.boolean(Map.get(attrs, "whole_word"))

    for line <- String.split(Map.get(attrs, "keywords", ""), "\n"),
        word = String.trim(line),
        word != "",
        do: %{"keyword" => word, "whole_word" => whole_word}
  end

  defp filter_action_label("warn"), do: gettext("Fold it behind a warning")
  defp filter_action_label("hide"), do: gettext("Hide it completely")
  defp filter_action_label(action), do: action

  defp account_id(value) do
    case Snowflake.cast(value) do
      {:ok, id} -> id
      _ -> nil
    end
  end
end
