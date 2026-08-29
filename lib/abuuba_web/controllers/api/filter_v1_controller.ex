defmodule AbuubaWeb.API.FilterV1Controller do
  @moduledoc """
  `/api/v1/filters`, for clients written before a filter could hold more than
  one keyword.

  The whole of the difference is what an id names. In v2 it names the rule and
  the rule carries its keywords; here it names a keyword, and the rule is
  something the client never sees — its context, its expiry and its action are
  reported as properties of the keyword. Nothing is stored differently: a v1
  write makes an ordinary rule with exactly one keyword in it, and both APIs
  read the same rows.

  ## Where the two shapes cannot be reconciled

  A rule with two keywords is two filters to a v1 client, and it has no way to
  say which of the two it means when it changes the context. So changing
  anything that belongs to the rule is refused on a rule with more than one
  keyword, and only the spelling may be edited. The reference implementation
  draws the line in the same place and for the same reason; a client that hits
  it is told to use a newer one.

  Refused on a *change*, not on a mention: a client that resends the whole form
  it was given has asked for what is already true, and answering that with an
  error would leave it unable to edit the one thing it may.

  Deleting removes the keyword and leaves the rule, even when it was the last
  keyword in it. Also what the reference implementation does: the client asked
  about a spelling and said nothing about the rule.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Filters
  alias Abuuba.Repo
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities

  plug AbuubaWeb.Plugs.RequireUser

  plug AbuubaWeb.Plugs.RequireScopes, ["read:filters"] when action in [:index, :show]
  plug AbuubaWeb.Plugs.RequireScopes, ["write:filters"] when action in [:create, :update, :delete]

  def index(conn, _params) do
    json(conn, Enum.map(Filters.keywords_for(current_account(conn)), &Entities.filter_v1/1))
  end

  def show(conn, %{"id" => id}) do
    with_keyword(conn, id, fn keyword -> json(conn, Entities.filter_v1(keyword)) end)
  end

  def create(conn, params) do
    case Filters.create(current_account(conn), create_attrs(params)) do
      {:ok, filter} ->
        # Exactly one, because that is what `create_attrs/1` asked for.
        [keyword] = filter.keywords

        json(conn, Entities.filter_v1(%{keyword | filter: filter}))

      {:error, changeset} ->
        invalid(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with_keyword(conn, id, fn keyword ->
      rule = rule_attrs(params)

      if rewrites?(rule, keyword.filter) and Filters.keyword_count(keyword.filter) > 1 do
        API.error(conn, 422, multiple_keywords_message())
      else
        apply_update(conn, keyword, keyword_attrs(params), rule)
      end
    end)
  end

  def delete(conn, %{"id" => id}) do
    with_keyword(conn, id, fn keyword ->
      Filters.delete_keyword(keyword)

      json(conn, %{})
    end)
  end

  ## Writes

  # Both halves or neither. A rule and its one spelling are one thing to the
  # client that sent them, so a context it cannot have must not leave the
  # keyword renamed under a rule that still says what it said.
  defp apply_update(conn, keyword, keyword_attrs, rule_attrs) do
    result =
      Repo.transaction(fn ->
        with {:ok, updated} <- Filters.update_keyword(keyword, keyword_attrs),
             {:ok, filter} <- update_rule(keyword.filter, rule_attrs) do
          %{updated | filter: filter}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, keyword} -> json(conn, Entities.filter_v1(keyword))
      {:error, changeset} -> invalid(conn, changeset)
    end
  end

  # Nothing to say about the rule is a request that never touches it, rather
  # than an empty write and a reload.
  defp update_rule(filter, attrs) when map_size(attrs) == 0, do: {:ok, filter}
  defp update_rule(filter, attrs), do: Filters.update(filter, attrs)

  # A rule named after its one keyword. `keywords_attributes` is built here
  # rather than taken from the request: a v1 client has no word for it, and
  # letting one through would be a v1 request quietly writing a v2 rule.
  defp create_attrs(params) do
    params
    |> rule_attrs()
    |> Map.put("keywords_attributes", [
      Map.put(keyword_attrs(params), "keyword", params["phrase"])
    ])
  end

  # Only the keys the request actually carried. Absent is not empty: a client
  # sending a new spelling and nothing else has said nothing about the context,
  # and defaulting one in would wipe it.
  defp rule_attrs(params) do
    %{}
    |> maybe_put("title", params["phrase"])
    |> maybe_put("context", params["context"])
    |> maybe_put("filter_action", action(params))
    |> maybe_take(params, "expires_in")
  end

  defp keyword_attrs(params) do
    %{}
    |> maybe_put("keyword", params["phrase"])
    |> maybe_put("whole_word", boolean(params["whole_word"]))
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  # Kept even when empty, unlike the others: an empty `expires_in` is how a
  # client takes an expiry back off.
  defp maybe_take(attrs, params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> attrs
    end
  end

  ## What counts as rewriting the rule

  # Asked of the attributes that would be written rather than of the parameters
  # that arrived, so there is one place that knows which v1 field means which
  # rule field. A value equal to what the rule already holds is not a rewrite —
  # including an expiry, where the comparison has to be of the resolved instant
  # rather than of the parameter, or `expires_in=` on a rule that never expired
  # would read as a change to it.
  defp rewrites?(attrs, filter) do
    Enum.any?(attrs, fn
      {"expires_in", _value} -> Filters.expires_at(attrs) != filter.expires_at
      {"title", value} -> value != filter.title
      {"context", value} -> value != filter.context
      {"filter_action", value} -> value != filter.filter_action
      {_key, _value} -> false
    end)
  end

  defp action(%{"irreversible" => value}), do: if(boolean(value), do: "hide", else: "warn")
  defp action(_params), do: nil

  # Absent stays absent, so that the schema's own default decides what a
  # keyword gets when nobody said.
  defp boolean(nil), do: nil
  defp boolean(value), do: API.boolean(value)

  defp with_keyword(conn, id, fun) do
    case Filters.get_keyword(current_account(conn), API.parse_id(id)) do
      nil -> API.error(conn, 404, "Record not found")
      keyword -> fun.(keyword)
    end
  end

  defp invalid(conn, changeset) do
    API.error(conn, 422, "Validation failed", Entities.field_errors(changeset))
  end

  defp multiple_keywords_message do
    "These parameters cannot be changed from this application because they " <>
      "apply to more than one filter keyword. Use a more recent application " <>
      "or the web interface."
  end
end
