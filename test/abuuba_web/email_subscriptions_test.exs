defmodule AbuubaWeb.EmailSubscriptionsTest do
  use AbuubaWeb.ConnCase, async: false

  import Swoosh.TestAssertions
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.EmailSubscriptions
  alias Abuuba.EmailSubscriptions.BroadcastWorker
  alias Abuuba.EmailSubscriptions.Subscription
  alias Abuuba.RateLimit
  alias Abuuba.Settings

  setup do
    account = account_fixture()
    user = user_fixture(%{account_id: account.id, approved: true})

    on_exit(fn ->
      Settings.put("email_subscriptions", false)
      RateLimit.reset()
    end)

    RateLimit.reset()

    %{account: account, user: user}
  end

  # The confirmation is queued rather than sent inside the call: an SMTP round
  # trip in an unauthenticated request would both park the process and make
  # "already confirmed" measurably faster to submit than "not yet". So every
  # assertion about mail runs the queue first.
  # `with_recursion`, because a broadcast hands the next page to a job it
  # queues itself. Without it a drain stops after the first page and the test
  # reads a half-sent message as the finished one.
  defp drain, do: Oban.drain_queue(queue: :ingress, with_recursion: true)

  # The test adapter posts every message to this process, so a test that wants
  # to count them takes them out of the mailbox rather than asking for one at a
  # time. Draining consumes them, so it happens once, after the sending.
  defp sent_emails(collected \\ []) do
    receive do
      {:email, email} -> sent_emails([email | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  defp recipient(email), do: email.to |> hd() |> elem(1)

  defp age_the_row(days) do
    Abuuba.EmailSubscriptions.Subscription
    |> Abuuba.Repo.all()
    |> Enum.each(fn row ->
      then = DateTime.add(DateTime.utc_now(), -days, :day)

      row
      |> Ecto.Changeset.change(inserted_at: then, updated_at: then)
      |> Abuuba.Repo.update!()
    end)
  end

  defp open_the_feature(user) do
    Settings.put("email_subscriptions", true)

    {:ok, user} =
      user
      |> Ecto.Changeset.change(
        settings: Map.put(user.settings || %{}, "email_subscriptions", true)
      )
      |> Abuuba.Repo.update()

    user
  end

  describe "writing to the list" do
    setup %{account: account, user: user} do
      user = open_the_feature(user)

      confirmed =
        for n <- 1..3 do
          :ok = EmailSubscriptions.subscribe(account, "reader#{n}@example.com")
          subscription = Abuuba.Repo.get_by!(Subscription, email: "reader#{n}@example.com")
          {:ok, confirmed} = EmailSubscriptions.confirm(subscription)
          confirmed
        end

      :ok = EmailSubscriptions.subscribe(account, "undecided@example.com")
      drain()
      _confirmations = sent_emails()

      %{user: user, confirmed: confirmed}
    end

    test "reaches every confirmed address and nobody else", %{account: account} do
      {:ok, _message} = EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})
      drain()

      sent = sent_emails()
      addresses = Enum.map(sent, &recipient/1)

      assert Enum.sort(addresses) ==
               ["reader1@example.com", "reader2@example.com", "reader3@example.com"]

      # An address that never confirmed is a claim somebody typed into a form,
      # and this is the message that would make the server a way to mail
      # strangers.
      refute "undecided@example.com" in addresses

      assert Enum.all?(sent, &(&1.subject =~ "News" and &1.text_body =~ "Hello."))
    end

    test "carries a way out of every message", %{account: account, confirmed: confirmed} do
      {:ok, _message} = EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})
      drain()

      tokens = Map.new(confirmed, &{&1.email, &1.token})

      for email <- sent_emails() do
        token = Map.fetch!(tokens, recipient(email))

        assert email.text_body =~ "/email_subscriptions/" <> token

        # A client that offers a one-click unsubscribe reads the header rather
        # than the body, and a list mail without one is a list mail people
        # report as spam instead.
        assert {_name, value} =
                 Enum.find(email.headers, fn {name, _value} -> name == "List-Unsubscribe" end)

        assert value =~ token
      end
    end

    test "records what went out", %{account: account} do
      {:ok, message} = EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})
      drain()

      message = Abuuba.Repo.reload!(message)

      assert message.subject == "News"
      assert message.recipient_count == 3
      assert message.finished_at
    end

    test "refuses an empty one", %{account: account} do
      assert {:error, %Ecto.Changeset{}} =
               EmailSubscriptions.broadcast(account, %{subject: "", body: ""})
    end

    test "refuses an account that does not take subscribers", %{account: account, user: user} do
      {:ok, _user} =
        user
        |> Ecto.Changeset.change(settings: Map.put(user.settings, "email_subscriptions", false))
        |> Abuuba.Repo.update()

      assert {:error, :closed} =
               EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})
    end

    test "stops an account writing all day", %{account: account} do
      results =
        for n <- 1..(EmailSubscriptions.messages_per_day() + 2) do
          EmailSubscriptions.broadcast(account, %{subject: "News #{n}", body: "Hello."})
        end

      assert {:error, :rate_limited} in results

      # The positive control: the first ones went out, so the refusal is a
      # budget rather than the whole thing being broken.
      assert Enum.any?(results, &match?({:ok, _message}, &1))
    end

    test "sends a long list in pages, and never twice", %{account: account} do
      for n <- 1..(EmailSubscriptions.batch_size() * 2 + 3) do
        address = "many#{n}@example.com"
        :ok = EmailSubscriptions.subscribe(account, address)
        {:ok, _} = EmailSubscriptions.confirm(Abuuba.Repo.get_by!(Subscription, email: address))
      end

      drain()
      _confirmations = sent_emails()

      {:ok, message} = EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})
      drain()

      total = EmailSubscriptions.count(account)
      addresses = Enum.map(sent_emails(), &recipient/1)

      assert length(addresses) == total
      assert Abuuba.Repo.reload!(message).recipient_count == total

      # One message per address, not one per address per page.
      assert length(Enum.uniq(addresses)) == total
    end

    test "resumes where it stopped rather than starting again", %{account: account} do
      {:ok, message} = EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})
      drain()
      _first_run = sent_emails()

      # The job died after the last page and Oban runs it again. Without a
      # cursor on the row, the retry mails everybody a second time.
      %{"message_id" => message.id}
      |> BroadcastWorker.new()
      |> Oban.insert!()

      drain()

      assert sent_emails() == []
    end

    test "sends nothing once the account has closed its list", %{account: account, user: user} do
      {:ok, message} = EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})

      # Said no in between. The queue is the one place that can still hear it.
      {:ok, _user} =
        user
        |> Ecto.Changeset.change(settings: Map.put(user.settings, "email_subscriptions", false))
        |> Abuuba.Repo.update()

      drain()

      assert sent_emails() == []
      assert Abuuba.Repo.reload!(message).finished_at
    end

    test "a stale second job does not write to somebody who subscribed later", %{
      account: account
    } do
      {:ok, message} = EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})
      drain()
      _first_run = sent_emails()

      :ok = EmailSubscriptions.subscribe(account, "latecomer@example.com")

      {:ok, _confirmed} =
        Subscription
        |> Abuuba.Repo.get_by!(email: "latecomer@example.com")
        |> EmailSubscriptions.confirm()

      drain()
      _confirmation = sent_emails()

      %{"message_id" => message.id}
      |> BroadcastWorker.new()
      |> Oban.insert!()

      drain()

      # The message was finished before they arrived, and a finished message is
      # not a message anybody new is owed.
      assert sent_emails() == []
    end

    test "one address the mail server refuses does not stop the rest", %{account: account} do
      # Swoosh answers with an error tuple for a recipient the server rejects.
      # The other addresses on the page have nothing to do with it.
      {:ok, message} = EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})
      drain()

      message = Abuuba.Repo.reload!(message)

      assert message.recipient_count == 3
      assert message.finished_at
      assert length(sent_emails()) == 3
    end

    test "is listed for the account that wrote it", %{account: account} do
      {:ok, _message} = EmailSubscriptions.broadcast(account, %{subject: "News", body: "Hello."})

      assert [%{subject: "News"}] = EmailSubscriptions.messages(account)
      assert EmailSubscriptions.messages(account_fixture()) == []
    end
  end

  describe "the two gates" do
    test "both closed means the account takes nobody", %{account: account} do
      refute EmailSubscriptions.open?(account)
    end

    test "the server alone is not enough", %{account: account} do
      Settings.put("email_subscriptions", true)

      refute EmailSubscriptions.open?(account)
    end

    test "the person alone is not enough", %{account: account, user: user} do
      user
      |> Ecto.Changeset.change(settings: %{"email_subscriptions" => true})
      |> Abuuba.Repo.update!()

      refute EmailSubscriptions.open?(account)
    end

    test "both open means the account takes subscribers", %{account: account, user: user} do
      open_the_feature(user)

      assert EmailSubscriptions.open?(account)
    end

    test "a suspended account takes nobody however the settings stand", %{
      account: account,
      user: user
    } do
      open_the_feature(user)

      account
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now())
      |> Abuuba.Repo.update!()

      refute account |> Map.get(:id) |> Accounts.get_account() |> EmailSubscriptions.open?()
    end

    test "an account from another server takes nobody" do
      remote = account_fixture(%{domain: "example.com"})
      Settings.put("email_subscriptions", true)

      refute EmailSubscriptions.open?(remote)
    end
  end

  describe "subscribing" do
    setup %{user: user} do
      %{user: open_the_feature(user)}
    end

    test "asks the address to confirm and sends it nothing else", %{account: account} do
      assert :ok = EmailSubscriptions.subscribe(account, "reader@example.com")

      drain()

      assert_email_sent(fn email ->
        assert {_name, "reader@example.com"} = hd(email.to)
        assert email.text_body =~ "/email_subscriptions/"
      end)

      # Not a subscriber yet. The claim is that somebody wants mail, not
      # evidence of it.
      assert EmailSubscriptions.count(account) == 0
    end

    test "normalises the address, so one person is one row", %{account: account} do
      assert :ok = EmailSubscriptions.subscribe(account, "  Reader@Example.COM ")

      [subscription] = Abuuba.Repo.all(Abuuba.EmailSubscriptions.Subscription)
      assert subscription.email == "reader@example.com"
    end

    test "refuses something that is not an address", %{account: account} do
      assert {:error, %Ecto.Changeset{}} = EmailSubscriptions.subscribe(account, "not-an-address")

      drain()

      refute_email_sent()
    end

    test "sends nothing more today to an address that never answered", %{account: account} do
      :ok = EmailSubscriptions.subscribe(account, "reader@example.com")
      drain()
      assert_email_sent()

      # The form must not be a way to mail a stranger once per button press,
      # with this server's name on every message.
      assert :ok = EmailSubscriptions.subscribe(account, "reader@example.com")
      drain()
      refute_email_sent()
    end

    test "sends it again once the day has passed", %{account: account} do
      :ok = EmailSubscriptions.subscribe(account, "reader@example.com")
      drain()
      assert_email_sent()

      # Somebody who lost the first message should not be stuck until a sweep
      # frees the address a week later.
      age_the_row(2)

      assert :ok = EmailSubscriptions.subscribe(account, "reader@example.com")
      drain()
      assert_email_sent()
    end

    test "sends nothing more to an address that already confirmed", %{account: account} do
      :ok = EmailSubscriptions.subscribe(account, "reader@example.com")
      drain()
      assert_email_sent()

      [subscription] = Abuuba.Repo.all(Abuuba.EmailSubscriptions.Subscription)
      {:ok, _confirmed} = EmailSubscriptions.confirm(subscription)

      # The same answer as a new subscription, and no mail. Anything else turns
      # the form into a way of mailing somebody once per submission, and into a
      # way of finding out who reads whom.
      assert :ok = EmailSubscriptions.subscribe(account, "reader@example.com")
      drain()
      refute_email_sent()
    end

    test "is refused where the account does not take subscribers" do
      closed = account_fixture()

      assert {:error, :closed} = EmailSubscriptions.subscribe(closed, "reader@example.com")
      drain()
      refute_email_sent()
    end

    test "writes the message in the language it was asked in", %{account: account} do
      assert :ok = EmailSubscriptions.subscribe(account, "leser@example.com", "de")

      drain()

      assert_email_sent(fn email ->
        assert email.subject =~ "Bestätige"
      end)
    end
  end

  describe "confirming and stopping" do
    setup %{account: account, user: user} do
      open_the_feature(user)
      :ok = EmailSubscriptions.subscribe(account, "reader@example.com")
      [subscription] = Abuuba.Repo.all(Abuuba.EmailSubscriptions.Subscription)

      %{subscription: subscription}
    end

    test "confirming counts the address in", %{account: account, subscription: subscription} do
      {:ok, confirmed} = EmailSubscriptions.confirm(subscription)

      assert confirmed.confirmed_at
      assert EmailSubscriptions.count(account) == 1
    end

    test "confirming twice is confirming once", %{subscription: subscription} do
      {:ok, first} = EmailSubscriptions.confirm(subscription)
      {:ok, second} = EmailSubscriptions.confirm(first)

      assert first.confirmed_at == second.confirmed_at
    end

    test "stopping takes the row away", %{account: account, subscription: subscription} do
      {:ok, confirmed} = EmailSubscriptions.confirm(subscription)

      assert :ok = EmailSubscriptions.unsubscribe(confirmed)
      assert EmailSubscriptions.count(account) == 0
      assert is_nil(EmailSubscriptions.by_token(subscription.token))
    end

    test "an unconfirmed row is swept once it is old enough", %{account: account} do
      age_the_row(30)

      assert EmailSubscriptions.purge_unconfirmed(7) == 1
      assert EmailSubscriptions.count(account) == 0
    end

    test "a confirmed row is never swept", %{subscription: subscription} do
      {:ok, _confirmed} = EmailSubscriptions.confirm(subscription)

      assert EmailSubscriptions.purge_unconfirmed(0) == 0
    end
  end

  describe "POST /api/v1/accounts/:account_id/email_subscriptions" do
    test "takes an address for an account that offers it", %{
      conn: conn,
      account: account,
      user: user
    } do
      open_the_feature(user)

      conn
      |> post(~p"/api/v1/accounts/#{account.id}/email_subscriptions", %{
        "email" => "reader@example.com"
      })
      |> json_response(200)

      drain()

      assert_email_sent()
    end

    test "answers 404 for an account that does not", %{conn: conn, account: account} do
      conn
      |> post(~p"/api/v1/accounts/#{account.id}/email_subscriptions", %{
        "email" => "reader@example.com"
      })
      |> json_response(404)

      drain()

      refute_email_sent()
    end

    test "answers 404 for an account id that is not an id", %{conn: conn} do
      # Unauthenticated, so a path segment that is not an id must not be
      # something anybody passing by can raise a cast error with.
      conn
      |> post(~p"/api/v1/accounts/not-an-id/email_subscriptions", %{
        "email" => "reader@example.com"
      })
      |> json_response(404)
    end

    test "answers 404 for an account that is not there", %{conn: conn} do
      conn
      |> post(~p"/api/v1/accounts/999999999/email_subscriptions", %{
        "email" => "reader@example.com"
      })
      |> json_response(404)
    end

    test "refuses an address that is not one", %{conn: conn, account: account, user: user} do
      open_the_feature(user)

      body =
        conn
        |> post(~p"/api/v1/accounts/#{account.id}/email_subscriptions", %{"email" => "nope"})
        |> json_response(422)

      assert body["error"] =~ "Validation failed"
      drain()
      refute_email_sent()
    end

    test "throttles somebody working through a list", %{conn: conn, account: account, user: user} do
      open_the_feature(user)

      for n <- 1..5 do
        conn
        |> post(~p"/api/v1/accounts/#{account.id}/email_subscriptions", %{
          "email" => "reader#{n}@example.com"
        })
        |> json_response(200)
      end

      conn
      |> post(~p"/api/v1/accounts/#{account.id}/email_subscriptions", %{
        "email" => "reader6@example.com"
      })
      |> json_response(429)
    end
  end

  describe "the page at the end of the link" do
    setup %{account: account, user: user} do
      open_the_feature(user)
      :ok = EmailSubscriptions.subscribe(account, "reader@example.com")
      [subscription] = Abuuba.Repo.all(Abuuba.EmailSubscriptions.Subscription)

      %{subscription: subscription}
    end

    test "offers to confirm", %{conn: conn, subscription: subscription} do
      body =
        conn
        |> get(~p"/email_subscriptions/#{subscription.token}")
        |> html_response(200)

      assert body =~ "reader@example.com"
      assert body =~ "/confirm"
    end

    test "does not confirm on being opened", %{conn: conn, subscription: subscription} do
      # A mail client fetching every link in a message must not subscribe
      # somebody who never read it.
      conn |> get(~p"/email_subscriptions/#{subscription.token}") |> html_response(200)

      assert is_nil(Abuuba.Repo.reload!(subscription).confirmed_at)
    end

    test "confirms when the button is pressed", %{conn: conn, subscription: subscription} do
      conn
      |> post(~p"/email_subscriptions/#{subscription.token}/confirm")
      |> redirected_to()

      assert Abuuba.Repo.reload!(subscription).confirmed_at
    end

    test "stops the updates when that button is pressed", %{
      conn: conn,
      subscription: subscription
    } do
      conn
      |> post(~p"/email_subscriptions/#{subscription.token}/unsubscribe")
      |> redirected_to()

      assert is_nil(EmailSubscriptions.by_token(subscription.token))
    end

    test "says nothing useful about a token that is not one", %{conn: conn} do
      conn |> get(~p"/email_subscriptions/nonsense") |> redirected_to()
    end

    test "does not blow up confirming a row that went in the meantime", %{
      conn: conn,
      subscription: subscription
    } do
      # Two tabs on the same link: "remove my address" in one, "yes, send them"
      # in the other.
      :ok = EmailSubscriptions.unsubscribe(subscription)

      assert {:error, :gone} = EmailSubscriptions.confirm(subscription)

      conn
      |> post(~p"/email_subscriptions/#{subscription.token}/confirm")
      |> redirected_to()
    end
  end
end
