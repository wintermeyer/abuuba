defmodule AbuubaWeb.API.FeaturedTagController do
  @moduledoc """
  `/api/v1/featured_tags`, the hashtags somebody has put on their own profile.

  A featured tag is a shortcut a person offers visitors: "the thing I write
  about is here". Which is why the answer carries how many posts carry it and
  when the last one was — a profile leading with a tag last used two years ago
  is worse than one leading with nothing.

  The id in the answer is the featured row's rather than the tag's. Two people
  featuring one tag are two rows, and a client deleting by tag id would be
  asking this server to take a tag off everybody's profile.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Statuses
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["read:accounts"] when action in [:index, :suggestions]
  plug AbuubaWeb.Plugs.RequireScopes, ["write:accounts"] when action in [:create, :delete]

  def index(conn, _params) do
    json(conn, Entities.featured_tags(current_account(conn)))
  end

  @doc """
  Puts one on, creating the tag if this server has not seen it before.
  """
  def create(conn, params) do
    account = current_account(conn)

    case Statuses.feature_tag_by_name(account, params["name"]) do
      {:ok, tag} ->
        json(conn, Entities.featured_tag(account, Statuses.get_featured_tag_for(account, tag)))

      {:error, :too_many} ->
        API.error(conn, 422, "Validation failed: you cannot feature any more hashtags")

      {:error, changeset} ->
        API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
    end
  end

  @doc """
  Takes one back off.
  """
  def delete(conn, %{"id" => id}) do
    account = current_account(conn)

    case Statuses.get_featured_tag(account, API.parse_id(id)) do
      nil ->
        API.error(conn, 404, "Record not found")

      featured ->
        :ok = Statuses.unfeature_tag(account, featured.tag)

        json(conn, %{})
    end
  end

  @doc """
  Tags this person has been using and has not featured.

  What a client puts in the box when somebody opens "feature a tag", so that
  the common case is a tap rather than typing a word they already use.
  """
  def suggestions(conn, _params) do
    account = current_account(conn)

    json(conn, Enum.map(Statuses.featured_tag_suggestions(account), &Entities.tag(&1, account)))
  end
end
