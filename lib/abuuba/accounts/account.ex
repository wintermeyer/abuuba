defmodule Abuuba.Accounts.Account do
  @moduledoc """
  An actor, local or remote.

  Both live in one table and an account is local exactly when its `domain` is
  `nil`. That is the single most load-bearing decision in the schema: a follow,
  a mention, a block or a favourite is then one foreign key rather than a
  polymorphic pair, and the client API can hand out the same shape for either.

  Ids below zero are reserved for actors abuuba creates for itself, see
  `Abuuba.Accounts.instance_actor_id/0`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Abuuba.Federation.Limits

  alias Abuuba.Accounts.Account
  alias Abuuba.Snowflake
  alias Abuuba.Statuses.Formatter

  # Mastodon's rule, and the one every fediverse client already assumes when it
  # parses an @handle. Deliberately narrower than what other servers accept, so
  # a local username can never need escaping in a URL or a WebFinger query.
  @username_format ~r/\A[a-zA-Z0-9_]+\z/
  @username_max 30
  # The ceiling for names this server did not choose. Long enough that no real
  # server is refused -- a domain cannot exceed 253 characters and no
  # implementation names accounts near that -- and **not** the reference
  # implementation's 2048, because `username` is `varchar(255)` here. A
  # validation that allowed more than the column would turn a refusal into a
  # Postgres 22001 on the untrusted path, which is a 500 where a 422 belongs.
  # Raise the column first if this ever needs to be higher.
  @username_hard_max 255

  # What somebody may put on their own profile here. A remote actor is held to
  # the reference implementation's much larger limits instead; see
  # `validate_profile_lengths/1`.
  @display_name_max 30
  @note_max 500
  @fields_max 4
  # The reference implementation's number. The list is walked once per link
  # preview, so it is bounded rather than left to grow.
  @attribution_domains_max 100
  @field_name_max 255
  @field_value_max 2_047

  # Internal actors are named after the host they speak for, so they carry the
  # dots and hyphens a hostname has. Still no slashes, spaces or percent signs:
  # the name goes into a URL and a WebFinger query either way.
  # The reference implementation's shape: dots and hyphens join runs of
  # ordinary characters rather than standing on their own, so `abuuba.interop`
  # and `sub.example.com` pass and `..`, `-` and `alice.` do not. Being laxer
  # than that would let a peer name an account something that renders as a
  # handle nobody can read or repeat.
  @internal_username_format ~r/\A[a-zA-Z0-9_]+([.-]+[a-zA-Z0-9_]+)*\z/

  @actor_types [
    person: "Person",
    service: "Service",
    group: "Group",
    organization: "Organization",
    application: "Application"
  ]

  @primary_key {:id, Snowflake, autogenerate: false, read_after_writes: true}
  @foreign_key_type Snowflake

  schema "accounts" do
    field :username, :string
    field :domain, :string

    field :actor_type, Ecto.Enum, values: @actor_types, default: :person
    field :display_name, :string, default: ""
    field :note, :string, default: ""

    field :uri, :string
    field :url, :string
    field :inbox_url, :string
    field :shared_inbox_url, :string
    field :outbox_url, :string
    field :followers_url, :string
    field :following_url, :string

    field :suspended_at, :utc_datetime_usec
    # When a suspended account's content stops being kept. Null unless a
    # suspension is standing; see `Abuuba.Moderation.Actions`.
    field :purge_after, :utc_datetime_usec
    field :silenced_at, :utc_datetime_usec
    # Kept in step by Postgres itself; see the search migration for why it is a
    # generated column rather than a trigger.
    field :searchable, Abuuba.Search.TSVector, load_in_query: false
    # Whether this account's posts may appear in the trending lists. Null until
    # somebody decides; see `Abuuba.Trends`.
    field :trendable, :boolean
    field :sensitized_at, :utc_datetime_usec

    field :also_known_as, {:array, :string}, default: []

    field :locked, :boolean, default: false
    field :bot, :boolean, default: false
    field :discoverable, :boolean, default: false
    field :indexable, :boolean, default: false
    field :attribution_domains, {:array, :string}, default: []
    field :hide_collections, :boolean, default: false

    # One of each per account, replaced rather than added to, and read on every
    # render of every post its owner wrote. See `Abuuba.Media.ProfileImages`.
    field :avatar_file_name, :string
    field :avatar_content_type, :string
    field :avatar_file_size, :integer
    field :avatar_updated_at, :utc_datetime_usec
    field :avatar_remote_url, :string

    field :header_file_name, :string
    field :header_content_type, :string
    field :header_file_size, :integer
    field :header_updated_at, :utc_datetime_usec
    field :header_remote_url, :string
    field :last_fetched_at, :utc_datetime_usec
    field :moved_at, :utc_datetime_usec

    # The account's owner has died. Not a moderation action: nothing is hidden
    # and nothing is removed, only signing in stops. See the migration.
    field :memorial, :boolean, default: false

    # What one moderator wants the next one to know. Never shown to the account
    # it is about, and never sent anywhere; see the migration.
    field :moderation_note, :string

    # Which URI shape this account's actor id uses. See the migration.
    field :id_scheme, Ecto.Enum,
      values: [username: "username", numeric: "numeric"],
      default: :username

    belongs_to :moved_to_account, Account

    embeds_many :fields, Field, on_replace: :delete, primary_key: false do
      field :name, :string
      field :value, :string
      field :verified_at, :utc_datetime_usec

      # When this server last managed to read the linked page, whatever it
      # found there. Separate from `verified_at`, which records only success:
      # without it the periodic re-check has no way to tell a link it has never
      # looked at from one it looked at this morning and found wanting, and
      # would refetch every unverified link on every sweep. Local fields only,
      # never published and never part of the API entity.
      field :checked_at, :utc_datetime_usec
    end

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A persisted `%__MODULE__{}` struct."
  @type t :: %__MODULE__{}

  @castable ~w(username domain actor_type display_name note uri url inbox_url
               shared_inbox_url outbox_url followers_url following_url
               suspended_at silenced_at sensitized_at also_known_as locked bot
               discoverable indexable memorial hide_collections id_scheme
               attribution_domains last_fetched_at
               moved_at
               moved_to_account_id
               avatar_file_name avatar_content_type avatar_file_size
               avatar_updated_at avatar_remote_url
               header_file_name header_content_type header_file_size
               header_updated_at header_remote_url)a

  # NOT NULL in the database. Without these, a JSON body carrying an explicit
  # `null` reaches Postgres as one and comes back a 23502 crash instead of a
  # validation error, and that body arrives on the untrusted path.
  @never_null ~w(display_name note also_known_as locked bot discoverable indexable
                 memorial hide_collections)a

  @doc """
  Changeset for creating or updating an account from trusted input.

  "Trusted" means our own code: a registration flow, or the fields parsed out
  of a remote actor document. It casts everything an account has, including
  moderation state and the federation endpoints, so it must never be handed
  parameters that came from the account's owner. Those go through
  `profile_changeset/2`, which reaches only the fields a person may edit about
  themselves.
  """
  def changeset(account, attrs) do
    account
    |> cast(attrs, @castable)
    |> validate_required([:username])
    |> reject_null_changes(@never_null)
    |> validate_username_format()
    |> validate_username_length()
    |> validate_domain()
    |> validate_profile_lengths()
    |> unique_constraint([:username, :domain], name: :accounts_username_domain_index)
    |> check_constraint(:fields, name: :accounts_field_count)
    |> check_constraint(:id, name: :accounts_internal_actors_are_local)
    |> foreign_key_constraint(:moved_to_account_id)
  end

  # Somebody else's naming is their business. A remote account's username is
  # whatever their server put in `preferredUsername`, and a peer's *instance*
  # actor is named after its domain -- `mastodon.interop`, dots and all. The
  # strict rule refused it, so abuuba could not store the actor, could not
  # resolve its key, and answered 401 to everything it signs: forwarded
  # moderation reports, which is a report somebody filed about abuse here that
  # no moderator here would ever see.
  #
  # Application actors get the same latitude wherever they live, because ours
  # is named after this domain for the same reason theirs is. That split is
  # where the reference implementation draws it too.
  # Thirty is our limit for our own names. Somebody else's is their business,
  # and a peer whose domain runs past thirty characters would otherwise have an
  # instance actor this server cannot store -- which is the same refusal that
  # was losing forwarded moderation reports, arriving by a different door. The
  # hard limit is the reference implementation's, and exists so that "no limit"
  # is not the answer either.
  defp validate_username_length(changeset) do
    max = if lenient_username?(changeset), do: @username_hard_max, else: @username_max

    validate_length(changeset, :username, max: max)
  end

  defp lenient_username?(changeset) do
    get_field(changeset, :domain) != nil or get_field(changeset, :actor_type) == :application
  end

  defp validate_username_format(changeset) do
    format =
      if lenient_username?(changeset), do: @internal_username_format, else: @username_format

    validate_format(changeset, :username, format)
  end

  # Our limits for our own accounts, and the reference implementation's for
  # everybody else's. Enforcing ours on a remote actor is not caution, it is a
  # refusal to federate: an actor whose display name runs past thirty
  # characters would never resolve, and the account would look to its owner
  # like this server had blocked them.
  #
  # `validate_domain/1` has to have run first, since it decides which of the
  # two sets applies.
  defp validate_profile_lengths(changeset) do
    if remote?(changeset) do
      changeset
      |> clean_remote_note()
      |> cast_embed(:fields, with: &remote_field_changeset/2)
      |> validate_length(:display_name, max: Limits.name_characters())
      |> validate_length(:note, count: :bytes, max: Limits.summary_bytes())
      |> validate_length(:fields, max: Limits.field_count())
    else
      changeset
      |> cast_embed(:fields, with: &field_changeset/2)
      |> validate_length(:display_name, max: @display_name_max)
      |> validate_length(:note, max: @note_max)
      |> validate_length(:fields, max: @fields_max)
    end
  end

  # Their bio and their fields are HTML written by somebody we have no reason to
  # trust, and both end up inside a reader's page. Cleaned on the way in rather
  # than at each place that renders one, so there is one place it happens and
  # no renderer has to remember. Our own are plain text and are escaped when
  # they are rendered, so cleaning them here would eat a typed "<3".
  defp clean_remote_note(changeset) do
    case fetch_change(changeset, :note) do
      {:ok, note} when is_binary(note) -> put_change(changeset, :note, Formatter.sanitize(note))
      _ -> changeset
    end
  end

  defp clean_field_value(changeset) do
    case fetch_change(changeset, :value) do
      {:ok, value} when is_binary(value) ->
        put_change(changeset, :value, Formatter.sanitize(value))

      _ ->
        changeset
    end
  end

  defp remote?(changeset) do
    not is_nil(get_field(changeset, :domain))
  end

  # What a person may change about their own profile. Notably absent:
  # `username` and `domain`, which decide who the account is; the moderation
  # timestamps, which would let a suspended account lift its own suspension;
  # and every federation endpoint, which belongs to whoever hosts the actor.
  # `also_known_as` is here because it is a claim about somebody's own other
  # accounts, which only they can make. It is what a move is checked against,
  # and the check is mutual: naming an account here does nothing until that
  # account names this one back.
  @editable ~w(display_name note locked bot discoverable indexable hide_collections
               attribution_domains
               also_known_as)a

  @doc """
  Changeset for the fields an account's owner may edit about themselves.

  This is the one to use with parameters from a form or an API request.
  """
  def profile_changeset(account, attrs) do
    account
    |> cast(attrs, @editable)
    |> cast_embed(:fields, with: &field_changeset/2)
    |> carry_over_verifications()
    |> normalise_attribution_domains()
    |> reject_null_changes(@never_null)
    |> validate_length(:display_name, max: @display_name_max)
    |> validate_length(:note, max: @note_max)
    |> validate_length(:fields, max: @fields_max)
    |> check_constraint(:fields, name: :accounts_field_count)
  end

  @doc """
  Records what fetching this account's profile links found.

  The one door to `verified_at` and `checked_at` on a local field, and it takes
  whole `%Field{}` structs rather than parameters, so that nothing which
  handles user input can reach it by accident. See `Abuuba.Accounts.LinkVerification`.
  """
  def link_verification_changeset(account, fields) when is_list(fields) do
    account |> change() |> put_embed(:fields, fields)
  end

  # What somebody types is an address, not a domain: they paste
  # `https://example.com/`, or write `*.example.com` because that is how the
  # reference implementation spells "and its subdomains". Both are stored as
  # the bare domain, which is what the preview card has to match against, and
  # what a subdomain check can walk up to.
  #
  # Capped, because the list is walked per link and an unbounded one is a slow
  # request somebody else pays for.
  defp normalise_attribution_domains(changeset) do
    case get_change(changeset, :attribution_domains) do
      nil ->
        changeset

      domains ->
        cleaned =
          domains
          |> Enum.map(&normalise_attribution_domain/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        changeset
        |> put_change(:attribution_domains, cleaned)
        |> validate_length(:attribution_domains, max: @attribution_domains_max)
        |> validate_attribution_domain_shape(cleaned)
    end
  end

  # Something that could be a host, rather than a path, a sentence, or a bare
  # `com` that would match every address on the internet. Not a full domain
  # validator: this is somebody describing their own site, and the check is
  # here to catch a typo before it silently matches nothing.
  defp validate_attribution_domain_shape(changeset, domains) do
    if Enum.all?(
         domains,
         &(&1 =~ ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/)
       ) do
      changeset
    else
      add_error(changeset, :attribution_domains, "must be domain names")
    end
  end

  defp normalise_attribution_domain(domain) do
    domain
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
    |> String.replace_prefix("*.", "")
    |> String.trim_trailing("/")
  end

  # `fields` is replaced wholesale on every save, so without this a person who
  # only changed their display name would come back from the edit form with the
  # tick beside an unchanged link gone. Matched on the value, because the value
  # is what was fetched; renaming the label leaves the evidence intact.
  defp carry_over_verifications(changeset) do
    previous = Map.new(changeset.data.fields || [], &{&1.value, &1})

    update_change(changeset, :fields, fn field_changesets ->
      Enum.map(field_changesets, &carry_over(&1, previous))
    end)
  end

  defp carry_over(field_changeset, previous) do
    case Map.get(previous, get_field(field_changeset, :value)) do
      nil ->
        field_changeset

      %{verified_at: verified_at, checked_at: checked_at} ->
        field_changeset
        |> put_change(:verified_at, verified_at)
        |> put_change(:checked_at, checked_at)
    end
  end

  @doc """
  Changeset for moderation state, which only a moderator may set.
  """
  def moderation_changeset(account, attrs) do
    cast(
      account,
      attrs,
      ~w(suspended_at silenced_at sensitized_at purge_after trendable memorial)a
    )
  end

  @doc """
  Changeset for an actor the server owns rather than a person, such as the
  instance actor.

  Two things differ from `changeset/2`. The id is assignable, because these
  actors sit at fixed ids in the reserved range instead of taking one from the
  database, and other servers cache them by URL so the id has to survive a
  rebuild. And the username may look like a hostname, since naming the instance
  actor after its host is what the rest of the fediverse expects to see.

  The id is never castable in `changeset/2`: letting user-supplied parameters
  choose a primary key is how one account overwrites another.
  """
  def internal_changeset(account, attrs) do
    account
    |> cast(attrs, @castable)
    |> put_internal_id(attrs)
    |> validate_required([:id, :username])
    |> validate_format(:username, @internal_username_format)
    |> validate_length(:username, max: 255)
    |> validate_local()
    |> validate_length(:display_name, max: 30)
    |> validate_length(:note, max: 500)
    |> unique_constraint([:username, :domain], name: :accounts_username_domain_index)
    |> check_constraint(:id, name: :accounts_internal_actors_are_local)
  end

  # Set rather than cast. `Abuuba.Snowflake` refuses a negative id on purpose,
  # because that is the right answer for an id arriving from an API client, and
  # the reserved range is precisely the case where the value is ours and not
  # theirs. Keeping this out of `cast/3` also keeps `:id` unreachable from
  # user-supplied parameters.
  defp put_internal_id(changeset, attrs) do
    case fetch_attr(attrs, :id) do
      {:ok, id} when is_integer(id) and id < 0 -> put_change(changeset, :id, id)
      {:ok, _other} -> add_error(changeset, :id, "must be a negative integer")
      :error -> changeset
    end
  end

  defp fetch_attr(attrs, key) do
    with :error <- Map.fetch(attrs, key) do
      Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp validate_local(changeset) do
    case get_field(changeset, :domain) do
      nil -> changeset
      _ -> add_error(changeset, :domain, "must be blank for an actor this server owns")
    end
  end

  # `verified_at` is deliberately not castable. It records that this server
  # fetched the link and found a `rel="me"` pointing back, which is an
  # assertion only the server may make. Casting it would let an account award
  # itself a verification tick next to any URL it likes.
  defp field_changeset(field, attrs) do
    bounded_field_changeset(field, attrs, @field_name_max, @field_value_max)
  end

  # A remote server sets its own limits, and cutting a field to ours would
  # corrupt what it published rather than protect anybody.
  #
  # `verified_at` is taken as published for a remote field and refused for a
  # local one. Another server's verification is that server's to assert and
  # ours only to display; our own has to be earned by fetching the linked page
  # and finding a link back, which is its own piece of work.
  defp remote_field_changeset(field, attrs) do
    field
    |> bounded_field_changeset(attrs, Limits.field_characters(), Limits.field_characters())
    |> cast(attrs, [:verified_at])
    |> clean_field_value()
  end

  defp bounded_field_changeset(field, attrs, name_max, value_max) do
    field
    |> cast(attrs, [:name, :value])
    |> validate_required([:name, :value])
    |> validate_length(:name, max: name_max)
    |> validate_length(:value, max: value_max)
  end

  # A hostname is case-insensitive and has no surrounding space, so it is
  # normalised on the way in rather than at every place that compares or
  # renders one. An empty string becomes nil: it would otherwise make the
  # account look remote on a host named "", which no query could match while it
  # still occupies the local slot in the unique index.
  # Not `validate_required/2`, which also rejects "". An empty display name or
  # an empty bio is perfectly ordinary; only an explicit null is the problem,
  # because the column forbids it and Postgres would answer with a crash.
  defp reject_null_changes(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case fetch_change(acc, field) do
        {:ok, nil} -> add_error(acc, field, "can't be null")
        _ -> acc
      end
    end)
  end

  defp validate_domain(changeset) do
    case get_change(changeset, :domain) do
      nil ->
        changeset

      domain ->
        case domain |> String.trim() |> String.downcase() do
          "" -> put_change(changeset, :domain, nil)
          normalised -> put_change(changeset, :domain, normalised)
        end
    end
  end

  @doc """
  Whether the account lives on this server.
  """
  def local?(%Account{domain: nil}), do: true
  def local?(%Account{}), do: false

  @doc """
  The `user@host` form, with the host omitted for local accounts, exactly as
  the client API's `acct` field reports it.
  """
  def acct(%Account{username: username, domain: nil}), do: username
  def acct(%Account{username: username, domain: domain}), do: "#{username}@#{domain}"

  @doc """
  The name to show for an account, falling back to the username.

  `display_name` is optional and blank far more often than it looks, so every
  screen that renders an account needs this fallback. It lives here because it
  was written out privately in eleven modules, in two spellings, and the most
  rendered string in the product should have one definition.
  """
  def display_name(%Account{display_name: name}) when is_binary(name) and name != "", do: name
  def display_name(%Account{username: username}), do: username

  @doc """
  The pattern a username must match.

  Exposed so that the signup form checks the same rule the schema does; two
  copies of it would drift, and the one that drifted would let somebody through
  the form only to be refused at the insert.
  """
  def username_format, do: @username_format

  @doc """
  The longest a username may be.
  """
  def username_max, do: @username_max

  @doc """
  The actor types an account may have.
  """
  def actor_types, do: Keyword.keys(@actor_types)

  @doc """
  The type behind an ActivityPub `type`, which arrives capitalised.

  Anything unrecognised is a Person: an actor whose type this server has never
  heard of is still somebody who posts, and refusing to represent them at all
  would be a worse answer than a plain one.

  One definition, read from the same list the column validates against, so a
  type added there cannot be missed by the fetcher or by the import.
  """
  @spec actor_type(String.t() | nil) :: atom()
  def actor_type(type) do
    Enum.find_value(@actor_types, :person, fn {atom, name} -> name == type and atom end)
  end

  @doc """
  Whether a type means "not a person at the keyboard".

  What the `bot` flag on the account records, and the reason it is derived
  rather than asked for: an actor that says it is a Service has already
  answered the question.
  """
  @spec bot?(atom() | String.t() | nil) :: boolean()
  def bot?(type) when is_atom(type), do: type in [:service, :application]
  def bot?(type), do: type |> actor_type() |> bot?()

  @doc """
  Hides an account that is being closed, and sets the day it is deleted.

  Suspended rather than deleted on the spot: the row has to outlive the
  `Delete` this server is queueing for its peers, because the key that signs
  those deliveries lives on it. Nothing of the account is reachable meanwhile.
  See `Abuuba.Accounts.Deletion`.
  """
  @spec closing_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def closing_changeset(%__MODULE__{} = account, purge_after) do
    change(account, suspended_at: DateTime.utc_now(), purge_after: purge_after)
  end
end
