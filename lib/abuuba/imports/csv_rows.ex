defmodule Abuuba.Imports.CSVRows do
  @moduledoc """
  Applying one row of an imported list to an account.

  ## Every row is its own attempt

  A follow list from a server that closed names accounts on a hundred other
  servers, and some of them will be gone, renamed, or slow. Stopping at the
  first one nobody can find would mean nobody ever finishes an import; so each
  row succeeds or is reported by name, and the rest carry on.

  ## Merge and overwrite

  Merge adds what is in the file to what is already here. Overwrite makes what
  is here match the file, which is what somebody moving between servers
  actually wants: they exported their list, edited it, and this is now the
  list. The removal happens before the first row is read, so a run that fails
  halfway does not leave somebody following nobody.
  """

  alias Abuuba.Federation.ResolveActor
  alias Abuuba.Federation.ResolveStatus
  alias Abuuba.Filters
  alias Abuuba.Lists
  alias Abuuba.Relationships
  alias Abuuba.Statuses

  @doc """
  Empties whatever the file is about to replace.

  Only for overwrite, and only the kinds where "everything I have" is a list
  somebody can hold in their head. Bookmarks and filters are not emptied: a
  bookmark list is a reading list somebody built over years, and clearing it to
  apply a file of twelve is a loss nobody asked for.
  """
  @spec clear(atom(), map()) :: :ok
  def clear(:following, account) do
    account
    |> Relationships.following(%{limit: 100_000})
    |> Enum.each(&Relationships.unfollow(account, &1))
  end

  def clear(:blocking, account) do
    account
    |> Relationships.blocked_accounts(%{limit: 100_000})
    |> Enum.each(&Relationships.unblock(account, &1))
  end

  def clear(:muting, account) do
    account
    |> Relationships.muted_accounts(%{limit: 100_000})
    |> Enum.each(&Relationships.unmute(account, &1))
  end

  def clear(:domain_blocking, account) do
    account
    |> Relationships.blocked_domains(%{limit: 100_000})
    |> Enum.each(&Relationships.unblock_domain(account, &1))
  end

  def clear(:lists, account) do
    Enum.each(Lists.all(account), &Lists.delete/1)
  end

  def clear(_kept, _account), do: :ok

  @doc """
  Applies one row.

  `:ok`, or `{:error, reason}` naming why this row could not be done.
  """
  @spec apply(atom(), map(), map()) :: :ok | {:error, atom()}
  def apply(:following, account, row) do
    with {:ok, target} <- lookup(row) do
      relate(Relationships.follow_or_request(account, target, follow_options(row)))
    end
  end

  def apply(:blocking, account, row) do
    with {:ok, target} <- lookup(row), do: relate(Relationships.block(account, target))
  end

  def apply(:muting, account, row) do
    options = %{hide_notifications: truthy?(row[:hide_notifications], true)}

    with {:ok, target} <- lookup(row), do: relate(Relationships.mute(account, target, options))
  end

  def apply(:domain_blocking, account, row) do
    case presence(row[:domain]) do
      nil -> {:error, :no_domain}
      domain -> relate(Relationships.block_domain(account, domain))
    end
  end

  def apply(:bookmarks, account, row) do
    with uri when is_binary(uri) <- presence(row[:uri]) || {:error, :no_address},
         {:ok, status} <- ResolveStatus.resolve(uri),
         {:ok, _bookmarked} <- Statuses.bookmark(account, status) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _unreachable -> {:error, :could_not_be_fetched}
    end
  end

  def apply(:lists, account, row) do
    with title when is_binary(title) <- presence(row[:list_name]) || {:error, :no_list_name},
         {:ok, list} <- find_or_create_list(account, title),
         {:ok, target} <- lookup(row) do
      # A list holds people somebody follows, so the follow comes first. An
      # exported list names accounts the old server knew they followed, and the
      # follow list may not have been imported yet — or at all.
      Relationships.follow_or_request(account, target)

      relate(Lists.add(list, [target.id]))
    else
      {:error, reason} -> {:error, reason}
      _unreadable -> {:error, :could_not_be_saved}
    end
  end

  def apply(:filters, account, row) do
    with title when is_binary(title) <- presence(row[:title]) || presence(row[:keyword]),
         {:ok, filter} <- Filters.create(account, filter_attrs(title, row)) do
      add_keyword(filter, row)
    else
      nil -> {:error, :no_title}
      {:error, _changeset} -> {:error, :could_not_be_saved}
    end
  end

  ## The pieces

  # A handle, as the file writes it: `bob@other.example`, sometimes with a
  # leading `@`, and for an account on the old server sometimes with no domain
  # at all. Resolving it may mean asking another server, which is the slow part
  # of every one of these imports.
  defp lookup(row) do
    case presence(row[:acct]) do
      nil ->
        {:error, :no_address}

      acct ->
        case ResolveActor.resolve_handle(String.trim_leading(acct, "@")) do
          {:ok, account} -> {:ok, account}
          _unreachable -> {:error, :could_not_be_found}
        end
    end
  end

  defp follow_options(row) do
    %{
      show_reblogs: truthy?(row[:show_reblogs], true),
      notify: truthy?(row[:notify], false),
      languages: languages(row[:languages])
    }
  end

  defp languages(value) do
    case presence(value) do
      nil -> nil
      list -> list |> String.split(~r/[,\s]+/) |> Enum.reject(&(&1 == ""))
    end
  end

  # The exporters write `true`, `false`, `1` and `0`, and an empty cell means
  # whatever the server's own default was.
  defp truthy?(value, default) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "" -> default
      answer -> answer in ~w(true 1 yes t)
    end
  end

  defp find_or_create_list(account, title) do
    case Enum.find(Lists.all(account), &(&1.title == title)) do
      nil -> Lists.create(account, %{title: title})
      list -> {:ok, list}
    end
  end

  defp filter_attrs(title, row) do
    %{
      title: title,
      context: context(row[:context]),
      filter_action: action(row[:action])
    }
  end

  defp context(value) do
    case presence(value) do
      nil -> ["home"]
      list -> list |> String.split(~r/[,\s]+/) |> Enum.reject(&(&1 == ""))
    end
  end

  defp action(value) do
    if presence(value) |> to_string() |> String.downcase() == "hide", do: "hide", else: "warn"
  end

  defp add_keyword(filter, row) do
    case presence(row[:keyword]) do
      nil ->
        :ok

      keyword ->
        case Filters.add_keyword(filter, %{keyword: keyword, whole_word: false}) do
          {:ok, _added} -> :ok
          {:error, _changeset} -> {:error, :could_not_be_saved}
        end
    end
  end

  # Doing something that was already done is not a failure. An import run twice
  # is somebody being careful, not somebody making a mistake.
  defp relate({:ok, _done}), do: :ok
  defp relate(:ok), do: :ok
  defp relate({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp relate({:error, _changeset}), do: {:error, :could_not_be_saved}

  defp presence(nil), do: nil

  defp presence(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
