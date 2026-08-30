defmodule AbuubaWeb.ReportLive do
  @moduledoc """
  Telling a moderator about somebody.

  ## Why the pages needed one at all

  `POST /api/v1/reports` has always answered and `/admin/reports` is a full
  triage queue with categories, evidence, rule attribution and forwarding. No
  page here could put anything into it, so the queue could only be filled from
  an app and a person reading a post on this server had no way to say anything
  about it.

  ## The steps are the moderator's, not the reporter's

  Somebody who has just read something upsetting will type one sentence and
  press send. A moderator then has to decide something, and what makes that
  possible is the shape around the sentence: which kind of problem, which posts,
  which rules. So the questions are asked one at a time and in that order,
  which is what the reference implementation settled on, and each one narrows
  what the next has to ask.

  One page rather than a stack of them: the whole thing is four short questions,
  and a wizard whose steps are each one radio group is four page loads to send
  one sentence. Back is the browser's Back, and nothing is written until the
  last press.

  ## The first option files nothing

  "I do not like it" is not a moderation problem, and a queue that fills with
  those is a queue where the real ones wait behind them. Choosing it jumps
  straight to mute and block, which is what the reader actually wanted, and the
  moderators never hear about it. Those two are offered after a real report as
  well: the report is a decision somebody else has to make, and in the meantime
  the reader still has to get through their day.
  """

  use AbuubaWeb, :live_view

  import AbuubaWeb.StatusComponent

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Moderation.Reports
  alias Abuuba.Relationships
  alias Abuuba.Settings
  alias Abuuba.Snowflake
  alias Abuuba.Statuses
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.Meta

  # `dislike` is not one of them: it is the way out of here, not a report.
  @evidence_limit 20

  @impl Phoenix.LiveView
  def mount(%{"username" => username} = params, _session, socket) do
    viewer = current_account(socket)

    case Accounts.lookup(username) do
      nil ->
        raise AbuubaWeb.NotFound, "no such account"

      %Account{id: id} when id == :erlang.map_get(:id, viewer) ->
        # Nothing a moderator could do with it, and the mute and block it ends
        # in would be somebody blocking themselves.
        {:ok, push_navigate(socket, to: ~p"/@#{Account.acct(viewer)}")}

      subject ->
        {:ok,
         socket
         |> assign(
           page_title: gettext("Report"),
           robots: Meta.noindex(),
           viewer: viewer,
           subject: subject,
           rules: Settings.rules(),
           step: :category,
           category: nil,
           rule_ids: [],
           forward: false,
           filed?: false,
           relationship: relationship(viewer, subject),
           posts: evidence(subject, viewer),
           chosen: chosen(params)
         )}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@page_title}>
      <header class="border-b border-base-300 p-4">
        <h1 class="text-xl font-semibold">
          {gettext("Report %{name}", name: Account.display_name(@subject))}
        </h1>
        <p class="text-sm text-base-content/60">@{Account.acct(@subject)}</p>
      </header>

      <.category :if={@step == :category} rules={@rules} />
      <.rules :if={@step == :rules} rules={@rules} rule_ids={@rule_ids} />
      <.evidence :if={@step == :evidence} posts={@posts} chosen={@chosen} viewer={@viewer} />
      <.comment :if={@step == :comment} subject={@subject} forward={@forward} />
      <.done :if={@step == :done} subject={@subject} filed?={@filed?} relationship={@relationship} />
    </Layouts.app>
    """
  end

  attr :rules, :list, required: true

  defp category(assigns) do
    ~H"""
    <div class="p-4">
      <h2 class="font-semibold">{gettext("What is going on?")}</h2>

      <ul class="mt-3 space-y-2">
        <li :for={{value, label, hint} <- categories(@rules)}>
          <button
            type="button"
            phx-click="category"
            phx-value-category={value}
            class="w-full rounded border border-base-300 p-3 text-left hover:bg-base-200"
          >
            <span class="block font-medium">{label}</span>
            <span class="block text-sm text-base-content/60">{hint}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :rules, :list, required: true
  attr :rule_ids, :list, required: true

  defp rules(assigns) do
    ~H"""
    <form id="rules-form" phx-submit="rules" class="p-4">
      <h2 class="font-semibold">{gettext("Which rules?")}</h2>
      <p class="mt-1 text-sm text-base-content/60">{gettext("Tick every one that applies.")}</p>

      <ul class="mt-3 space-y-2">
        <li :for={rule <- @rules} class="flex items-start gap-3">
          <input
            type="checkbox"
            name="report[rule_ids][]"
            value={rule.id}
            checked={to_string(rule.id) in @rule_ids}
            class="checkbox checkbox-sm mt-1"
            id={"rule-#{rule.id}"}
          />
          <label for={"rule-#{rule.id}"} class="flex-1">{rule.text}</label>
        </li>
      </ul>

      <button type="submit" class="btn btn-primary mt-4">{gettext("Next")}</button>
    </form>
    """
  end

  attr :posts, :list, required: true
  attr :chosen, :list, required: true
  attr :viewer, :map, required: true

  defp evidence(assigns) do
    ~H"""
    <form id="evidence-form" phx-submit="evidence" class="p-4">
      <h2 class="font-semibold">{gettext("Are there posts that show it?")}</h2>
      <p class="mt-1 text-sm text-base-content/60">
        {gettext("Tick every one a moderator should read. You can tick none.")}
      </p>

      <ul class="mt-3 divide-y divide-base-300">
        <li :for={post <- @posts} class="flex items-start gap-3 py-2">
          <input
            type="checkbox"
            name="report[status_ids][]"
            value={post["id"]}
            checked={post["id"] in @chosen}
            class="checkbox checkbox-sm mt-3"
            aria-label={gettext("Include this post")}
          />
          <div class="min-w-0 flex-1">
            <.status
              id={"evidence-#{post["id"]}"}
              status={post}
              viewer_id={viewer_id(@viewer)}
              interactive={false}
              menu={false}
            />
          </div>
        </li>
      </ul>

      <p :if={@posts == []} class="py-4 text-base-content/60">
        {gettext("Nothing of theirs is here to point at.")}
      </p>

      <button type="submit" phx-click="to_comment" class="btn btn-primary mt-4">
        {gettext("Next")}
      </button>
    </form>
    """
  end

  attr :subject, :map, required: true
  attr :forward, :boolean, required: true

  defp comment(assigns) do
    ~H"""
    <form id="report-form" phx-submit="file" class="p-4">
      <h2 class="font-semibold">{gettext("Anything else a moderator should know?")}</h2>

      <textarea
        name="report[comment]"
        rows="4"
        class="textarea mt-3 w-full"
        placeholder={gettext("In your own words. This is optional.")}
      ></textarea>

      <label :if={@subject.domain} class="mt-3 flex items-start gap-3">
        <input type="hidden" name="report[forward]" value="false" />
        <input
          type="checkbox"
          name="report[forward]"
          value="true"
          checked={@forward}
          class="checkbox checkbox-sm mt-1"
        />
        <span class="flex-1 text-sm">
          {gettext(
            "This account is on %{domain}. Send a copy of this report there as well, without your name.",
            domain: @subject.domain
          )}
        </span>
      </label>

      <button type="submit" class="btn btn-primary mt-4">{gettext("Send the report")}</button>
    </form>
    """
  end

  attr :subject, :map, required: true
  attr :filed?, :boolean, required: true
  attr :relationship, :map, required: true

  defp done(assigns) do
    ~H"""
    <div class="p-4">
      <h2 class="font-semibold">
        {if @filed?,
          do: gettext("Thank you. A moderator will read this."),
          else: gettext("Then here is what you can do yourself.")}
      </h2>

      <p class="mt-1 text-sm text-base-content/60">
        {if @filed?,
          do: gettext("While you wait, you do not have to keep seeing them."),
          else: gettext("Neither of these tells a moderator anything.")}
      </p>

      <div class="mt-4 space-y-4">
        <div :if={@relationship.following}>
          <h3 class="font-medium">{gettext("Unfollow")}</h3>
          <p class="text-sm text-base-content/60">
            {gettext("Their posts leave your home timeline. They keep following you.")}
          </p>
          <button type="button" phx-click="unfollow" class="btn btn-sm mt-2">
            {gettext("Unfollow")}
          </button>
        </div>

        <div>
          <h3 class="font-medium">{gettext("Mute")}</h3>
          <p class="text-sm text-base-content/60">
            {gettext("You stop seeing them everywhere. They can still follow you and are not told.")}
          </p>
          <button
            type="button"
            phx-click="mute"
            disabled={@relationship.muting}
            class="btn btn-sm mt-2"
          >
            {if @relationship.muting, do: gettext("Muted"), else: gettext("Mute")}
          </button>
        </div>

        <div>
          <h3 class="font-medium">{gettext("Block")}</h3>
          <p class="text-sm text-base-content/60">
            {gettext(
              "Everything mute does, and they cannot follow you or read your posts. They can tell."
            )}
          </p>
          <button
            type="button"
            phx-click="block"
            disabled={@relationship.blocking}
            class="btn btn-sm mt-2"
          >
            {if @relationship.blocking, do: gettext("Blocked"), else: gettext("Block")}
          </button>
        </div>
      </div>

      <.link navigate={~p"/@#{Account.acct(@subject)}"} class="btn btn-primary mt-6">
        {gettext("Done")}
      </.link>
    </div>
    """
  end

  ## Events

  @impl Phoenix.LiveView
  def handle_event("category", %{"category" => "dislike"}, socket) do
    # No report, and the moderators never hear about it.
    {:noreply, assign(socket, category: "dislike", step: :done, filed?: false)}
  end

  def handle_event("category", %{"category" => "violation"}, socket) do
    {:noreply, assign(socket, category: "violation", step: :rules)}
  end

  def handle_event("category", %{"category" => category}, socket) do
    {:noreply, assign(socket, category: category, step: :evidence)}
  end

  def handle_event("rules", params, socket) do
    ids = params |> get_in(["report", "rule_ids"]) |> List.wrap()

    {:noreply, assign(socket, rule_ids: ids, step: :evidence)}
  end

  def handle_event("evidence", params, socket) do
    chosen = params |> get_in(["report", "status_ids"]) |> List.wrap()

    {:noreply, assign(socket, chosen: chosen, step: :comment)}
  end

  # The submit button on the evidence form carries this so that a screen with
  # nothing to tick still has a way forward.
  def handle_event("to_comment", _params, socket), do: {:noreply, assign(socket, step: :comment)}

  def handle_event("file", params, socket) do
    attrs = params["report"] || %{}

    Reports.create(socket.assigns.viewer, %{
      "target_account_id" => socket.assigns.subject.id,
      "category" => socket.assigns.category,
      "comment" => attrs["comment"] || "",
      "rule_ids" => socket.assigns.rule_ids,
      "status_ids" => socket.assigns.chosen,
      "forward" => attrs["forward"] == "true"
    })

    {:noreply, assign(socket, step: :done, filed?: true)}
  end

  def handle_event("unfollow", _params, socket),
    do: {:noreply, act(socket, &Relationships.unfollow/2)}

  def handle_event("mute", _params, socket), do: {:noreply, act(socket, &Relationships.mute/2)}
  def handle_event("block", _params, socket), do: {:noreply, act(socket, &Relationships.block/2)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp act(socket, decide) do
    decide.(socket.assigns.viewer, socket.assigns.subject)

    assign(socket, relationship: relationship(socket.assigns.viewer, socket.assigns.subject))
  end

  ## Reading

  # `violation` only where there are rules to name: an option that leads to an
  # empty list of rules is a question nobody can answer.
  defp categories(rules) do
    [
      {"dislike", gettext("I do not like it"),
       gettext("It is not something you want to see. This tells nobody.")},
      {"spam", gettext("It is spam"),
       gettext("Malicious links, fake engagement, or the same thing over and over.")},
      {"legal", gettext("It is illegal"),
       gettext("You believe it breaks the law here or where you are.")}
    ] ++
      rules_option(rules) ++
      [
        {"other", gettext("Something else"), gettext("It does not fit any of the above.")}
      ]
  end

  defp rules_option([]), do: []

  defp rules_option(_rules) do
    [
      {"violation", gettext("It breaks the rules of this server"),
       gettext("You know which rule it breaks.")}
    ]
  end

  defp relationship(viewer, subject) do
    %{
      following: Relationships.following?(viewer.id, subject.id),
      muting: Relationships.muting?(viewer.id, subject.id),
      blocking: Relationships.blocking?(viewer.id, subject.id)
    }
  end

  # Only what the reporter can already see. A report screen is not a way to
  # read somebody's followers-only posts.
  defp evidence(subject, viewer) do
    subject
    |> Statuses.account_timeline(viewer, %{limit: @evidence_limit})
    |> Entities.statuses(viewer)
  end

  defp chosen(%{"status" => id}) do
    case Snowflake.cast(id) do
      {:ok, number} -> [to_string(number)]
      :error -> []
    end
  end

  defp chosen(_params), do: []
end
