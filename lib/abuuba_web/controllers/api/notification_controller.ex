defmodule AbuubaWeb.API.NotificationController do
  @moduledoc """
  `/api/v1/notifications` and `/api/v2/notifications`.

  Two shapes of the same list. v1 is one entry per event and v2 is one per
  group, and both stay because clients written against either are still in use;
  the grouped one is what a modern client renders, because twenty people
  boosting one post is one line rather than twenty.

  ## Forward compatibility

  `grouped_types[]` and `supported_types[]` let a client say which types it
  knows how to render. A type it has never heard of is answered ungrouped, so a
  client written before a type existed shows it as a plain entry rather than
  dropping it or crashing on a shape it cannot read.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Accounts
  alias Abuuba.Notifications
  alias Abuuba.Notifications.Notification
  alias Abuuba.Notifications.Policy
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.NestedParams
  alias AbuubaWeb.API.Pagination

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes,
       ["read:notifications"]
       when action in [
              :index,
              :show,
              :unread_count,
              :grouped_index,
              :show_group,
              :grouped_unread_count,
              :group_accounts,
              :get_policy,
              :requests,
              :show_request,
              :requests_merged
            ]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:notifications"]
       when action in [
              :dismiss,
              :clear,
              :dismiss_group,
              :put_policy,
              :accept_request,
              :dismiss_request,
              :accept_requests,
              :dismiss_requests
            ]

  def index(conn, params) do
    account = current_account(conn)
    notifications = Notifications.list(account, page(params))

    conn
    |> Pagination.put_link_header(notifications)
    |> json(Entities.notifications(notifications, account))
  end

  def show(conn, %{"id" => id}) do
    account = current_account(conn)

    case Notifications.get(account, API.id_param(%{"id" => id}, "id")) do
      nil -> API.error(conn, 404, "Record not found")
      notification -> json(conn, Entities.notification(notification, account))
    end
  end

  def dismiss(conn, %{"id" => id}) do
    account = current_account(conn)

    case API.id_param(%{"id" => id}, "id") do
      nil -> API.error(conn, 404, "Record not found")
      notification_id -> Notifications.dismiss(account, notification_id) && json(conn, %{})
    end
  end

  def clear(conn, _params) do
    Notifications.clear(current_account(conn))

    json(conn, %{})
  end

  def unread_count(conn, params) do
    account = current_account(conn)
    since = API.id_param(params, "since_id")

    json(conn, %{"count" => Notifications.unread_count(account, since)})
  end

  ## Grouped

  def grouped_index(conn, params) do
    account = current_account(conn)
    groups = Notifications.grouped(account, page(params))
    grouped_types = grouped_types(params)

    conn
    |> Pagination.put_link_header(Enum.map(groups, &representative/1))
    |> json(Entities.grouped_notifications(groups, account, grouped_types))
  end

  @doc """
  One group, for a client that has a key and wants the group behind it.
  """
  def show_group(conn, %{"group_key" => key} = params) do
    account = current_account(conn)

    case Notifications.group(account, key) do
      [] ->
        API.error(conn, 404, "Record not found")

      notifications ->
        # The same envelope the list answers with, holding one group. That is
        # what the reference implementation sends here, and a client that
        # reused its list parser on a bare group would find no accounts and no
        # statuses to render it with.
        json(
          conn,
          Entities.grouped_notifications(
            [%{key: key, notifications: notifications}],
            account,
            grouped_types(params)
          )
        )
    end
  end

  @doc """
  Dismisses a whole group at once, which is what the client's swipe does.
  """
  def dismiss_group(conn, %{"group_key" => key}) do
    :ok = Notifications.dismiss_group(current_account(conn), key)

    json(conn, %{})
  end

  @doc """
  How many groups are unread, which is the number a v2 client puts on the tab.

  Groups rather than notifications: a client showing "40" for one post that
  forty people favourited is counting rows rather than things that happened.
  """
  def grouped_unread_count(conn, params) do
    account = current_account(conn)
    since = API.id_param(params, "since_id")

    json(conn, %{"count" => Notifications.unread_group_count(account, since)})
  end

  @doc """
  Everybody in one group, for the "and 19 others" a client shows.
  """
  def group_accounts(conn, %{"group_key" => key}) do
    account = current_account(conn)

    ids =
      account
      |> Notifications.group(key)
      |> Enum.map(& &1.from_account_id)
      |> Enum.uniq()

    # One query rather than one per sender. A group is up to a hundred people,
    # and `Accounts.get_accounts/1` is the batch that answers them all --
    # keyed by id, so the group's own order is what survives.
    found = Accounts.get_accounts(ids)
    accounts = Enum.flat_map(ids, &List.wrap(Map.get(found, &1)))

    json(conn, Entities.accounts(accounts, account))
  end

  ## Policy

  def get_policy(conn, _params) do
    json(conn, Entities.notification_policy(Notifications.policy(current_account(conn))))
  end

  def put_policy(conn, params) do
    account = current_account(conn)

    case Notifications.put_policy(account, Map.take(params, axis_names())) do
      {:ok, policy} ->
        json(conn, Entities.notification_policy(policy))

      {:error, changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  ## The requests inbox

  def requests(conn, params) do
    account = current_account(conn)
    requests = Notifications.requests(account, Pagination.params(params, default: 40))

    conn
    |> Pagination.put_link_header(requests)
    |> json(Entities.notification_requests(requests, account))
  end

  @doc """
  One request, for a client that has an id and wants the sender behind it.
  """
  def show_request(conn, %{"id" => id}) do
    account = current_account(conn)

    case Notifications.get_request(account, API.parse_id(id)) do
      nil -> API.error(conn, 404, "Record not found")
      request -> json(conn, Entities.notification_request(request, account))
    end
  end

  def accept_request(conn, %{"id" => id}), do: answer_request(conn, id, :accept)
  def dismiss_request(conn, %{"id" => id}), do: answer_request(conn, id, :dismiss)

  @doc """
  Accepting or dismissing several at once, which is what a client's "clear all"
  sends rather than one request per person.
  """
  def accept_requests(conn, params), do: answer_many(conn, params, :accept)
  def dismiss_requests(conn, params), do: answer_many(conn, params, :dismiss)

  @doc """
  Whether the requests inbox has finished being rebuilt.

  Answered rather than absent, because a client polls it and a 404 would stop
  it polling. Nothing here rebuilds asynchronously, so it is always ready.
  """
  def requests_merged(conn, _params), do: json(conn, %{"merged" => true})

  # The id in the path is the request's, which is what the entity hands out.
  # Resolving it to the sender here rather than treating the two as the same
  # number: they are not, and a client acting on the id it was given would have
  # been accepting whoever happened to have that account id.
  defp answer_request(conn, id, action) do
    account = current_account(conn)

    case Notifications.get_request(account, API.parse_id(id)) do
      nil -> API.error(conn, 404, "Record not found")
      request -> apply_request(conn, account, request.from_account_id, action)
    end
  end

  defp apply_request(conn, account, from_id, :accept) do
    case Notifications.accept_request(account, from_id) do
      :ok -> json(conn, %{})
      {:error, :not_found} -> API.error(conn, 404, "Record not found")
    end
  end

  defp apply_request(conn, account, from_id, :dismiss) do
    Notifications.dismiss_request(account, from_id)

    json(conn, %{})
  end

  defp answer_many(conn, params, action) do
    account = current_account(conn)

    account
    |> Notifications.get_requests(API.id_list(params, "id"))
    |> Enum.map(& &1.from_account_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn from_id ->
      case action do
        :accept -> Notifications.accept_request(account, from_id)
        :dismiss -> Notifications.dismiss_request(account, from_id)
      end
    end)

    json(conn, %{})
  end

  ## Plumbing

  defp representative(%{notifications: [newest | _rest]}), do: newest

  # A type the client did not say it can group is answered ungrouped, so a
  # client written before a type existed shows it as a plain entry rather than
  # dropping it.
  defp grouped_types(params) do
    case NestedParams.list(params["grouped_types"]) do
      [] -> Notification.types()
      types -> Enum.filter(types, &is_binary/1)
    end
  end

  defp page(params) do
    params
    |> Pagination.params(default: 40, max: 80)
    |> Map.merge(%{
      types: string_list(params["types"]),
      exclude_types: string_list(params["exclude_types"]),
      # abuuba's own: only the waiting list, which is what the notifications
      # page draws. The reference has no equivalent, and `include_filtered`
      # below is its way of asking for both.
      filtered: API.truthy?(params["filtered"]),
      include_filtered: API.truthy?(params["include_filtered"]),
      from_account_id: API.id_param(params, "account_id")
    })
  end

  defp string_list(value), do: value |> NestedParams.list() |> Enum.filter(&is_binary/1)

  defp axis_names, do: Enum.map(Policy.axes(), &Atom.to_string/1)
end
