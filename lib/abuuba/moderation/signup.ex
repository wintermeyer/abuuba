defmodule Abuuba.Moderation.Signup do
  @moduledoc """
  What a server refuses at the door.

  ## Three answers, not two

  `:ok` lets somebody in, `{:error, reason}` turns them away, and
  `{:approval, reason}` lets them fill in the form and puts them in the queue a
  moderator reads. The middle answer is the one that gets used: most of what an
  admin actually wants is "make these ones ask", and a server with only a yes
  and a no ends up shutting out a university because one person there was a
  nuisance.

  A refusal always beats a request for approval. If two lists disagree, the
  stricter one is the decision that was taken most deliberately.

  ## Domains are blocked by name and by where their mail goes

  A disposable-address service runs a thousand domains off one set of MX
  records. Blocking them one at a time is a game nobody wins, so a domain whose
  mail servers sit under a blocked domain is blocked too. The lookup is passed
  in rather than hard-wired, so nothing here depends on DNS in a test and a
  deployment can point it at its own resolver.

  ## Addresses are stored as hashes

  The canonical list exists to recognise somebody who was suspended coming
  back, which needs a comparison and not the ability to read the addresses back
  out. It is normalised first, so `a.b+spam@gmail.com` and `ab@gmail.com` are
  one person, and only at the providers where a dot really means nothing.
  """

  import Ecto.Query

  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Deletion
  alias Abuuba.Accounts.User
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.Signup.CanonicalEmailBlock
  alias Abuuba.Moderation.Signup.EmailDomainBlock
  alias Abuuba.Moderation.Signup.IPBlock
  alias Abuuba.Moderation.Signup.UsernameBlock
  alias Abuuba.Pagination
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings

  # Providers where a dot in the local part means nothing. Folding dots
  # everywhere would block strangers who happen to share a spelling.
  @dotless_providers ~w(gmail.com googlemail.com)

  # How long a server may go unattended before it stops taking sign-ups on its
  # own. Long enough that a holiday is not a lockout, short enough that a
  # forgotten server does not spend a month filling with spam.
  @unattended_days 7

  @doc """
  Whether this sign-up may go ahead.

  Pass whichever of `:email`, `:ip` and `:username` the caller has; a key that
  is absent is not checked rather than being treated as empty.
  """
  @spec check(map(), keyword()) :: :ok | {:approval, atom()} | {:error, atom()}
  def check(attrs, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    [
      username_answer(attrs[:username] || attrs["username"]),
      ip_answer(attrs[:ip] || attrs["ip"], now),
      email_answer(attrs[:email] || attrs["email"], opts)
    ]
    |> Enum.reduce(:ok, &strictest/2)
  end

  # A refusal beats a request for approval beats a yes.
  defp strictest({:error, _reason} = refusal, _acc), do: refusal
  defp strictest(_answer, {:error, _reason} = refusal), do: refusal
  defp strictest({:approval, _reason} = approval, :ok), do: approval
  defp strictest(:ok, acc), do: acc
  defp strictest(_answer, acc), do: acc

  @doc """
  Whether an address may reach this server at all.

  Only the hardest severity. A sign-up block is about registering, not about
  reading, and turning one into the other would quietly wall off everybody
  behind a shared address.
  """
  @spec blocked_from_access?(String.t() | nil, DateTime.t()) :: boolean()
  def blocked_from_access?(address, now \\ DateTime.utc_now())
  def blocked_from_access?(nil, _now), do: false

  def blocked_from_access?(address, now) do
    address
    |> matching_ip_blocks(now)
    |> Enum.any?(&(&1.severity == "no_access"))
  end

  ## Email domains

  @doc """
  Blocks a mail domain.
  """
  @spec block_email_domain(Account.t(), map()) ::
          {:ok, EmailDomainBlock.t()} | {:error, Ecto.Changeset.t()}
  def block_email_domain(%Account{} = actor, attrs) do
    with {:ok, block} <-
           %EmailDomainBlock{} |> EmailDomainBlock.changeset(attrs) |> Repo.insert() do
      log(actor, "signup.block_email_domain", block.domain)

      {:ok, block}
    end
  end

  @doc "Every blocked mail domain, newest first."
  @spec email_domain_blocks(map() | nil) :: [EmailDomainBlock.t()]
  def email_domain_blocks(page \\ nil)

  def email_domain_blocks(nil), do: EmailDomainBlock |> order_by([b], desc: b.id) |> Repo.all()

  def email_domain_blocks(page) do
    EmailDomainBlock
    |> Pagination.window(page)
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  @doc """
  One of them by id, or `nil`.
  """
  @spec get_email_domain_block(term()) :: EmailDomainBlock.t() | nil
  def get_email_domain_block(id), do: fetch(EmailDomainBlock, id)

  @doc "Lifts one."
  @spec unblock_email_domain(Account.t(), EmailDomainBlock.t()) :: :ok
  def unblock_email_domain(%Account{} = actor, %EmailDomainBlock{} = block) do
    Repo.delete(block)
    log(actor, "signup.unblock_email_domain", block.domain)

    :ok
  end

  ## Canonical addresses

  @doc """
  Blocks one address, stored as a hash of its normalised form.
  """
  @spec block_email(Account.t(), String.t(), integer() | nil) ::
          {:ok, CanonicalEmailBlock.t()} | {:error, Ecto.Changeset.t()}
  def block_email(%Account{} = actor, email, reference_account_id \\ nil) do
    attrs = %{
      canonical_email_hash: hash(canonical(email)),
      reference_account_id: reference_account_id
    }

    with {:ok, block} <-
           %CanonicalEmailBlock{} |> CanonicalEmailBlock.changeset(attrs) |> Repo.insert() do
      # The address itself is never written to the log either.
      log(actor, "signup.block_email", String.slice(block.canonical_email_hash, 0, 12))

      {:ok, block}
    end
  end

  @doc """
  Blocks the address behind a user, for use when suspending them.
  """
  @spec block_email_of(Account.t(), User.t()) :: :ok
  def block_email_of(%Account{} = actor, %User{} = user) do
    block_email(actor, user.email, user.account_id)

    :ok
  end

  @doc "Every canonical block, newest first."
  @spec canonical_email_blocks(map() | nil) :: [CanonicalEmailBlock.t()]
  def canonical_email_blocks(page \\ nil)

  def canonical_email_blocks(nil),
    do: CanonicalEmailBlock |> order_by([b], desc: b.id) |> Repo.all()

  def canonical_email_blocks(page) do
    CanonicalEmailBlock
    |> Pagination.window(page)
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  @doc """
  One of them by id, or `nil`.
  """
  @spec get_canonical_email_block(term()) :: CanonicalEmailBlock.t() | nil
  def get_canonical_email_block(id), do: fetch(CanonicalEmailBlock, id)

  @doc """
  The blocks an address would trip, without writing anything.

  For the moderator about to block somebody and wondering whether the address
  is already covered. Answered by the same canonicalisation the block itself
  uses, so it cannot say one thing here and another when the block lands.
  """
  @spec matching_canonical_email_blocks(String.t() | nil) :: [CanonicalEmailBlock.t()]
  def matching_canonical_email_blocks(email) do
    case canonical(email) do
      nil ->
        []

      address ->
        # Hashed, because that is what is stored: the address itself is
        # deliberately never written down, here or in the audit log.
        digest = hash(address)

        CanonicalEmailBlock |> where([b], b.canonical_email_hash == ^digest) |> Repo.all()
    end
  end

  @doc "Lifts one."
  @spec unblock_email(Account.t(), CanonicalEmailBlock.t()) :: :ok
  def unblock_email(%Account{} = actor, %CanonicalEmailBlock{} = block) do
    Repo.delete(block)
    log(actor, "signup.unblock_email", String.slice(block.canonical_email_hash, 0, 12))

    :ok
  end

  @doc """
  The comparable form of an address: case dropped, a `+tag` removed, and dots
  folded only where the provider ignores them.
  """
  @spec canonical(String.t() | nil) :: String.t()
  def canonical(email) do
    case String.split(to_string(email), "@", parts: 2) do
      [local, domain] ->
        domain = String.downcase(String.trim(domain))
        local = local |> String.downcase() |> String.split("+", parts: 2) |> hd()

        local = if domain in @dotless_providers, do: String.replace(local, ".", ""), else: local

        "#{local}@#{domain}"

      _ ->
        String.downcase(to_string(email))
    end
  end

  ## Addresses

  @doc """
  Blocks an address or a range.
  """
  @spec block_ip(Account.t(), map()) :: {:ok, IPBlock.t()} | {:error, Ecto.Changeset.t()}
  def block_ip(%Account{} = actor, attrs) do
    with {:ok, block} <- %IPBlock{} |> IPBlock.changeset(attrs) |> Repo.insert() do
      log(actor, "signup.block_ip", block.cidr)

      {:ok, block}
    end
  end

  @doc "Every address block, newest first."
  @spec ip_blocks(map() | nil) :: [IPBlock.t()]
  def ip_blocks(page \\ nil)

  def ip_blocks(nil), do: IPBlock |> order_by([b], desc: b.id) |> Repo.all()

  def ip_blocks(page) do
    IPBlock
    |> Pagination.window(page)
    |> Repo.all()
    |> Pagination.reading_order(page)
  end

  @doc """
  One of them by id, or `nil`.
  """
  @spec get_ip_block(term()) :: IPBlock.t() | nil
  def get_ip_block(id), do: fetch(IPBlock, id)

  @doc """
  Changes one, so a moderator can soften or extend a block rather than taking
  it off and writing it again — which is two audit entries for one decision.
  """
  @spec update_ip_block(Account.t(), IPBlock.t(), map()) ::
          {:ok, IPBlock.t()} | {:error, Ecto.Changeset.t()}
  def update_ip_block(%Account{} = actor, %IPBlock{} = block, attrs) do
    with {:ok, updated} <- block |> IPBlock.changeset(attrs) |> Repo.update() do
      AuditLog.record(actor, "ip_block.update", :ip_block, updated.id, %{
        "cidr" => updated.cidr,
        "severity" => updated.severity
      })

      {:ok, updated}
    end
  end

  @doc "Lifts one."
  @spec unblock_ip(Account.t(), IPBlock.t()) :: :ok
  def unblock_ip(%Account{} = actor, %IPBlock{} = block) do
    Repo.delete(block)
    log(actor, "signup.unblock_ip", block.cidr)

    :ok
  end

  ## Usernames

  @doc """
  Blocks a username, exactly or as part of a longer one.
  """
  @spec block_username(Account.t(), map()) ::
          {:ok, UsernameBlock.t()} | {:error, Ecto.Changeset.t()}
  def block_username(%Account{} = actor, attrs) do
    with {:ok, block} <- %UsernameBlock{} |> UsernameBlock.changeset(attrs) |> Repo.insert() do
      log(actor, "signup.block_username", block.username)

      {:ok, block}
    end
  end

  @doc "Every username block, newest first."
  @spec username_blocks() :: [UsernameBlock.t()]
  def username_blocks, do: UsernameBlock |> order_by([b], desc: b.id) |> Repo.all()

  @doc """
  One of them by id, or `nil`.
  """
  @spec get_username_block(term()) :: UsernameBlock.t() | nil
  def get_username_block(id), do: fetch(UsernameBlock, id)

  # An id that is not a number is an id nobody has, which is a miss rather
  # than a crash: it arrives from a URL a client built.
  defp fetch(schema, id) when is_integer(id), do: Repo.get(schema, id)

  defp fetch(schema, id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} -> Repo.get(schema, number)
      _ -> nil
    end
  end

  defp fetch(_schema, _id), do: nil

  @doc "Lifts one."
  @spec unblock_username(Account.t(), UsernameBlock.t()) :: :ok
  def unblock_username(%Account{} = actor, %UsernameBlock{} = block) do
    Repo.delete(block)
    log(actor, "signup.unblock_username", block.username)

    :ok
  end

  ## Closing the door when nobody is watching

  @doc """
  Closes an open server that no moderator has visited for a week.

  An open server left unattended fills with spam registrations within days, and
  the admin who forgot about it is the one who finds out. Returns `:closed`,
  `:open` where somebody has been about, and `:unchanged` where sign-ups were
  not open in the first place.
  """
  @spec close_if_unattended(DateTime.t()) :: :closed | :open | :unchanged
  def close_if_unattended(now \\ DateTime.utc_now()) do
    cond do
      Settings.registration_mode() != :open ->
        :unchanged

      moderator_seen_since?(DateTime.add(now, -@unattended_days, :day)) ->
        :open

      true ->
        :ok = Settings.put_registration_mode("closed")

        # Recorded with no actor: the server did this, and an admin coming back
        # to a closed server has to be able to find out why without guessing.
        AuditLog.record(nil, "registrations.auto_close", :settings, 0, %{
          "after_days" => @unattended_days,
          "label" => "registrations"
        })

        :closed
    end
  end

  @doc """
  How long a server may go unattended before it closes sign-ups.
  """
  @spec unattended_days() :: pos_integer()
  def unattended_days, do: @unattended_days

  ## Checking, inside

  defp username_answer(nil), do: :ok
  defp username_answer(""), do: :ok

  defp username_answer(username) do
    cond do
      Enum.any?(username_blocks(), &UsernameBlock.matches?(&1, username)) ->
        {:error, :username_blocked}

      # A name that belonged to an account somebody closed. It never comes
      # back: every old mention and link of `@alice` would otherwise point at
      # whoever registered it next. See `Abuuba.Accounts.Deletion`.
      Deletion.username_taken?(username) ->
        {:error, :username_taken}

      true ->
        :ok
    end
  end

  defp ip_answer(nil, _now), do: :ok
  defp ip_answer("", _now), do: :ok

  defp ip_answer(address, now) do
    address
    |> matching_ip_blocks(now)
    |> Enum.map(& &1.severity)
    |> Enum.reduce(:ok, fn
      "sign_up_requires_approval", acc -> strictest({:approval, :ip}, acc)
      _blocked, acc -> strictest({:error, :ip_blocked}, acc)
    end)
  end

  defp matching_ip_blocks(address, now) do
    IPBlock
    |> Repo.all()
    |> Enum.filter(&(not IPBlock.expired?(&1, now) and IPBlock.covers?(&1, address)))
  end

  defp email_answer(nil, _opts), do: :ok
  defp email_answer("", _opts), do: :ok

  defp email_answer(email, opts) do
    strictest(canonical_answer(email), domain_answer(email, opts))
  end

  defp canonical_answer(email) do
    hash = hash(canonical(email))

    if Repo.exists?(from(b in CanonicalEmailBlock, where: b.canonical_email_hash == ^hash)) do
      {:error, :email_blocked}
    else
      :ok
    end
  end

  defp domain_answer(email, opts) do
    case domain_of(email) do
      nil ->
        :ok

      domain ->
        blocks = email_domain_blocks()

        names = [domain | mail_hosts(domain, blocks, opts)]

        blocks
        |> Enum.filter(fn block -> Enum.any?(names, &covers_domain?(block.domain, &1)) end)
        |> Enum.reduce(:ok, fn
          %{allow_with_approval: true}, acc -> strictest({:approval, :email_domain}, acc)
          _block, acc -> strictest({:error, :email_domain_blocked}, acc)
        end)
    end
  end

  # Only asked where a block exists at all. A DNS lookup on every sign-up for a
  # server with an empty list is a round trip bought for nothing.
  defp mail_hosts(_domain, [], _opts), do: []

  defp mail_hosts(domain, _blocks, opts) do
    case Keyword.get(opts, :resolver) do
      nil -> []
      resolver -> domain |> resolver.() |> Enum.map(&EmailDomainBlock.normalise/1)
    end
  end

  # A block on `bad.example` covers `mail.bad.example`, on label boundaries so
  # that `notbad.example` never matches.
  defp covers_domain?(blocked, candidate) do
    candidate == blocked or String.ends_with?(candidate, "." <> blocked)
  end

  defp domain_of(email) do
    case String.split(to_string(email), "@", parts: 2) do
      [_local, domain] -> EmailDomainBlock.normalise(domain)
      _ -> nil
    end
  end

  defp moderator_seen_since?(since) do
    from(u in User,
      join: r in "user_roles",
      on: r.id == u.role_id,
      where: not is_nil(u.last_signed_in_at) and u.last_signed_in_at >= ^since,
      select: u.account_id
    )
    |> Repo.all()
    |> Enum.any?(&watching?/1)
  end

  defp watching?(account_id) do
    case Repo.get_by(User, account_id: account_id) do
      nil -> false
      user -> Roles.can?(user, "manage_users") or Roles.can?(user, "manage_reports")
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp log(actor, action, subject) do
    AuditLog.record(actor, action, :signup, 0, %{"subject" => subject, "label" => subject})
  end
end
