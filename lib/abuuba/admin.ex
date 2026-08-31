defmodule Abuuba.Admin do
  @moduledoc """
  What the admin area asks for: what is waiting, who is here, and what has been
  done.

  ## The dashboard is a list of work, not a wall of numbers

  Pending counts are the queue lengths somebody is expected to act on, and the
  system checks say what is wrong rather than confirming what is right. A page
  of green ticks is read once and never again; a short list of what needs
  attention is read every day.

  ## Settings are written through a list of keys

  The form posts what it renders, so a key arriving from anywhere else is
  either a mistake or somebody trying one. Writing it would let anybody who can
  reach the settings page put anything into the settings table, and the table
  is read by the rest of the server without asking where a value came from.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.PasswordResetWorker
  alias Abuuba.Accounts.Suggestions
  alias Abuuba.Accounts.User
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.InstanceActor
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Instance.DonationCampaign
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.Report
  alias Abuuba.Moderation.Reports
  alias Abuuba.OAuth
  alias Abuuba.Pagination
  alias Abuuba.Relationships.Follow
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Roles.Role
  alias Abuuba.Settings
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag
  alias AbuubaWeb.Endpoint

  # Everything the settings pages may write. Anything else is dropped.
  @settings_keys ~w(
    site_title site_description site_contact_email site_contact_account
    site_status_page_url extended_description
    privacy_text privacy_effective_on
    registration_mode closed_registration_message timeline_access show_domain_blocks
    limited_federation content_retention_days remote_post_retention_days
    email_subscriptions
    donation_campaign_message donation_campaign_button_text donation_campaign_url
    custom_css update_check
  )

  ## Dashboard

  @doc """
  How much of each kind of work is waiting.
  """
  @spec pending_counts() :: %{reports: integer(), appeals: integer(), users: integer()}
  def pending_counts do
    %{
      reports: Reports.open_count(),
      appeals: Actions.pending_appeal_count(),
      users: Repo.aggregate(pending_users(), :count)
    }
  end

  @doc """
  What is wrong with this server right now.

  Each check answers `ok?` and carries a key the interface translates, so that
  a check is a fact here and a sentence there.
  """
  @spec system_checks() :: [%{key: String.t(), ok?: boolean(), detail: String.t() | nil}]
  def system_checks do
    [
      database_check(),
      instance_actor_check(),
      registrations_check(),
      administrator_check()
    ]
  end

  defp database_check do
    Repo.aggregate(Account, :count)

    %{key: "database", ok?: true, detail: nil}
  rescue
    error -> %{key: "database", ok?: false, detail: Exception.message(error)}
  end

  # Without it, every fetch this server makes is signed by whichever person
  # happened to trigger it, or by nobody at all.
  defp instance_actor_check do
    %{key: "instance_actor", ok?: not is_nil(InstanceActor.fetch!()), detail: nil}
  rescue
    _error -> %{key: "instance_actor", ok?: false, detail: nil}
  end

  # Open registration with nobody reading the queue is how a server fills with
  # spam accounts over a weekend.
  defp registrations_check do
    %{key: "registrations", ok?: Settings.registration_mode() != :open, detail: nil}
  end

  defp administrator_check do
    mask = Roles.bit("administrator")

    exists? =
      from(u in User,
        join: r in Role,
        on: r.id == u.role_id,
        where: fragment("(? & ?) > 0", r.permissions, ^mask)
      )
      |> Repo.exists?()

    %{key: "administrator", ok?: exists?, detail: nil}
  end

  ## Accounts

  @doc """
  Accounts matching a filter, newest first.

  `query` matches the handle, `origin` is `local` or `remote`, and `status` is
  one of `pending`, `silenced`, `suspended` or `disabled`.
  """
  @spec accounts(map()) :: [Account.t()]
  def accounts(filters \\ %{}) do
    Account
    |> where([a], a.id != ^Accounts.instance_actor_id())
    |> filter_query(Map.get(filters, :query))
    |> filter_origin(Map.get(filters, :origin))
    |> filter_status(Map.get(filters, :status))
    |> Pagination.window(page_of(filters))
    |> Repo.all()
    |> Pagination.reading_order(filters)
  end

  # The filters a caller passes carry the cursors alongside everything else, so
  # the page is just those keys with a default limit this endpoint's own.
  defp page_of(filters) do
    filters
    |> Map.take([:max_id, :since_id, :min_id, :order])
    |> Map.put(:limit, Map.get(filters, :limit, 50))
  end

  defp filter_query(query, nil), do: query
  defp filter_query(query, ""), do: query

  defp filter_query(query, text) do
    {username, domain} =
      case String.split(String.trim(text, "@"), "@", parts: 2) do
        [username, domain] -> {username, domain}
        [username] -> {username, nil}
      end

    query
    |> where([a], ilike(a.username, ^"#{escape_like(username)}%"))
    |> then(fn q ->
      if domain,
        do: where(q, [a], fragment("lower(?)", a.domain) == ^String.downcase(domain)),
        else: q
    end)
  end

  defp filter_origin(query, "local"), do: where(query, [a], is_nil(a.domain))
  defp filter_origin(query, "remote"), do: where(query, [a], not is_nil(a.domain))
  defp filter_origin(query, _origin), do: query

  defp filter_status(query, "silenced"), do: where(query, [a], not is_nil(a.silenced_at))
  defp filter_status(query, "suspended"), do: where(query, [a], not is_nil(a.suspended_at))

  defp filter_status(query, "pending") do
    join(query, :inner, [a], u in ^User.pending(), on: u.account_id == a.id)
  end

  defp filter_status(query, "disabled") do
    join(query, :inner, [a], u in ^User.disabled(), on: u.account_id == a.id)
  end

  defp filter_status(query, _status), do: query

  @doc """
  One user by id, or `nil`.
  """
  @spec get_user(integer() | String.t()) :: User.t() | nil
  def get_user(id) do
    case Snowflake.cast(id) do
      {:ok, id} -> Repo.get(User, id)
      _ -> nil
    end
  end

  @doc """
  Which of these accounts are still waiting to be let in.

  Keyed by account id, carrying the user id to act on and what the applicant
  wrote when the sign-up form asked why they want to join. The reason travels
  with the id rather than in a second lookup, because the screen that shows the
  Let in button is the screen that has to show what it is deciding about.

  One query for the list rather than one per row: the accounts page shows fifty
  at a time and nearly none of them are pending.
  """
  @spec pending_user_ids([Account.t()]) ::
          %{integer() => %{id: integer(), reason: String.t() | nil}}
  def pending_user_ids([]), do: %{}

  def pending_user_ids(accounts) do
    ids = Enum.map(accounts, & &1.id)

    User.pending()
    |> where([u], u.account_id in ^ids)
    |> select([u], {u.account_id, %{id: u.id, reason: u.sign_up_reason}})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The users behind these accounts, with their roles, keyed by account id.

  One query for the list. The moderation list shows fifty accounts and the
  entity for each needs its user, which is fifty queries asked one at a time.
  """
  @spec users_for([Account.t()]) :: %{integer() => User.t()}
  def users_for([]), do: %{}

  def users_for(accounts) do
    ids = Enum.map(accounts, & &1.id)

    from(u in User, where: u.account_id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.account_id, &1})
  end

  @doc """
  The user behind an account, or `nil` for a remote one.
  """
  @spec user_for(Account.t() | integer()) :: User.t() | nil
  def user_for(%Account{id: id}), do: user_for(id)
  def user_for(account_id), do: Repo.get_by(User, account_id: account_id)

  ## The approval queue

  @doc """
  Lets somebody in.
  """
  @spec approve_user(Account.t(), User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def approve_user(%Account{} = moderator, %User{} = user) do
    with {:ok, approved} <- user |> User.approve_changeset() |> Repo.update() do
      log(moderator, "user.approve", user)

      {:ok, approved}
    end
  end

  @doc """
  Turns somebody away, taking the account with them.

  The account goes too, or a rejected registration holds its username against
  the next person who wants it and leaves a profile nobody can sign in to.
  """
  @spec reject_user(Account.t(), User.t()) :: :ok | {:error, :already_approved}
  def reject_user(%Account{} = moderator, %User{approved: false} = user) do
    account = Accounts.get_account(user.account_id)

    log(moderator, "user.reject", user)

    Repo.delete(user)
    if account, do: Accounts.delete_account(account)

    :ok
  end

  def reject_user(_moderator, %User{}), do: {:error, :already_approved}

  @doc """
  Changes somebody's email address.

  For the case where they cannot reach the old one, which is the only reason an
  admin should be touching it at all.
  """
  @spec change_email(Account.t(), User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def change_email(%Account{} = moderator, %User{} = user, email) do
    with {:ok, changed} <- user |> User.changeset(%{email: email}) |> Repo.update() do
      log(moderator, "user.email", user, %{"email" => changed.email})

      {:ok, changed}
    end
  end

  @doc """
  Hashtags, newest first, for the screen that decides which may trend.
  """
  @spec tags(map()) :: [Tag.t()]
  def tags(page \\ %{}) do
    Tag
    |> Pagination.window(Map.put_new(page, :limit, 40))
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  @doc """
  One hashtag by id, or `nil`.
  """
  @spec get_tag(term()) :: Tag.t() | nil
  def get_tag(id) do
    case Snowflake.cast(id) do
      {:ok, id} -> Repo.get(Tag, id)
      :error -> nil
    end
  end

  @doc """
  Changes what a hashtag is allowed to do.

  `usable` decides whether anybody may post under it at all, `trendable`
  whether it may appear in trends, `listable` whether it shows up in search
  and on profiles. Stamped as reviewed whichever way the decision went: the
  point of the review queue is that a moderator has looked, not that they said
  yes.
  """
  @spec update_tag(Account.t(), Tag.t(), map()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t()}
  def update_tag(%Account{} = moderator, %Tag{} = tag, attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(~w(usable trendable listable))
      |> Map.put("reviewed_at", DateTime.utc_now())

    with {:ok, updated} <- tag |> Tag.moderation_changeset(attrs) |> Repo.update() do
      AuditLog.record(moderator, "tag.update", :tag, updated.id, %{
        "name" => updated.name,
        "usable" => updated.usable,
        "trendable" => updated.trendable,
        "listable" => updated.listable
      })

      {:ok, updated}
    end
  end

  @doc """
  Marks an account as belonging to somebody who has died, or unmarks it.

  Not a moderation action and deliberately not on the strike ladder: nothing is
  hidden, nothing is taken down, and no judgement is being made about anybody's
  conduct. What changes is that the account cannot be signed in to and clients
  mark the profile as a memorial. The posts stay exactly where they are,
  because that is what the people who knew them want.

  Logged like every other admin action, because it is irreversible in the way
  that matters: it disables somebody's login, and if it is ever done to the
  wrong account there has to be a record of who did it.
  """
  @spec memorialize(Account.t(), Account.t(), boolean()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def memorialize(%Account{} = moderator, %Account{} = target, memorial? \\ true) do
    with {:ok, updated} <- Accounts.update_moderation(target, %{memorial: memorial?}) do
      if memorial?, do: disable_login(target), else: :ok

      AuditLog.record(moderator, "account.memorial", :account, target.id, %{
        "memorial" => memorial?
      })

      {:ok, updated}
    end
  end

  defp disable_login(target) do
    case Repo.get_by(User, account_id: target.id) do
      nil -> :ok
      user -> user |> User.disable_changeset() |> Repo.update()
    end
  end

  @doc """
  Gives somebody a role, or takes theirs away with `nil`.
  """
  @spec assign_role(Account.t(), User.t(), Role.t() | nil) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def assign_role(%Account{} = moderator, %User{} = user, role) do
    with {:ok, changed} <- Roles.assign(user, role) do
      log(moderator, "user.role", user, %{"role" => role && role.name})

      {:ok, changed}
    end
  end

  ## Reports

  # Newest first, so a queue longer than this hides the ones that have waited
  # longest. The screen says when it is showing a full page rather than leaving
  # a moderator to assume the queue is exactly this long.
  @report_page 100

  @doc """
  The queue, open ones by default.

  A queue that shows everything ever filed is a queue nobody works, so
  `"resolved"` and `"all"` are asked for rather than the default.
  """
  @spec reports(String.t()) :: [Report.t()]
  def reports(state \\ "open")
  def reports("resolved"), do: Reports.list(%{resolved: true, limit: @report_page})
  def reports("all"), do: Reports.list(%{limit: @report_page})
  def reports(_open), do: Reports.list(%{resolved: false, limit: @report_page})

  @doc """
  How many reports one page of the queue holds.
  """
  @spec report_page() :: pos_integer()
  def report_page, do: @report_page

  @doc """
  The accounts a page of reports names, by id.

  One query for the page rather than one per report: a report names two
  accounts, and a queue of forty would otherwise be eighty lookups for a list
  of handles.
  """
  @spec accounts_by_id([integer() | nil]) :: %{integer() => Account.t()}
  def accounts_by_id(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Account
    |> where([a], a.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  The posts a report names, in the order it named them.
  """
  @spec reported_statuses(Report.t()) :: [Status.t()]
  def reported_statuses(%Report{status_ids: []}), do: []

  def reported_statuses(%Report{status_ids: ids}) do
    found =
      Status
      |> where([s], s.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id -> List.wrap(Map.get(found, id)) end)
  end

  @doc """
  Notes about one thing, each with the handle of whoever wrote it.

  The handle rather than the account, because a note is read and never acted
  on, and "who said this" is the only thing about the author that matters here.
  """
  @spec notes_with_authors(atom(), integer()) :: [map()]
  def notes_with_authors(target_type, target_id) do
    notes = Actions.notes(target_type, target_id)
    authors = accounts_by_id(Enum.map(notes, & &1.account_id))

    Enum.map(notes, fn note ->
      Map.put(note, :author, handle_of(Map.get(authors, note.account_id)))
    end)
  end

  defp handle_of(nil), do: "?"
  defp handle_of(account), do: Account.acct(account)

  ## The audit log

  @doc """
  Log entries, newest first, narrowed by moderator or action.
  """
  @spec audit_log(map()) :: [map()]
  def audit_log(filters \\ %{}) do
    from(e in "audit_log_entries",
      order_by: [desc: e.id],
      select: %{
        id: e.id,
        account_id: e.account_id,
        account_handle: e.account_handle,
        action: e.action,
        target_type: e.target_type,
        target_id: e.target_id,
        target_label: e.target_label,
        details: e.details,
        inserted_at: e.inserted_at
      }
    )
    |> audit_by_actor(Map.get(filters, :account_id))
    |> audit_by_action(Map.get(filters, :action))
    |> limit(^Map.get(filters, :limit, 50))
    |> Repo.all()
  end

  defp audit_by_actor(query, nil), do: query
  defp audit_by_actor(query, ""), do: query
  defp audit_by_actor(query, account_id), do: where(query, [e], e.account_id == ^account_id)

  defp audit_by_action(query, nil), do: query
  defp audit_by_action(query, ""), do: query
  defp audit_by_action(query, action), do: where(query, [e], e.action == ^action)

  @doc """
  Every verb the log currently holds, for the filter to offer.
  """
  @spec audit_actions() :: [String.t()]
  def audit_actions do
    from(e in "audit_log_entries", distinct: true, order_by: [asc: e.action], select: e.action)
    |> Repo.all()
  end

  ## Instance settings

  @doc """
  Every setting the admin area may show, with its current value.
  """
  @spec settings() :: map()
  def settings, do: Map.new(@settings_keys, &{&1, Settings.get(&1)})

  @doc """
  The keys the settings pages may write.
  """
  @spec settings_keys() :: [String.t()]
  def settings_keys, do: @settings_keys

  @doc """
  Stores settings, dropping anything not on the list.
  """
  @spec put_settings(Account.t(), map()) :: :ok
  def put_settings(%Account{} = moderator, attrs) do
    written =
      attrs
      |> Map.take(@settings_keys)
      |> Enum.reject(fn {key, value} -> write_setting(key, value) == :error end)
      |> Map.new()

    if written != %{} do
      AuditLog.record(moderator, "settings.update", :settings, 0, %{
        "keys" => written |> Map.keys() |> Enum.sort()
      })
    end

    :ok
  end

  # Registration mode goes through `Settings` rather than being written
  # directly: it is the one setting whose wrong value opens the server up.
  defp write_setting("registration_mode", value) do
    case Settings.put_registration_mode(value) do
      :ok -> :ok
      _ -> :error
    end
  end

  defp write_setting("remote_post_retention_days", value) do
    case day_count(value) do
      {:ok, days} when days >= 0 -> Settings.put("remote_post_retention_days", days)
      _ -> :error
    end
  end

  defp write_setting("content_retention_days", value) do
    case day_count(value) do
      {:ok, days} when days >= 0 -> Settings.put("content_retention_days", days)
      _ -> :error
    end
  end

  defp write_setting(key, value)
       when key in ~w(limited_federation email_subscriptions update_check) do
    Settings.put(key, value in [true, "true", "on", "1"])
  end

  # Refused rather than stored, so that a typo takes the whole campaign down
  # instead of putting a broken link in every client on the server. Blank is
  # allowed and is how an admin takes it down deliberately.
  defp write_setting("donation_campaign_url", value) do
    url = value |> to_string() |> String.trim()

    if url == "" or DonationCampaign.valid_url?(url) do
      Settings.put("donation_campaign_url", url)
    else
      :error
    end
  end

  # The same reasoning as the campaign address above: this one is handed to
  # every client that asks what this server is, so a typo is a broken link on
  # somebody else's screen. Blank is how an admin takes it down.
  defp write_setting("site_status_page_url", value) do
    url = value |> to_string() |> String.trim()

    if url == "" or DonationCampaign.valid_url?(url) do
      Settings.put("site_status_page_url", url)
    else
      :error
    end
  end

  defp write_setting(key, value), do: Settings.put(key, to_string(value))

  @doc """
  Writes what one moderator wants the next one to know about an account.

  Not a strike and not a warning: nobody is told, nothing is applied, and the
  account's owner never sees it. It is where "this is the third report about
  the same joke" goes, which otherwise lives in one person's head and leaves
  when they do.
  """
  @spec put_moderation_note(Account.t(), Account.t(), String.t() | nil) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def put_moderation_note(%Account{} = moderator, %Account{} = target, note) do
    with {:ok, saved} <-
           target
           |> Ecto.Changeset.change(moderation_note: trim_note(note))
           |> Repo.update() do
      AuditLog.record(moderator, "account.note", :account, target.id)

      {:ok, saved}
    end
  end

  @doc """
  Ends every session an account has and mails them a way back in.

  For an account somebody else is in. It does not change the password, because
  a moderator choosing somebody's password is a moderator who knows it: it
  takes away every session and every app, and sends the owner the ordinary
  reset link so the next password is one only they have seen.
  """
  @spec force_password_reset(Account.t(), Account.t()) :: :ok | {:error, :no_user}
  def force_password_reset(%Account{} = moderator, %Account{} = target) do
    case Accounts.get_user_by_account(target) do
      nil ->
        {:error, :no_user}

      user ->
        Auth.delete_all_session_tokens(user)
        :ok = OAuth.revoke_all_for(user)

        %{email: user.email, url: Endpoint.url() <> "/reset-password/:token"}
        |> PasswordResetWorker.new()
        |> Oban.insert()

        AuditLog.record(moderator, "account.force_reset", :account, target.id)

        :ok
    end
  end

  @doc """
  Asks another server for its copy of an account again.

  For a profile that is out of date here — a display name changed, a picture
  replaced, a note rewritten — where waiting for the next thing they post is
  waiting for something that may not come.
  """
  @spec refetch(Account.t(), Account.t()) :: {:ok, Account.t()} | {:error, term()}
  def refetch(%Account{} = moderator, %Account{domain: domain} = target)
      when is_binary(domain) do
    # `max_age_seconds: 0` rather than a flag of its own: "fetch it again
    # whatever its age" is exactly what a zero maximum age means, and one way
    # of saying it is better than two.
    case ResolveActor.resolve(Actor.id(target), max_age_seconds: 0) do
      {:ok, refreshed} ->
        AuditLog.record(moderator, "account.refetch", :account, target.id)

        {:ok, refreshed}

      other ->
        other
    end
  end

  def refetch(_moderator, %Account{}), do: {:error, :local}

  defp trim_note(nil), do: nil

  defp trim_note(note) do
    case note |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 2000)
    end
  end

  @doc """
  The accounts most likely to be suggested to a newcomer, and the ones an admin
  has taken out.

  Ranked the way the suggestions themselves are — by how many people here
  already follow them — because a screen for tuning suggestions that showed a
  different order from the suggestions would be tuning something else. Who is
  eligible at all comes from the same `Abuuba.Accounts.listable/1` they do,
  which this claimed and did not do: it went on offering an account that had
  migrated away long after the suggestions stopped.
  """
  @spec suggestion_candidates(pos_integer()) :: [Account.t()]
  def suggestion_candidates(limit \\ 50) do
    suppressed = Suggestions.suppressed()

    popular =
      from(f in Follow,
        join: a in Account,
        as: :account,
        on: a.id == f.target_account_id,
        group_by: a.id,
        order_by: [desc: count(f.account_id), desc: a.id],
        limit: ^limit,
        select: a
      )
      |> Accounts.listable()
      |> Repo.all()

    # The suppressed ones are shown too, and first: an admin looking at this
    # screen is usually here to undo something, and a list that hid what they
    # had already done would be the wrong list.
    hidden =
      if suppressed == [], do: [], else: Repo.all(from a in Account, where: a.id in ^suppressed)

    Enum.uniq_by(hidden ++ popular, & &1.id)
  end

  @doc """
  How many confirmed subscribers each account here has.

  Confirmed only. An unconfirmed address is a claim somebody typed into a form,
  and counting it would tell an admin this server is sending mail it is not.
  """
  @spec subscription_counts() :: [%{account: Account.t(), count: non_neg_integer()}]
  def subscription_counts do
    counts =
      from(s in "email_subscriptions",
        where: not is_nil(s.confirmed_at),
        group_by: s.account_id,
        select: {s.account_id, count(s.id)}
      )
      |> Repo.all()

    # `get_accounts/1` already answers with a map keyed by id.
    accounts = counts |> Enum.map(&elem(&1, 0)) |> Accounts.get_accounts()

    counts
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.flat_map(fn {account_id, count} ->
      case Map.get(accounts, account_id) do
        nil -> []
        account -> [%{account: account, count: count}]
      end
    end)
  end

  ## Plumbing

  defp pending_users, do: User.pending()

  defp log(moderator, action, %User{} = user, details \\ %{}) do
    AuditLog.record(moderator, action, :account, user.account_id, details)
  end

  defp escape_like(text), do: String.replace(text, ~r/([%_\\])/, "\\\\\\1")

  # A day count from the settings form, and deliberately not an id: the whole
  # string has to be the number, so "30 days" is a refusal rather than thirty.
  defp day_count(value) when is_integer(value), do: {:ok, value}

  defp day_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp day_count(_value), do: :error
end
