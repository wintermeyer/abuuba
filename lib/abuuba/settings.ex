defmodule Abuuba.Settings do
  @moduledoc """
  Settings the admin of this server chooses, and the rules people agree to.

  Stored as key and jsonb value rather than as columns on a singleton row, so
  that adding a setting is not a migration. Every setting has a default here,
  which means a fresh database is a working server rather than one that crashes
  on the first missing row.
  """

  import Ecto.Query

  alias Abuuba.Cache
  alias Abuuba.Repo
  alias Abuuba.Settings.InstanceSetting
  alias Abuuba.Settings.ServerRule

  @registration_modes ~w(open approved closed)a

  @defaults %{
    # `approved` rather than `open` out of the box. An open server left
    # unattended fills with spam registrations within days, and an admin who
    # wanted open has to make one deliberate choice to get it, where an admin
    # who did not want it would otherwise find out the hard way.
    "registration_mode" => "approved",
    "site_title" => "abuuba",
    # Open, which is what the fediverse assumes of a server and what makes a
    # new one discoverable at all. An admin who wants otherwise says so.
    "timeline_access" => "public",
    # Off. A server that talks to nobody until an admin has written a list is a
    # server whose first day is spent wondering why nothing federates.
    "limited_federation" => false,
    # Nobody, until an admin decides otherwise. The blocklist is a record of
    # moderation decisions, and naming the servers a moderator acted against
    # is exactly what invites their users to come and argue about it -- the
    # same reason a single block can be obfuscated. `disabled`, `users`, `all`.
    "show_domain_blocks" => "disabled",
    # Off. A trending list nobody has reviewed is whatever an anonymous crowd
    # pushed hardest, and the front page is the worst place to find that out.
    "trendable_by_default" => false,
    # Off. This one sends mail in a member's name to addresses that never
    # signed up here, which is worth an admin having decided to allow rather
    # than having failed to notice.
    "email_subscriptions" => false,
    # No appeal. Three keys rather than one document, because the admin form
    # writes three fields and a setting that is a map is a setting somebody has
    # to merge by hand to change one line of.
    "donation_campaign_message" => "",
    "donation_campaign_button_text" => "",
    "donation_campaign_url" => "",
    # The admin's own stylesheet, served from this origin and linked from every
    # page. Empty means the file is served empty rather than not served: a
    # missing stylesheet is a 404 in every browser console on the server.
    "custom_css" => "",
    # Zero, meaning keep other servers' posts for ever. A server discarding a
    # year of them because a default said so is the one surprise this setting
    # cannot afford to be; see `Abuuba.Statuses.RemoteVacuum` for what a number
    # here does and does not delete.
    "remote_post_retention_days" => 0,
    # Accounts an admin has taken out of everybody's follow suggestions. See
    # `Abuuba.Accounts.Suggestions`.
    "suppressed_suggestions" => [],
    # Named warning texts a moderator picks instead of retyping the same
    # paragraph. Per server rather than per moderator, because the point is
    # that two moderators writing about the same thing say the same thing.
    # Each is `%{"title" => ..., "text" => ...}`.
    "warning_presets" => [],
    # Off. Asking a third party whether this server is up to date means telling
    # that third party this server exists and what it is running, and an admin
    # should decide that rather than discover it.
    "update_check" => false,
    "update_check_url" => "https://api.github.com/repos/wintermeyer/abuuba/releases/latest"
  }

  @doc """
  The ways this server can be signed up for.

  `open` takes anyone, `approved` queues them for a moderator, `closed` takes
  nobody.
  """
  @spec registration_modes() :: [atom()]
  def registration_modes, do: @registration_modes

  @doc """
  How this server handles registration right now.
  """
  @spec registration_mode() :: :open | :approved | :closed
  def registration_mode do
    "registration_mode" |> get() |> String.to_existing_atom()
  end

  @doc """
  Sets the registration mode.
  """
  @spec put_registration_mode(atom() | String.t()) :: :ok | {:error, :unknown_mode}
  def put_registration_mode(mode) do
    normalised = to_string(mode)

    if normalised in Enum.map(@registration_modes, &to_string/1) do
      put("registration_mode", normalised)
    else
      {:error, :unknown_mode}
    end
  end

  @doc """
  Whether anybody may sign up at all.
  """
  @spec registration_open?() :: boolean()
  def registration_open?, do: registration_mode() != :closed

  @doc """
  Who may read this server's public timelines.

  `:public` is anybody, `:authenticated` is people with an account here, and
  `:disabled` is nobody -- a server that has turned them off entirely.

  One function because the question has one answer: the API enforced it and
  the pages of this server's own interface did not, so a server set to
  `:authenticated` would have gone on showing the same posts to a stranger who
  opened the front page.
  """
  @spec timeline_access() :: :public | :authenticated | :disabled
  def timeline_access do
    case get("timeline_access") do
      "authenticated" -> :authenticated
      "disabled" -> :disabled
      _anything_else -> :public
    end
  end

  @doc """
  Whether this reader may read them.
  """
  @spec public_timelines_readable?(term()) :: boolean()
  def public_timelines_readable?(viewer) do
    case timeline_access() do
      :public -> true
      :authenticated -> not is_nil(viewer)
      :disabled -> false
    end
  end

  @doc """
  Whether this reader is told which servers this one has blocked.

  `all` is anybody, `users` is people with an account here, and `disabled` --
  the default -- is nobody. The same three shapes as `timeline_access/0`, and
  here for the same reason: the one caller read the raw string and matched on
  it, so the next one would have matched on it slightly differently.
  """
  @spec domain_blocks_visible?(term()) :: boolean()
  def domain_blocks_visible?(viewer) do
    case get("show_domain_blocks") do
      "all" -> true
      "users" -> not is_nil(viewer)
      _disabled -> false
    end
  end

  # Long enough that a busy server reads settings from memory, short enough
  # that a node which missed the invalidation broadcast rights itself within
  # a minute.
  @cache_ttl_ms :timer.minutes(1)

  @doc """
  A setting's value, or its default.

  Read through `Abuuba.Cache`: settings sit on per-request paths — permissions,
  federation policy, the instance document — and change on admin action, so
  each is read from the database at most once a minute per node.
  """
  @spec get(String.t()) :: term()
  def get(key) do
    Cache.fetch({:setting, key}, @cache_ttl_ms, fn ->
      case Repo.get(InstanceSetting, key) do
        nil -> Map.get(@defaults, key)
        %InstanceSetting{value: %{"value" => value}} -> value
      end
    end)
  end

  @doc """
  Stores a setting.
  """
  @spec put(String.t(), term()) :: :ok
  def put(key, value) do
    now = DateTime.utc_now()

    Repo.insert_all(
      InstanceSetting,
      [[key: key, value: %{"value" => value}, inserted_at: now, updated_at: now]],
      conflict_target: [:key],
      on_conflict: [set: [value: %{"value" => value}, updated_at: now]]
    )

    Cache.invalidate({:setting, key})
    Cache.invalidate({:setting_updated_at, key})

    :ok
  end

  @doc """
  When a setting was last written, or `nil` if nobody has ever written it.

  The extended description carries this over the API so a client can tell
  whether the about page it already showed is still the current one. It
  answered `nil` unconditionally, which reads as "never written" for text an
  admin may have changed this morning.
  """
  @spec updated_at(String.t()) :: DateTime.t() | nil
  def updated_at(key) do
    Cache.fetch({:setting_updated_at, key}, @cache_ttl_ms, fn ->
      case Repo.get(InstanceSetting, key) do
        nil -> nil
        %InstanceSetting{updated_at: at} -> at
      end
    end)
  end

  ## Server rules

  @doc """
  The rules people agree to when they sign up, in the order they are shown.
  """
  @spec rules(String.t() | nil) :: [ServerRule.t()]
  def rules(locale \\ nil) do
    # The rows are cached untranslated: the translation depends on the
    # reader, the rows only on what a moderator wrote.
    Cache.fetch(:server_rules, @cache_ttl_ms, fn ->
      ServerRule
      |> where([r], is_nil(r.deleted_at))
      |> order_by([r], asc: r.position, asc: r.id)
      |> Repo.all()
    end)
    |> Enum.map(&translated(&1, locale))
  end

  @doc """
  One rule's text in a language, falling back to what it was written in.
  """
  @spec rule_text(ServerRule.t(), String.t() | nil) :: String.t()
  def rule_text(rule, locale), do: ServerRule.text(rule, locale)

  # The rule struct with its `text` already in the reader's language, so every
  # caller renders `rule.text` and none of them has to remember the fallback.
  defp translated(rule, nil), do: rule
  defp translated(rule, locale), do: %{rule | text: ServerRule.text(rule, locale)}

  @doc """
  Adds a rule.
  """
  @spec create_rule(map()) :: {:ok, ServerRule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(attrs) do
    with {:ok, rule} <- %ServerRule{} |> ServerRule.changeset(attrs) |> Repo.insert() do
      Cache.invalidate(:server_rules)

      {:ok, rule}
    end
  end

  @doc """
  Retires a rule without erasing it, so that an agreement recorded against it
  still means something.
  """
  @spec delete_rule(ServerRule.t()) :: {:ok, ServerRule.t()} | {:error, Ecto.Changeset.t()}
  def delete_rule(%ServerRule{} = rule) do
    with {:ok, deleted} <-
           rule
           |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
           |> Repo.update() do
      Cache.invalidate(:server_rules)

      {:ok, deleted}
    end
  end
end
