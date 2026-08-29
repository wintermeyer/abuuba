defmodule Mix.Tasks.Abuuba.Accounts do
  @shortdoc "Account operations: approve, delete, refresh, cull, unfollow"

  @moduledoc """
  The account verbs an admin reaches for at a terminal.

      mix abuuba.accounts approve --all
      mix abuuba.accounts delete alice
      mix abuuba.accounts refresh --domain remote.example
      mix abuuba.accounts cull --dry-run
      mix abuuba.accounts unfollow alice

  ## self-destruct

  Closes every account on this server, which tells every peer that has heard of
  them to forget them. For shutting an instance down properly rather than
  turning it off and leaving its people as ghosts on a hundred other servers.

  It takes the server's own domain rather than a yes/no prompt, because an
  operator who has to name the thing they are destroying cannot do it by
  pressing return in the wrong terminal. There is no undo: the Deletes are on
  their way the moment it returns.

  ## duplicates

  Remote accounts that sign with the same key, which is what says two rows are
  one person. Prints the `merge` to run for each pair rather than running it:
  which of the two survives is a judgement about the handle people already
  know, and a query does not have it.

  Nothing is reported on a healthy server. Duplicates come from a peer changing
  its actor URI, or from the same actor being fetched twice under two
  identities, and until now the only way to notice was somebody complaining
  that a person had two profiles.

  ## approve

  Lets pending registrations in. `--all` or one username. On a server that
  turned approval on and then found four hundred people waiting, this is the
  difference between an afternoon and a command.

  ## delete

  Closes an account the way its owner would: the name is kept and can never be
  handed to anybody else, the peers are told, and the rows go through the
  ordinary purge. See `Abuuba.Accounts.Deletion`.

  ## refresh

  Asks other servers for their accounts again. `--domain` narrows it to one.
  For a peer that renamed itself or replaced its pictures, where waiting for
  everybody there to post is waiting for something that may not come.

  ## cull

  Removes remote accounts whose server has been unreachable for long enough
  and which nobody here follows. Those are the rows that accumulate on an old
  server and are the reason its database is mostly other people's dead
  accounts.

  ## unfollow

  Takes an account out of everybody's following. For a spam account whose
  server is gone and which cannot be asked to stop.
  """

  use Mix.Task

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.Deletion
  alias Abuuba.Accounts.Merge
  alias Abuuba.Accounts.User
  alias Abuuba.Exports
  alias Abuuba.Federation.Actor
  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Federation.URIs
  alias Abuuba.Ops
  alias Abuuba.Relationships.Follow
  alias Abuuba.Release
  alias Abuuba.Repo
  alias Abuuba.Roles

  @commands ~w(create bootstrap-owner modify merge duplicates rotate-keys backup approve delete refresh cull unfollow self-destruct)

  @switches [
    all: :boolean,
    domain: :string,
    dry_run: :boolean,
    days: :integer,
    email: :string,
    role: :string,
    disable: :boolean,
    force: :boolean,
    enable: :boolean,
    confirm: :string
  ]

  @impl Mix.Task
  def run(args) do
    Ops.start!()

    {opts, rest, _invalid} = OptionParser.parse(args, switches: @switches)

    dispatch(rest, opts)
  end

  # One clause per command rather than a `case` that grows past what anybody
  # can read at once.
  defp dispatch(["create" | names], opts), do: create(names, opts)
  defp dispatch(["bootstrap-owner" | names], opts), do: bootstrap_owner(names, opts)
  defp dispatch(["modify" | names], opts), do: modify(names, opts)
  defp dispatch(["merge" | names], opts), do: merge(names, opts)
  defp dispatch(["duplicates" | _rest], _opts), do: duplicates()
  defp dispatch(["rotate-keys" | names], opts), do: rotate_keys(names, opts)
  defp dispatch(["backup" | names], opts), do: backup(names, opts)
  defp dispatch(["approve" | names], opts), do: approve(names, opts)
  defp dispatch(["delete" | names], opts), do: delete(names, opts)
  defp dispatch(["refresh" | _rest], opts), do: refresh(opts)
  defp dispatch(["cull" | _rest], opts), do: cull(opts)
  defp dispatch(["unfollow" | names], opts), do: unfollow(names, opts)
  defp dispatch(["self-destruct" | _rest], opts), do: self_destruct(opts)
  defp dispatch([command | _rest], _opts), do: Ops.unknown(command, @commands)

  defp dispatch([], _opts), do: Mix.raise("Say what to do: #{Enum.join(@commands, ", ")}")

  # The same function `bin/abuuba eval` calls on a release, so a development
  # server and a production one are bootstrapped by one piece of code rather
  # than by two that can disagree. `create --role Owner` cannot do this job: it
  # assigns a role by name and a fresh database has none to name.
  defp bootstrap_owner([], _opts), do: Mix.raise("Say which name to create.")

  defp bootstrap_owner([username | _rest], opts) do
    email = Keyword.get(opts, :email) || Mix.raise("An account needs --email.")

    case Release.bootstrap_owner(%{username: username, email: email}) do
      {:ok, %{account: account, password: password}} ->
        Mix.shell().info("""
        Created @#{account.username}, who can administer this server.
        Password: #{password}
        """)

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("Could not create that account: #{errors(changeset)}")

      {:error, reason} ->
        Mix.raise("Could not create that account: #{inspect(reason)}")
    end
  end

  defp create([], _opts), do: Mix.raise("Say which name to create.")

  defp create([username | _rest], opts) do
    email = Keyword.get(opts, :email) || Mix.raise("An account needs --email.")
    password = generated_password()

    case Auth.create_by_admin(%{username: username, email: email, password: password}) do
      {:ok, %{account: account, user: user}} ->
        assign_role(user, Keyword.get(opts, :role))

        # Printed once, here. There is nowhere else it can come from: the
        # column holds a hash, so an admin who loses this line has to send a
        # reset rather than look it up.
        Mix.shell().info("""
        Created @#{account.username}
        Password: #{password}
        """)

      {:error, changeset} ->
        Mix.raise("Could not create that account: #{errors(changeset)}")
    end
  end

  defp modify([], _opts), do: Mix.raise("Say which account to change.")

  defp modify([username | _rest], opts) do
    account = account_named(username) || Mix.raise("No account called #{username}.")

    user =
      Accounts.get_user_by_account(account) || Mix.raise("#{username} is not a local account.")

    user
    |> change_email(Keyword.get(opts, :email))
    |> change_approval(opts)
    |> assign_role(Keyword.get(opts, :role))

    Mix.shell().info("Changed @#{account.username}.")
  end

  defp merge([duplicate, keeper | _rest], opts) do
    duplicate = remote_named(duplicate)
    keeper = remote_named(keeper)

    unless Keyword.get(opts, :force, false) or Merge.same_key?(duplicate, keeper) do
      Mix.raise("""
      Those two do not have the same signing key, so they may not be the same
      person. Pass --force if you know they are — for instance because their
      server rotated its key between the two fetches.
      """)
    end

    if Ops.dry_run?(opts), do: report_merge(duplicate, keeper), else: do_merge(duplicate, keeper)
  end

  defp merge(_names, _opts), do: Mix.raise("Say which two: merge <from> <into>.")

  # Report only. Which of a pair survives is a judgement about which handle
  # people already know, so this prints the merge to run rather than running
  # one, and prints it in the order `merge` takes: the newer id into the older.
  defp duplicates do
    case Merge.duplicates() do
      [] ->
        Mix.shell().info("No remote accounts share a signing key.")

      groups ->
        Enum.each(groups, &report_group/1)

        Ops.report(true, length(groups), "group")
    end
  end

  defp report_group([keeper | rest] = group) do
    Mix.shell().info(Enum.map_join(group, " ", &Account.acct/1))

    Enum.each(rest, fn duplicate ->
      Mix.shell().info(
        "  mix abuuba.accounts merge #{Account.acct(duplicate)} #{Account.acct(keeper)}"
      )
    end)
  end

  defp report_merge(duplicate, keeper) do
    case Merge.would_move(duplicate, keeper) do
      {:ok, count} -> Ops.report(true, count, "row")
      {:error, reason} -> Mix.raise(merge_refusal(reason))
    end
  end

  defp do_merge(duplicate, keeper) do
    case Merge.merge(duplicate, keeper) do
      {:ok, count} ->
        Ops.report(false, count, "row")
        Mix.shell().info("@#{Account.acct(duplicate)} is now @#{Account.acct(keeper)}.")

      {:error, reason} ->
        Mix.raise(merge_refusal(reason))
    end
  end

  defp merge_refusal(:local_account) do
    """
    Both accounts have to be from another server. Merging two accounts here is
    a decision for the person they belong to, and the way to do it is to move
    one account to the other from the settings.
    """
  end

  defp merge_refusal(:same_account), do: "Those are the same account."

  defp remote_named(handle) do
    case account_named(handle) do
      nil -> Mix.raise("No account called #{handle}.")
      %Account{domain: nil} -> Mix.raise(merge_refusal(:local_account))
      account -> account
    end
  end

  defp rotate_keys(names, opts) do
    accounts =
      if Keyword.get(opts, :all, false) do
        local_accounts()
      else
        names |> Enum.map(&account_named/1) |> Enum.reject(&is_nil/1)
      end

    unless Ops.dry_run?(opts) do
      accounts
      |> Enum.with_index(1)
      |> Enum.each(fn {account, index} ->
        Ops.progress(index, length(accounts))
        Accounts.rotate_keypair(account)
      end)

      Ops.progress_done()
    end

    Ops.report(Ops.dry_run?(opts), length(accounts), "account")
  end

  defp backup([], _opts), do: Mix.raise("Say whose archive to build.")

  defp backup([username | _rest], _opts) do
    account = account_named(username) || Mix.raise("No account called #{username}.")

    # The same archive the export page builds, through the same job, so there
    # is one way of making one and it is the way that has been tested.
    case Exports.request(account) do
      {:ok, export} ->
        Mix.shell().info("""
        Building the archive for @#{account.username}.
        It appears under Settings → Export when the job finishes (id #{export.id}).
        """)

      {:error, :in_progress} ->
        Mix.raise("One is already being built for #{username}.")

      {:error, {:too_soon, at}} ->
        Mix.raise("#{username} can ask for another from #{DateTime.to_iso8601(at)}.")
    end
  end

  defp approve(names, opts) do
    users = if Keyword.get(opts, :all, false), do: pending(), else: Enum.map(names, &user_named/1)
    users = Enum.reject(users, &is_nil/1)

    unless Ops.dry_run?(opts), do: Enum.each(users, &Auth.approve_user/1)

    Ops.report(Ops.dry_run?(opts), length(users), "account")
  end

  defp delete(names, opts) do
    accounts = names |> Enum.map(&account_named/1) |> Enum.reject(&is_nil/1)

    unless Ops.dry_run?(opts), do: Enum.each(accounts, &Deletion.close/1)

    Ops.report(Ops.dry_run?(opts), length(accounts), "account")
  end

  # Closing every local account, which tells every peer to forget them. There
  # is no undo: the Deletes are on their way the moment this returns, and no
  # message exists that takes one back.
  #
  # The guard is the server's own domain typed out rather than a yes/no prompt,
  # because an operator who has to name the thing they are destroying cannot
  # do it by pressing return at the wrong moment in the wrong terminal.
  defp self_destruct(opts) do
    domain = URIs.local_domain()

    unless Keyword.get(opts, :confirm) == domain do
      Mix.raise("""
      This closes every account on #{domain} and tells every server that has
      heard of them to do the same. It cannot be undone.

          mix abuuba.accounts self-destruct --confirm #{domain}
      """)
    end

    accounts = Repo.all(from a in Account, where: is_nil(a.domain))
    total = length(accounts)

    unless Ops.dry_run?(opts) do
      accounts
      |> Enum.with_index(1)
      |> Enum.each(fn {account, index} ->
        Ops.progress(index, total)
        Deletion.close(account)
      end)

      Ops.progress_done()
    end

    Ops.report(Ops.dry_run?(opts), total, "account")
  end

  defp refresh(opts) do
    accounts = remote_accounts(Keyword.get(opts, :domain))
    total = length(accounts)

    done =
      accounts
      |> Enum.with_index(1)
      |> Enum.reduce(0, fn {account, index}, ok ->
        Ops.progress(index, total)

        ok + refetched(account, Ops.dry_run?(opts))
      end)

    Ops.progress_done()
    Ops.report(Ops.dry_run?(opts), done, "account")
  end

  defp refetched(_account, true), do: 1

  defp refetched(account, false) do
    case ResolveActor.resolve(Actor.id(account), max_age_seconds: 0) do
      {:ok, _account} -> 1
      _ -> 0
    end
  end

  # Unreachable *and* unfollowed. Either on its own is a live account: a server
  # that is down comes back, and somebody nobody here follows may still be
  # mentioned in a thread people are reading.
  defp cull(opts) do
    followed = from(f in Follow, select: f.target_account_id)

    accounts =
      Account
      |> where([a], not is_nil(a.domain))
      |> where([a], a.id not in subquery(followed))
      |> Repo.all()
      |> Enum.filter(&Availability.unavailable?(&1.domain))

    unless Ops.dry_run?(opts), do: Enum.each(accounts, &Accounts.delete_account/1)

    Ops.report(Ops.dry_run?(opts), length(accounts), "remote account")
  end

  defp unfollow(names, opts) do
    accounts = names |> Enum.map(&account_named/1) |> Enum.reject(&is_nil/1)
    ids = Enum.map(accounts, & &1.id)

    count =
      if ids == [] do
        0
      else
        query = from(f in Follow, where: f.target_account_id in ^ids)

        if Ops.dry_run?(opts) do
          Repo.aggregate(query, :count)
        else
          {removed, _} = Repo.delete_all(query)
          removed
        end
      end

    Ops.report(Ops.dry_run?(opts), count, "follow")
  end

  ## Plumbing

  # Long, random, and printed once. An admin who has to invent a password
  # invents the same one twice.
  defp generated_password,
    do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp change_email(user, nil), do: user

  defp change_email(user, email) do
    case user |> User.changeset(%{email: email}) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Mix.raise("Could not change the address: #{errors(changeset)}")
    end
  end

  defp change_approval(user, opts) do
    cond do
      Keyword.get(opts, :disable, false) -> Repo.update!(User.disable_changeset(user))
      Keyword.get(opts, :enable, false) -> Repo.update!(User.approve_changeset(user))
      true -> user
    end
  end

  defp assign_role(user, nil), do: user

  defp assign_role(user, name) do
    case Enum.find(Roles.all(), &(&1.name == name)) do
      nil ->
        Mix.raise("No role called #{name}.")

      role ->
        {:ok, updated} = Roles.assign(user, role)

        updated
    end
  end

  defp local_accounts do
    Account
    |> where([a], is_nil(a.domain) and is_nil(a.suspended_at))
    |> Repo.all()
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join(", ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp pending, do: Repo.all(from u in User, where: not u.approved and is_nil(u.approved_at))

  defp user_named(name) do
    case account_named(name) do
      nil -> nil
      account -> Accounts.get_user_by_account(account)
    end
  end

  # A bare name is a local account and `name@server` is a remote one, which is
  # how everybody writes them everywhere else on this server.
  defp account_named(name) do
    case String.split(String.trim_leading(name, "@"), "@", parts: 2) do
      [username] ->
        Repo.one(from a in Account, where: a.username == ^username and is_nil(a.domain))

      [username, domain] ->
        Repo.get_by(Account, username: username, domain: domain)
    end
  end

  defp remote_accounts(nil) do
    Account |> where([a], not is_nil(a.domain)) |> Repo.all()
  end

  defp remote_accounts(domain) do
    Account |> where([a], a.domain == ^domain) |> Repo.all()
  end
end
