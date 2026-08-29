defmodule AbuubaWeb.API.AdminController do
  @moduledoc """
  `/api/v1/admin/*`: accounts, reports and domain blocks for a moderation
  client.

  The same decisions the admin area takes, through the same context functions.
  Two implementations of "suspend this account" is one implementation and one
  bug, and the bug is always in the surface nobody is looking at.

  Every route names the permission it needs in the router. Rank is checked here
  as well, because a token belonging to a junior moderator is a way to act on a
  senior one that no permission flag would catch on its own.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Admin
  alias Abuuba.Admin.Metrics
  alias Abuuba.Media.ProfileImages
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.Domains
  alias Abuuba.Moderation.Reports
  alias Abuuba.Moderation.Signup
  alias Abuuba.Roles
  alias Abuuba.Trends
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.NestedParams
  alias AbuubaWeb.API.Pagination

  plug AbuubaWeb.Plugs.RequireUser

  # An admin token as well as an admin. The permission pipelines say who the
  # person is allowed to be; this says what the app they authorised was allowed
  # to ask for, which is a different question and the one a leaked token turns on.
  # Per resource, and either the umbrella or the narrow child. An app that
  # asked for exactly `admin:read:reports` is an app that should not come back
  # with the account table, and naming only the umbrella would have left every
  # narrow admin scope this server advertises satisfying nothing at all.
  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:read", "admin:read:accounts"]} when action in [:accounts, :account]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:read", "admin:read:reports"]} when action in [:reports, :report]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:read", "admin:read:domain_blocks"]}
       when action in [:domain_blocks, :domain_block]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:read", "admin:read:domain_allows"]}
       when action in [:domain_allows, :domain_allow]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:read", "admin:read:email_domain_blocks"]}
       when action in [:email_domain_blocks, :email_domain_block]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:read", "admin:read:ip_blocks"]}
       when action in [:ip_blocks, :ip_block]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:read", "admin:read:canonical_email_blocks"]}
       when action in [:canonical_email_blocks, :canonical_email_block]

  # No narrow scope exists for these, so the umbrella is the whole vocabulary.
  plug AbuubaWeb.Plugs.RequireScopes,
       ["admin:read"]
       when action in [:trends, :link_publishers, :tags, :tag, :measures, :dimensions, :retention]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:write", "admin:write:accounts"]}
       when action in [
              :account_action,
              :approve,
              :reject,
              :enable,
              :unsilence,
              :unsuspend,
              :unsensitive,
              :remove_avatar,
              :remove_header,
              :delete_account
            ]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:write", "admin:write:reports"]}
       when action in [
              :resolve_report,
              :reopen_report,
              :assign_report,
              :unassign_report,
              :update_report
            ]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:write", "admin:write:domain_blocks"]}
       when action in [:create_domain_block, :update_domain_block, :delete_domain_block]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:write", "admin:write:domain_allows"]}
       when action in [:create_domain_allow, :delete_domain_allow]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:write", "admin:write:email_domain_blocks"]}
       when action in [:create_email_domain_block, :delete_email_domain_block]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:write", "admin:write:ip_blocks"]}
       when action in [:create_ip_block, :update_ip_block, :delete_ip_block]

  plug AbuubaWeb.Plugs.RequireScopes,
       {:any, ["admin:write", "admin:write:canonical_email_blocks"]}
       when action in [
              :create_canonical_email_block,
              :delete_canonical_email_block,
              :test_canonical_email_block
            ]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["admin:write"] when action in [:review_trend, :review_publisher, :update_tag]

  ## Accounts

  def accounts(conn, params) do
    page = Pagination.params(params, default: 50, max: 200)

    accounts =
      Admin.accounts(%{
        query: params["username"] || params["by_domain"] || params["email"],
        origin: origin_of(params),
        status: status_of(params),
        max_id: page.max_id,
        since_id: page.since_id,
        min_id: page.min_id,
        order: page.order,
        limit: page.limit
      })

    conn
    |> Pagination.put_link_header(accounts)
    |> json(Entities.admin_accounts(accounts))
  end

  def account(conn, %{"id" => id}) do
    case fetch_account(id) do
      {:ok, account} -> json(conn, Entities.admin_account(account))
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  def account_action(conn, %{"id" => id} = params) do
    with {:ok, account} <- fetch_account(id),
         :ok <- may_act(conn, account),
         {:ok, _strike} <- take(conn, account, params) do
      json(conn, %{})
    else
      {:error, :forbidden} -> API.error(conn, 403, "This account outranks yours")
      {:error, :unknown_action} -> API.error(conn, 422, "Unknown action")
      {:error, :no_statuses} -> API.error(conn, 422, "No statuses were named")
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  def approve(conn, %{"id" => id}), do: with_user(conn, id, &Admin.approve_user(actor(conn), &1))

  def reject(conn, %{"id" => id}) do
    with {:ok, account} <- fetch_account(id),
         :ok <- may_act(conn, account),
         user when not is_nil(user) <- Admin.user_for(account),
         :ok <- Admin.reject_user(actor(conn), user) do
      json(conn, %{})
    else
      {:error, :forbidden} -> API.error(conn, 403, "This account outranks yours")
      {:error, :already_approved} -> API.error(conn, 422, "That account is already approved")
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  # Mastodon's three undo verbs, each lifting one thing. Kept separate rather
  # than folded into one "unmoderate" call, because a client that means to lift
  # a silence must not also lift a suspension nobody asked about.
  def unsilence(conn, %{"id" => id}), do: lift(conn, id, %{silenced_at: nil})

  def unsensitive(conn, %{"id" => id}), do: lift(conn, id, %{sensitized_at: nil})

  @doc """
  Deletes an account and everything it wrote.

  Not a suspension: this is the end of the grace window brought forward, and
  there is nothing to appeal afterwards. Peers are told, so the posts go from
  their copies too rather than only from ours.
  """
  def delete_account(conn, %{"id" => id}) do
    with {:ok, account} <- fetch_account(id),
         :ok <- may_act(conn, account) do
      rendered = Entities.admin_account(account)

      {:ok, _account} = Accounts.delete_account(account)

      json(conn, rendered)
    else
      {:error, :forbidden} -> API.error(conn, 403, "This account outranks yours")
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  def unsuspend(conn, %{"id" => id}),
    do: lift(conn, id, %{suspended_at: nil, purge_after: nil})

  @doc """
  Takes a picture off somebody's profile, for a moderator.

  Its own action rather than part of an account action: a picture that breaks
  the rules is not a reason to take the whole account away, and a moderator
  reaching for the smaller tool should find one there.
  """
  def remove_avatar(conn, %{"id" => id}), do: remove_picture(conn, id, :avatar)

  @doc """
  The same for a header.
  """
  def remove_header(conn, %{"id" => id}), do: remove_picture(conn, id, :header)

  defp remove_picture(conn, id, kind) do
    with {:ok, account} <- fetch_account(id),
         :ok <- may_act(conn, account),
         {:ok, updated} <-
           Accounts.update_account(
             account,
             ProfileImages.remove(account, kind)
           ) do
      json(conn, Entities.admin_account(updated))
    else
      {:error, :forbidden} -> API.error(conn, 403, "This account outranks yours")
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  def enable(conn, %{"id" => id}) do
    with {:ok, account} <- fetch_account(id),
         :ok <- may_act(conn, account),
         user when not is_nil(user) <- Admin.user_for(account),
         {:ok, _user} <- Admin.approve_user(actor(conn), user) do
      json(conn, Entities.admin_account(account))
    else
      {:error, :forbidden} -> API.error(conn, 403, "This account outranks yours")
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  ## Reports

  def reports(conn, params) do
    resolved = params["resolved"] in ["true", true, "1"]

    page = Pagination.params(params, default: 50, max: 200)
    reports = Reports.list(Map.merge(page, %{resolved: resolved}))

    conn
    |> Pagination.put_link_header(reports)
    |> json(Entities.admin_reports(reports))
  end

  def report(conn, %{"id" => id}) do
    case Reports.get(id) do
      nil -> API.error(conn, 404, "Record not found")
      report -> json(conn, Entities.admin_report(report))
    end
  end

  def update_report(conn, %{"id" => id} = params) do
    change_report(conn, id, &Reports.update(&1, &2, params))
  end

  def resolve_report(conn, %{"id" => id}), do: change_report(conn, id, &Reports.resolve(&1, &2))
  def reopen_report(conn, %{"id" => id}), do: change_report(conn, id, &Reports.reopen(&1, &2))

  def assign_report(conn, %{"id" => id}),
    do: change_report(conn, id, &Reports.assign(&1, &2, &2))

  def unassign_report(conn, %{"id" => id}),
    do: change_report(conn, id, &Reports.assign(&1, nil, &2))

  ## Trends

  def trends(conn, %{"kind" => kind} = params) when kind in ~w(tag link status) do
    pending = params["pending"] in ["true", true, "1"]

    entries =
      if pending do
        Enum.map(Trends.pending_reviews(kind), &%{"subject" => &1.subject, "kind" => kind})
      else
        Enum.map(Trends.list(kind), &trend_entry/1)
      end

    json(conn, entries)
  end

  def trends(conn, _params), do: API.error(conn, 422, "Unknown kind")

  @doc """
  Publishers whose links have trended.

  A site rather than an article: deciding about one story from a newspaper
  says nothing about the next one, and the site is the decision a moderator
  actually wants to take.
  """
  def link_publishers(conn, params) do
    publishers = Trends.providers(%{limit: API.limit(params, 40, 200)})

    json(conn, Enum.map(publishers, &Entities.admin_link_publisher/1))
  end

  # Named rather than assembled. `String.to_existing_atom("approve_provider")`
  # only finds that atom once `Abuuba.Trends` happens to be loaded, and modules
  # load when they are first used -- so on a server that had not touched
  # trending yet this answered 500, and started working later for no reason
  # the operator could see. Two clauses cost nothing and cannot do that.
  def review_publisher(conn, %{"provider" => provider, "decision" => "approve"}) do
    Trends.approve_provider(actor(conn), provider)

    json(conn, %{})
  end

  def review_publisher(conn, %{"provider" => provider, "decision" => "reject"}) do
    Trends.reject_provider(actor(conn), provider)

    json(conn, %{})
  end

  def review_publisher(conn, _params), do: API.error(conn, 422, "Unknown decision")

  def review_trend(conn, %{"kind" => kind, "subject" => subject, "decision" => decision})
      when kind in ~w(tag link status) and decision in ~w(approve reject) do
    apply_trend_decision(actor(conn), kind, subject, decision)

    json(conn, %{})
  end

  def review_trend(conn, _params), do: API.error(conn, 422, "Unknown kind or decision")

  defp apply_trend_decision(actor, kind, subject, "approve"),
    do: Trends.approve(actor, kind, subject)

  defp apply_trend_decision(actor, kind, subject, "reject"),
    do: Trends.reject(actor, kind, subject)

  defp trend_entry(trend) do
    %{
      "kind" => trend.kind,
      "subject" => trend.subject,
      "language" => trend.language,
      "score" => trend.score,
      "rank" => trend.rank,
      "uses" => trend.uses,
      "accounts" => trend.accounts
    }
  end

  ## Domain blocks

  def domain_blocks(conn, params) do
    page = Pagination.params(params, default: 100, max: 200)
    blocks = Domains.blocks(page)

    conn
    |> Pagination.put_link_header(blocks)
    |> json(Enum.map(blocks, &Entities.admin_domain_block/1))
  end

  def domain_block(conn, %{"id" => id}) do
    case Domains.get_block(id) do
      nil -> API.error(conn, 404, "Record not found")
      block -> json(conn, Entities.admin_domain_block(block))
    end
  end

  def create_domain_block(conn, params) do
    case Domains.block(actor(conn), params) do
      {:ok, block} -> json(conn, Entities.admin_domain_block(block))
      {:error, _changeset} -> API.error(conn, 422, "That block could not be saved")
    end
  end

  def update_domain_block(conn, %{"id" => id} = params) do
    with block when not is_nil(block) <- Domains.get_block(id),
         {:ok, updated} <- Domains.update_block(actor(conn), block, params) do
      json(conn, Entities.admin_domain_block(updated))
    else
      nil -> API.error(conn, 404, "Record not found")
      {:error, _changeset} -> API.error(conn, 422, "That block could not be saved")
    end
  end

  def delete_domain_block(conn, %{"id" => id}) do
    case Domains.get_block(id) do
      nil ->
        API.error(conn, 404, "Record not found")

      block ->
        :ok = Domains.unblock(actor(conn), block)

        json(conn, %{})
    end
  end

  ## Hashtags

  def tags(conn, params) do
    page = Pagination.params(params, default: 40, max: 200)
    tags = Admin.tags(page)

    conn
    |> Pagination.put_link_header(tags)
    |> json(Enum.map(tags, &Entities.admin_tag/1))
  end

  def tag(conn, %{"id" => id}) do
    with_record(conn, Admin.get_tag(id), &Entities.admin_tag/1)
  end

  def update_tag(conn, %{"id" => id} = params) do
    with tag when not is_nil(tag) <- Admin.get_tag(id),
         {:ok, updated} <- Admin.update_tag(actor(conn), tag, params) do
      json(conn, Entities.admin_tag(updated))
    else
      nil -> API.error(conn, 404, "Record not found")
      {:error, _changeset} -> API.error(conn, 422, "That tag could not be saved")
    end
  end

  ## The dashboard's numbers

  def measures(conn, params) do
    with {:ok, from, to} <- window(params),
         {:ok, measures} <- Metrics.measure(keys(params), from, to) do
      json(conn, Enum.map(measures, &Entities.admin_measure/1))
    else
      {:error, {:unknown_keys, unknown}} ->
        API.error(conn, 422, "Unknown measure: #{Enum.join(unknown, ", ")}")

      {:error, :bad_window} ->
        API.error(conn, 422, "start_at and end_at have to be dates")
    end
  end

  def dimensions(conn, params) do
    with {:ok, from, to} <- window(params),
         {:ok, dimensions} <- Metrics.dimension(keys(params), from, to, API.limit(params, 10, 50)) do
      json(conn, Enum.map(dimensions, &Entities.admin_dimension/1))
    else
      {:error, {:unknown_keys, unknown}} ->
        API.error(conn, 422, "Unknown dimension: #{Enum.join(unknown, ", ")}")

      {:error, :bad_window} ->
        API.error(conn, 422, "start_at and end_at have to be dates")
    end
  end

  def retention(conn, params) do
    case window(params) do
      {:ok, from, to} ->
        cohorts = Metrics.retention(from, to, to_string(params["frequency"]))

        json(conn, Enum.map(cohorts, &Entities.admin_cohort/1))

      {:error, :bad_window} ->
        API.error(conn, 422, "start_at and end_at have to be dates")
    end
  end

  # A day either side, defaulted to the last fortnight, which is the window a
  # dashboard opens on.
  defp window(params) do
    with {:ok, from} <- date(params["start_at"], Date.add(Date.utc_today(), -14)),
         {:ok, to} <- date(params["end_at"], Date.utc_today()) do
      if Date.compare(from, to) == :gt, do: {:ok, to, from}, else: {:ok, from, to}
    end
  end

  defp date(nil, fallback), do: {:ok, fallback}
  defp date("", fallback), do: {:ok, fallback}

  defp date(value, _fallback) do
    case value |> to_string() |> String.slice(0, 10) |> Date.from_iso8601() do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :bad_window}
    end
  end

  defp keys(params),
    do: params |> Map.get("keys", []) |> NestedParams.list() |> Enum.map(&to_string/1)

  ## The block families

  def domain_allows(conn, params) do
    page = Pagination.params(params, default: 100, max: 200)
    allows = Domains.allows(page)

    conn
    |> Pagination.put_link_header(allows)
    |> json(Enum.map(allows, &Entities.admin_domain_allow/1))
  end

  def domain_allow(conn, %{"id" => id}) do
    with_record(conn, Domains.get_allow(id), &Entities.admin_domain_allow/1)
  end

  def create_domain_allow(conn, params) do
    case Domains.allow(actor(conn), to_string(params["domain"])) do
      {:ok, allow} -> json(conn, Entities.admin_domain_allow(allow))
      {:error, _reason} -> API.error(conn, 422, "That domain could not be allowed")
    end
  end

  def delete_domain_allow(conn, %{"id" => id}) do
    case Domains.get_allow(id) do
      nil ->
        API.error(conn, 404, "Record not found")

      allow ->
        :ok = Domains.disallow(actor(conn), allow)

        json(conn, %{})
    end
  end

  def email_domain_blocks(conn, params) do
    page = Pagination.params(params, default: 100, max: 200)
    blocks = Signup.email_domain_blocks(page)

    conn
    |> Pagination.put_link_header(blocks)
    |> json(Enum.map(blocks, &Entities.admin_email_domain_block/1))
  end

  def email_domain_block(conn, %{"id" => id}) do
    with_record(
      conn,
      Signup.get_email_domain_block(id),
      &Entities.admin_email_domain_block/1
    )
  end

  def create_email_domain_block(conn, params) do
    case Signup.block_email_domain(actor(conn), params) do
      {:ok, block} -> json(conn, Entities.admin_email_domain_block(block))
      {:error, _changeset} -> API.error(conn, 422, "That block could not be saved")
    end
  end

  def delete_email_domain_block(conn, %{"id" => id}) do
    case Signup.get_email_domain_block(id) do
      nil ->
        API.error(conn, 404, "Record not found")

      block ->
        :ok = Signup.unblock_email_domain(actor(conn), block)

        json(conn, %{})
    end
  end

  def ip_blocks(conn, params) do
    page = Pagination.params(params, default: 100, max: 200)
    blocks = Signup.ip_blocks(page)

    conn
    |> Pagination.put_link_header(blocks)
    |> json(Enum.map(blocks, &Entities.admin_ip_block/1))
  end

  def ip_block(conn, %{"id" => id}) do
    with_record(conn, Signup.get_ip_block(id), &Entities.admin_ip_block/1)
  end

  def create_ip_block(conn, params) do
    case Signup.block_ip(actor(conn), ip_attrs(params)) do
      {:ok, block} -> json(conn, Entities.admin_ip_block(block))
      {:error, _changeset} -> API.error(conn, 422, "That block could not be saved")
    end
  end

  def update_ip_block(conn, %{"id" => id} = params) do
    with block when not is_nil(block) <- Signup.get_ip_block(id),
         {:ok, updated} <- Signup.update_ip_block(actor(conn), block, ip_attrs(params)) do
      json(conn, Entities.admin_ip_block(updated))
    else
      nil -> API.error(conn, 404, "Record not found")
      {:error, _changeset} -> API.error(conn, 422, "That block could not be saved")
    end
  end

  def delete_ip_block(conn, %{"id" => id}) do
    case Signup.get_ip_block(id) do
      nil ->
        API.error(conn, 404, "Record not found")

      block ->
        :ok = Signup.unblock_ip(actor(conn), block)

        json(conn, %{})
    end
  end

  def canonical_email_blocks(conn, params) do
    page = Pagination.params(params, default: 100, max: 200)
    blocks = Signup.canonical_email_blocks(page)

    conn
    |> Pagination.put_link_header(blocks)
    |> json(Enum.map(blocks, &Entities.admin_canonical_email_block/1))
  end

  def canonical_email_block(conn, %{"id" => id}) do
    with_record(
      conn,
      Signup.get_canonical_email_block(id),
      &Entities.admin_canonical_email_block/1
    )
  end

  def create_canonical_email_block(conn, params) do
    case Signup.block_email(actor(conn), to_string(params["email"])) do
      {:ok, block} -> json(conn, Entities.admin_canonical_email_block(block))
      {:error, _reason} -> API.error(conn, 422, "That address could not be blocked")
    end
  end

  @doc """
  Which blocks an address would trip, without writing one.

  For the moderator about to block somebody and wondering whether the address
  is already covered. Answered by the same canonicalisation the block itself
  uses, so it cannot say one thing here and another when the block lands.
  """
  def test_canonical_email_block(conn, params) do
    blocks = Signup.matching_canonical_email_blocks(params["email"])

    json(conn, Enum.map(blocks, &Entities.admin_canonical_email_block/1))
  end

  def delete_canonical_email_block(conn, %{"id" => id}) do
    case Signup.get_canonical_email_block(id) do
      nil ->
        API.error(conn, 404, "Record not found")

      block ->
        :ok = Signup.unblock_email(actor(conn), block)

        json(conn, %{})
    end
  end

  # The API calls the range `ip` and the column calls it `cidr`, because a
  # single address is a /32 and the column has to say so.
  defp ip_attrs(params) do
    params
    |> Map.take(~w(severity comment expires_in))
    |> then(fn attrs ->
      case params["ip"] do
        nil -> attrs
        ip -> Map.put(attrs, "cidr", ip)
      end
    end)
  end

  defp with_record(conn, nil, _render), do: API.error(conn, 404, "Record not found")
  defp with_record(conn, record, render), do: json(conn, render.(record))

  ## Plumbing

  defp take(conn, account, params) do
    Actions.take(actor(conn), account, ladder_action(params["type"]),
      text: params["text"] || "",
      status_ids: Enum.map(NestedParams.list(params["status_ids"]), &to_integer/1)
    )
  end

  # Mastodon calls it `sensitive`; the ladder calls it what it does.
  defp ladder_action("sensitive"), do: "mark_statuses_as_sensitive"
  defp ladder_action(nil), do: "none"
  defp ladder_action(type), do: to_string(type)

  defp lift(conn, id, attrs) do
    with {:ok, account} <- fetch_account(id),
         :ok <- may_act(conn, account),
         {:ok, updated} <- Accounts.update_moderation(account, attrs) do
      json(conn, Entities.admin_account(updated))
    else
      {:error, :forbidden} -> API.error(conn, 403, "This account outranks yours")
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  defp with_user(conn, id, fun) do
    with {:ok, account} <- fetch_account(id),
         :ok <- may_act(conn, account),
         user when not is_nil(user) <- Admin.user_for(account),
         {:ok, _user} <- fun.(user) do
      json(conn, Entities.admin_account(account))
    else
      {:error, :forbidden} -> API.error(conn, 403, "This account outranks yours")
      _ -> API.error(conn, 404, "Record not found")
    end
  end

  defp change_report(conn, id, fun) do
    with report when not is_nil(report) <- Reports.get(id),
         {:ok, changed} <- fun.(report, actor(conn)) do
      json(conn, Entities.admin_report(changed))
    else
      nil -> API.error(conn, 404, "Record not found")
      {:error, _reason} -> API.error(conn, 422, "That report could not be changed")
    end
  end

  defp fetch_account(id) do
    case Accounts.get_account(to_integer(id)) do
      %Account{} = account -> {:ok, account}
      nil -> {:error, :not_found}
    end
  end

  # A remote account has no user and no rank, so nobody is outranked by one.
  defp may_act(conn, account) do
    case Admin.user_for(account) do
      nil -> :ok
      user -> if Roles.can_act_on?(current_user(conn), user), do: :ok, else: {:error, :forbidden}
    end
  end

  defp origin_of(%{"local" => value}) when value in ["true", true, "1"], do: "local"
  defp origin_of(%{"remote" => value}) when value in ["true", true, "1"], do: "remote"
  defp origin_of(_params), do: nil

  defp status_of(%{"status" => status}), do: status
  defp status_of(%{"pending" => value}) when value in ["true", true, "1"], do: "pending"
  defp status_of(%{"suspended" => value}) when value in ["true", true, "1"], do: "suspended"
  defp status_of(%{"silenced" => value}) when value in ["true", true, "1"], do: "silenced"
  defp status_of(_params), do: nil

  defp actor(conn), do: Accounts.get_account(current_user(conn).account_id)

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> 0
    end
  end
end
