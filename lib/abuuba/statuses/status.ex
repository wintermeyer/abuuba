defmodule Abuuba.Statuses.Status do
  @moduledoc """
  A post, a boost, or a reply. All three are rows in this table.

  A boost is a status whose `reblog_of_id` points at the boosted status and
  which carries no text of its own. Keeping it here rather than in a separate
  table is what lets a timeline be one ordered scan over one table, with posts
  and boosts already interleaved.

  Deletion is soft. A status has to outlive its own deletion: the `Delete`
  activity may still be travelling to other servers, and replies or boosts
  elsewhere may still point at it. Every query therefore goes through
  `Abuuba.Statuses.visible/0` rather than the bare schema.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Accounts.Account
  alias Abuuba.Federation.Limits
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Conversation
  alias Abuuba.Statuses.Formatter
  alias Abuuba.Statuses.Mention
  alias Abuuba.Statuses.Status
  alias Abuuba.Statuses.Tag

  @visibilities [
    public: "public",
    unlisted: "unlisted",
    private: "private",
    direct: "direct",
    limited: "limited"
  ]

  # Who may quote a post, which is a separate question from who may read it.
  # Posting in the open is not the same as agreeing to be carried off under
  # somebody else's commentary.
  @quote_policies [:public, :followers, :nobody]

  @primary_key {:id, Snowflake, autogenerate: false, read_after_writes: true}
  @foreign_key_type Snowflake

  schema "statuses" do
    field :uri, :string
    field :url, :string
    field :local, :boolean, default: true

    # The app this was written in, for local posts. Shown under the post as
    # "via <name>" unless the author has turned that off; see
    # `Abuuba.Accounts.PostingDefaults`.
    field :application_id, :id

    field :text, :string, default: ""
    field :spoiler_text, :string, default: ""
    field :language, :string
    # Kept in step by Postgres itself; see the search migration for why it is a
    # generated column rather than a trigger.
    field :searchable, Abuuba.Search.TSVector, load_in_query: false
    field :sensitive, :boolean, default: false
    field :visibility, Ecto.Enum, values: @visibilities, default: :public
    field :quote_policy, Ecto.Enum, values: @quote_policies, default: :public

    field :deleted_at, :utc_datetime_usec
    field :edited_at, :utc_datetime_usec
    # Written here, published somewhere else, years ago. See the migration:
    # this is what the fan-out, the delivery queue and the trends reader check
    # before treating a post as new.
    field :imported_at, :utc_datetime_usec

    field :ordered_media_attachment_ids, {:array, :integer}, default: []

    belongs_to :account, Account
    belongs_to :reblog_of, Status
    belongs_to :in_reply_to, Status
    belongs_to :in_reply_to_account, Account
    belongs_to :conversation, Conversation, type: :id

    has_many :mentions, Mention
    many_to_many :tags, Tag, join_through: "statuses_tags"

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @castable ~w(account_id uri url local text spoiler_text language sensitive
               visibility quote_policy reblog_of_id in_reply_to_id in_reply_to_account_id
               conversation_id ordered_media_attachment_ids edited_at application_id)a

  @never_null ~w(text spoiler_text local sensitive ordered_media_attachment_ids)a

  @doc """
  Changeset for a post read back in from somebody's own archive.

  The same validations, plus the three things only an import sets: its own id
  and timestamps, which are the post's original date, and the mark that keeps
  it out of everybody's timeline and off the network.

  `validate_local_length/1` still applies. A post that was too long for this
  server is one this server cannot show properly, and silently storing it would
  be worse than saying so.
  """
  def import_changeset(status, attrs) do
    status
    |> changeset(attrs)
    |> cast(attrs, [:id, :imported_at, :inserted_at, :updated_at])
    |> validate_required([:imported_at, :id])
    # An id is a time, and two posts published in the same millisecond want the
    # same one. The importer answers a conflict by moving to the next sequence
    # rather than by dropping a post, which needs the clash back as a
    # changeset instead of as a raised constraint error.
    |> unique_constraint(:id, name: :statuses_pkey)
  end

  @doc """
  Changeset for a status.
  """
  def changeset(status, attrs) do
    status
    |> cast(attrs, @castable)
    |> validate_required([:account_id, :visibility])
    |> reject_null_changes(@never_null)
    |> validate_local_length()
    |> validate_spoiler_length()
    |> derive_sensitive()
    |> validate_language()
    |> validate_boost()
    |> unique_constraint(:uri)
    |> unique_constraint([:account_id, :reblog_of_id],
      name: :statuses_one_boost_per_account_index
    )
    |> check_constraint(:visibility, name: :statuses_visibility_known)
    |> check_constraint(:quote_policy, name: :statuses_quote_policy_known)
    |> check_constraint(:reblog_of_id, name: :statuses_boosts_have_no_content)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:reblog_of_id)
    |> foreign_key_constraint(:in_reply_to_id)
    |> foreign_key_constraint(:conversation_id)
  end

  # A content warning means the post is sensitive, whatever the client said.
  #
  # Every reader decides whether to open a warned post by that flag: an app
  # blurs the picture behind it, and so does every other server we deliver to.
  # A post that carried a warning and said `sensitive: false` was showing the
  # picture somebody had warned about, here and everywhere it went.
  #
  # Local posts only. A remote one carries whatever its own server decided, and
  # deciding differently on their behalf would be answering for them.
  defp derive_sensitive(changeset) do
    warned? = get_field(changeset, :spoiler_text) not in [nil, ""]

    if get_field(changeset, :local) and warned? do
      put_change(changeset, :sensitive, true)
    else
      changeset
    end
  end

  # A boost is a pointer with an author. Text on one would never be shown,
  # because every renderer reads through to the boosted status, so accepting it
  # would silently discard what somebody wrote.
  defp validate_boost(changeset) do
    if get_field(changeset, :reblog_of_id) do
      changeset
      |> reject_content(:text)
      |> reject_content(:spoiler_text)
    else
      changeset
    end
  end

  defp reject_content(changeset, field) do
    case get_field(changeset, field) do
      value when value in [nil, ""] -> changeset
      _ -> add_error(changeset, field, "a boost carries no text of its own")
    end
  end

  # BCP 47 is broader than this, but a language tag reaching us is either a
  # two- or three-letter code or a code with a region, and anything else is a
  # client bug we would rather reject than store and render.
  # Only our own posts, and measured the way the composer's counter measures,
  # so that a counter saying there is room left cannot be followed by a save
  # that fails. Another server's limit is theirs: refusing a longer post here
  # would lose it, and every reply to it would then point at nothing.
  @doc """
  Who may quote a post.
  """
  @spec quote_policies() :: [atom()]
  def quote_policies, do: @quote_policies

  # Ours are capped at 500 and theirs are not capped at all on most
  # implementations. Applying our number to a post somebody else wrote refused
  # the whole post over its warning -- content dropped rather than cut, which
  # is the opposite of what `Abuuba.Federation.Limits` is for. The inbound path
  # truncates instead, so what arrives here is already bounded.
  defp validate_spoiler_length(changeset) do
    if get_field(changeset, :local) do
      validate_length(changeset, :spoiler_text, max: 500)
    else
      validate_length(changeset, :spoiler_text, max: Limits.spoiler_characters())
    end
  end

  defp validate_local_length(changeset) do
    if get_field(changeset, :local) do
      # The warning counts towards the same limit as the body, which is what
      # upstream does and what every client's counter is drawn against. Read
      # off the changeset rather than passed in, because a validator on `:text`
      # only sees the text.
      warning = get_field(changeset, :spoiler_text) || ""

      validate_change(changeset, :text, &over_limit(&1, &2, warning))
    else
      changeset
    end
  end

  defp over_limit(:text, text, warning) do
    limit = Abuuba.Instance.max_characters()

    if Formatter.length(text) + Formatter.length(warning) > limit do
      [text: {"should be at most %{count} character(s)", count: limit, kind: :max}]
    else
      []
    end
  end

  defp validate_language(changeset) do
    validate_format(changeset, :language, ~r/\A[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*\z/)
  end

  defp reject_null_changes(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case fetch_change(acc, field) do
        {:ok, nil} -> add_error(acc, field, "can't be null")
        _ -> acc
      end
    end)
  end

  @doc """
  Whether the status has been soft-deleted.
  """
  def deleted?(%Status{deleted_at: nil}), do: false
  def deleted?(%Status{}), do: true

  @doc """
  Whether the status is a boost of another.
  """
  def boost?(%Status{reblog_of_id: nil}), do: false
  def boost?(%Status{}), do: true

  @doc """
  Whether the status is a reply.
  """
  def reply?(%Status{in_reply_to_id: nil}), do: false
  def reply?(%Status{}), do: true

  @doc """
  The visibilities a status may have, widest first.
  """
  def visibilities, do: Keyword.keys(@visibilities)
end
