defmodule AbuubaWeb.AdminLive do
  @moduledoc """
  The admin area: what is waiting, who is here, what the server is set to, and
  what has been done.

  One LiveView with a section per live action, the same shape as
  `AbuubaWeb.SettingsLive`. An admin moving from the dashboard to an account and
  on to the log should not cross a seam where the navigation and the layout
  change under them.

  ## Permissions are asked twice

  Getting in asks whether the person may use any section. Each section then
  asks for its own, so an address typed by hand is refused the same way the
  missing link would have been. The navigation only lists what somebody may
  actually open: a link that answers "not allowed" is a worse answer than no
  link at all.
  """

  use AbuubaWeb, :live_view

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Suggestions
  alias Abuuba.Admin
  alias Abuuba.Admin.Metrics
  alias Abuuba.Federation.Instances
  alias Abuuba.Federation.Relays
  alias Abuuba.Instance
  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Instance.EmojiImages
  alias Abuuba.Instance.UpdateCheck
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.DomainLists
  alias Abuuba.Moderation.Domains
  alias Abuuba.Moderation.Reports
  alias Abuuba.Moderation.Signup
  alias Abuuba.Moderation.Strike
  alias Abuuba.Moderation.WarningPresets
  alias Abuuba.Roles
  alias Abuuba.Roles.Role
  alias Abuuba.Settings
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Formatter
  alias Abuuba.Streaming
  alias Abuuba.Trends
  alias Abuuba.Webhooks
  alias Abuuba.Webhooks.Delivery
  alias Abuuba.Webhooks.Webhook
  alias AbuubaWeb.Formats

  @sections [
    {:dashboard, "view_dashboard"},
    {:accounts, "manage_users"},
    {:reports, "manage_reports"},
    {:appeals, "manage_appeals"},
    {:emoji, "manage_custom_emojis"},
    {:trends, "manage_taxonomies"},
    {:announcements, "manage_announcements"},
    {:signups, "manage_blocks"},
    {:relays, "manage_federation"},
    {:webhooks, "manage_webhooks"},
    {:roles, "manage_roles"},
    {:instances, "manage_federation"},
    {:domain_lists, "manage_federation"},
    {:suggestions, "manage_taxonomies"},
    {:subscriptions, "manage_settings"},
    {:settings, "manage_settings"},
    {:audit, "view_audit_log"}
  ]

  # What each event needs, and nothing is reachable that is not named here.
  #
  # The section gate in `handle_params/3` decides which screens somebody may
  # open; it says nothing about which events they may send, and an event is
  # sent by whatever is on the other end of the socket rather than by the page
  # that was rendered. So a moderator let in for one section could send another
  # section's events, and did: a role holding only report permissions could
  # rewrite the server settings by sending `save_settings` from the report
  # queue.
  #
  # Default-deny, so an event added without a line here is refused rather than
  # open. That is the failure worth having: a missing entry is a button that
  # does not work, which somebody notices, where the other way round is a hole
  # nobody notices.
  @event_permissions %{
    "act" => "manage_users",
    "approve" => "manage_users",
    "batch" => "manage_users",
    "block_email_domain" => "manage_blocks",
    "block_instance" => "manage_federation",
    "block_ip" => "manage_blocks",
    "block_username" => "manage_blocks",
    "force_password_reset" => "manage_users",
    "memorialize" => "manage_users",
    "pick_batch" => "manage_users",
    "pick_preset" => "manage_users",
    "refetch_account" => "manage_users",
    "reject" => "manage_users",
    "save_email" => "manage_users",
    "save_moderation_note" => "manage_users",
    "save_role" => "manage_users",
    "search" => "manage_users",
    # The sign-up blocks screen: an email domain, an address, a username.
    "unblock" => "manage_blocks",
    "undo" => "manage_users",
    "delete_status" => "manage_users",
    "save_emoji" => "manage_custom_emojis",
    "validate_emoji" => "manage_custom_emojis",
    "toggle_emoji" => "manage_custom_emojis",
    "toggle_offered" => "manage_custom_emojis",
    "delete_emoji" => "manage_custom_emojis",
    "approve_appeal" => "manage_appeals",
    "reject_appeal" => "manage_appeals",
    "add_report_note" => "manage_reports",
    "assign_report" => "manage_reports",
    "filter_reports" => "manage_reports",
    "reopen_report" => "manage_reports",
    "resolve_report" => "manage_reports",
    "announce_terms" => "manage_settings",
    "add_rule" => "manage_settings",
    "delete_preset" => "manage_settings",
    "delete_rule" => "manage_settings",
    "publish_terms" => "manage_settings",
    "save_preset" => "manage_settings",
    "save_settings" => "manage_settings",
    "create_announcement" => "manage_announcements",
    "delete_announcement" => "manage_announcements",
    "approve_trend" => "manage_taxonomies",
    "reject_trend" => "manage_taxonomies",
    "toggle_suggestion" => "manage_taxonomies",
    "add_relay" => "manage_federation",
    "clear_delivery_errors" => "manage_federation",
    "disable_relay" => "manage_federation",
    "enable_relay" => "manage_federation",
    "import_domains" => "manage_federation",
    "remove_relay" => "manage_federation",
    "restart_delivery" => "manage_federation",
    "save_instance_note" => "manage_federation",
    "search_instances" => "manage_federation",
    "stop_delivery" => "manage_federation",
    "add_webhook" => "manage_webhooks",
    "delete_webhook" => "manage_webhooks",
    "disable_webhook" => "manage_webhooks",
    "enable_webhook" => "manage_webhooks",
    "rotate_webhook" => "manage_webhooks",
    "delete_role" => "manage_roles",
    "save_role_definition" => "manage_roles",
    "filter_audit" => "view_audit_log"
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(
       user: user,
       account: Accounts.get_account(user.account_id),
       error: nil,
       saved?: false
     )
     |> allow_upload(:image,
       accept: ~w(.png .gif),
       max_entries: 1,
       # Stated here so the browser refuses an oversized file before it is
       # uploaded rather than after it has wasted somebody's time.
       max_file_size: EmojiImages.max_bytes()
     )
     |> attach_hook(:admin_event_permissions, :handle_event, &permitted_event/3)}
  end

  # One place rather than fifty-six, so an event cannot be added with the check
  # forgotten.
  defp permitted_event(event, _params, socket) do
    case Map.fetch(@event_permissions, event) do
      {:ok, permission} ->
        if Roles.can?(socket.assigns.user, permission) do
          {:cont, socket}
        else
          {:halt, assign(socket, error: gettext("Your account may not do that."))}
        end

      :error ->
        {:halt, assign(socket, error: gettext("Your account may not do that."))}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    section = socket.assigns.live_action

    # Read once here and then drawn from for the rest of the render. The
    # navigation asks about every section and the permission form twice about
    # every permission, and each of those was another read of the same role
    # row. Still a fresh read at the moment the answer below is a decision.
    permissions = Roles.permissions_of(socket.assigns.user)

    if Roles.allows?(permissions, permission_for(section)) do
      {:noreply,
       socket
       |> assign(
         permissions: permissions,
         new_secret: nil,
         editing_role: nil,
         subject_statuses: [],
         imported: nil,
         measures: [],
         dimensions: [],
         retention: [],
         section: section,
         page_title: section_label(section),
         error: nil,
         saved?: false
       )
       |> load(section, params)}
    else
      {:noreply, refuse(socket)}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <nav class="border-b border-base-300 p-2" aria-label={gettext("Administration")}>
        <ul class="flex flex-wrap gap-1">
          <li :for={{action, label} <- allowed_sections(@permissions)}>
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
        <p :if={@imported} class="mt-2 text-sm text-success" role="status">{@imported}</p>
        <p :if={@error} class="mt-2 text-sm text-error" role="alert">{@error}</p>

        <.dashboard
          :if={@section == :dashboard}
          counts={@counts}
          may_appeals?={Roles.allows?(@permissions, "manage_appeals")}
          checks={@checks}
          measures={@measures}
          dimensions={@dimensions}
          retention={@retention}
        />
        <.emoji :if={@section == :emoji} emoji={@emoji} uploads={@uploads} />
        <.reports
          :if={@section == :reports}
          reports={@reports}
          report_state={@report_state}
          report_accounts={@report_accounts}
        />
        <.report
          :if={@section == :report}
          report={@report}
          report_notes={@report_notes}
          report_statuses={@report_statuses}
          report_accounts={@report_accounts}
        />
        <.appeals :if={@section == :appeals} appeals={@appeals} />
        <.accounts
          :if={@section == :accounts}
          accounts={@accounts}
          filters={@filters}
          pending={@pending}
          batch={@batch}
          batch_count={@batch_count}
        />
        <.account
          :if={@section == :account}
          subject={@subject}
          subject_user={@subject_user}
          subject_statuses={@subject_statuses}
          strikes={@strikes}
          roles={@roles}
          may_act?={@may_act?}
          presets={@presets}
          action_text={@action_text}
        />
        <.trends :if={@section == :trends} pending={@pending_trends} ranked={@ranked_trends} />
        <.announcements :if={@section == :announcements} announcements={@announcements} />
        <.signups :if={@section == :signups} lists={@lists} />
        <.relays :if={@section == :relays} relays={@relays} />
        <.instances :if={@section == :instances} instances={@instances} filters={@filters} />
        <.domain_lists :if={@section == :domain_lists} counts={@domain_counts} />
        <.suggestions :if={@section == :suggestions} suggestions={@suggestions} />
        <.subscriptions :if={@section == :subscriptions} subscriptions={@subscriptions} />
        <.roles
          :if={@section == :roles}
          roles={@roles}
          user={@user}
          permissions={@permissions}
          editing={@editing_role}
        />
        <.webhooks
          :if={@section == :webhooks}
          webhooks={@webhooks}
          deliveries={@deliveries}
          new_secret={@new_secret}
        />
        <.settings
          :if={@section == :settings}
          settings={@settings}
          rules={@rules}
          terms={@terms}
          presets={@presets}
        />
        <.audit :if={@section == :audit} entries={@entries} actions={@actions} />
      </div>
    </Layouts.app>
    """
  end

  ## Sections

  attr :points, :list, required: true
  attr :label, :string, required: true

  # An inline SVG rather than a charting library. The shape of thirty numbers
  # is the whole question a dashboard chart answers, and a page that pulled in
  # a library to draw it would be a page that cannot be served with the strict
  # policy everything else here has.
  defp sparkline(assigns) do
    values = Enum.map(assigns.points, &to_number(&1.value))
    top = Enum.max([1 | values])
    step = if length(values) > 1, do: 100 / (length(values) - 1), else: 100

    assigns =
      assign(assigns,
        line:
          values
          |> Enum.with_index()
          |> Enum.map_join(" ", fn {value, index} ->
            "#{Float.round(index * step, 2)},#{Float.round(30 - value / top * 28, 2)}"
          end),
        top: top
      )

    ~H"""
    <svg
      viewBox="0 0 100 30"
      preserveAspectRatio="none"
      class="mt-2 h-12 w-full"
      role="img"
      aria-label={gettext("%{label}, highest %{top}", label: @label, top: @top)}
    >
      <polyline
        points={@line}
        fill="none"
        stroke="currentColor"
        stroke-width="1"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  attr :counts, :map, required: true
  attr :may_appeals?, :boolean, required: true
  attr :checks, :list, required: true
  attr :measures, :list, required: true
  attr :dimensions, :list, required: true
  attr :retention, :list, required: true

  defp dashboard(assigns) do
    ~H"""
    <div class="mt-4 grid gap-3 sm:grid-cols-3">
      <div class="rounded-box border border-base-300 p-3">
        <p class="text-2xl font-semibold">{Formats.number(@counts.reports)}</p>
        <p class="text-sm text-base-content/60">{gettext("Reports waiting")}</p>
      </div>
      <.link
        :if={@may_appeals?}
        navigate={~p"/admin/appeals"}
        class="rounded-box border border-base-300 p-3"
      >
        <p class="text-2xl font-semibold">{Formats.number(@counts.appeals)}</p>
        <p class="text-sm text-base-content/60">{gettext("Appeals waiting")}</p>
      </.link>
      <div :if={not @may_appeals?} class="rounded-box border border-base-300 p-3">
        <p class="text-2xl font-semibold">{Formats.number(@counts.appeals)}</p>
        <p class="text-sm text-base-content/60">{gettext("Appeals waiting")}</p>
      </div>
      <div class="rounded-box border border-base-300 p-3">
        <p class="text-2xl font-semibold">{Formats.number(@counts.users)}</p>
        <p class="text-sm text-base-content/60">{gettext("People waiting to be let in")}</p>
      </div>
    </div>

    <h3 class="mt-8 font-semibold">{gettext("The last thirty days")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "The same numbers a moderation client draws from the API, so what you see here and what it shows are the same figures rather than two answers to one question."
      )}
    </p>

    <div class="mt-3 grid gap-4 sm:grid-cols-2">
      <div :for={series <- @measures} class="rounded-box border border-base-300 p-3">
        <p class="font-medium">{measure_label(series.key)}</p>
        <p class="text-2xl font-semibold">{Formats.number(series.total)}</p>
        <.sparkline points={series.data} label={measure_label(series.key)} />
      </div>
    </div>

    <h3 class="mt-8 font-semibold">{gettext("Where things come from")}</h3>

    <div class="mt-3 grid gap-4 sm:grid-cols-2">
      <div :for={dimension <- @dimensions} class="rounded-box border border-base-300 p-3">
        <p class="font-medium">{dimension_label(dimension.key)}</p>

        <ul :if={dimension.data != []} class="mt-2 space-y-1">
          <li :for={row <- dimension.data} class="flex items-baseline gap-2 text-sm">
            <span class="min-w-0 flex-1 truncate">{row.human_key || row.key}</span>
            <span class="tabular-nums text-base-content/70">{row.value}</span>
          </li>
        </ul>

        <p :if={dimension.data == []} class="mt-2 text-sm text-base-content/60">
          {gettext("Nothing yet.")}
        </p>
      </div>
    </div>

    <h3 class="mt-8 font-semibold">{gettext("Who stayed")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Of the people who signed up in a given week, how many were still posting in the weeks after. A number that only means something once the server has been running a while."
      )}
    </p>

    <ul :if={@retention != []} class="mt-3 space-y-1">
      <li :for={cohort <- @retention} class="flex flex-wrap items-baseline gap-2 text-sm">
        <span class="w-28">{cohort.period}</span>
        <span class="w-20 text-base-content/60">
          {ngettext("one signed up", "%{count} signed up", cohort.total)}
        </span>
        <span :for={point <- cohort.data} class="tabular-nums text-base-content/70">
          {percentage(point.rate)}
        </span>
      </li>
    </ul>

    <p :if={@retention == []} class="mt-3 text-sm text-base-content/60">
      {gettext("Nothing yet.")}
    </p>

    <h3 class="mt-8 font-semibold">{gettext("What needs attention")}</h3>

    <ul :if={Enum.any?(@checks, &(not &1.ok?))} class="mt-2 space-y-2">
      <li :for={check <- Enum.reject(@checks, & &1.ok?)} class="rounded-box border border-warning p-3">
        <p class="font-medium">{check_title(check.key)}</p>
        <p class="text-sm text-base-content/70">{check_advice(check.key)}</p>
        <p :if={check.detail} class="mt-1 text-sm text-base-content/60">{check.detail}</p>
      </li>
    </ul>

    <p :if={Enum.all?(@checks, & &1.ok?)} class="mt-2 text-base-content/70">
      {gettext("Nothing. Every check this server knows how to make came back fine.")}
    </p>
    """
  end

  attr :emoji, :list, required: true
  attr :uploads, :map, required: true

  defp emoji(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "Pictures people here can type into a post by name. One uploaded here is held on this server, so it outlives whoever made it."
      )}
    </p>

    <form id="emoji-form" phx-submit="save_emoji" phx-change="validate_emoji" class="mt-4 space-y-2">
      <div class="flex flex-wrap gap-2">
        <label class="flex-1">
          <span class="label">{gettext("Shortcode")}</span>
          <input type="text" name="emoji[shortcode]" required class="input w-full" />
        </label>

        <label class="flex-1">
          <span class="label">{gettext("Group it under")}</span>
          <input type="text" name="emoji[category]" class="input w-full" />
        </label>
      </div>

      <label class="block">
        <span class="label">{gettext("The picture")}</span>
        <.live_file_input upload={@uploads.image} class="file-input w-full" />
        <span class="mt-1 block text-sm text-base-content/60">
          {gettext("A PNG or a GIF, at most %{size}.", size: "256 KB")}
        </span>
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Add it")}</button>
    </form>

    <ul class="mt-6 divide-y divide-base-300">
      <li :for={one <- @emoji} class="flex flex-wrap items-center gap-3 py-2">
        <img src={one.image_url} alt="" class="size-6" />
        <span class="font-medium">:{one.shortcode}:</span>
        <span :if={one.domain} class="badge badge-sm badge-ghost">{one.domain}</span>
        <span :if={one.category} class="text-sm text-base-content/60">{one.category}</span>
        <span :if={one.disabled} class="badge badge-sm">{gettext("turned off")}</span>
        <span :if={not one.disabled and not one.visible_in_picker} class="badge badge-sm">
          {gettext("not offered")}
        </span>

        <span class="ml-auto flex gap-2">
          <button
            :if={is_nil(one.domain)}
            type="button"
            phx-click="toggle_offered"
            phx-value-id={one.id}
            class="btn btn-sm btn-ghost"
          >
            {if one.visible_in_picker,
              do: gettext("Stop offering it"),
              else: gettext("Offer it")}
          </button>

          <button
            :if={is_nil(one.domain)}
            type="button"
            phx-click="toggle_emoji"
            phx-value-id={one.id}
            data-confirm={
              if one.disabled,
                do: nil,
                else:
                  gettext(
                    "Every post that used it loses its picture until you turn it back on. Go ahead?"
                  )
            }
            class="btn btn-sm btn-ghost"
          >
            {if one.disabled, do: gettext("Turn it on"), else: gettext("Turn it off")}
          </button>

          <button
            type="button"
            phx-click="delete_emoji"
            phx-value-id={one.id}
            data-confirm={gettext("Every post that used it loses its picture. Go ahead?")}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Remove")}
          </button>
        </span>
      </li>
    </ul>

    <p :if={@emoji == []} class="mt-4 text-base-content/70">{gettext("None yet.")}</p>
    """
  end

  attr :reports, :list, required: true
  attr :report_state, :string, required: true
  attr :report_accounts, :map, required: true

  defp reports(assigns) do
    ~H"""
    <form id="report-filter" phx-change="filter_reports" class="mt-4">
      <label class="block">
        <span class="label">{gettext("Which ones")}</span>
        <select name="state" class="select">
          <option value="open" selected={@report_state == "open"}>{gettext("Still open")}</option>
          <option value="resolved" selected={@report_state == "resolved"}>
            {gettext("Dealt with")}
          </option>
          <option value="all" selected={@report_state == "all"}>{gettext("All of them")}</option>
        </select>
      </label>
    </form>

    <ul class="mt-4 divide-y divide-base-300">
      <li :for={report <- @reports} class="flex flex-wrap items-center gap-2 py-2">
        <.link navigate={~p"/admin/reports/#{report.id}"} class="link link-hover font-medium">
          {gettext("Report %{id}", id: report.id)}
        </.link>

        <span class="text-sm">
          {gettext("about")} {handle(@report_accounts, report.target_account_id)} · {gettext("from")} {handle(
            @report_accounts,
            report.account_id
          )}
        </span>

        <span class="badge badge-sm">{report.category}</span>
        <span :if={report.action_taken_at} class="badge badge-sm">{gettext("dealt with")}</span>
        <span :if={report.assigned_account_id} class="badge badge-sm badge-ghost">
          {gettext("taken")}
        </span>

        <span class="ml-auto text-sm text-base-content/60">
          {Formats.date(report.inserted_at)}
        </span>
      </li>
    </ul>

    <p :if={@reports == []} class="mt-4 text-base-content/70">
      {gettext("Nothing waiting.")}
    </p>

    <p :if={length(@reports) >= Admin.report_page()} class="mt-4 text-sm text-base-content/60">
      {gettext(
        "Showing the newest %{count}. Deal with some to see the ones that have waited longest.",
        count: Admin.report_page()
      )}
    </p>
    """
  end

  attr :report, :map, required: true
  attr :report_notes, :list, required: true
  attr :report_statuses, :list, required: true
  attr :report_accounts, :map, required: true

  defp report(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext("About")} <.link
        navigate={~p"/admin/accounts/#{@report.target_account_id}"}
        class="link"
      >{handle(@report_accounts, @report.target_account_id)}</.link>, {gettext("from")}
      {handle(@report_accounts, @report.account_id)}.
    </p>

    <p class="mt-1 text-sm text-base-content/60">
      {gettext("Filed as %{category} on %{date}.",
        category: @report.category,
        date: Formats.date(@report.inserted_at)
      )}
    </p>

    <blockquote :if={@report.comment not in [nil, ""]} class="mt-3 border-l-4 border-base-300 pl-3">
      {@report.comment}
    </blockquote>

    <h3 :if={@report_statuses != []} class="mt-6 font-semibold">{gettext("The posts it names")}</h3>

    <ul :if={@report_statuses != []} class="mt-2 divide-y divide-base-300">
      <li :for={status <- @report_statuses} class="py-2">
        <p :if={status.spoiler_text not in [nil, ""]} class="font-medium">
          {gettext("Warning:")} {status.spoiler_text}
        </p>
        <p class="break-words">{plain_text(status.text)}</p>
        <span class="text-sm text-base-content/60">
          {Formats.date(status.inserted_at)}
          <span :if={status.ordered_media_attachment_ids != []}>
            · {gettext("has pictures or video")}
          </span>
        </span>
      </li>
    </ul>

    <div class="mt-6 flex flex-wrap gap-2">
      <button
        :if={is_nil(@report.assigned_account_id)}
        type="button"
        phx-click="assign_report"
        class="btn btn-sm"
      >
        {gettext("I am on this")}
      </button>

      <button
        :if={is_nil(@report.action_taken_at)}
        type="button"
        phx-click="resolve_report"
        class="btn btn-sm btn-primary"
      >
        {gettext("Mark it dealt with")}
      </button>

      <button
        :if={@report.action_taken_at}
        type="button"
        phx-click="reopen_report"
        class="btn btn-sm"
      >
        {gettext("Put it back in the queue")}
      </button>
    </div>

    <h3 class="mt-8 font-semibold">{gettext("What moderators have written here")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "For whoever picks this up next. The person reported never sees any of it, and neither does whoever filed it."
      )}
    </p>

    <ul :if={@report_notes != []} class="mt-3 divide-y divide-base-300">
      <li :for={note <- @report_notes} class="py-2">
        <p class="break-words">{note.content}</p>
        <span class="text-sm text-base-content/60">
          {note.author} · {Formats.date(note.inserted_at)}
        </span>
      </li>
    </ul>

    <p :if={@report_notes == []} class="mt-3 text-base-content/70">{gettext("Nothing yet.")}</p>

    <form id="report-note-form" phx-submit="add_report_note" class="mt-3 space-y-2">
      <textarea
        name="note"
        rows="3"
        placeholder={gettext("What you found")}
        class="textarea w-full"
      ></textarea>
      <button type="submit" class="btn btn-sm">{gettext("Add it")}</button>
    </form>
    """
  end

  attr :accounts, :list, required: true
  attr :filters, :map, required: true
  attr :pending, :map, required: true
  attr :batch, :any, required: true
  attr :batch_count, :integer, required: true

  defp accounts(assigns) do
    ~H"""
    <form id="account-search" phx-submit="search" class="mt-4 flex flex-wrap gap-2">
      <input
        type="text"
        name="query"
        value={@filters["query"]}
        placeholder={gettext("Name or name@server")}
        class="input"
      />
      <select name="origin" class="select">
        <option value="">{gettext("Anywhere")}</option>
        <option value="local" selected={@filters["origin"] == "local"}>{gettext("Here")}</option>
        <option value="remote" selected={@filters["origin"] == "remote"}>
          {gettext("Elsewhere")}
        </option>
      </select>
      <select name="status" class="select">
        <option value="">{gettext("Any state")}</option>
        <option
          :for={{value, label} <- account_states()}
          value={value}
          selected={@filters["status"] == value}
        >
          {label}
        </option>
      </select>
      <button type="submit" class="btn">{gettext("Find")}</button>
    </form>

    <form id="batch-form" phx-change="pick_batch" phx-submit="batch" class="mt-4">
      <div :if={@accounts != []} class="flex flex-wrap items-center gap-2 rounded bg-base-200 p-3">
        <span class="font-medium">
          {if @batch_count == 0 do
            gettext("Tick some accounts to do one thing to all of them.")
          else
            ngettext("One account ticked.", "%{count} accounts ticked.", @batch_count)
          end}
        </span>

        <select name="action" class="select select-sm">
          <option :for={{value, label} <- batch_choices()} value={value}>{label}</option>
        </select>

        <button
          type="submit"
          disabled={@batch_count == 0}
          class="btn btn-sm btn-primary"
          data-confirm={
            ngettext(
              "This does the same thing to one account and tells them. Go ahead?",
              "This does the same thing to all %{count} accounts and tells each of them. Go ahead?",
              @batch_count
            )
          }
        >
          {gettext("Do it to all of them")}
        </button>
      </div>

      <ul class="mt-4 divide-y divide-base-300">
        <li :for={account <- @accounts} class="flex flex-wrap items-center gap-2 py-2">
          <input
            type="checkbox"
            name={"accounts[#{account.id}]"}
            value="true"
            checked={MapSet.member?(@batch, account.id)}
            aria-label={gettext("Tick %{name}", name: Account.acct(account))}
            class="checkbox checkbox-sm"
          />
          <.link navigate={~p"/admin/accounts/#{account.id}"} class="link link-hover font-medium">
            {Account.acct(account)}
          </.link>
          <p
            :if={@pending[account.id][:reason] not in [nil, ""]}
            class="order-last w-full text-sm text-base-content/70"
          >
            {gettext("Why they want to join:")} {@pending[account.id][:reason]}
          </p>
          <span :if={account.suspended_at} class="badge badge-sm">{gettext("suspended")}</span>
          <span :if={account.silenced_at} class="badge badge-sm">{gettext("limited")}</span>

          <span class="ml-auto flex gap-2">
            <button
              :if={@pending[account.id]}
              type="button"
              phx-click="approve"
              phx-value-user={@pending[account.id][:id]}
              class="btn btn-sm btn-primary"
            >
              {gettext("Let in")}
            </button>
            <button
              :if={@pending[account.id]}
              type="button"
              phx-click="reject"
              phx-value-user={@pending[account.id][:id]}
              class="btn btn-sm btn-ghost"
              data-confirm={gettext("This deletes the account as well. Go ahead?")}
            >
              {gettext("Turn away")}
            </button>
          </span>
        </li>
      </ul>
    </form>

    <p :if={@accounts == []} class="mt-4 text-base-content/70">
      {gettext("Nobody here matches that.")}
    </p>
    """
  end

  attr :subject, :map, required: true
  attr :subject_user, :map, default: nil
  attr :subject_statuses, :list, default: []
  attr :strikes, :list, required: true
  attr :roles, :list, required: true
  attr :may_act?, :boolean, required: true
  attr :presets, :list, required: true
  attr :action_text, :string, default: ""

  defp account(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">{Account.acct(@subject)}</p>

    <p :if={not @may_act?} class="mt-4 rounded-box border border-base-300 p-3">
      {gettext("This account outranks yours, so there is nothing here you can do to it.")}
    </p>

    <form :if={@may_act? and @presets != []} id="preset-picker" phx-change="pick_preset" class="mt-4">
      <label class="block">
        <span class="label">{gettext("Start from")}</span>
        <select name="preset" class="select">
          <option value="">{gettext("Nothing, I will write it")}</option>
          <option :for={preset <- @presets} value={preset["title"]}>{preset["title"]}</option>
        </select>
      </label>
    </form>

    <form :if={@may_act?} id="action-form" phx-submit="act" class="mt-4 space-y-3">
      <label class="block">
        <span class="label">{gettext("What to do")}</span>
        <select name="action" class="select">
          <option :for={{value, label} <- action_choices(@subject)} value={value}>{label}</option>
        </select>
      </label>

      <label class="block">
        <span class="label">{gettext("What to tell them")}</span>
        <textarea name="text" rows="3" class="textarea w-full">{@action_text}</textarea>
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Do it")}</button>
    </form>

    <h3 class="mt-6 font-semibold">{gettext("What has been decided about them")}</h3>

    <ul :if={@strikes != []} class="mt-2 divide-y divide-base-300">
      <li :for={strike <- @strikes} class="flex flex-wrap items-center gap-2 py-2">
        <span class="font-medium">{strike.action}</span>
        <span class="text-sm text-base-content/60">
          {Formats.date(strike.inserted_at)}
        </span>
        <span :if={strike.overruled_at} class="text-sm text-base-content/60">
          · {gettext("lifted")}
        </span>
        <button
          :if={@may_act? and is_nil(strike.overruled_at) and Strike.undoable?(strike.action)}
          type="button"
          phx-click="undo"
          phx-value-strike={strike.id}
          class="btn btn-sm btn-ghost ml-auto"
        >
          {gettext("Lift it")}
        </button>
      </li>
    </ul>

    <p :if={@strikes == []} class="mt-2 text-base-content/70">{gettext("Nothing yet.")}</p>

    <div :if={@may_act?} class="mt-6">
      <p class="text-sm text-base-content/70">
        {gettext(
          "Marking an account as a memorial stops it being signed in to and marks the profile as one. Nothing is hidden and nothing is deleted."
        )}
      </p>
      <button
        type="button"
        phx-click="memorialize"
        phx-value-memorial={to_string(not @subject.memorial)}
        data-confirm={@subject.memorial || gettext("This also disables their login. Go ahead?")}
        class="btn btn-sm mt-2"
      >
        {if @subject.memorial,
          do: gettext("This is not a memorial"),
          else: gettext("Mark as a memorial")}
      </button>
    </div>

    <div class="mt-6 rounded border border-base-300 p-3">
      <p class="font-semibold">{gettext("A note for the other moderators")}</p>
      <p class="mt-1 text-sm text-base-content/70">
        {gettext(
          "Nobody is told and nothing is applied. This is for the context that otherwise lives in one person's head: that this is the third report about the same joke, or that somebody spoke to them and they understood."
        )}
      </p>

      <form id="moderation-note-form" phx-submit="save_moderation_note" class="mt-2">
        <textarea name="note" rows="3" class="textarea w-full">{@subject.moderation_note}</textarea>
        <button type="submit" class="btn btn-sm mt-2">{gettext("Save the note")}</button>
      </form>
    </div>

    <div :if={@subject_user} class="mt-6 rounded border border-base-300 p-3">
      <p class="font-semibold">{gettext("Locked out, or somebody else is in")}</p>
      <p class="mt-1 text-sm text-base-content/70">
        {gettext(
          "This ends every session and every app, and emails them a link to set a new password. It does not choose one for them: a password a moderator picked is a password a moderator knows."
        )}
      </p>
      <button
        type="button"
        phx-click="force_password_reset"
        data-confirm={gettext("Sign them out everywhere and send a reset link?")}
        class="btn btn-sm mt-2"
      >
        {gettext("Force a password reset")}
      </button>
    </div>

    <div :if={@subject.domain} class="mt-6 rounded border border-base-300 p-3">
      <p class="font-semibold">{gettext("Their profile here is a copy")}</p>
      <p class="mt-1 text-sm text-base-content/70">
        {gettext(
          "Ask their server for it again. Worth doing when the name or picture here is out of date and waiting for their next post is waiting for something that may not come."
        )}
      </p>
      <button type="button" phx-click="refetch_account" class="btn btn-sm mt-2">
        {gettext("Fetch it again")}
      </button>
    </div>

    <div class="mt-6">
      <p class="font-semibold">{gettext("Their most recent posts")}</p>
      <p class="mt-1 text-sm text-base-content/70">
        {gettext("Deleting one from here is the same delete they would do themselves.")}
      </p>

      <ul :if={@subject_statuses != []} class="mt-2 divide-y divide-base-300">
        <li :for={status <- @subject_statuses} class="flex items-start gap-2 py-2">
          <span class="min-w-0 flex-1">
            <span class="block text-sm">{plain_text(status.text)}</span>
            <span class="block text-sm text-base-content/60">
              {Formats.datetime(status.inserted_at)} · {status.visibility}
            </span>
          </span>
          <button
            type="button"
            phx-click="delete_status"
            phx-value-status={status.id}
            data-confirm={gettext("Delete this post? Other servers are told to delete it too.")}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Delete")}
          </button>
        </li>
      </ul>

      <p :if={@subject_statuses == []} class="mt-2 text-sm text-base-content/60">
        {gettext("Nothing posted.")}
      </p>
    </div>

    <div :if={@subject_user} class="mt-6 space-y-4">
      <form id="role-form" phx-submit="save_role" class="flex flex-wrap items-end gap-2">
        <label class="block">
          <span class="label">{gettext("Role")}</span>
          <select name="role" class="select">
            <option value="">{gettext("None")}</option>
            <option
              :for={role <- @roles}
              value={role.id}
              selected={@subject_user.role_id == role.id}
            >
              {role.name}
            </option>
          </select>
        </label>
        <button type="submit" class="btn">{gettext("Save")}</button>
      </form>

      <form id="email-form" phx-submit="save_email" class="flex flex-wrap items-end gap-2">
        <label class="block">
          <span class="label">{gettext("Email address")}</span>
          <input type="email" name="email" value={@subject_user.email} class="input" />
        </label>
        <button type="submit" class="btn">{gettext("Save")}</button>
      </form>
      <p class="text-sm text-base-content/60">
        {gettext("Change an address only when somebody cannot reach their own.")}
      </p>
    </div>
    """
  end

  attr :pending, :list, required: true
  attr :ranked, :list, required: true

  defp trends(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "Nothing appears in the trending lists until somebody here has looked at it. This is what is waiting."
      )}
    </p>

    <ul :if={@pending != []} class="mt-4 divide-y divide-base-300">
      <li :for={item <- @pending} class="flex flex-wrap items-center gap-2 py-2">
        <span class="badge badge-sm">{item.kind}</span>
        <span class="font-medium break-all">{item.subject}</span>

        <span class="ml-auto flex gap-2">
          <button
            type="button"
            phx-click="approve_trend"
            phx-value-kind={item.kind}
            phx-value-subject={item.subject}
            class="btn btn-sm btn-primary"
          >
            {gettext("Allow")}
          </button>
          <button
            type="button"
            phx-click="reject_trend"
            phx-value-kind={item.kind}
            phx-value-subject={item.subject}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Refuse")}
          </button>
        </span>
      </li>
    </ul>

    <p :if={@pending == []} class="mt-4 text-base-content/70">
      {gettext("Nothing is waiting to be looked at.")}
    </p>

    <h3 class="mt-8 font-semibold">{gettext("What is trending now")}</h3>

    <ul class="mt-2 divide-y divide-base-300">
      <li :for={trend <- @ranked} class="flex flex-wrap items-center gap-2 py-2">
        <span class="badge badge-sm">{trend.kind}</span>
        <span class="font-medium break-all">{trend.subject}</span>
        <span class="text-sm text-base-content/60">
          {ngettext("%{count} person", "%{count} people", trend.accounts, count: trend.accounts)}
        </span>
        <button
          type="button"
          phx-click="reject_trend"
          phx-value-kind={trend.kind}
          phx-value-subject={trend.subject}
          class="btn btn-sm btn-ghost ml-auto"
        >
          {gettext("Take it down")}
        </button>
      </li>
    </ul>

    <p :if={@ranked == []} class="mt-2 text-base-content/70">
      {gettext("Nothing is trending. That is what a quiet day looks like.")}
    </p>
    """
  end

  attr :announcements, :list, required: true

  defp announcements(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "Something everybody here should read. Give it a time and it publishes itself, so a notice about Sunday can be written on Thursday."
      )}
    </p>

    <form id="announcement-form" phx-submit="create_announcement" class="mt-4 space-y-3">
      <label class="block">
        <span class="label">{gettext("What to say")}</span>
        <textarea name="text" rows="3" class="textarea w-full"></textarea>
      </label>

      <label class="block">
        <span class="label">{gettext("When to publish it")}</span>
        <input type="datetime-local" name="scheduled_at" class="input" />
        <span class="text-sm text-base-content/60">
          {gettext("Leave this empty to publish it now.")}
        </span>
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
    </form>

    <ul class="mt-6 divide-y divide-base-300">
      <li :for={announcement <- @announcements} class="py-2">
        <p class="whitespace-pre-wrap break-words">{announcement.text}</p>
        <p class="mt-1 text-sm text-base-content/60">
          <span :if={announcement.published}>
            {gettext("Published")} {Formats.datetime(announcement.published_at)}
          </span>
          <span :if={not announcement.published and announcement.scheduled_at}>
            {gettext("Goes up")} {Formats.datetime(announcement.scheduled_at)}
          </span>
          <span :if={not announcement.published and is_nil(announcement.scheduled_at)}>
            {gettext("Not published")}
          </span>
        </p>
        <button
          type="button"
          phx-click="delete_announcement"
          phx-value-announcement={announcement.id}
          class="btn btn-sm btn-ghost"
        >
          {gettext("Take it down")}
        </button>
      </li>
    </ul>

    <p :if={@announcements == []} class="mt-4 text-base-content/70">
      {gettext("Nothing has been announced.")}
    </p>
    """
  end

  attr :lists, :map, required: true

  defp signups(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "What this server refuses at the door. Most of these have a middle setting that asks somebody to look rather than shutting the door."
      )}
    </p>

    <section class="mt-6">
      <h3 class="font-semibold">{gettext("Mail domains")}</h3>
      <form
        id="email-domain-form"
        phx-submit="block_email_domain"
        class="mt-2 flex flex-wrap items-end gap-2"
      >
        <input type="text" name="domain" placeholder="spam.example" class="input" />
        <label class="flex items-center gap-2 pb-2">
          <input type="checkbox" name="allow_with_approval" value="true" class="checkbox" />
          <span>{gettext("Only ask for approval")}</span>
        </label>
        <button type="submit" class="btn">{gettext("Block it")}</button>
      </form>

      <ul class="mt-2 divide-y divide-base-300">
        <li :for={block <- @lists.email_domains} class="flex items-center gap-2 py-2">
          <span class="font-medium">{block.domain}</span>
          <span :if={block.allow_with_approval} class="badge badge-sm">
            {gettext("approval only")}
          </span>
          <button
            type="button"
            phx-click="unblock"
            phx-value-kind="email_domain"
            phx-value-id={block.id}
            class="btn btn-sm btn-ghost ml-auto"
          >
            {gettext("Lift it")}
          </button>
        </li>
      </ul>
    </section>

    <section class="mt-6">
      <h3 class="font-semibold">{gettext("Addresses")}</h3>
      <form id="ip-form" phx-submit="block_ip" class="mt-2 flex flex-wrap items-end gap-2">
        <input type="text" name="cidr" placeholder="203.0.113.0/24" class="input" />
        <select name="severity" class="select">
          <option :for={{value, label} <- ip_severities()} value={value}>{label}</option>
        </select>
        <button type="submit" class="btn">{gettext("Block it")}</button>
      </form>

      <ul class="mt-2 divide-y divide-base-300">
        <li :for={block <- @lists.ips} class="flex items-center gap-2 py-2">
          <span class="font-mono">{block.cidr}</span>
          <span class="badge badge-sm">{ip_severity_label(block.severity)}</span>
          <button
            type="button"
            phx-click="unblock"
            phx-value-kind="ip"
            phx-value-id={block.id}
            class="btn btn-sm btn-ghost ml-auto"
          >
            {gettext("Lift it")}
          </button>
        </li>
      </ul>
    </section>

    <section class="mt-6">
      <h3 class="font-semibold">{gettext("Usernames")}</h3>
      <form id="username-form" phx-submit="block_username" class="mt-2 flex flex-wrap items-end gap-2">
        <input type="text" name="username" placeholder="admin" class="input" />
        <label class="flex items-center gap-2 pb-2">
          <input type="checkbox" name="partial" value="true" class="checkbox" />
          <span>{gettext("Anywhere in a name")}</span>
        </label>
        <button type="submit" class="btn">{gettext("Block it")}</button>
      </form>

      <ul class="mt-2 divide-y divide-base-300">
        <li :for={block <- @lists.usernames} class="flex items-center gap-2 py-2">
          <span class="font-medium">{block.username}</span>
          <span :if={not block.exact} class="badge badge-sm">{gettext("anywhere")}</span>
          <button
            type="button"
            phx-click="unblock"
            phx-value-kind="username"
            phx-value-id={block.id}
            class="btn btn-sm btn-ghost ml-auto"
          >
            {gettext("Lift it")}
          </button>
        </li>
      </ul>
    </section>

    <section class="mt-6">
      <h3 class="font-semibold">{gettext("Email addresses")}</h3>
      <p class="mt-1 text-sm text-base-content/60">
        {gettext(
          "Kept as hashes rather than addresses. The list has to recognise somebody coming back, not be readable."
        )}
      </p>

      <ul class="mt-2 divide-y divide-base-300">
        <li :for={block <- @lists.emails} class="flex items-center gap-2 py-2">
          <span class="font-mono text-sm">{String.slice(block.canonical_email_hash, 0, 12)}…</span>
          <button
            type="button"
            phx-click="unblock"
            phx-value-kind="email"
            phx-value-id={block.id}
            class="btn btn-sm btn-ghost ml-auto"
          >
            {gettext("Lift it")}
          </button>
        </li>
      </ul>

      <p :if={@lists.emails == []} class="mt-2 text-base-content/70">
        {gettext("None. One is added when an account is suspended and you ask for it.")}
      </p>
    </section>
    """
  end

  attr :counts, :map, required: true

  defp domain_lists(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "A server that has decided about four hundred domains has made four hundred decisions, and the way those get shared is a list somebody publishes. This reads and writes those lists."
      )}
    </p>

    <h3 class="mt-6 font-semibold">{gettext("Take a copy")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {ngettext("One blocked domain", "%{count} blocked domains", @counts.blocks)} · {ngettext(
        "one allowed domain",
        "%{count} allowed domains",
        @counts.allows
      )}
    </p>
    <div class="mt-2 flex flex-wrap gap-2">
      <a href={~p"/admin/domain-lists/blocks/download"} class="btn btn-sm">{gettext("Blocks")}</a>
      <a href={~p"/admin/domain-lists/allows/download"} class="btn btn-sm">{gettext("Allows")}</a>
    </div>

    <h3 class="mt-8 font-semibold">{gettext("Read one in")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Domains this server has already decided about are left exactly as they are. An import adds and never removes: one paste should not be able to undo every decision made here, silently and unrecoverably."
      )}
    </p>

    <form id="domain-import-form" phx-submit="import_domains" class="mt-2 space-y-2">
      <label class="block">
        <span class="label">{gettext("Which list")}</span>
        <select name="kind" class="select">
          <option value="blocks">{gettext("Blocks")}</option>
          <option value="allows">{gettext("Allows")}</option>
        </select>
      </label>

      <textarea
        name="csv"
        rows="6"
        placeholder="#domain,#severity,#public_comment"
        class="textarea w-full font-mono text-sm"
      ></textarea>

      <button type="submit" class="btn">{gettext("Read it in")}</button>
    </form>
    """
  end

  attr :appeals, :list, required: true

  defp appeals(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "Somebody who was warned, silenced or suspended saying it was a mistake. Upholding an appeal undoes the action where it can be undone; where it cannot, the appeal is still recorded as upheld. Either way the account's owner is told."
      )}
    </p>

    <ul :if={@appeals != []} class="mt-4 divide-y divide-base-300">
      <li :for={appeal <- @appeals} class="py-3">
        <div class="flex flex-wrap items-baseline gap-2">
          <.link navigate={~p"/admin/accounts/#{appeal.account_id}"} class="font-medium">
            {Account.acct(appeal.account)}
          </.link>
          <span class="badge badge-sm">{action_label(appeal.account_warning.action)}</span>
          <span class="text-sm text-base-content/60">
            {Formats.relative_time(appeal.inserted_at)}
          </span>
        </div>

        <p class="mt-2 whitespace-pre-line text-sm">{appeal.text}</p>

        <div class="mt-3 flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="approve_appeal"
            phx-value-appeal={appeal.id}
            class="btn btn-sm"
          >
            {gettext("Uphold and undo")}
          </button>
          <button
            type="button"
            phx-click="reject_appeal"
            phx-value-appeal={appeal.id}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Turn down")}
          </button>
        </div>
      </li>
    </ul>

    <p :if={@appeals == []} class="mt-4 text-base-content/60">
      {gettext("Nothing is waiting. Appeals against a strike show up here.")}
    </p>
    """
  end

  attr :suggestions, :list, required: true

  defp suggestions(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "Who this server puts in front of a newcomer. Taking somebody out is not a block and not a silence: their account carries on exactly as before and nobody is told."
      )}
    </p>

    <ul :if={@suggestions != []} class="mt-4 divide-y divide-base-300">
      <li :for={account <- @suggestions} class="flex flex-wrap items-center gap-2 py-2">
        <.link navigate={~p"/admin/accounts/#{account.id}"} class="min-w-0 flex-1 font-medium">
          {Account.acct(account)}
        </.link>

        <span :if={Suggestions.suppressed?(account)} class="badge badge-sm">
          {gettext("Not suggested")}
        </span>

        <button
          type="button"
          phx-click="toggle_suggestion"
          phx-value-account={account.id}
          phx-value-on={to_string(not Suggestions.suppressed?(account))}
          class="btn btn-ghost btn-sm"
        >
          {if Suggestions.suppressed?(account),
            do: gettext("Suggest again"),
            else: gettext("Stop suggesting")}
        </button>
      </li>
    </ul>

    <p :if={@suggestions == []} class="mt-4 text-base-content/60">
      {gettext("Nobody is being suggested yet. It needs a few follows to work from.")}
    </p>
    """
  end

  attr :subscriptions, :list, required: true

  defp subscriptions(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "Addresses that asked one account here to write to them. Only the confirmed ones are counted: an unconfirmed address is a claim somebody typed, not a subscriber."
      )}
    </p>

    <ul :if={@subscriptions != []} class="mt-4 divide-y divide-base-300">
      <li :for={row <- @subscriptions} class="flex items-center gap-2 py-2">
        <.link navigate={~p"/admin/accounts/#{row.account.id}"} class="min-w-0 flex-1 font-medium">
          {Account.acct(row.account)}
        </.link>
        <span class="text-sm text-base-content/60">
          {ngettext("One address", "%{count} addresses", row.count)}
        </span>
      </li>
    </ul>

    <p :if={@subscriptions == []} class="mt-4 text-base-content/60">
      {gettext("Nobody here has any subscribers.")}
    </p>
    """
  end

  attr :instances, :list, required: true
  attr :filters, :map, required: true

  defp instances(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "Every server this one has heard from, busiest first. A peer that has quietly stopped accepting deliveries looks exactly like a peer whose people have gone quiet, and this is where the two are told apart."
      )}
    </p>

    <form id="instance-search" phx-submit="search_instances" class="mt-4 flex flex-wrap gap-2">
      <input
        type="text"
        name="query"
        value={@filters["query"]}
        placeholder={gettext("Server name")}
        class="input"
      />
      <button type="submit" class="btn">{gettext("Find")}</button>
    </form>

    <ul class="mt-4 divide-y divide-base-300">
      <li :for={instance <- @instances} class="py-3">
        <div class="flex flex-wrap items-center gap-2">
          <span class="min-w-0 flex-1">
            <span class="font-medium">{instance.domain}</span>
            <span :if={instance.software} class="text-sm text-base-content/60">
              · {instance.software} {instance.version}
            </span>
            <span class="block text-sm text-base-content/60">
              {ngettext("One account", "%{count} accounts", instance.accounts)} · {ngettext(
                "one post",
                "%{count} posts",
                instance.posts
              )}
            </span>
            <span class="block text-sm">
              <span :if={instance.stopped_at} class="text-warning">
                {gettext("Delivery stopped by a moderator")}
              </span>
              <span
                :if={is_nil(instance.stopped_at) and instance.unavailable_since}
                class="text-error"
              >
                {gettext("Treated as down since %{when}",
                  when: Formats.date(instance.unavailable_since)
                )}
              </span>
              <span
                :if={is_nil(instance.stopped_at) and is_nil(instance.unavailable_since)}
                class="text-base-content/60"
              >
                {gettext("Delivering")}
              </span>
              <span :if={instance.failure_days > 0} class="text-base-content/60">
                · {ngettext("one bad day", "%{count} bad days", instance.failure_days)}
              </span>
            </span>
            <span :if={instance.last_error} class="block text-sm text-error">
              {gettext("Last error:")} {instance.last_error}
            </span>
          </span>

          <button
            :if={is_nil(instance.stopped_at)}
            type="button"
            phx-click="stop_delivery"
            phx-value-domain={instance.domain}
            class="btn btn-sm"
          >
            {gettext("Stop delivering")}
          </button>

          <button
            :if={instance.stopped_at}
            type="button"
            phx-click="restart_delivery"
            phx-value-domain={instance.domain}
            class="btn btn-sm"
          >
            {gettext("Start again")}
          </button>

          <button
            :if={instance.last_error || instance.failure_days > 0}
            type="button"
            phx-click="clear_delivery_errors"
            phx-value-domain={instance.domain}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Forget the failures")}
          </button>

          <span :if={instance.blocked} class="badge badge-warning">
            {gettext("Blocked: %{severity}", severity: instance.blocked)}
          </span>

          <button
            :if={is_nil(instance.blocked)}
            type="button"
            phx-click="block_instance"
            phx-value-domain={instance.domain}
            class="btn btn-ghost btn-sm"
            data-confirm={
              gettext("Silence this server? Its posts stop appearing in public timelines.")
            }
          >
            {gettext("Silence this server")}
          </button>
        </div>

        <form phx-submit="save_instance_note" class="mt-2 flex flex-wrap gap-2">
          <input type="hidden" name="domain" value={instance.domain} />
          <input
            type="text"
            name="note"
            value={instance.note}
            placeholder={gettext("A note for the other moderators")}
            class="input input-sm w-full max-w-lg"
          />
          <button type="submit" class="btn btn-ghost btn-sm">{gettext("Save")}</button>
        </form>
      </li>
    </ul>

    <p :if={@instances == []} class="mt-4 text-base-content/60">
      {gettext("No other servers yet.")}
    </p>
    """
  end

  attr :relays, :list, required: true

  defp relays(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "A relay forwards every public post it is sent on to everybody subscribed to it. On a young server it is the quickest way to have a federated timeline with anything in it."
      )}
    </p>

    <form id="relay-form" phx-submit="add_relay" class="mt-4 flex flex-wrap gap-2">
      <input
        type="url"
        name="inbox_url"
        placeholder="https://relay.example/inbox"
        required
        class="input w-full max-w-md"
      />
      <button type="submit" class="btn">{gettext("Add")}</button>
    </form>

    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "The relay's inbox address, which its operator publishes. Adding and turning on are separate steps, so a mistyped address can be corrected before anything is sent to it."
      )}
    </p>

    <ul :if={@relays != []} class="mt-4 divide-y divide-base-300">
      <li :for={relay <- @relays} class="flex flex-wrap items-center gap-2 py-3">
        <span class="min-w-0 flex-1">
          <span class="block truncate font-medium">{relay.inbox_url}</span>
          <span class="block text-sm text-base-content/60">
            {relay_state(relay.state)}
            <span :if={relay.last_delivery_at}>
              · {gettext("last sent %{when}",
                when: Formats.datetime(relay.last_delivery_at)
              )}
            </span>
          </span>
          <span :if={relay.last_error} class="block text-sm text-error">
            {gettext("Last error:")} {relay.last_error}
          </span>
        </span>

        <button
          :if={relay.state == :idle or relay.state == :rejected}
          type="button"
          phx-click="enable_relay"
          phx-value-relay={relay.id}
          class="btn btn-sm"
        >
          {gettext("Turn on")}
        </button>

        <button
          :if={relay.state in [:pending, :accepted]}
          type="button"
          phx-click="disable_relay"
          phx-value-relay={relay.id}
          class="btn btn-sm"
        >
          {gettext("Turn off")}
        </button>

        <button
          type="button"
          phx-click="remove_relay"
          phx-value-relay={relay.id}
          class="btn btn-ghost btn-sm"
          data-confirm={gettext("Remove this relay?")}
        >
          {gettext("Remove")}
        </button>
      </li>
    </ul>

    <p :if={@relays == []} class="mt-4 text-base-content/60">
      {gettext("No relays yet.")}
    </p>
    """
  end

  attr :roles, :list, required: true
  attr :user, :map, required: true
  attr :permissions, :integer, required: true
  attr :editing, :any, required: true

  defp roles(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "A role is a set of permissions and a position. Position is what decides who may act on whom: nobody may edit a role at or above their own, and nobody may grant a permission they do not hold themselves."
      )}
    </p>

    <form id="role-editor" phx-submit="save_role_definition" class="mt-4 space-y-3">
      <input type="hidden" name="role_id" value={@editing && @editing.id} />

      <div class="flex flex-wrap gap-2">
        <label class="block">
          <span class="label">{gettext("Name")}</span>
          <input type="text" name="name" value={@editing && @editing.name} required class="input" />
        </label>

        <label class="block">
          <span class="label">{gettext("Position")}</span>
          <input
            type="number"
            name="position"
            value={(@editing && @editing.position) || 0}
            class="input w-28"
          />
        </label>

        <label class="block">
          <span class="label">{gettext("Colour")}</span>
          <input
            type="text"
            name="color"
            value={@editing && @editing.color}
            placeholder="#7c3aed"
            class="input w-32"
          />
        </label>
      </div>

      <fieldset class="rounded-box border border-base-300 p-3">
        <legend class="px-1">{gettext("What this role may do")}</legend>

        <label :for={permission <- Roles.permissions()} class="flex items-start gap-2 py-1">
          <input
            type="hidden"
            name={"permissions[#{permission}]"}
            value="false"
          />
          <input
            type="checkbox"
            name={"permissions[#{permission}]"}
            value="true"
            checked={held?(@editing, permission)}
            disabled={not Roles.allows?(@permissions, permission)}
            class="checkbox checkbox-sm mt-1"
          />
          <span>
            <span class="font-medium">{permission_label(permission)}</span>
            <span class="block text-sm text-base-content/60">{permission_hint(permission)}</span>
            <span :if={not Roles.allows?(@permissions, permission)} class="block text-sm text-warning">
              {gettext("You do not hold this yourself, so you cannot grant it.")}
            </span>
          </span>
        </label>
      </fieldset>

      <button type="submit" class="btn btn-primary">
        {if @editing, do: gettext("Save the role"), else: gettext("Create the role")}
      </button>
      <.link :if={@editing} patch={~p"/admin/roles"} class="btn btn-ghost">
        {gettext("Cancel")}
      </.link>
    </form>

    <ul class="mt-6 divide-y divide-base-300">
      <li :for={role <- @roles} class="flex flex-wrap items-center gap-2 py-3">
        <span class="min-w-0 flex-1">
          <span class="font-medium" style={role.color != "" && "color: #{role.color}"}>
            {role.name}
          </span>
          <span class="block text-sm text-base-content/60">
            {gettext("Position %{position}", position: role.position)} · {permission_summary(role)}
          </span>
        </span>

        <.link
          :if={Roles.can_manage?(@user, role)}
          patch={~p"/admin/roles?edit=#{role.id}"}
          class="btn btn-sm"
        >
          {gettext("Edit")}
        </.link>

        <button
          :if={Roles.can_manage?(@user, role)}
          type="button"
          phx-click="delete_role"
          phx-value-role={role.id}
          class="btn btn-ghost btn-sm"
          data-confirm={gettext("Remove this role? Anybody holding it keeps their account.")}
        >
          {gettext("Remove")}
        </button>

        <span :if={not Roles.can_manage?(@user, role)} class="text-sm text-base-content/60">
          {gettext("Above yours")}
        </span>
      </li>
    </ul>

    <p :if={@roles == []} class="mt-6 text-base-content/60">{gettext("No roles yet.")}</p>
    """
  end

  attr :webhooks, :list, required: true
  attr :deliveries, :map, required: true
  attr :new_secret, :any, required: true

  defp webhooks(assigns) do
    ~H"""
    <p class="mt-2 text-base-content/70">
      {gettext(
        "This server posts to a webhook when something happens that a moderator would want to know about."
      )}
    </p>

    <div :if={@new_secret} class="mt-4 rounded-box border border-warning p-3">
      <p class="font-medium">{gettext("The signing secret")}</p>
      <p class="mt-1 text-sm text-base-content/70">
        {gettext("Copy it now. It is not shown again.")}
      </p>
      <code class="mt-2 block break-all font-mono text-sm">{@new_secret}</code>
    </div>

    <form id="webhook-form" phx-submit="add_webhook" class="mt-4 space-y-2">
      <input
        type="url"
        name="url"
        placeholder="https://example.com/hooks/abuuba"
        required
        class="input w-full max-w-md"
      />

      <div class="flex flex-wrap gap-3">
        <label :for={event <- Webhook.events()} class="flex items-center gap-1">
          <input type="checkbox" name="events[]" value={event} class="checkbox checkbox-sm" />
          <span class="font-mono text-sm">{event}</span>
        </label>
      </div>

      <button type="submit" class="btn">{gettext("Add")}</button>
    </form>

    <p class="mt-1 text-sm text-base-content/60">
      {gettext("Added turned off, so a URL typed wrong can be corrected before anything goes to it.")}
    </p>

    <ul :if={@webhooks != []} class="mt-6 divide-y divide-base-300">
      <li :for={webhook <- @webhooks} class="py-3">
        <div class="flex flex-wrap items-center gap-2">
          <span class="min-w-0 flex-1">
            <span class="block truncate font-medium">{webhook.url}</span>
            <span class="block font-mono text-sm text-base-content/60">
              {Enum.join(webhook.events, " ")}
            </span>
          </span>

          <button
            type="button"
            phx-click={if webhook.enabled, do: "disable_webhook", else: "enable_webhook"}
            phx-value-webhook={webhook.id}
            class="btn btn-sm"
          >
            {if webhook.enabled, do: gettext("Turn off"), else: gettext("Turn on")}
          </button>

          <button
            type="button"
            phx-click="rotate_webhook"
            phx-value-webhook={webhook.id}
            class="btn btn-ghost btn-sm"
            data-confirm={gettext("The old secret stops working immediately. Continue?")}
          >
            {gettext("New secret")}
          </button>

          <button
            type="button"
            phx-click="delete_webhook"
            phx-value-webhook={webhook.id}
            class="btn btn-ghost btn-sm"
            data-confirm={gettext("Remove this webhook?")}
          >
            {gettext("Remove")}
          </button>
        </div>

        <ul class="mt-2 space-y-1">
          <li
            :for={delivery <- Map.get(@deliveries, webhook.id, [])}
            class="flex flex-wrap gap-x-3 text-sm"
          >
            <span class={[
              "font-medium",
              not Delivery.delivered?(delivery) && "text-error"
            ]}>
              {delivery.status || gettext("no answer")}
            </span>
            <span class="font-mono">{delivery.event}</span>
            <span class="text-base-content/60">
              {Formats.datetime(delivery.inserted_at)}
            </span>
            <span :if={delivery.error} class="text-error">{delivery.error}</span>
          </li>
        </ul>

        <p
          :if={Map.get(@deliveries, webhook.id, []) == []}
          class="mt-2 text-sm text-base-content/60"
        >
          {gettext("Nothing sent yet.")}
        </p>
      </li>
    </ul>

    <p :if={@webhooks == []} class="mt-6 text-base-content/60">{gettext("No webhooks yet.")}</p>
    """
  end

  attr :settings, :map, required: true
  attr :rules, :list, required: true
  attr :terms, :list, required: true
  attr :presets, :list, required: true

  defp settings(assigns) do
    ~H"""
    <form id="settings-form" phx-submit="save_settings" class="mt-4 space-y-4">
      <label class="block">
        <span class="label">{gettext("Server name")}</span>
        <input type="text" name="site_title" value={@settings["site_title"]} class="input w-full" />
      </label>

      <label class="block">
        <span class="label">{gettext("What this server is for")}</span>
        <textarea name="site_description" rows="3" class="textarea w-full">{@settings["site_description"]}</textarea>
      </label>

      <label class="block">
        <span class="label">{gettext("The longer version, for the about page")}</span>
        <textarea name="extended_description" rows="6" class="textarea w-full">{@settings["extended_description"]}</textarea>
      </label>

      <label class="block">
        <span class="label">{gettext("Status page")}</span>
        <input
          type="url"
          name="site_status_page_url"
          value={@settings["site_status_page_url"]}
          placeholder="https://status.example.com"
          class="input w-full"
        />
      </label>

      <label class="block">
        <span class="label">{gettext("The account to write to")}</span>
        <input
          type="text"
          name="site_contact_account"
          value={@settings["site_contact_account"]}
          placeholder={gettext("a username on this server")}
          class="input w-full"
        />
      </label>

      <label class="block">
        <span class="label">{gettext("Privacy policy")}</span>
        <textarea name="privacy_text" rows="6" class="textarea w-full">{@settings["privacy_text"]}</textarea>
      </label>

      <label class="block">
        <span class="label">{gettext("The privacy policy takes effect on")}</span>
        <input
          type="date"
          name="privacy_effective_on"
          value={@settings["privacy_effective_on"]}
          class="input"
        />
      </label>

      <label class="block">
        <span class="label">{gettext("Who may read the blocklist")}</span>
        <select name="show_domain_blocks" class="select w-full">
          <option value="disabled" selected={@settings["show_domain_blocks"] in [nil, "disabled"]}>
            {gettext("Nobody: the server does not say")}
          </option>
          <option value="users" selected={@settings["show_domain_blocks"] == "users"}>
            {gettext("Only people signed in here")}
          </option>
          <option value="all" selected={@settings["show_domain_blocks"] == "all"}>
            {gettext("Anybody, including people with no account")}
          </option>
        </select>
      </label>

      <label class="block">
        <span class="label">{gettext("Who may read the public timelines")}</span>
        <select name="timeline_access" class="select w-full">
          <option value="public" selected={@settings["timeline_access"] in [nil, "public"]}>
            {gettext("Anybody, including people with no account")}
          </option>
          <option value="authenticated" selected={@settings["timeline_access"] == "authenticated"}>
            {gettext("Only people signed in here")}
          </option>
          <option value="disabled" selected={@settings["timeline_access"] == "disabled"}>
            {gettext("Nobody: turn them off")}
          </option>
        </select>
      </label>

      <label class="block">
        <span class="label">{gettext("Address people can write to")}</span>
        <input
          type="email"
          name="site_contact_email"
          value={@settings["site_contact_email"]}
          class="input w-full"
        />
      </label>

      <label class="block">
        <span class="label">{gettext("Who may sign up")}</span>
        <select name="registration_mode" class="select">
          <option
            :for={{value, label} <- registration_choices()}
            value={value}
            selected={@settings["registration_mode"] == value}
          >
            {label}
          </option>
        </select>
      </label>

      <label class="block">
        <span class="label">{gettext("What to say when nobody may sign up")}</span>
        <textarea name="closed_registration_message" rows="2" class="textarea w-full">{@settings["closed_registration_message"]}</textarea>
      </label>

      <label class="block">
        <span class="label">{gettext("Days to keep other servers' files")}</span>
        <input
          type="number"
          name="content_retention_days"
          min="0"
          value={@settings["content_retention_days"]}
          class="input"
        />
        <span class="text-sm text-base-content/60">
          {gettext(
            "Zero keeps them indefinitely. Anything older goes off this server's disk each night. The posts stay, and a file is fetched again if somebody opens it."
          )}
        </span>
      </label>

      <label class="block">
        <span class="label">{gettext("Days to keep other servers' posts")}</span>
        <input
          type="number"
          name="remote_post_retention_days"
          min="0"
          value={@settings["remote_post_retention_days"]}
          class="input"
        />
        <span class="text-sm text-base-content/60">
          {gettext(
            "Zero keeps them for ever. Anything older is deleted each night, except a post somebody here favourited, bookmarked, pinned, boosted, quoted, replied to or was mentioned in."
          )}
        </span>
      </label>

      <label class="flex items-center gap-2">
        <input type="hidden" name="limited_federation" value="false" />
        <input
          type="checkbox"
          name="limited_federation"
          value="true"
          checked={@settings["limited_federation"] == true}
          class="checkbox"
        />
        <span>{gettext("Talk only to servers on the allowlist")}</span>
      </label>

      <label class="flex items-center gap-2">
        <input type="hidden" name="email_subscriptions" value="false" />
        <input
          type="checkbox"
          name="email_subscriptions"
          value="true"
          checked={@settings["email_subscriptions"] == true}
          class="checkbox"
        />
        <span>{gettext("Let people collect email addresses for updates")}</span>
      </label>
      <p class="text-sm text-base-content/60">
        {gettext(
          "Each person still has to turn it on for themselves, and every address has to confirm before anything is sent to it."
        )}
      </p>

      <h4 class="mt-6 font-semibold">{gettext("Asking for money")}</h4>
      <p class="text-sm text-base-content/60">
        {gettext(
          "Clients show this to people signed in here. Leave the message empty to show nothing."
        )}
      </p>

      <label class="block">
        <span class="label">{gettext("What to say")}</span>
        <textarea name="donation_campaign_message" rows="2" class="textarea w-full">{@settings["donation_campaign_message"]}</textarea>
      </label>

      <label class="block">
        <span class="label">{gettext("Where the button goes")}</span>
        <input
          type="url"
          name="donation_campaign_url"
          value={@settings["donation_campaign_url"]}
          class="input w-full"
        />
        <span class="text-sm text-base-content/60">
          {gettext("An http or https address. Anything else is refused and nothing is shown.")}
        </span>
      </label>

      <label class="block">
        <span class="label">{gettext("What the button says")}</span>
        <input
          type="text"
          name="donation_campaign_button_text"
          value={@settings["donation_campaign_button_text"]}
          class="input w-full"
        />
      </label>

      <h4 class="mt-6 font-semibold">{gettext("Checking for updates")}</h4>
      <p class="text-sm text-base-content/60">
        {gettext(
          "Off unless you turn it on. It asks %{url} whether there is a newer abuuba. What that tells them is what any web request tells anybody: this server's address, a user agent, and that somebody asked. Nothing about the accounts here, their number or their posts is sent, and there is nowhere in the request for it to go.",
          url: UpdateCheck.endpoint()
        )}
      </p>

      <label class="flex items-center gap-2">
        <input type="hidden" name="update_check" value="false" />
        <input
          type="checkbox"
          name="update_check"
          value="true"
          checked={@settings["update_check"] == true}
          class="checkbox"
        />
        <span>{gettext("Tell me when there is a newer version")}</span>
      </label>

      <p class="text-sm text-base-content/60">
        {gettext("Running %{version}.", version: UpdateCheck.current_version())}
        <span :if={UpdateCheck.behind?()} class="text-warning">
          {gettext("%{latest} is out.", latest: UpdateCheck.latest_version())}
        </span>
      </p>

      <h4 class="mt-6 font-semibold">{gettext("Your own CSS")}</h4>
      <p class="text-sm text-base-content/60">
        {gettext("Served from this server and linked from every page. It goes out exactly as typed.")}
      </p>

      <label class="block">
        <textarea name="custom_css" rows="6" class="textarea w-full font-mono text-sm">{@settings["custom_css"]}</textarea>
      </label>

      <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
    </form>

    <h3 class="mt-8 font-semibold">{gettext("Warning presets")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Ready-made texts a moderator picks instead of retyping. Kept for the server rather than for one moderator, so two people writing about the same thing say the same thing."
      )}
    </p>

    <form id="warning-preset-form" phx-submit="save_preset" class="mt-3 space-y-2">
      <input
        type="text"
        name="preset[title]"
        placeholder={gettext("What to call it")}
        class="input w-full"
      />
      <textarea
        name="preset[text]"
        rows="3"
        placeholder={gettext("What it says")}
        class="textarea w-full"
      ></textarea>
      <button type="submit" class="btn">{gettext("Keep it")}</button>
    </form>

    <ul class="mt-3 divide-y divide-base-300">
      <li :for={preset <- @presets} class="flex flex-wrap items-start gap-2 py-2">
        <span class="min-w-0 flex-1">
          <span class="font-medium">{preset["title"]}</span>
          <span class="block text-sm text-base-content/60">{preset["text"]}</span>
        </span>
        <button
          type="button"
          phx-click="delete_preset"
          phx-value-title={preset["title"]}
          class="btn btn-sm btn-ghost"
        >
          {gettext("Remove")}
        </button>
      </li>
    </ul>

    <h3 class="mt-8 font-semibold">{gettext("Terms of service")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext(
        "Each version is kept with the day it takes effect, so somebody can still read what they agreed to."
      )}
    </p>

    <form id="terms-form" phx-submit="publish_terms" class="mt-3 space-y-2">
      <textarea name="text" rows="4" class="textarea w-full"></textarea>
      <label class="block">
        <span class="label">{gettext("In effect from")}</span>
        <input type="date" name="effective_date" class="input" />
      </label>
      <button type="submit" class="btn">{gettext("Publish a new version")}</button>
    </form>

    <ul class="mt-3 divide-y divide-base-300">
      <li :for={version <- @terms} class="flex flex-wrap items-center gap-2 py-2">
        <span class="font-medium">{version.effective_date}</span>
        <span :if={version.notified_at} class="text-sm text-base-content/60">
          {gettext("everybody was told")}
        </span>
        <button
          :if={is_nil(version.notified_at)}
          type="button"
          phx-click="announce_terms"
          phx-value-terms={version.id}
          class="btn btn-sm btn-ghost ml-auto"
        >
          {gettext("Tell everybody")}
        </button>
      </li>
    </ul>

    <h3 class="mt-8 font-semibold">{gettext("Rules people agree to")}</h3>
    <p class="mt-1 text-sm text-base-content/60">
      {gettext("Shown when somebody signs up and when they file a report.")}
    </p>

    <ul class="mt-3 divide-y divide-base-300">
      <li :for={rule <- @rules} class="flex items-center gap-2 py-2">
        <span>{rule.text}</span>
        <button
          type="button"
          phx-click="delete_rule"
          phx-value-rule={rule.id}
          class="btn btn-sm btn-ghost ml-auto"
        >
          {gettext("Retire it")}
        </button>
      </li>
    </ul>

    <form id="rule-form" phx-submit="add_rule" class="mt-3 flex flex-wrap items-end gap-2">
      <label class="block grow">
        <span class="label">{gettext("A new rule")}</span>
        <input type="text" name="text" class="input w-full" />
      </label>
      <button type="submit" class="btn">{gettext("Add")}</button>
    </form>
    """
  end

  attr :entries, :list, required: true
  attr :actions, :list, required: true

  defp audit(assigns) do
    ~H"""
    <form id="audit-filter" phx-submit="filter_audit" class="mt-4 flex flex-wrap gap-2">
      <select name="action" class="select">
        <option value="">{gettext("Everything")}</option>
        <option :for={action <- @actions} value={action}>{action}</option>
      </select>
      <button type="submit" class="btn">{gettext("Show")}</button>
    </form>

    <ul class="mt-4 divide-y divide-base-300">
      <li :for={entry <- @entries} class="py-2">
        <p>
          <span class="font-medium">{entry.account_handle || gettext("the server")}</span>
          <span class="text-base-content/70">{entry.action}</span>
          <span class="font-medium">{entry.target_label}</span>
        </p>
        <p class="text-sm text-base-content/60">
          {Formats.datetime(entry.inserted_at)}
        </p>
      </li>
    </ul>

    <p :if={@entries == []} class="mt-4 text-base-content/70">
      {gettext("Nothing has been done yet.")}
    </p>
    """
  end

  ## Events

  @impl Phoenix.LiveView
  def handle_event("search", params, socket) do
    query = Map.take(params, ~w(query origin status)) |> Enum.reject(&(elem(&1, 1) == ""))

    {:noreply, push_patch(socket, to: ~p"/admin/accounts?#{query}")}
  end

  def handle_event("memorialize", %{"memorial" => memorial}, socket) do
    case Admin.memorialize(socket.assigns.account, socket.assigns.subject, memorial == "true") do
      {:ok, _subject} ->
        {:noreply,
         socket
         |> assign(saved?: true, error: nil)
         |> load(:account, %{"id" => to_string(socket.assigns.subject.id)})}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: gettext("That could not be saved."))}
    end
  end

  def handle_event("approve", %{"user" => id}, socket) do
    with_user(socket, id, fn user ->
      Admin.approve_user(socket.assigns.account, user)
    end)
  end

  def handle_event("reject", %{"user" => id}, socket) do
    with_user(socket, id, fn user ->
      Admin.reject_user(socket.assigns.account, user)
    end)
  end

  def handle_event("act", %{"action" => action} = params, socket) do
    # Asked again here rather than trusted from the render: the form is not
    # shown to somebody who may not act, but an event carries whatever it was
    # sent with.
    if socket.assigns.may_act? do
      take_action(socket, action, Map.get(params, "text", ""))
    else
      {:noreply, assign(socket, error: outranks_message())}
    end
  end

  # The browser reports its own refusals through this, so the form needs it
  # even though nothing here has to be recomputed.
  def handle_event("validate_emoji", _params, socket), do: {:noreply, socket}

  def handle_event("save_emoji", %{"emoji" => attrs}, socket) when is_map(attrs) do
    {:noreply, add_emoji(socket, attrs)}
  end

  # The gentle one: out of the picker, still rendering wherever it was already
  # used. The loud one below it is `toggle_emoji`, which stops it rendering.
  def handle_event("toggle_offered", %{"id" => id}, socket) do
    with %CustomEmoji{} = emoji <- emoji_of(socket, id) do
      Instance.set_custom_emoji_offered(emoji, not emoji.visible_in_picker)
    end

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:emoji, %{})}
  end

  def handle_event("toggle_emoji", %{"id" => id}, socket) do
    with %CustomEmoji{} = emoji <- emoji_of(socket, id) do
      Instance.set_custom_emoji_disabled(emoji, not emoji.disabled)
    end

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:emoji, %{})}
  end

  def handle_event("delete_emoji", %{"id" => id}, socket) do
    with %CustomEmoji{} = emoji <- emoji_of(socket, id) do
      Instance.delete_custom_emoji(emoji)
    end

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:emoji, %{})}
  end

  def handle_event("filter_reports", %{"state" => state}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/reports?state=#{state}")}
  end

  def handle_event("assign_report", _params, socket) do
    {:noreply,
     on_report(socket, &Reports.assign(&1, socket.assigns.account, socket.assigns.account))}
  end

  def handle_event("approve_appeal", %{"appeal" => id}, socket) do
    {:noreply, on_appeal(socket, id, &Actions.approve_appeal(socket.assigns.account, &1))}
  end

  def handle_event("reject_appeal", %{"appeal" => id}, socket) do
    {:noreply, on_appeal(socket, id, &Actions.reject_appeal(socket.assigns.account, &1))}
  end

  def handle_event("resolve_report", _params, socket) do
    {:noreply, on_report(socket, &Reports.resolve(&1, socket.assigns.account))}
  end

  def handle_event("reopen_report", _params, socket) do
    {:noreply, on_report(socket, &Reports.reopen(&1, socket.assigns.account))}
  end

  # An empty note is somebody pressing the button by accident, and a thread of
  # blank entries is a thread the next moderator stops reading.
  def handle_event("add_report_note", %{"note" => note}, socket) do
    report = socket.assigns[:report]

    if is_nil(report) or String.trim(to_string(note)) == "" do
      {:noreply, socket}
    else
      Actions.add_note(socket.assigns.account, :report, report.id, note)

      {:noreply,
       socket
       |> assign(saved?: true, error: nil)
       |> assign(report_notes: Admin.notes_with_authors(:report, report.id))}
    end
  end

  # Every tick, so the bar can name the count before anybody presses anything.
  def handle_event("pick_batch", params, socket) do
    batch = ticked(params)

    {:noreply, assign(socket, batch: batch, batch_count: MapSet.size(batch))}
  end

  def handle_event("batch", params, socket) do
    {:noreply, apply_batch(socket, ticked(params), Map.get(params, "action"))}
  end

  def handle_event("save_preset", %{"preset" => %{"title" => title, "text" => text}}, socket) do
    case WarningPresets.put(socket.assigns.account, title, text) do
      :ok -> {:noreply, socket |> assign(saved?: true, error: nil) |> load(:settings, %{})}
      {:error, :blank} -> {:noreply, assign(socket, error: gettext("A preset needs both."))}
    end
  end

  def handle_event("delete_preset", %{"title" => title}, socket) do
    WarningPresets.delete(socket.assigns.account, title)

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:settings, %{})}
  end

  # Filled in rather than replaced silently: the moderator sees the text and
  # can edit it before it goes, because a preset is a starting point and the
  # account being written to is not a form letter.
  def handle_event("pick_preset", %{"preset" => title}, socket) do
    {:noreply, assign(socket, action_text: WarningPresets.text(title) || "")}
  end

  def handle_event("undo", %{"strike" => id}, socket) do
    strike = Enum.find(socket.assigns.strikes, &(to_string(&1.id) == to_string(id)))

    if socket.assigns.may_act? and strike do
      Actions.undo(socket.assigns.account, strike)
    end

    {:noreply, socket |> assign(saved?: true, error: nil) |> reload_subject()}
  end

  def handle_event("save_role", %{"role" => id}, socket) do
    role = Enum.find(socket.assigns.roles, &(to_string(&1.id) == id))

    cond do
      not socket.assigns.may_act? ->
        {:noreply, assign(socket, error: outranks_message())}

      # Granting a role somebody may not manage is how a moderator hands
      # themselves anything through a third account.
      not is_nil(role) and not Roles.can_manage?(socket.assigns.user, role) ->
        {:noreply, assign(socket, error: gettext("That is not a role you can hand out."))}

      true ->
        Admin.assign_role(socket.assigns.account, socket.assigns.subject_user, role)

        {:noreply, socket |> assign(saved?: true, error: nil) |> reload_subject()}
    end
  end

  def handle_event("save_email", %{"email" => email}, socket) do
    case Admin.change_email(socket.assigns.account, socket.assigns.subject_user, email) do
      {:ok, _user} ->
        {:noreply, socket |> assign(saved?: true, error: nil) |> reload_subject()}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: gettext("That is not an address."))}
    end
  end

  def handle_event("save_settings", params, socket) do
    :ok = Admin.put_settings(socket.assigns.account, params)

    {:noreply, socket |> assign(saved?: true, settings: Admin.settings())}
  end

  def handle_event("approve_trend", %{"kind" => kind, "subject" => subject}, socket) do
    :ok = Trends.approve(socket.assigns.account, kind, subject)

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:trends, %{})}
  end

  def handle_event("reject_trend", %{"kind" => kind, "subject" => subject}, socket) do
    :ok = Trends.reject(socket.assigns.account, kind, subject)

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:trends, %{})}
  end

  def handle_event("create_announcement", %{"text" => text} = params, socket) do
    scheduled = parse_datetime(params["scheduled_at"])

    attrs = %{
      text: text,
      scheduled_at: scheduled,
      # No time given means now, which is what somebody pressing Save without
      # filling in a date meant.
      published: is_nil(scheduled)
    }

    case Instance.create_announcement(attrs) do
      {:ok, announcement} ->
        if announcement.published, do: Streaming.publish_announcement(announcement)

        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:announcements, %{})}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: gettext("An announcement needs some text."))}
    end
  end

  def handle_event("delete_announcement", %{"announcement" => id}, socket) do
    case Instance.get_announcement(to_integer(id)) do
      nil ->
        {:noreply, socket}

      announcement ->
        {:ok, _} = Instance.delete_announcement(announcement)
        Streaming.publish_announcement_delete(announcement)

        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:announcements, %{})}
    end
  end

  def handle_event("publish_terms", %{"text" => text, "effective_date" => date}, socket) do
    attrs = %{"text" => text, "effective_date" => date}

    case Instance.publish_terms(socket.assigns.account, attrs) do
      {:ok, _terms} ->
        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:settings, %{})}

      {:error, _changeset} ->
        {:noreply,
         assign(socket, error: gettext("Terms need some text and a day they take effect."))}
    end
  end

  def handle_event("announce_terms", %{"terms" => id}, socket) do
    case Enum.find(socket.assigns.terms, &(to_string(&1.id) == id)) do
      nil -> {:noreply, socket}
      terms -> announce(socket, Instance.announce_terms(terms))
    end
  end

  def handle_event("block_email_domain", params, socket) do
    blocked(
      socket,
      Signup.block_email_domain(socket.assigns.account, %{
        "domain" => params["domain"],
        "allow_with_approval" => params["allow_with_approval"] == "true"
      })
    )
  end

  def handle_event("block_ip", params, socket) do
    blocked(
      socket,
      Signup.block_ip(socket.assigns.account, %{
        "cidr" => params["cidr"],
        "severity" => params["severity"]
      })
    )
  end

  def handle_event("block_username", params, socket) do
    blocked(
      socket,
      Signup.block_username(socket.assigns.account, %{
        "username" => params["username"],
        "exact" => params["partial"] != "true"
      })
    )
  end

  def handle_event("unblock", %{"kind" => kind, "id" => id}, socket) do
    lift(socket.assigns.account, kind, socket.assigns.lists, id)

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:signups, %{})}
  end

  def handle_event("add_webhook", params, socket) do
    case Webhooks.create(%{url: String.trim(params["url"] || ""), events: params["events"] || []}) do
      {:ok, webhook} ->
        # Shown once, here, and never again. A secret that stays readable on a
        # page is a secret that leaks with the first screenshot of that page.
        {:noreply,
         socket
         |> assign(saved?: true, error: nil, new_secret: webhook.secret)
         |> load(:webhooks, %{})}

      {:error, changeset} ->
        {:noreply, assign(socket, error: webhook_error(changeset))}
    end
  end

  def handle_event("enable_webhook", %{"webhook" => id}, socket),
    do: with_webhook(socket, id, &Webhooks.set_enabled(&1, true))

  def handle_event("disable_webhook", %{"webhook" => id}, socket),
    do: with_webhook(socket, id, &Webhooks.set_enabled(&1, false))

  def handle_event("delete_webhook", %{"webhook" => id}, socket),
    do: with_webhook(socket, id, &Webhooks.delete/1)

  def handle_event("rotate_webhook", %{"webhook" => id}, socket) do
    case Webhooks.get(id) do
      nil ->
        {:noreply, socket}

      webhook ->
        {:ok, rotated} = Webhooks.rotate_secret(webhook)

        {:noreply,
         socket
         |> assign(saved?: true, error: nil, new_secret: rotated.secret)
         |> load(:webhooks, %{})}
    end
  end

  @doc """
  Creating or changing a role.

  Every write is checked against `Roles.can_manage?/2` here rather than only in
  the markup: the buttons are hidden for a role somebody may not touch, and a
  hidden button is not a check. Somebody can always send the event anyway.
  """
  def handle_event("save_role_definition", params, socket) do
    attrs = role_attrs(params, socket.assigns.user)

    case existing_role(params) do
      nil -> create_role(socket, attrs)
      role -> edit_role(socket, role, attrs)
    end
  end

  def handle_event("delete_role", %{"role" => id}, socket) do
    with %Role{} = role <- Roles.get(id),
         true <- Roles.can_manage?(socket.assigns.user, role) do
      {:ok, _deleted} = Roles.delete(role)

      AuditLog.record(socket.assigns.account, "role.delete", :role, role.id, %{
        "label" => role.name
      })

      {:noreply, socket |> assign(saved?: true, error: nil) |> load(:roles, %{})}
    else
      _ -> {:noreply, assign(socket, error: refusal_message())}
    end
  end

  # Silence rather than suspend, because this is one click from a list and the
  # louder of the two is not a thing to reach by accident. Whoever wants a
  # suspension has the full domain-block form and a decision to make.
  def handle_event("block_instance", %{"domain" => domain}, socket) do
    case Domains.block(socket.assigns.account, %{"domain" => domain, "severity" => "silence"}) do
      {:ok, _block} ->
        {:noreply,
         socket
         |> assign(saved?: true, error: nil)
         |> load(:instances, socket.assigns.filters)}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: gettext("That server could not be blocked."))}
    end
  end

  def handle_event("save_moderation_note", %{"note" => note}, socket) do
    {:ok, _saved} =
      Admin.put_moderation_note(socket.assigns.account, socket.assigns.subject, note)

    {:noreply,
     socket |> assign(saved?: true, error: nil) |> load(:account, %{"id" => subject_id(socket)})}
  end

  def handle_event("force_password_reset", _params, socket) do
    case Admin.force_password_reset(socket.assigns.account, socket.assigns.subject) do
      :ok ->
        {:noreply, assign(socket, saved?: true, error: nil)}

      {:error, :no_user} ->
        {:noreply, assign(socket, error: gettext("That account has nobody to sign in as."))}
    end
  end

  def handle_event("refetch_account", _params, socket) do
    case Admin.refetch(socket.assigns.account, socket.assigns.subject) do
      {:ok, _refreshed} ->
        {:noreply,
         socket
         |> assign(saved?: true, error: nil)
         |> load(:account, %{"id" => subject_id(socket)})}

      _ ->
        {:noreply, assign(socket, error: gettext("Their server did not answer."))}
    end
  end

  def handle_event("delete_status", %{"status" => id}, socket) do
    # Scoped to the account being looked at, so an id somebody types is only
    # ever one of the posts on the screen in front of them.
    case Enum.find(socket.assigns.subject_statuses, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, socket}

      status ->
        Statuses.delete_status(status)

        AuditLog.record(
          socket.assigns.account,
          "status.delete",
          :account,
          socket.assigns.subject.id,
          %{
            "status_id" => to_string(status.id)
          }
        )

        {:noreply,
         socket
         |> assign(saved?: true, error: nil)
         |> load(:account, %{"id" => subject_id(socket)})}
    end
  end

  def handle_event("import_domains", %{"kind" => kind, "csv" => csv}, socket) do
    moderator = socket.assigns.account

    # Blocks go through `Domains.import_csv/2`, which reads the column order
    # shared lists actually use and that `export_csv/0` writes. The importer
    # this used to call read the third column as the public comment, where
    # that format puts `reject_media` -- so a list exported here and imported
    # here came back with "true" as its comment and its media, report and
    # obfuscation decisions gone.
    {added, skipped} =
      case kind do
        "allows" ->
          DomainLists.import_allows(moderator, csv)

        _ ->
          {:ok, %{created: created, skipped: skipped}} = Domains.import_csv(moderator, csv)
          {created, skipped}
      end

    {:noreply,
     socket
     |> assign(
       saved?: true,
       error: nil,
       imported:
         gettext("Added %{added}. %{skipped} were already decided about.",
           added: added,
           skipped: skipped
         )
     )
     |> load(:domain_lists, %{})}
  end

  def handle_event("toggle_suggestion", %{"account" => id, "on" => on}, socket) do
    :ok = Suggestions.suppress(id, on == "true")

    AuditLog.record(socket.assigns.account, "suggestion.suppress", :account, to_integer(id), %{
      "on" => on
    })

    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:suggestions, %{})}
  end

  def handle_event("search_instances", %{"query" => query}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/instances?query=#{String.trim(query)}")}
  end

  def handle_event("stop_delivery", %{"domain" => domain}, socket),
    do: with_instance(socket, domain, "instance.stop_delivery", &Instances.stop_delivery/1)

  def handle_event("restart_delivery", %{"domain" => domain}, socket),
    do: with_instance(socket, domain, "instance.restart_delivery", &Instances.restart_delivery/1)

  def handle_event("clear_delivery_errors", %{"domain" => domain}, socket),
    do:
      with_instance(
        socket,
        domain,
        "instance.clear_errors",
        &Instances.clear_delivery_errors/1
      )

  def handle_event("save_instance_note", %{"domain" => domain, "note" => note}, socket) do
    :ok = Instances.put_note(domain, note)

    {:noreply,
     socket
     |> assign(saved?: true, error: nil)
     |> load(:instances, socket.assigns.filters)}
  end

  def handle_event("add_relay", %{"inbox_url" => url}, socket) do
    case Relays.add(String.trim(url)) do
      {:ok, relay} ->
        audit(socket, "relay.add", relay)

        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:relays, %{})}

      {:error, _changeset} ->
        {:noreply,
         assign(socket,
           error: gettext("That is not an https inbox address, or it is already here.")
         )}
    end
  end

  def handle_event("enable_relay", %{"relay" => id}, socket),
    do: with_relay(socket, id, "relay.enable", &Relays.enable/1)

  def handle_event("disable_relay", %{"relay" => id}, socket),
    do: with_relay(socket, id, "relay.disable", &Relays.disable/1)

  def handle_event("remove_relay", %{"relay" => id}, socket),
    do: with_relay(socket, id, "relay.remove", &Relays.remove/1)

  def handle_event("add_rule", %{"text" => text}, socket) do
    case Settings.create_rule(%{text: text, position: length(socket.assigns.rules)}) do
      {:ok, _rule} ->
        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:settings, %{})}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: gettext("A rule needs some text."))}
    end
  end

  def handle_event("delete_rule", %{"rule" => id}, socket) do
    # Retired rather than erased, so an agreement recorded against it still
    # means something.
    case Enum.find(socket.assigns.rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        {:ok, _retired} = Settings.delete_rule(rule)

        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:settings, %{})}
    end
  end

  def handle_event("filter_audit", %{"action" => action}, socket) do
    {:noreply, assign(socket, entries: Admin.audit_log(%{action: action}))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Plumbing

  defp take_action(socket, action, text) do
    case Actions.take(socket.assigns.account, socket.assigns.subject, action, text: text) do
      {:ok, _strike} ->
        {:noreply, socket |> assign(saved?: true, error: nil) |> reload_subject()}

      {:error, :no_statuses} ->
        {:noreply,
         assign(socket,
           error: gettext("Deleting posts needs the posts named, which this page cannot do yet.")
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, error: gettext("That could not be done."))}
    end
  end

  defp with_user(socket, id, fun) do
    case Admin.get_user(id) do
      nil -> {:noreply, socket}
      user -> after_user_change(socket, fun.(user))
    end
  end

  defp after_user_change(socket, {:error, _reason}) do
    {:noreply, assign(socket, error: gettext("That could not be done."))}
  end

  defp after_user_change(socket, _result) do
    {:noreply,
     socket |> assign(saved?: true, error: nil) |> load(:accounts, socket.assigns.filters)}
  end

  defp reload_subject(socket) do
    load(socket, :account, %{"id" => to_string(socket.assigns.subject.id)})
  end

  # A month, which is what the charts are for: how the server is doing now
  # rather than what it did last spring.
  @dashboard_days 30

  defp load(socket, :dashboard, _params) do
    to = Date.utc_today()
    from = Date.add(to, -@dashboard_days)

    assign(socket,
      counts: Admin.pending_counts(),
      checks: Admin.system_checks(),
      measures: series(Metrics.measure(dashboard_measures(), from, to)),
      dimensions: series(Metrics.dimension(dashboard_dimensions(), from, to, 5)),
      # `retention/3` answers with the list itself rather than an ok tuple.
      retention: Metrics.retention(Date.add(to, -84), to, "week")
    )
  end

  defp load(socket, :accounts, params) do
    filters = Map.take(params, ~w(query origin status))

    accounts =
      Admin.accounts(%{
        query: filters["query"],
        origin: filters["origin"],
        status: filters["status"]
      })

    # Ticks survive a filter change only for accounts still on the page. A batch
    # that quietly carries an account somebody filtered away is a batch that
    # does something nobody can see it about to do.
    visible = MapSet.new(accounts, & &1.id)
    batch = MapSet.intersection(socket.assigns[:batch] || MapSet.new(), visible)

    assign(socket,
      filters: filters,
      accounts: accounts,
      pending: Admin.pending_user_ids(accounts),
      batch: batch,
      batch_count: MapSet.size(batch)
    )
  end

  defp load(socket, :emoji, _params), do: assign(socket, emoji: Instance.all_custom_emojis())

  defp load(socket, :reports, params) do
    state = Map.get(params, "state", "open")

    assign(socket,
      report_state: state,
      reports: Admin.reports(state),
      report_accounts: %{}
    )
    |> assign_report_accounts()
  end

  defp load(socket, :appeals, _params),
    do: assign(socket, appeals: Actions.pending_appeals())

  defp load(socket, :report, %{"id" => id}) do
    case Reports.get(id) do
      nil ->
        refuse(socket)

      report ->
        assign(socket,
          report: report,
          report_notes: Admin.notes_with_authors(:report, report.id),
          report_statuses: Admin.reported_statuses(report),
          report_accounts: Admin.accounts_by_id([report.account_id, report.target_account_id])
        )
    end
  end

  defp load(socket, :account, %{"id" => id}) do
    case Accounts.get_account(to_integer(id)) do
      nil ->
        refuse(socket)

      subject ->
        user = Admin.user_for(subject)

        assign(socket,
          subject: subject,
          subject_user: user,
          subject_statuses: Statuses.account_timeline(subject, subject, %{limit: 20}),
          strikes: Actions.strikes(subject),
          roles: Roles.all(),
          may_act?: may_act?(socket.assigns.user, user),
          presets: WarningPresets.all(),
          action_text: socket.assigns[:action_text] || ""
        )
    end
  end

  defp load(socket, :trends, _params) do
    assign(socket,
      pending_trends: Trends.pending_reviews(),
      ranked_trends: Enum.flat_map(Trends.kinds(), &Trends.list(&1, limit: 20))
    )
  end

  defp load(socket, :signups, _params) do
    assign(socket,
      lists: %{
        email_domains: Signup.email_domain_blocks(),
        emails: Signup.canonical_email_blocks(),
        ips: Signup.ip_blocks(),
        usernames: Signup.username_blocks()
      }
    )
  end

  defp load(socket, :instances, params) do
    filters = Map.take(params, ["query"])

    assign(socket,
      filters: filters,
      instances: Instances.list(%{query: filters["query"], limit: 100})
    )
  end

  defp load(socket, :domain_lists, _params) do
    assign(socket, domain_counts: Domains.counts())
  end

  defp load(socket, :suggestions, _params) do
    assign(socket, suggestions: Admin.suggestion_candidates())
  end

  defp load(socket, :subscriptions, _params) do
    assign(socket, subscriptions: Admin.subscription_counts())
  end

  defp load(socket, :relays, _params), do: assign(socket, relays: Relays.list())

  defp load(socket, :roles, params) do
    assign(socket, roles: Roles.all(), editing_role: Roles.get(params["edit"] || ""))
  end

  defp load(socket, :webhooks, _params) do
    webhooks = Webhooks.list()

    assign(socket,
      webhooks: webhooks,
      deliveries: Map.new(webhooks, &{&1.id, Webhooks.deliveries(&1, 5)})
    )
  end

  defp load(socket, :announcements, _params),
    do: assign(socket, announcements: Instance.all_announcements())

  defp load(socket, :settings, _params),
    do:
      assign(socket,
        settings: Admin.settings(),
        rules: Settings.rules(),
        terms: Instance.terms_versions(),
        presets: WarningPresets.all()
      )

  defp load(socket, :audit, _params) do
    assign(socket, entries: Admin.audit_log(%{}), actions: Admin.audit_actions())
  end

  # The appeal is looked up here rather than taken from the rendered list, and
  # the lookup only finds undecided ones, so an id sent over the socket for an
  # appeal somebody else has just answered decides nothing.
  #
  # Rank is checked for the same reason it is checked on the account screen:
  # upholding an appeal reaches `Actions.undo/2`, and without this the appeal
  # queue would be a second path to lifting a strike that the account screen
  # refuses to lift.
  defp on_appeal(socket, id, fun) do
    case Actions.get_pending_appeal(id) do
      nil ->
        assign(socket, error: gettext("That appeal is no longer waiting."))

      appeal ->
        if may_act?(socket.assigns.user, Admin.user_for(appeal.account)) do
          {:ok, _decided} = fun.(appeal)

          socket |> assign(saved?: true, error: nil) |> load(:appeals, %{})
        else
          assign(socket, error: outranks_message())
        end
    end
  end

  # A report event that arrives from a section with no report open changes
  # nothing rather than killing the socket. An event is sent by whatever is on
  # the other end, and a crash is a worse answer than a shrug.
  defp on_report(socket, fun) do
    case socket.assigns[:report] do
      nil ->
        socket

      report ->
        case fun.(report) do
          {:ok, updated} -> assign(socket, saved?: true, report: updated)
          {:error, _reason} -> assign(socket, error: gettext("That did not work."))
        end
    end
  end

  # From the list this screen is showing rather than from the event, so an id
  # for something else is an id this does not find.
  defp emoji_of(socket, id) do
    Enum.find(socket.assigns[:emoji] || [], &(to_string(&1.id) == to_string(id)))
  end

  # Stored before the row is written, because the path contains the id — so the
  # row is created first with a placeholder address and then told where its
  # picture went. A failure between the two leaves an emoji pointing nowhere,
  # which is why the whole thing is undone rather than left.
  defp add_emoji(socket, attrs) do
    {done, waiting} = uploaded_entries(socket, :image)

    cond do
      # The browser refused it — the wrong sort of file, or too large. Consuming
      # now raises, which took the whole screen down for somebody who had picked
      # the wrong file and pressed the button.
      socket.assigns.uploads.image.errors != [] ->
        assign(socket, error: upload_error(socket.assigns.uploads.image.errors))

      waiting != [] ->
        assign(socket, error: gettext("The picture is still uploading. Try again in a moment."))

      done == [] ->
        assign(socket, error: gettext("Choose a picture for it."))

      true ->
        consume_emoji(socket, attrs)
    end
  end

  defp upload_error(errors) do
    cond do
      Enum.any?(errors, &match?({_ref, :not_accepted}, &1)) ->
        gettext("An emoji has to be a PNG or a GIF.")

      Enum.any?(errors, &match?({_ref, :too_large}, &1)) ->
        gettext("That picture is too large for an emoji.")

      true ->
        gettext("That picture could not be used.")
    end
  end

  defp consume_emoji(socket, attrs) do
    # The path a consumed upload hands over is deleted the moment the callback
    # returns, and the picture cannot be stored until the row exists — the key
    # contains the row's id. So it is copied somewhere of its own first.
    uploads =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        kept = Path.join(System.tmp_dir!(), "abuuba-emoji-#{System.unique_integer([:positive])}")
        File.cp!(path, kept)

        {:ok, %{path: kept, filename: entry.client_name, content_type: entry.client_type}}
      end)

    case uploads do
      [] ->
        assign(socket, error: gettext("Choose a picture for it."))

      [upload] ->
        store_emoji(socket, attrs, upload)
    end
  end

  defp store_emoji(socket, attrs, upload) do
    # What the shortcode pointed at before, so that replacing a picture takes
    # the old file with it rather than leaving it on the disk for good.
    previous = Instance.local_emoji_image_url(attrs["shortcode"])

    with {:ok, emoji} <- Instance.put_local_emoji(Map.put(attrs, "image_url", "pending")),
         {:ok, url} <- EmojiImages.store(emoji.id, upload, replacing: previous),
         {:ok, _stored} <-
           Instance.put_local_emoji(Map.merge(attrs, %{"image_url" => url, "static_url" => url})) do
      socket |> assign(saved?: true, error: nil) |> load(:emoji, %{})
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, error: emoji_error(changeset))

      {:error, :unsupported} ->
        assign(socket, error: gettext("An emoji has to be a PNG or a GIF."))

      {:error, :too_large} ->
        assign(socket, error: gettext("That picture is too large for an emoji."))

      {:error, _reason} ->
        assign(socket, error: gettext("That picture could not be stored."))
    end
  after
    # The copy made to survive `consume_uploaded_entries` is this function's to
    # clean up, whichever way the store went.
    File.rm(upload.path)
  end

  # The shortcode rule said in words. "has invalid format" tells somebody that
  # something is wrong and nothing about what to type instead.
  defp emoji_error(changeset) do
    if Keyword.has_key?(changeset.errors, :shortcode) do
      gettext("A shortcode is letters, numbers and underscores, and nothing else.")
    else
      gettext("That emoji could not be saved.")
    end
  end

  # The ids the form actually sent. A checkbox that is not ticked sends nothing
  # at all, so the map is the whole answer rather than a set of true and false.
  defp ticked(params) do
    params
    |> Map.get("accounts", %{})
    |> case do
      accounts when is_map(accounts) -> accounts
      _other -> %{}
    end
    |> Enum.filter(fn {_id, value} -> value == "true" end)
    |> Enum.map(fn {id, _value} -> to_integer(id) end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # One at a time, through the same call a single account goes through, so each
  # gets its own strike, its own notification and its own audit entry. "Who
  # suspended this account" has to stay answerable per account, and a batch
  # that wrote one entry naming twenty would answer it with a shrug.
  #
  # Only the three actions the bar offers, and only accounts that were on the
  # page the moderator was looking at. Both come from the event rather than
  # from the server, so both are checked here: without the first, a crafted
  # event reaches every action a strike knows, including the one that deletes
  # posts and cannot be undone; without the second, it reaches accounts the
  # filter had hidden.
  defp apply_batch(socket, _ids, action) when action not in ~w(silence suspend disable),
    do: assign(socket, error: gettext("That is not something this list can do."))

  defp apply_batch(socket, ids, action) do
    moderator = socket.assigns.account
    on_page = MapSet.new(socket.assigns.accounts, & &1.id)

    outcomes =
      ids
      |> MapSet.intersection(on_page)
      |> Enum.map(&Accounts.get_account/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&outcome(socket, moderator, &1, action))
      |> Enum.frequencies()

    socket
    |> assign(saved?: true, batch: MapSet.new(), batch_count: 0)
    |> assign(error: batch_message(outcomes))
    |> load(:accounts, socket.assigns.filters)
  end

  defp outcome(socket, moderator, target, action) do
    cond do
      not may_act?(socket.assigns.user, Admin.user_for(target)) -> :outranked
      match?({:ok, _strike}, Actions.take(moderator, target, action)) -> :done
      true -> :failed
    end
  end

  # Said out loud rather than left to be noticed. A batch that silently did
  # nineteen of twenty is a batch whose twentieth account nobody follows up,
  # and "it outranks yours" said about an account that failed for some other
  # reason is worse than saying nothing.
  defp batch_message(outcomes) do
    [
      count_message(outcomes[:outranked], fn count ->
        ngettext(
          "One account was left alone because it outranks yours.",
          "%{count} accounts were left alone because they outrank yours.",
          count
        )
      end),
      count_message(outcomes[:failed], fn count ->
        ngettext(
          "One account could not be changed.",
          "%{count} accounts could not be changed.",
          count
        )
      end)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp count_message(nil, _build), do: nil
  defp count_message(0, _build), do: nil
  defp count_message(count, build), do: build.(count)

  # Silence, suspend and turn away: the three a moderator reaches for over a
  # filtered list. Deleting somebody's posts is deliberately not here, because
  # it is the one action on the list that cannot be lifted afterwards.
  defp batch_choices do
    [
      {"silence", gettext("Limit them")},
      {"suspend", gettext("Suspend them")},
      {"disable", gettext("Stop them signing in")}
    ]
  end

  defp assign_report_accounts(socket) do
    ids =
      Enum.flat_map(socket.assigns.reports, &[&1.account_id, &1.target_account_id])

    assign(socket, report_accounts: Admin.accounts_by_id(ids))
  end

  # The handle of an account a page already loaded, or a placeholder. A report
  # names accounts that may have been deleted since it was filed, and a queue
  # that raised on one of those would be a queue nobody could open.
  defp handle(accounts, id) do
    case Map.get(accounts, id) do
      nil -> gettext("somebody who is gone")
      account -> Account.acct(account)
    end
  end

  # An account with no user behind it is remote, and nobody outranks a stranger
  # on another server.
  defp may_act?(_moderator, nil), do: true
  defp may_act?(moderator, subject_user), do: Roles.can_act_on?(moderator, subject_user)

  defp refuse(socket) do
    socket
    |> put_flash(:error, gettext("That is not something your account can do."))
    |> push_navigate(to: ~p"/")
  end

  defp outranks_message,
    do: gettext("That account outranks yours, so there is nothing here you can do to it.")

  # The account page belongs to the accounts section, and needs its permission.
  defp permission_for(:account), do: "manage_users"
  defp permission_for(:report), do: "manage_reports"

  defp permission_for(section) do
    case List.keyfind(@sections, section, 0) do
      {_section, permission} -> permission
      nil -> "administrator"
    end
  end

  defp allowed_sections(permissions) do
    for {action, permission} <- @sections,
        Roles.allows?(permissions, permission),
        do: {action, section_label(action)}
  end

  # The moderator's wording for what a strike did. `SettingsLive` has its own
  # list for the same six actions, in the second person, because it is telling
  # the person it happened to. "Your account was limited" is the wrong sentence
  # to put in a queue, so these are two lists on purpose rather than one shared
  # one somebody should merge later.
  defp action_label("none"), do: gettext("Warned")
  defp action_label("disable"), do: gettext("Account disabled")
  defp action_label("mark_statuses_as_sensitive"), do: gettext("Posts marked sensitive")
  defp action_label("delete_statuses"), do: gettext("Posts deleted")
  defp action_label("silence"), do: gettext("Account limited")
  defp action_label("suspend"), do: gettext("Account suspended")
  defp action_label(action), do: action

  defp section_label(:dashboard), do: gettext("Dashboard")
  defp section_label(:accounts), do: gettext("Accounts")
  defp section_label(:account), do: gettext("Account")
  defp section_label(:reports), do: gettext("Reports")
  defp section_label(:emoji), do: gettext("Custom emoji")
  defp section_label(:report), do: gettext("Report")
  defp section_label(:appeals), do: gettext("Appeals")
  defp section_label(:trends), do: gettext("Trends")
  defp section_label(:announcements), do: gettext("Announcements")
  defp section_label(:signups), do: gettext("Sign-up blocks")
  defp section_label(:relays), do: gettext("Relays")
  defp section_label(:subscriptions), do: gettext("Email subscriptions")
  defp section_label(:suggestions), do: gettext("Suggestions")
  defp section_label(:domain_lists), do: gettext("Domain lists")
  defp section_label(:instances), do: gettext("Other servers")
  defp section_label(:roles), do: gettext("Roles")
  defp section_label(:webhooks), do: gettext("Webhooks")
  defp section_label(:settings), do: gettext("Server settings")
  defp section_label(:audit), do: gettext("Audit log")
  defp section_label(_section), do: gettext("Administration")

  defp section_path(:dashboard), do: ~p"/admin"
  defp section_path(:accounts), do: ~p"/admin/accounts"
  defp section_path(:reports), do: ~p"/admin/reports"
  defp section_path(:appeals), do: ~p"/admin/appeals"
  defp section_path(:emoji), do: ~p"/admin/emoji"
  defp section_path(:trends), do: ~p"/admin/trends"
  defp section_path(:announcements), do: ~p"/admin/announcements"
  defp section_path(:signups), do: ~p"/admin/signups"
  defp section_path(:relays), do: ~p"/admin/relays"
  defp section_path(:subscriptions), do: ~p"/admin/subscriptions"
  defp section_path(:suggestions), do: ~p"/admin/suggestions"
  defp section_path(:domain_lists), do: ~p"/admin/domain-lists"
  defp section_path(:instances), do: ~p"/admin/instances"
  defp section_path(:roles), do: ~p"/admin/roles"
  defp section_path(:webhooks), do: ~p"/admin/webhooks"
  defp section_path(:settings), do: ~p"/admin/settings"
  defp section_path(:audit), do: ~p"/admin/audit-log"

  defp account_states do
    [
      {"pending", gettext("Waiting to be let in")},
      {"silenced", gettext("Limited")},
      {"suspended", gettext("Suspended")}
    ]
  end

  defp registration_choices do
    [
      {"open", gettext("Anybody, straight away")},
      {"approved", gettext("Anybody, after somebody here says yes")},
      {"closed", gettext("Nobody")}
    ]
  end

  defp action_choices(_subject) do
    [
      {"none", gettext("Send a warning and nothing else")},
      {"silence", gettext("Silence: out of everywhere nobody asked for them")},
      {"suspend", gettext("Suspend: hidden, and deleted after the grace window")},
      {"disable", gettext("Disable: they cannot sign in")},
      {"mark_statuses_as_sensitive", gettext("Mark everything they post sensitive")}
    ]
  end

  # Stopping delivery to a server is a decision about everybody here who talks
  # to anybody there, so it is recorded with the domain rather than only taken.
  defp subject_id(socket), do: to_string(socket.assigns.subject.id)

  defp plain_text(html), do: Formatter.plain_text(html, limit: 200)

  defp with_instance(socket, domain, action, act) do
    act.(domain)

    AuditLog.record(socket.assigns.account, action, :domain, 0, %{"domain" => domain})

    {:noreply,
     socket
     |> assign(saved?: true, error: nil)
     |> load(:instances, socket.assigns.filters)}
  end

  defp with_relay(socket, id, action, act) do
    case Relays.get(id) do
      nil ->
        {:noreply, socket}

      relay ->
        act.(relay)
        audit(socket, action, relay)

        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:relays, %{})}
    end
  end

  # Who turned a relay on, and when. A relay is a standing decision to send
  # every public post here to somebody else's machine and to take back whatever
  # it sends; a server with more than one moderator should be able to find out
  # which of them made that decision without asking around.
  #
  # The inbox address goes in as the label, because "relay #4" tells whoever
  # reads the log a year later nothing at all, and the row outlives the relay.
  defp audit(socket, action, relay) do
    AuditLog.record(socket.assigns.account, action, :relay, relay.id, %{
      "label" => relay.inbox_url
    })
  end

  defp create_role(socket, attrs) do
    # Checked against a role that does not exist yet by building it and asking
    # the same question: a new role above the person making it, or holding a
    # permission they do not, is the same escalation as editing one into that
    # shape.
    proposed = struct(%Role{}, attrs)

    if Roles.can_manage?(socket.assigns.user, proposed) do
      case Roles.create(attrs) do
        {:ok, role} ->
          AuditLog.record(socket.assigns.account, "role.create", :role, role.id, %{
            "label" => role.name
          })

          {:noreply, socket |> assign(saved?: true, error: nil) |> load(:roles, %{})}

        {:error, _changeset} ->
          {:noreply, assign(socket, error: gettext("That role could not be saved."))}
      end
    else
      {:noreply, assign(socket, error: refusal_message())}
    end
  end

  defp edit_role(socket, role, attrs) do
    proposed = struct(role, attrs)

    # Both shapes: the role as it stands, so nobody edits one above them, and
    # the role as it would be, so nobody edits one upwards into that position.
    if Roles.can_manage?(socket.assigns.user, role) and
         Roles.can_manage?(socket.assigns.user, proposed) do
      case Roles.update(role, attrs) do
        {:ok, saved} ->
          AuditLog.record(socket.assigns.account, "role.update", :role, saved.id, %{
            "label" => saved.name
          })

          {:noreply,
           socket
           |> assign(saved?: true, error: nil, editing_role: nil)
           |> load(:roles, %{})}

        {:error, _changeset} ->
          {:noreply, assign(socket, error: gettext("That role could not be saved."))}
      end
    else
      {:noreply, assign(socket, error: refusal_message())}
    end
  end

  defp existing_role(%{"role_id" => id}) when is_binary(id) and id != "", do: Roles.get(id)
  defp existing_role(_params), do: nil

  # Only the boxes this person may tick. A permission they do not hold is left
  # exactly as it was on the role rather than dropped, so editing a role that
  # is otherwise above nobody does not quietly strip a permission the editor
  # could not see.
  defp role_attrs(params, user) do
    wanted = Map.get(params, "permissions", %{})

    %{
      name: String.trim(Map.get(params, "name", "")),
      color: String.trim(Map.get(params, "color", "")),
      position: to_position(Map.get(params, "position")),
      permissions: role_mask(wanted, params, user)
    }
  end

  defp role_mask(wanted, params, user) do
    existing =
      case existing_role(params) do
        %Role{permissions: bits} -> bits
        _ -> 0
      end

    Enum.reduce(Roles.permissions(), 0, fn permission, mask ->
      on? =
        if Roles.can?(user, permission) do
          Map.get(wanted, permission) == "true"
        else
          Bitwise.band(existing, Roles.bit(permission)) != 0
        end

      if on?, do: Bitwise.bor(mask, Roles.bit(permission)), else: mask
    end)
  end

  defp to_position(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp refusal_message,
    do:
      gettext(
        "You cannot make a role at or above your own position, or grant a permission you do not hold."
      )

  # In plain language, because "manage_taxonomies" is a word this project made
  # up and the person ticking the box has to know what they are handing over.
  defp permission_label("administrator"), do: gettext("Everything")
  defp permission_label("view_dashboard"), do: gettext("See the admin area")
  defp permission_label("view_audit_log"), do: gettext("Read the audit log")
  defp permission_label("manage_users"), do: gettext("Act on accounts")
  defp permission_label("manage_user_access"), do: gettext("Let people in and out")
  defp permission_label("delete_user_data"), do: gettext("Delete an account's data")
  defp permission_label("manage_reports"), do: gettext("Handle reports")
  defp permission_label("manage_appeals"), do: gettext("Answer appeals")
  defp permission_label("manage_federation"), do: gettext("Decide about other servers")
  defp permission_label("manage_blocks"), do: gettext("Block sign-ups")
  defp permission_label("manage_settings"), do: gettext("Change the server's settings")
  defp permission_label("manage_taxonomies"), do: gettext("Approve what trends")
  defp permission_label("manage_invites"), do: gettext("Manage everybody's invites")
  defp permission_label("invite_users"), do: gettext("Write invites")
  defp permission_label("manage_rules"), do: gettext("Write the server rules")
  defp permission_label("manage_announcements"), do: gettext("Write announcements")
  defp permission_label("manage_custom_emojis"), do: gettext("Manage custom emoji")
  defp permission_label("manage_webhooks"), do: gettext("Manage webhooks")
  defp permission_label("manage_roles"), do: gettext("Manage roles")
  defp permission_label(name), do: name

  defp permission_hint("administrator"),
    do: gettext("Every permission below, including ones added later. Give it to very few people.")

  defp permission_hint("view_dashboard"), do: gettext("Without this the admin area is closed.")

  defp permission_hint("view_audit_log"),
    do: gettext("What every moderator has done, including this person's own actions.")

  defp permission_hint("manage_users"),
    do: gettext("Silence, suspend, approve and reject accounts on this server.")

  defp permission_hint("manage_user_access"),
    do: gettext("Approve registrations, and turn two-factor off for somebody locked out.")

  defp permission_hint("delete_user_data"),
    do: gettext("Delete somebody's posts and files. This cannot be undone.")

  defp permission_hint("manage_reports"), do: gettext("Read the queue, resolve and reopen.")

  defp permission_hint("manage_federation"),
    do: gettext("Block and unblock other servers, and set up relays.")

  defp permission_hint("manage_settings"),
    do: gettext("Who may sign up, the server's name and description, and the rest.")

  defp permission_hint("manage_taxonomies"),
    do: gettext("Decide which hashtags, links and posts may appear in what is trending.")

  defp permission_hint("manage_roles"),
    do:
      gettext(
        "Make and change roles, never above their own and never granting more than they hold."
      )

  defp permission_hint(_name), do: ""

  defp held?(nil, _permission), do: false

  defp held?(%Role{permissions: bits}, permission),
    do: Bitwise.band(bits, Roles.bit(permission)) != 0

  defp permission_summary(%Role{permissions: bits}) do
    case Roles.names(bits) do
      [] -> gettext("nothing in particular")
      names -> Enum.join(names, ", ")
    end
  end

  defp with_webhook(socket, id, act) do
    case Webhooks.get(id) do
      nil ->
        {:noreply, socket}

      webhook ->
        act.(webhook)

        {:noreply, socket |> assign(saved?: true, error: nil) |> load(:webhooks, %{})}
    end
  end

  defp webhook_error(changeset) do
    cond do
      Keyword.has_key?(changeset.errors, :url) ->
        gettext("That is not an https address, or it is already here.")

      Keyword.has_key?(changeset.errors, :events) ->
        gettext("That is not an event this server sends.")

      true ->
        gettext("That did not work.")
    end
  end

  defp relay_state(:idle), do: gettext("Off")
  defp relay_state(:pending), do: gettext("Waiting for the relay to answer")
  defp relay_state(:accepted), do: gettext("On")
  defp relay_state(:rejected), do: gettext("The relay refused")
  defp relay_state(state), do: to_string(state)

  # A rate is a fraction between nought and one; a person reads percentages.
  defp percentage(rate) when is_number(rate), do: "#{round(rate * 100)}%"
  defp percentage(_rate), do: "—"

  defp to_number(value) when is_integer(value), do: value

  defp to_number(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} -> number
      _ -> 0
    end
  end

  # In words, because the API's keys are for clients and a dashboard is for a
  # person.
  defp measure_label("active_users"), do: gettext("People who posted")
  defp measure_label("new_users"), do: gettext("New accounts")
  defp measure_label("new_statuses"), do: gettext("Posts written here")
  defp measure_label("interactions"), do: gettext("Favourites, boosts and replies")
  defp measure_label("opened_reports"), do: gettext("Reports opened")
  defp measure_label("resolved_reports"), do: gettext("Reports resolved")
  defp measure_label(key), do: key

  defp dimension_label("languages"), do: gettext("Languages people write in")
  defp dimension_label("sources"), do: gettext("Where accounts signed up from")
  defp dimension_label("servers"), do: gettext("Servers we hear most from")
  defp dimension_label("software_versions"), do: gettext("What those servers run")
  defp dimension_label(key), do: key

  defp check_title("database"), do: gettext("The database is not answering")
  defp check_title("instance_actor"), do: gettext("This server has no actor of its own")
  defp check_title("registrations"), do: gettext("Anybody may sign up without being checked")
  defp check_title("administrator"), do: gettext("Nobody here is an administrator")
  defp check_title(key), do: key

  defp check_advice("database"),
    do: gettext("Everything else on this page is guesswork until that is fixed.")

  defp check_advice("instance_actor"),
    do:
      gettext(
        "Servers running authorized fetch will refuse this one. It is created on first use, so this usually means something went wrong writing it."
      )

  defp check_advice("registrations"),
    do:
      gettext(
        "An open server left unattended fills with spam registrations within days. Put sign-ups behind approval unless somebody is watching."
      )

  defp check_advice("administrator"),
    do:
      gettext(
        "Nobody can grant roles or change settings that need it. Give somebody a role holding the administrator permission."
      )

  defp check_advice(_key), do: ""

  defp blocked(socket, {:ok, _block}) do
    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:signups, %{})}
  end

  defp blocked(socket, {:error, _changeset}) do
    {:noreply, assign(socket, error: gettext("That could not be saved. Check what you typed."))}
  end

  defp lift(actor, "email_domain", lists, id),
    do: with_block(lists.email_domains, id, &Signup.unblock_email_domain(actor, &1))

  defp lift(actor, "email", lists, id),
    do: with_block(lists.emails, id, &Signup.unblock_email(actor, &1))

  defp lift(actor, "ip", lists, id),
    do: with_block(lists.ips, id, &Signup.unblock_ip(actor, &1))

  defp lift(actor, "username", lists, id),
    do: with_block(lists.usernames, id, &Signup.unblock_username(actor, &1))

  defp lift(_actor, _kind, _lists, _id), do: :ok

  # Found in what was rendered rather than fetched by id, so an event can only
  # name something the page actually offered.
  defp with_block(blocks, id, fun) do
    case Enum.find(blocks, &(to_string(&1.id) == id)) do
      nil -> :ok
      block -> fun.(block)
    end
  end

  defp ip_severities do
    [
      {"sign_up_requires_approval", gettext("Ask for approval")},
      {"sign_up_block", gettext("No sign-ups")},
      {"no_access", gettext("No access at all")}
    ]
  end

  defp ip_severity_label(severity) do
    case Enum.find(ip_severities(), fn {value, _label} -> value == severity end) do
      {_value, label} -> label
      nil -> severity
    end
  end

  defp announce(socket, {:ok, _terms}) do
    {:noreply, socket |> assign(saved?: true, error: nil) |> load(:settings, %{})}
  end

  defp announce(socket, {:error, :already_announced}) do
    {:noreply, assign(socket, error: gettext("Everybody has already been told about that one."))}
  end

  # A browser sends a local time with no zone. Read as UTC rather than guessed
  # at, and the field says so.
  defp parse_datetime(value) when value in [nil, ""], do: nil

  defp parse_datetime(value) do
    case NaiveDateTime.from_iso8601(value <> ":00") do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end

  # The handful worth a chart. Every measure the API serves is not a dashboard;
  # it is a list, and a page of twenty charts is a page nobody reads.
  defp dashboard_measures,
    do: ~w(active_users new_users new_statuses interactions opened_reports resolved_reports)

  defp dashboard_dimensions, do: ~w(languages servers sources software_versions)

  # The metrics module answers `{:ok, list}` or an error for an unknown key.
  # Every key here is one of its own, so an error is a bug rather than
  # something a dashboard should try to render around.
  defp series({:ok, list}), do: list
  defp series(_other), do: []

  defp to_integer(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> 0
    end
  end
end
