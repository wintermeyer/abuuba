defmodule Abuuba.EmailSubscriptions do
  @moduledoc """
  Addresses that asked one account to write to them.

  Somebody who reads what one person writes and has no interest in joining a
  social network to do it. They give an address, confirm it, and can take it
  back out with one click from any message.

  ## Nothing is sent to an unconfirmed address

  Anybody can type anybody's address into a form. An unconfirmed row is a claim
  that somebody wants mail, not evidence of it, and the only message that ever
  goes to one is the single confirmation asking whether the claim is true. A
  server that treated the claim as the subscription would be a way to mail
  strangers with this server's reputation attached.

  For the same reason `subscribe/3` answers the same way whether the address
  was new, already waiting, or already confirmed. Distinguishing them would let
  somebody type addresses into the form until one came back "already
  subscribed", which is a way to find out who reads whom.

  ## Two gates, both off by default

  The admin turns the feature on for the server, and each person turns it on
  for themselves. Both start off: mail sent in somebody's name is the kind of
  thing that should require having decided to do it.
  """

  import Ecto.Query

  alias Abuuba.Accounts
  alias Abuuba.Accounts.Account
  alias Abuuba.ActionLimits
  alias Abuuba.EmailSubscriptions.BroadcastWorker
  alias Abuuba.EmailSubscriptions.ConfirmationWorker
  alias Abuuba.EmailSubscriptions.Message
  alias Abuuba.EmailSubscriptions.Subscription
  alias Abuuba.Repo
  alias Abuuba.Settings

  # A day. Long enough that the form is not a megaphone, short enough that
  # somebody who lost the first message is not stuck until a sweep frees the
  # address a week later.
  @resend_cooldown_seconds 86_400

  # How many addresses one job writes to. Small enough that a job which dies
  # halfway repeats at most this many messages, and that no single job holds a
  # list bigger than it can finish.
  @batch_size 50

  @doc """
  Whether this server offers the feature at all.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get("email_subscriptions") == true

  @doc """
  Whether this account takes subscribers.

  Local, present, and having said yes. A remote account has no user here to
  have said anything, and a suspended one is not writing to anybody.
  """
  @spec open?(Account.t() | nil) :: boolean()
  def open?(nil), do: false

  def open?(%Account{} = account) do
    enabled?() and Account.local?(account) and is_nil(account.suspended_at) and
      case Accounts.get_user_by_account(account) do
        nil -> false
        user -> get_in(user.settings, ["email_subscriptions"]) == true
      end
  end

  @doc """
  Records that an address wants to hear from an account, and asks it to confirm.

  Always `:ok` where the account takes subscribers, whatever state the address
  was already in. See the module note on why.
  """
  @spec subscribe(Account.t(), String.t(), String.t()) ::
          :ok | {:error, Ecto.Changeset.t() | :closed}
  def subscribe(%Account{} = account, email, locale \\ "en") do
    if open?(account), do: record(account, email, locale), else: {:error, :closed}
  end

  defp record(account, email, locale) do
    attrs = %{account_id: account.id, email: email, locale: locale, token: new_token()}

    case Repo.insert(Subscription.changeset(%Subscription{}, attrs)) do
      {:ok, subscription} ->
        deliver_confirmation(subscription)

      # A row that is already there is not an error the submitter may see, but
      # a bad address is: they typed it and can fix it.
      {:error, changeset} ->
        if taken?(changeset), do: resend(account, email), else: {:error, changeset}
    end
  end

  @doc """
  The subscription this token belongs to, or `nil`.
  """
  @spec by_token(term()) :: Subscription.t() | nil
  def by_token(token) when is_binary(token) and byte_size(token) > 0 do
    Subscription |> where([s], s.token == ^token) |> preload(:account) |> Repo.one()
  end

  def by_token(_token), do: nil

  @doc """
  Records that the address itself agreed.
  """
  @spec confirm(Subscription.t()) :: {:ok, Subscription.t()} | {:error, :gone}
  def confirm(%Subscription{confirmed_at: nil} = subscription) do
    subscription
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now())
    |> Repo.update(stale_error_field: :id)
    |> case do
      {:ok, confirmed} -> {:ok, confirmed}
      # Somebody pressed "remove my address" in the other tab, or the sweep got
      # there first. Both are the link having stopped being valid, which is
      # what the page already knows how to say.
      {:error, _changeset} -> {:error, :gone}
    end
  end

  def confirm(%Subscription{} = subscription), do: {:ok, subscription}

  @doc """
  Takes an address back off.

  The row goes rather than being marked: there is nothing here worth keeping
  about somebody who asked to be forgotten, and a fresh subscription later is
  a fresh confirmation anyway.
  """
  @spec unsubscribe(Subscription.t()) :: :ok
  def unsubscribe(%Subscription{} = subscription) do
    Repo.delete(subscription, stale_error_field: :id)

    :ok
  end

  @doc """
  How many addresses one account has confirmed.
  """
  @spec count(Account.t() | integer()) :: non_neg_integer()
  def count(%Account{id: id}), do: count(id)

  def count(account_id) do
    Subscription
    |> where([s], s.account_id == ^account_id and not is_nil(s.confirmed_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  How many messages one account may write to its list in a day.
  """
  @spec messages_per_day() :: pos_integer()
  def messages_per_day do
    {limit, _window} = ActionLimits.family(:email_updates)

    limit
  end

  @doc """
  How many addresses one job writes to before handing on to the next.
  """
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @doc """
  Writes one message to every address on an account's list.

  Records the message and hands the sending to a job. Nothing is written to
  from here: this runs inside somebody pressing a button, and a list of a
  thousand addresses is not something to mail while a browser waits.

  The budget is spent only once the message is worth sending. A typo that the
  changeset refuses should not cost somebody one of the day's messages.
  """
  @spec broadcast(Account.t(), map()) ::
          {:ok, Message.t()} | {:error, :closed | :rate_limited | Ecto.Changeset.t()}
  def broadcast(%Account{} = account, attrs) do
    # On the struct rather than put on the changeset afterwards: `changeset/2`
    # requires `account_id`, and a value added after that check has run is a
    # value the check never saw.
    changeset = Message.changeset(%Message{account_id: account.id}, attrs)

    cond do
      not open?(account) -> {:error, :closed}
      not changeset.valid? -> {:error, Map.put(changeset, :action, :insert)}
      true -> insert_and_send(account, changeset)
    end
  end

  @doc """
  What an account has written to its list, newest first.
  """
  @spec messages(Account.t() | integer(), pos_integer()) :: [Message.t()]
  def messages(account, limit \\ 20)
  def messages(%Account{id: id}, limit), do: messages(id, limit)

  def messages(account_id, limit) do
    Message
    |> where([m], m.account_id == ^account_id)
    |> order_by([m], desc: m.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  The next page of confirmed addresses for an account, after a cursor.

  Ordered by id and taken forward only, so a job that resumes cannot go back
  over addresses it has already written to.
  """
  @spec confirmed_after(integer(), integer() | nil, pos_integer()) :: [Subscription.t()]
  def confirmed_after(account_id, cursor, limit \\ @batch_size) do
    Subscription
    |> where([s], s.account_id == ^account_id and not is_nil(s.confirmed_at))
    |> then(fn query ->
      if cursor, do: where(query, [s], s.id > ^cursor), else: query
    end)
    |> order_by([s], asc: s.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Deletes the claims nobody ever confirmed.

  An address that never answered did not want the mail, and keeping the row is
  keeping somebody's address for no reason anybody could defend.
  """
  @spec purge_unconfirmed(pos_integer()) :: non_neg_integer()
  def purge_unconfirmed(older_than_days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_days * 86_400, :second)

    {deleted, _} =
      Subscription
      |> where([s], is_nil(s.confirmed_at) and s.inserted_at < ^cutoff)
      |> Repo.delete_all()

    deleted
  end

  ## Plumbing

  defp insert_and_send(account, changeset) do
    with :ok <- ActionLimits.take(account, :email_updates),
         {:ok, message} <- Repo.insert(changeset) do
      %{"message_id" => message.id}
      |> BroadcastWorker.new()
      |> Oban.insert!()

      {:ok, message}
    end
  end

  # A repeat submission for an address that never answered gets the
  # confirmation again, because the usual reason for one is that the first went
  # missing. At most once a day, though: without that bound the form is a way
  # to mail a stranger as many times as somebody cares to press the button,
  # with this server's name on every message. Never at all to an address that
  # has already confirmed — that would be the same amplifier aimed at somebody
  # who is on the list, and answering differently for the two cases would say
  # out loud which addresses read which accounts.
  defp resend(account, email) do
    normalised = Subscription.normalise(email)

    Subscription
    |> where([s], s.account_id == ^account.id and s.email == ^normalised)
    |> Repo.one()
    |> case do
      %Subscription{confirmed_at: nil} = subscription ->
        if resendable?(subscription), do: deliver_confirmation(subscription)

        :ok

      _ ->
        :ok
    end
  end

  defp resendable?(%Subscription{updated_at: sent_at}) do
    DateTime.diff(DateTime.utc_now(), sent_at, :second) >= @resend_cooldown_seconds
  end

  # Queued rather than sent here. An SMTP round trip inside the request would
  # park an unauthenticated request process on a third party's network, and it
  # would make "already confirmed" measurably faster to submit than "not yet",
  # which is the very thing this module refuses to tell anybody.
  defp deliver_confirmation(subscription) do
    touch(subscription)

    %{subscription_id: subscription.id}
    |> ConfirmationWorker.new()
    |> Oban.insert()

    :ok
  end

  # The send is stamped on the row, which is what the cooldown reads.
  defp touch(subscription) do
    Subscription
    |> where([s], s.id == ^subscription.id)
    |> Repo.update_all(set: [updated_at: DateTime.utc_now()])
  end

  defp taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {field, {_message, opts}} ->
      field == :email and Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp new_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
