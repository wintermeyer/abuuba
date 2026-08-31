defmodule AbuubaWeb.API.PollController do
  @moduledoc """
  `/api/v1/polls`.

  A poll is shown to anybody who may see the post it belongs to, and voted in
  only by somebody signed in. The refusals are specific on purpose: a client
  that gets "you already voted" can show the result, while one that gets a bare
  422 can only shrug at the person.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.NestedParams

  plug AbuubaWeb.Plugs.RequireUser when action in [:vote]

  # A poll on a public post is as public as the post, so the scope conditions
  # the token rather than the request.
  plug AbuubaWeb.Plugs.RequireScopes,
       {:when_authenticated, ["read:statuses"]} when action in [:show]

  plug AbuubaWeb.Plugs.RequireScopes, ["write:statuses"] when action in [:vote]

  def show(conn, %{"id" => id}) do
    with_poll(conn, id, fn poll, viewer -> json(conn, Entities.poll(poll, viewer)) end)
  end

  def vote(conn, %{"id" => id} = params) do
    with_poll(conn, id, fn poll, voter ->
      choices = params |> Map.get("choices", []) |> NestedParams.list() |> Enum.map(&to_choice/1)

      case Statuses.vote(poll, voter, choices) do
        {:ok, voted} -> json(conn, Entities.poll(voted, voter))
        {:error, reason} -> API.error(conn, 422, message(reason))
      end
    end)
  end

  # The poll is reachable exactly when its status is, so the entitlement check
  # is the status's. Checking the poll separately would be a second set of
  # rules to keep in step with the first.
  defp with_poll(conn, id, fun) do
    viewer = current_account(conn)
    poll = Abuuba.Repo.get(Poll, API.id_param(%{"id" => id}, "id") || 0)

    case poll && Statuses.readable(poll.status_id, viewer) do
      nil -> API.error(conn, 404, "Record not found")
      _status -> fun.(poll, viewer)
    end
  end

  defp to_choice(value) when is_integer(value), do: value

  defp to_choice(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> -1
    end
  end

  defp to_choice(_value), do: -1

  defp message(:expired), do: "Validation failed: The poll has already ended"
  defp message(:own_poll), do: "Validation failed: You cannot vote in your own poll"
  defp message(:already_voted), do: "Validation failed: You have already voted on this poll"
  defp message(:too_many_choices), do: "Validation failed: Only one choice is allowed"
  defp message(_reason), do: "Validation failed"
end
