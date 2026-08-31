defmodule Abuuba.Federation.Quotes do
  @moduledoc """
  Quote posts, and whether the quoted author agreed to be quoted.

  A quote republishes somebody's words next to commentary they did not choose,
  in front of an audience they did not choose. That is why FEP-044f exists and
  why the interesting part of this module is consent rather than rendering.

  A quote is only "accepted" when the quoted author's server has issued a
  `QuoteAuthorization` and that authorization checks out. Three things are
  checked, and each closes a different forgery:

  * the authorization is served by the **quoted author's own host**, because an
    approval hosted anywhere else is one the author never gave;
  * its `interactingObject` is the quoting post, so an approval for one quote
    cannot be reused for another;
  * its `interactionTarget` is the quoted post, so an approval to quote one
    post is not an approval to quote everything that author wrote.

  Anything unapproved is still stored, as `pending`. Dropping it would lose the
  post, and a client can render an unapproved quote as a plain link; what it
  must not do is present it as endorsed.

  ## Legacy quotes

  Servers were quoting each other years before the spec. `quoteUri` and
  `_misskey_quote` are read as quotes, and they carry no approval at all, so
  they land as `pending` like anything else unapproved.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.HTTP
  alias Abuuba.Federation.Serializer
  alias Abuuba.Federation.URIs
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Stats
  alias Abuuba.Statuses
  alias Abuuba.Statuses.Status

  @doc """
  The quoted post's URI out of an object, in every spelling servers use.
  """
  @spec quoted_uri(map()) :: String.t() | nil
  def quoted_uri(object) when is_map(object) do
    object["quote"] || object["quoteUri"] || object["_misskey_quote"] ||
      object["quoteUrl"]
  end

  def quoted_uri(_object), do: nil

  @doc """
  Records that one post quotes another.
  """
  @spec record(Status.t(), String.t(), String.t() | nil) :: :ok
  def record(%Status{} = status, quoted_uri, approval_uri \\ nil) do
    now = DateTime.utc_now()
    quoted = Statuses.get_status_unchecked_by_uri(quoted_uri)

    Repo.insert_all(
      "quotes",
      [
        [
          status_id: status.id,
          quoted_status_id: quoted && quoted.id,
          quoted_status_uri: quoted_uri,
          approval_uri: approval_uri,
          state: "pending",
          inserted_at: now,
          updated_at: now
        ]
      ],
      on_conflict: {:replace, [:quoted_status_uri, :approval_uri, :updated_at]},
      conflict_target: [:status_id]
    )

    :ok
  end

  @doc """
  Checks an approval and marks the quote accepted if it holds up.

  Unapproved is left `pending` rather than deleted: the post is still a post,
  and a client can render it as a plain link. What it must not do is present it
  as endorsed.
  """
  @spec verify(Status.t(), keyword()) :: {:ok, :accepted | :pending} | {:error, term()}
  def verify(%Status{} = status, opts \\ []) do
    case quote_row(status.id) do
      nil -> {:ok, :pending}
      %{approval_uri: nil} -> {:ok, :pending}
      row -> check(status, row, opts)
    end
  end

  defp check(status, row, opts) do
    with {:ok, document} <- HTTP.fetch_json(row.approval_uri, opts),
         :ok <- check_type(document),
         :ok <- check_host(row, document, opts),
         :ok <- check_interacting_object(document, status),
         :ok <- check_interaction_target(document, row) do
      set_state(status.id, "accepted")

      {:ok, :accepted}
    else
      _ -> {:ok, :pending}
    end
  end

  defp check_type(%{"type" => "QuoteAuthorization"}), do: :ok
  defp check_type(_document), do: {:error, :not_an_authorization}

  # The approval has to come from the quoted author's own host. One hosted
  # anywhere else is an approval the author never gave.
  defp check_host(row, document, opts) do
    quoted_author = quoted_author_uri(row, opts)

    cond do
      is_nil(quoted_author) -> {:error, :unknown_quoted_author}
      URIs.same_host?(document["id"], quoted_author) -> :ok
      true -> {:error, :approval_from_wrong_host}
    end
  end

  defp quoted_author_uri(row, _opts) do
    with %Status{} = quoted <- Statuses.get_status_unchecked_by_uri(row.quoted_status_uri),
         account when not is_nil(account) <- Repo.get(Abuuba.Accounts.Account, quoted.account_id) do
      account.uri
    else
      # No local copy of the quoted post, so fall back to the host the quoted
      # URI itself names. Weaker, but still refuses an approval hosted
      # somewhere unrelated to the post being quoted.
      _ -> row.quoted_status_uri
    end
  end

  # An approval names exactly which post may quote which post. Without both
  # checks, one approval could be replayed for a different quote or reused to
  # quote everything that author ever wrote.
  defp check_interacting_object(document, status) do
    if same_uri?(document["interactingObject"], status.uri) do
      :ok
    else
      {:error, :approval_for_another_quote}
    end
  end

  defp check_interaction_target(document, row) do
    if same_uri?(document["interactionTarget"], row.quoted_status_uri) do
      :ok
    else
      {:error, :approval_for_another_post}
    end
  end

  # The one funnel for a quote's state, so the counter on the quoted post can
  # only ever move with it. Nudged by the difference between the old state and
  # the new rather than recomputed, like every other counter here, and only
  # ever when the state actually changes: a redelivered approval must not count
  # the same quote twice.
  defp set_state(status_id, state) do
    before = quote_row(status_id)

    from(q in "quotes", where: q.status_id == ^status_id)
    |> Repo.update_all(set: [state: state, updated_at: DateTime.utc_now()])

    if before && before.state != state && before.quoted_status_id do
      case {before.state, state} do
        {_old, "accepted"} -> Stats.bump_status(before.quoted_status_id, quotes_count: 1)
        {"accepted", _new} -> Stats.bump_status(before.quoted_status_id, quotes_count: -1)
        _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Marks a quote revoked, which is what an `Undo` of the approval means.
  """
  @spec revoke(integer()) :: :ok
  def revoke(status_id) do
    set_state(status_id, "revoked")

    :ok
  end

  @doc """
  Withdraws the approval for one particular quote of a post.

  `:error` when that post does not quote this one, so a caller cannot revoke an
  approval that was never given by naming any two ids it likes.
  """
  @spec revoke_for(Status.t(), integer() | nil) :: :ok | :error
  def revoke_for(%Status{id: quoted_id}, quoting_id) when is_integer(quoting_id) do
    case quote_row(quoting_id) do
      %{quoted_status_id: ^quoted_id} -> revoke(quoting_id)
      _ -> :error
    end
  end

  def revoke_for(%Status{}, _quoting_id), do: :error

  @doc """
  Whether an account may quote a post.

  A separate question from whether they may read it. A quote carries the post
  to the quoter's own audience with their words wrapped around it, which is not
  something reading it granted. `:nobody` means only the author, because
  quoting yourself reaches nobody the post did not already.
  """
  @spec allowed?(Account.t(), Status.t()) :: boolean()
  def allowed?(%Account{id: id}, %Status{account_id: id}), do: true
  def allowed?(_account, %Status{quote_policy: :nobody}), do: false
  def allowed?(_account, %Status{quote_policy: :public}), do: true

  def allowed?(%Account{} = account, %Status{quote_policy: :followers} = status) do
    # The quoter follows the author, not the other way round: the setting is
    # "people who follow me may quote me".
    Relationships.following?(account.id, status.account_id)
  end

  @doc """
  Records one of our own posts quoting another, already approved where it is
  ours to approve.

  A local quote of a local post needs nobody's permission but the quoted
  author's, and we are that author's server, so the approval is issued here
  rather than asked for. A local quote of a *remote* post is `pending` until
  their server says otherwise, which is the same state an inbound quote starts
  in.
  """
  @spec record_local(Status.t(), Status.t()) :: :ok
  def record_local(%Status{} = status, %Status{} = quoted) do
    if quoted.local do
      approve(status, quoted)
    else
      record(status, Serializer.status_uri(quoted), nil)
    end
  end

  @doc """
  Approves a quote of one of our own posts, whoever is doing the quoting.

  The row is what makes the approval answerable: the endpoint serving a
  `QuoteAuthorization` builds it from the quote, so an `Accept` sent without
  this names a document that answers 404 -- which is worse for the asker than
  a refusal, because it looks like permission until anybody checks.
  """
  @spec approve(Status.t(), Status.t()) :: :ok
  def approve(%Status{} = quoting, %Status{} = quoted) do
    before = state(quoting.id)

    :ok = record(quoting, Serializer.status_uri(quoted), authorization_uri(quoting, quoted))

    set_state(quoting.id, "accepted")

    # Only when it becomes a quote, so a redelivery or a re-approval does not
    # tell somebody twice about the same post.
    if before != "accepted", do: announce_quote(quoting, quoted)

    :ok
  end

  # The one door both paths go through: a local quote of a local post arrives
  # here from `record_local/2`, and a quote from another server from the
  # `QuoteRequest` handler.
  #
  # The type has been in the schema all along, the notifications screen has
  # known how to draw it, and the filtering policy has had an axis for it --
  # and nothing ever wrote the row, so being quoted was silent. Everything
  # about it looked finished from the outside, which is how it stayed that way.
  defp announce_quote(%Status{account_id: quoter_id, id: quoting_id}, %Status{} = quoted) do
    with %Account{} = author <- Repo.get(Account, quoted.account_id),
         true <- Account.local?(author),
         true <- author.id != quoter_id do
      Abuuba.Notifications.notify(author, quoter_id, "quote", status_id: quoting_id)
    end

    :ok
  end

  @doc """
  The id of the `QuoteAuthorization` this server issues for a quote of one of
  its own posts.

  Derived from the two posts rather than stored, like every other id here, so
  it survives a rebuild and cannot drift from the row it describes.
  """
  @spec authorization_uri(Status.t(), Status.t()) :: String.t()
  def authorization_uri(%Status{} = status, %Status{} = quoted) do
    "#{Serializer.status_uri(quoted)}/quote_authorizations/#{status.id}"
  end

  @doc """
  The post a status quotes, by id, or `nil`.
  """
  @spec quoted_status_id(Status.t()) :: integer() | nil
  def quoted_status_id(%Status{id: status_id}) do
    case quote_row(status_id) do
      %{quoted_status_id: id} -> id
      _ -> nil
    end
  end

  @doc """
  The approval a quote is riding on, or `nil` where it has none.
  """
  @spec approval_uri(Status.t()) :: String.t() | nil
  def approval_uri(%Status{id: status_id}) do
    case quote_row(status_id) do
      %{approval_uri: uri} -> uri
      _ -> nil
    end
  end

  @doc """
  The posts that quote a given one, newest first.

  Only the accepted ones. A pending quote is somebody asserting a relationship
  the quoted author has not agreed to, and listing it on their own post would
  publish the assertion for them.
  """
  @spec quoting(Status.t(), map()) :: [Status.t()]
  def quoting(%Status{id: quoted_id}, page \\ %{}) do
    ids =
      from(q in "quotes",
        where: q.quoted_status_id == ^quoted_id and q.state == "accepted",
        select: q.status_id
      )
      |> Repo.all()

    Statuses.not_deleted()
    |> where([s], s.id in ^ids)
    |> order_by([s], desc: s.id)
    |> limit(^Map.get(page, :limit, 40))
    |> Repo.all()
  end

  @doc """
  The accepted quotes for a page of posts, keyed by the quoting post's id.

  One query for the page rather than one per post. Rendering a timeline asks
  this once, and the entity module's query budget is what keeps it that way.
  """
  @spec accepted_by_status([integer()]) :: %{integer() => map()}
  def accepted_by_status([]), do: %{}

  def accepted_by_status(status_ids) do
    rows =
      from(q in "quotes",
        where: q.status_id in ^status_ids and q.state == "accepted",
        select: %{
          status_id: q.status_id,
          quoted_status_id: q.quoted_status_id,
          uri: q.quoted_status_uri
        }
      )
      |> Repo.all()

    quoted =
      rows
      |> Enum.map(& &1.quoted_status_id)
      |> Enum.reject(&is_nil/1)
      |> Statuses.get_statuses()
      |> Map.new(&{&1.id, &1})

    Map.new(rows, fn row ->
      {row.status_id, %{status: Map.get(quoted, row.quoted_status_id), uri: row.uri}}
    end)
  end

  @doc """
  The quote a post makes, as far as anybody is entitled to see it.

  `nil` when the post quotes nothing, and when it quotes something whose author
  has not approved: an unapproved quote renders as an ordinary post, which is
  what keeps somebody from putting words in another person's mouth by asserting
  a quote they were refused.
  """
  @spec accepted_quote(Status.t()) :: %{status: Status.t() | nil, uri: String.t()} | nil
  def accepted_quote(%Status{id: status_id}) do
    case quote_row(status_id) do
      %{state: "accepted"} = row ->
        %{
          status: Statuses.get_status_unchecked_by_uri(row.quoted_status_uri),
          uri: row.quoted_status_uri
        }

      _ ->
        nil
    end
  end

  @doc """
  The state of a status's quote, or `nil` if it does not quote anything.
  """
  @spec state(integer()) :: String.t() | nil
  def state(status_id) do
    case quote_row(status_id) do
      nil -> nil
      row -> row.state
    end
  end

  defp quote_row(status_id) do
    from(q in "quotes",
      where: q.status_id == ^status_id,
      select: %{
        status_id: q.status_id,
        quoted_status_id: q.quoted_status_id,
        quoted_status_uri: q.quoted_status_uri,
        approval_uri: q.approval_uri,
        state: q.state
      }
    )
    |> Repo.one()
  end

  defp same_uri?(a, b) when is_binary(a) and is_binary(b) do
    String.downcase(String.trim_trailing(a, "/")) == String.downcase(String.trim_trailing(b, "/"))
  end

  defp same_uri?(%{"id" => id}, b), do: same_uri?(id, b)
  defp same_uri?(_a, _b), do: false
end
