defmodule AbuubaWeb.API.StatusController do
  @moduledoc """
  `/api/v1/statuses`.

  ## Why the un-actions are POST

  `POST /unfavourite` rather than `DELETE /favourite`, and the same for every
  other pair. It reads as a mistake and it is what every client sends: they
  were written against the reference implementation, and an endpoint that only
  answered `DELETE` would leave the button in an app doing nothing at all.

  ## Deleting hands the post back

  A `DELETE` answers with the post's source rather than with nothing, because
  the button in every client is "delete and redraft": the client immediately
  puts the text back in the compose box. Answering with 204 would lose whatever
  the person had written.
  """

  use AbuubaWeb, :controller

  alias Abuuba.Federation.Quotes
  alias Abuuba.Instance
  alias Abuuba.Media
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Poll
  alias Abuuba.Statuses.ScheduledStatus
  alias Abuuba.Statuses.Status
  alias Abuuba.Translation
  alias AbuubaWeb.API
  alias AbuubaWeb.API.Entities
  alias AbuubaWeb.API.NestedParams
  alias AbuubaWeb.API.Pagination

  plug AbuubaWeb.Plugs.RequireUser
       when action in [
              :create,
              :update,
              :delete,
              :reblog,
              :unreblog,
              :favourite,
              :unfavourite,
              :bookmark,
              :unbookmark,
              :mute,
              :unmute,
              :pin,
              :unpin,
              # These three reach for the signed-in account through
              # `with_own_status/3`, which compares an id against `account.id`.
              # Anonymously that account is nil and the comparison raised, so
              # the endpoint answered 500 to a request that should have been
              # told to sign in.
              :source,
              :revoke_quote,
              :interaction_policy
            ]

  # Deleting has a budget of its own, narrower than the general API one, and
  # undoing a boost is in it: both take a post back out of other people's
  # timelines, and a script that empties an account's history in two minutes is
  # what the general 1,500-per-five-minutes allows without it.
  plug AbuubaWeb.Plugs.APIRateLimit, [bucket: :delete] when action in [:delete, :unreblog]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:statuses"]
       when action in [
              :create,
              :update,
              :delete,
              :reblog,
              :unreblog,
              :pin,
              :unpin,
              :revoke_quote,
              :interaction_policy
            ]

  plug AbuubaWeb.Plugs.RequireScopes,
       ["write:favourites"] when action in [:favourite, :unfavourite]

  plug AbuubaWeb.Plugs.RequireScopes, ["write:bookmarks"] when action in [:bookmark, :unbookmark]
  plug AbuubaWeb.Plugs.RequireScopes, ["write:mutes"] when action in [:mute, :unmute]

  plug AbuubaWeb.Plugs.RequireScopes, ["read:statuses"] when action in [:source]

  # Translation goes out to a paid service on the server's account, so this one
  # wants a real token rather than a conditional check: a stranger who brought
  # nothing must not be able to spend the bill.
  plug AbuubaWeb.Plugs.RequireScopes, ["read:statuses"] when action in [:translate]

  # Reading a public post has never needed a token, so the scope is a condition
  # on the token rather than on the request. Requiring it outright would refuse
  # an app while still answering a stranger who brought nothing at all. The
  # token still widens what comes back — a follower sees a private post here —
  # so every one of these needs the check when a token is present.
  plug AbuubaWeb.Plugs.RequireScopes,
       {:when_authenticated, ["read:statuses"]}
       when action in [
              :index,
              :show,
              :context,
              :history,
              :quotes,
              :reblogged_by,
              :favourited_by
            ]

  @doc """
  Posts something.

  An `Idempotency-Key` makes a retry safe. A client that times out has no way
  to know whether the post landed, so without this its retry is a second post
  and the person says the same thing twice.
  """
  def create(conn, params) do
    account = current_account(conn)
    key = idempotency_key(conn)
    params = with_text(params)

    cond do
      empty?(params) ->
        API.error(conn, 422, "Validation failed: Text can't be blank")

      already = Statuses.replay_key(account, key) ->
        replay(conn, already, account)

      true ->
        create_new(conn, account, key, params)
    end
  end

  # A key names whichever of the two the first attempt made, and the answer has
  # to be the same shape the first one got: a client that scheduled something
  # and retried is waiting for a scheduled status, and handing it a post would
  # be a different object with a different id under the same request.
  defp replay(conn, %ScheduledStatus{} = scheduled, _account),
    do: json(conn, Entities.scheduled_status(scheduled))

  defp replay(conn, status, account), do: render_status(conn, status, account)

  # The words are `status` on the wire and `text` in this server's own
  # vocabulary. Every written client sends the first, so reading only the
  # second answered 200 with an empty post: the worst possible failure, because
  # the client believes it posted. `status` does not travel any further than
  # this: a scheduled post stores its params and hands them back, so the wire
  # spelling would otherwise be persisted and echoed to clients. An explicit
  # `text` still wins, since a caller that sent it meant it.
  defp with_text(%{"status" => status} = params) when is_binary(status),
    do: params |> Map.delete("status") |> Map.put_new("text", status)

  defp with_text(params), do: Map.delete(params, "status")

  # A post with nothing in it at all. Accepting one answered 200 and left
  # somebody looking at an empty post they believed they had written, which is
  # worse than the refusal every client already knows how to show.
  #
  # A quote, a content warning, a picture and a poll each count as something
  # said, matching the reference implementation: a quote with no comment of its
  # own is an ordinary thing to post, so is a bare warning, and a post that is
  # four photographs is most of what anybody posts. Whitespace does not count,
  # because a post of four spaces is the same empty post with a different cause.
  defp empty?(params) do
    blank?(params["text"]) and blank?(params["spoiler_text"]) and blank?(params["quote_id"]) and
      params |> Map.get("media_ids", []) |> NestedParams.list() |> Enum.empty?() and
      not is_map(Map.get(params, "poll"))
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  # `scheduled_at` turns a post into a plan. The same endpoint answers both,
  # because that is how every client sends it, and the two answers are
  # different shapes: a scheduled status has no content to render yet.
  defp create_new(conn, account, key, %{"scheduled_at" => at} = params) when is_binary(at) do
    case parse_time(at) do
      nil ->
        API.error(conn, 422, "Validation failed: scheduled_at is invalid")

      at ->
        with {:ok, media_ids} <- attachable(params, account),
             {:ok, _poll} <- pollable(params, media_ids) do
          schedule(conn, account, Map.delete(params, "scheduled_at"), at, key)
        else
          error -> refuse(conn, error)
        end
    end
  end

  defp create_new(conn, account, key, params) do
    attrs =
      params
      |> Map.take(~w(text spoiler_text language sensitive visibility in_reply_to_id quote_policy))
      |> Map.put("account_id", account.id)
      # Recorded here rather than in the context, because the token is the only
      # thing that knows which app is asking and it never travels further in.
      |> Map.put("application_id", application_id(conn))

    # Everything that can be refused is refused before the post is written. A
    # post that appeared without its pictures, or without the poll it was
    # written to ask, looks to its author like the upload failed silently, and
    # there is no way back from it but deleting and starting again.
    with {:ok, media_ids} <- attachable(params, account),
         {:ok, poll} <- pollable(params, media_ids),
         {:ok, quoted} <- quoted_status(params, account),
         {:ok, status} <-
           Statuses.create_status(attrs, media_ids: media_ids, poll: poll_attrs(poll)) do
      if quoted, do: Quotes.record_local(status, quoted)
      if key, do: Statuses.remember_key(account, key, status)

      render_status(conn, status, account)
    else
      error ->
        refuse(conn, error)
    end
  end

  # One place, because the scheduled branch refuses the same things the
  # immediate one does and answering differently would make scheduling a way
  # round the checks.
  defp refuse(conn, error) do
    case error do
      {:error, :quote_not_found} ->
        API.error(conn, 404, "Record not found")

      {:error, :quote_refused} ->
        API.error(conn, 422, "Validation failed: that post may not be quoted")

      {:error, :unknown_attachment} ->
        API.error(conn, 422, "Validation failed: one of those uploads is not yours to post")

      {:error, :too_many_attachments} ->
        API.error(
          conn,
          422,
          "Validation failed: a post takes at most #{Instance.max_media_attachments()} attachments"
        )

      {:error, :media_and_poll} ->
        API.error(conn, 422, "Validation failed: a post is pictures or a poll, not both")

      {:error, :poll_too_short} ->
        API.error(conn, 422, "Validation failed: a poll needs at least two options")

      {:error, :poll_too_long} ->
        API.error(
          conn,
          422,
          "Validation failed: a poll takes at most #{Poll.max_options()} options"
        )

      {:error, changeset} ->
        API.error(conn, 422, changeset_message(changeset))
    end
  end

  # The ids the client sent, checked against what this account actually has
  # unattached. One query, and the answer is the same one `Media.attach/2`
  # would give a moment later.
  defp attachable(params, account) do
    ids =
      params
      |> Map.get("media_ids", [])
      |> NestedParams.list()
      |> Enum.map(&API.parse_id/1)
      # The same id twice passes every check below and comes back as the same
      # picture rendered twice.
      |> Enum.uniq()

    cond do
      ids == [] -> {:ok, []}
      Enum.any?(ids, &is_nil/1) -> {:error, :unknown_attachment}
      length(ids) > Instance.max_media_attachments() -> {:error, :too_many_attachments}
      true -> found(ids, account)
    end
  end

  defp found(ids, account) do
    have = Media.own_unattached(account, ids)

    if Enum.all?(ids, &Map.has_key?(have, &1)) do
      {:ok, ids}
    else
      {:error, :unknown_attachment}
    end
  end

  # Both is refused rather than one silently winning. A post carrying a poll
  # and four pictures has no rendering anywhere: every client shows one or the
  # other, and which one is not this server's to decide for the author.
  defp pollable(%{"poll" => poll}, media_ids) when is_map(poll) do
    options = poll |> Map.get("options", []) |> NestedParams.list()

    cond do
      media_ids != [] -> {:error, :media_and_poll}
      length(options) < 2 -> {:error, :poll_too_short}
      length(options) > Poll.max_options() -> {:error, :poll_too_long}
      true -> {:ok, poll}
    end
  end

  defp pollable(_params, _media_ids), do: {:ok, nil}

  defp poll_attrs(nil), do: nil

  defp poll_attrs(poll) do
    %{
      options: poll |> Map.get("options", []) |> NestedParams.list(),
      multiple: poll["multiple"] in [true, "true"],
      expires_at: DateTime.add(DateTime.utc_now(), poll_seconds(poll), :second)
    }
  end

  # A day, which is what a client that sends no expiry means, clamped to the
  # reference implementation's bounds. Unclamped, a negative number produced a
  # poll that was already closed when it was published, and a large one a poll
  # expiring in the year 33715.
  defp poll_seconds(%{"expires_in" => value}) do
    case value |> to_string() |> Integer.parse() do
      {seconds, _rest} ->
        seconds
        |> max(Poll.min_expiration_seconds())
        |> min(Poll.max_expiration_seconds())

      :error ->
        86_400
    end
  end

  defp poll_seconds(_poll), do: 86_400

  # A stale or malformed entry is skipped rather than refused, matching what
  # `Media.update_on_status/2` does with an id that is not on this post.
  defp media_attributes(%{"media_attributes" => attributes}),
    do: attributes |> NestedParams.list() |> Enum.filter(&is_map/1)

  defp media_attributes(_params), do: []

  defp application_id(conn) do
    case conn.assigns[:current_token] do
      %{application_id: id} -> id
      _ -> nil
    end
  end

  # `quote_id` is what a client sends. Refused rather than silently dropped
  # when the author has said no: a post that quietly came out as an ordinary
  # post would look to the writer as though the quote had gone through.
  defp quoted_status(params, account) do
    case API.id_param(params, "quote_id") do
      nil ->
        {:ok, nil}

      id ->
        id |> Statuses.readable(account) |> quotable(account)
    end
  end

  defp quotable(nil, _account), do: {:error, :quote_not_found}

  defp quotable(quoted, account) do
    if Quotes.allowed?(account, quoted), do: {:ok, quoted}, else: {:error, :quote_refused}
  end

  @doc """
  The posts quoting this one.

  Only the ones its author approved. A pending quote is somebody asserting a
  relationship that has not been agreed to, and listing it on the quoted
  author's own post would publish the assertion for them.
  """
  def quotes(conn, %{"id" => id}) do
    with_readable_status(conn, id, fn status, viewer ->
      json(conn, Entities.statuses(Quotes.quoting(status), viewer))
    end)
  end

  @doc """
  Withdraws the quoted author's approval.

  Un-endorses the quote everywhere without deleting anybody's post: the quoting
  author still has what they wrote, and it stops being presented as agreed to.
  """
  def revoke_quote(conn, %{"status_id" => status_id, "id" => quoting_id}) do
    with_own_status(conn, status_id, fn status, viewer ->
      case Quotes.revoke_for(status, API.id_param(%{"id" => quoting_id}, "id")) do
        :ok -> json(conn, Entities.status(status, viewer))
        :error -> API.error(conn, 404, "Record not found")
      end
    end)
  end

  @doc """
  Sets who may quote a post.
  """
  def interaction_policy(conn, %{"id" => id} = params) do
    with_own_status(conn, id, fn status, viewer ->
      case Statuses.set_quote_policy(status, quote_policy_of(params)) do
        {:ok, updated} -> json(conn, Entities.status(updated, viewer))
        {:error, changeset} -> API.error(conn, 422, changeset_message(changeset))
      end
    end)
  end

  # Mastodon nests it under `quotes[automatic_approval]`; the flat
  # `quote_policy` is read too, because that is what abuuba's own UI sends.
  defp quote_policy_of(%{"quotes" => %{"automatic_approval" => value}}), do: value
  defp quote_policy_of(%{"quote_policy" => value}), do: value
  defp quote_policy_of(_params), do: nil

  defp schedule(conn, account, params, at, key) do
    case Statuses.schedule(account, params, at) do
      {:ok, scheduled} ->
        if key, do: Statuses.remember_key(account, key, scheduled)

        json(conn, Entities.scheduled_status(scheduled))

      {:error, changeset} ->
        API.error(conn, 422, changeset_message(changeset))
    end
  end

  @doc """
  One post.
  """
  def show(conn, %{"id" => id}) do
    with_readable_status(conn, id, fn status, viewer -> render_status(conn, status, viewer) end)
  end

  @doc """
  Several posts at once, for a client filling in gaps in a timeline it already
  holds.
  """
  def index(conn, params) do
    viewer = current_account(conn)

    ids = params |> API.id_list("id") |> Enum.take(40)

    statuses = Statuses.readable_many(ids, viewer)

    json(conn, Entities.statuses(statuses, viewer, filter_context: "thread"))
  end

  @doc """
  Edits a post.
  """
  def update(conn, %{"id" => id} = params) do
    with_own_status(conn, id, fn status, account ->
      attrs = params |> with_text() |> Map.take(~w(text spoiler_text language sensitive))

      # Before the edit, so the corrected description travels with it: the
      # outbox reads the attachments as they stand when the edit goes out.
      # This is how alt text is fixed after posting -- `Media.update_upload/2`
      # refuses once a picture is on a post, and says the post is the place.
      Media.update_on_status(status, media_attributes(params))

      case Statuses.edit_status(status, attrs) do
        {:ok, edited} -> render_status(conn, edited, account)
        {:error, changeset} -> API.error(conn, 422, changeset_message(changeset))
      end
    end)
  end

  @doc """
  Deletes a post and hands back what it said, for redrafting.
  """
  def delete(conn, %{"id" => id}) do
    with_own_status(conn, id, fn status, account ->
      {:ok, deleted} = Statuses.delete_status(status)

      # The rendered post plus its source, which is the shape the reference
      # implementation answers with and what a client's redraft reads.
      conn
      |> json(
        deleted
        |> Entities.status(account)
        |> Map.put("text", status.text)
      )
    end)
  end

  @doc """
  The conversation a post sits in.
  """
  def context(conn, %{"id" => id}) do
    with_readable_status(conn, id, fn status, viewer ->
      json(conn, status |> Statuses.context(viewer) |> Entities.context(viewer))
    end)
  end

  @doc """
  The text as it was typed, which is what an edit box needs.
  """
  def source(conn, %{"id" => id}) do
    with_own_status(conn, id, fn status, _account ->
      json(conn, Entities.status_source(status))
    end)
  end

  @doc """
  Every earlier version of a post.
  """
  def history(conn, %{"id" => id}) do
    with_readable_status(conn, id, fn status, _viewer ->
      # The current version closes the list. Each stored row is the state
      # *before* one edit, so a post edited twice has two rows and neither says
      # what it reads now -- and the newest edit is the one somebody opened the
      # history to see. A post nobody edited answers with itself rather than
      # with nothing, which is upstream's behaviour and what stops a client
      # rendering an empty history for a post it can see.
      #
      # Composed here rather than in `edit_history/1`, which describes what was
      # superseded and should keep saying only that.
      versions = Statuses.edit_history(status) ++ [status]

      json(conn, Enum.map(versions, &Entities.status_edit/1))
    end)
  end

  @doc """
  Translating a post.

  Answered with 501 until a translation provider is configured, which is the
  reference implementation's answer in the same situation and what a client
  reads as "this server does not translate". Providers arrive with their own
  issue; the endpoint is here so a client can ask and be told.
  """
  def translate(conn, %{"id" => id} = params) do
    with_readable_status(conn, id, fn status, viewer ->
      target = params["lang"] || reader_language(viewer, conn)

      case Translation.translate(status, target) do
        {:ok, translation} ->
          json(conn, Entities.translation(translation))

        {:error, reason} ->
          API.error(conn, translation_status(reason), translation_message(reason))
      end
    end)
  end

  # What the reader reads in, where they have not said which language they
  # want. A client that names one is believed; one that does not is asking for
  # "mine", and their own setting is the only honest answer to that.
  defp reader_language(viewer, conn) do
    case viewer do
      %{locale: locale} when is_binary(locale) and locale != "" -> locale
      _ -> conn.assigns[:locale] || "en"
    end
  end

  defp translation_status(:not_configured), do: 501
  defp translation_status(:not_translatable), do: 422
  defp translation_status(:same_language), do: 422
  defp translation_status(:quota_exceeded), do: 503
  defp translation_status(:rate_limited), do: 503
  defp translation_status(_reason), do: 503

  # Each reason says what somebody can do about it. "Something went wrong" is
  # the one answer nobody can act on.
  defp translation_message(:not_configured), do: "Translation is not enabled on this server"
  defp translation_message(:not_translatable), do: "This post cannot be translated"
  defp translation_message(:same_language), do: "This post is already in that language"
  defp translation_message(:quota_exceeded), do: "This server has used up its translation quota"
  defp translation_message(:rate_limited), do: "Too many translations just now; try again shortly"

  defp translation_message(:unauthorised),
    do: "This server's translation credentials were refused"

  defp translation_message(_reason), do: "The translation service could not be reached"

  ## Interactions

  def reblog(conn, %{"id" => id}) do
    with_readable_status(conn, id, fn status, account ->
      if Statuses.boostable?(account, status) do
        act(conn, id, &Statuses.boost/2)
      else
        API.error(conn, 422, "Validation failed: cannot boost this status")
      end
    end)
  end

  def unreblog(conn, %{"id" => id}), do: undo(conn, id, &Statuses.unboost/2)
  def favourite(conn, %{"id" => id}), do: act(conn, id, &Statuses.favourite/2)
  def unfavourite(conn, %{"id" => id}), do: undo(conn, id, &Statuses.unfavourite/2)
  def bookmark(conn, %{"id" => id}), do: act(conn, id, &Statuses.bookmark/2)
  def unbookmark(conn, %{"id" => id}), do: undo(conn, id, &Statuses.unbookmark/2)
  def mute(conn, %{"id" => id}), do: act(conn, id, &Statuses.mute_thread/2)
  def unmute(conn, %{"id" => id}), do: undo(conn, id, &Statuses.unmute_thread/2)

  def pin(conn, %{"id" => id}) do
    with_readable_status(conn, id, fn status, account ->
      case Statuses.pin(account, status) do
        {:ok, _pin} ->
          render_status(conn, reload(status), account)

        {:error, reason} when reason in [:not_yours, :not_public] ->
          API.error(conn, 422, "Validation failed: cannot pin this status")

        {:error, :too_many} ->
          API.error(
            conn,
            422,
            "Validation failed: You have already pinned the maximum number of posts"
          )

        {:error, _changeset} ->
          API.error(conn, 422, "Validation failed")
      end
    end)
  end

  def unpin(conn, %{"id" => id}), do: undo(conn, id, &Statuses.unpin/2)

  ## Who did what

  def reblogged_by(conn, %{"id" => id} = params) do
    with_readable_status(conn, id, fn status, viewer ->
      accounts = Statuses.boosted_by(status, Pagination.params(params, default: 40))

      conn
      |> Pagination.put_link_header(accounts)
      |> json(Entities.accounts(accounts, viewer))
    end)
  end

  def favourited_by(conn, %{"id" => id} = params) do
    with_readable_status(conn, id, fn status, viewer ->
      accounts = Statuses.favourited_by(status, Pagination.params(params, default: 40))

      conn
      |> Pagination.put_link_header(accounts)
      |> json(Entities.accounts(accounts, viewer))
    end)
  end

  ## Plumbing

  # Every interaction is the same three steps, and the state a client wants
  # back is always the post as it now reads.
  #
  # Putting a mark on is being shown the post, so it comes through the reading
  # door; taking one back off is `undo/3` below.
  defp act(conn, id, fun), do: interact(conn, id, fun, &with_readable_status/3)

  defp undo(conn, id, fun), do: interact(conn, id, fun, &with_actionable_status/3)

  defp interact(conn, id, fun, door) do
    door.(conn, id, fn status, account ->
      case fun.(account, status) do
        {:error, :no_conversation} ->
          API.error(conn, 422, "Validation failed")

        {:error, %Ecto.Changeset{} = changeset} ->
          API.error(conn, 422, changeset_message(changeset))

        _ ->
          render_status(conn, reload(status), account)
      end
    end)
  end

  # For the endpoints that hand a post back to be read: `Statuses.readable/2`
  # answers the reader's blocks and mutes as well as the audience, so a post
  # from somebody they will not deal with is a 404 here rather than a body.
  defp with_readable_status(conn, id, fun) do
    fetch(conn, id, &Statuses.readable/2, fun)
  end

  # For taking a mark back off: readable, or already marked by this reader.
  # `/bookmarks` and `/favourites` list what somebody saved whatever they have
  # done about the author since, so the button drawn over a row those lists
  # still return has to reach it.
  defp with_actionable_status(conn, id, fun) do
    fetch(conn, id, &Statuses.actionable/2, fun)
  end

  # Audience only, for a caller that has its own reason to reach past the
  # reader's blocks and mutes. `with_own_status/3` is the one left: a post is
  # never hidden from the person who wrote it, and ownership is the check.
  defp with_status(conn, id, fun) do
    fetch(conn, id, &Statuses.get_status/2, fun)
  end

  defp fetch(conn, id, read, fun) do
    viewer = current_account(conn)

    case read.(API.id_param(%{"id" => id}, "id"), viewer) do
      nil -> API.error(conn, 404, "Record not found")
      status -> fun.(status, viewer)
    end
  end

  defp with_own_status(conn, id, fun) do
    with_status(conn, id, fn status, account ->
      if status.account_id == account.id do
        fun.(status, account)
      else
        API.error(conn, 403, "This action is not allowed")
      end
    end)
  end

  defp render_status(conn, status, viewer), do: json(conn, Entities.status(status, viewer))

  defp reload(%Status{id: id}), do: Statuses.get_status_unchecked(id)

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key | _] when byte_size(key) > 0 -> String.slice(key, 0, 255)
      _ -> nil
    end
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r/%\{(\w+)\}/, message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> then(&"Validation failed: #{&1}")
  end
end
