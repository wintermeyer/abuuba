defmodule Abuuba.DomainsTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Federation.Activity.Flag
  alias Abuuba.Federation.Availability
  alias Abuuba.Federation.Inbox
  alias Abuuba.Federation.URIs
  alias Abuuba.Moderation.Actions
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.Domains
  alias Abuuba.Moderation.Reports
  alias Abuuba.Notifications
  alias Abuuba.Relationships
  alias Abuuba.Settings

  setup do
    %{moderator: account_fixture()}
  end

  defp remote(domain, attrs \\ %{}) do
    remote_account_fixture(Map.merge(%{domain: domain}, attrs))
  end

  describe "writing one down" do
    test "a block names a domain and how far it goes", %{moderator: mod} do
      assert {:ok, block} =
               Domains.block(mod, %{
                 "domain" => "Bad.Example",
                 "severity" => "silence",
                 "public_comment" => "Nothing but spam."
               })

      assert block.domain == "bad.example"
      assert block.severity == "silence"
    end

    test "refuses a severity nobody defined", %{moderator: mod} do
      assert {:error, changeset} =
               Domains.block(mod, %{"domain" => "bad.example", "severity" => "vanish"})

      assert %{severity: [_]} = errors_on(changeset)
    end

    test "refuses this server's own domain", %{moderator: mod} do
      # Blocking ourselves silences every local account at once, which is one
      # typo away from taking the whole server down.
      assert {:error, changeset} =
               Domains.block(mod, %{"domain" => URIs.local_domain()})

      assert %{domain: [_]} = errors_on(changeset)
    end

    test "one row per domain", %{moderator: mod} do
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example"})

      assert {:error, changeset} = Domains.block(mod, %{"domain" => "bad.example"})
      assert %{domain: [_]} = errors_on(changeset)
    end

    test "writes to the audit log", %{moderator: mod} do
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example"})

      assert [%{action: "domain_block.create"}] = AuditLog.by_actor(mod)
    end
  end

  describe "which block applies" do
    test "the domain's own", %{moderator: mod} do
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example"})

      assert Domains.block_for("bad.example").id == block.id
    end

    test "a parent domain's, for a subdomain", %{moderator: mod} do
      # Otherwise blocking a server is undone by whoever runs it pointing a
      # subdomain at the same machine.
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example"})

      assert Domains.block_for("users.bad.example").id == block.id
    end

    test "the most specific one where both exist", %{moderator: mod} do
      {:ok, _wide} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      {:ok, narrow} =
        Domains.block(mod, %{"domain" => "ok.bad.example", "severity" => "silence"})

      assert Domains.block_for("ok.bad.example").id == narrow.id
      assert Domains.severity("ok.bad.example") == "silence"
      assert Domains.severity("other.bad.example") == "suspend"
    end

    test "not a domain that merely ends the same way", %{moderator: mod} do
      # "example.com" and "notbad.example" share a suffix and nothing else.
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example"})

      assert Domains.block_for("notbad.example") == nil
    end

    test "nothing at all for a domain nobody wrote down" do
      assert Domains.block_for("fine.example") == nil
      assert Domains.severity("fine.example") == "noop"
    end
  end

  describe "applying a silence" do
    test "silences the accounts already here", %{moderator: mod} do
      account = remote("bad.example")

      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "silence"})

      assert Accounts.get_account(account.id).silenced_at
    end

    test "and the ones on its subdomains", %{moderator: mod} do
      account = remote("users.bad.example")

      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "silence"})

      assert Accounts.get_account(account.id).silenced_at
    end

    test "leaves everybody else alone", %{moderator: mod} do
      bystander = remote("fine.example")

      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "silence"})

      refute Accounts.get_account(bystander.id).silenced_at
    end

    test "keeps the follows somebody chose", %{moderator: mod} do
      # A silence is "not in front of people who did not ask for it", not "cut
      # off from the people who did".
      local = account_fixture()
      them = remote("bad.example")
      {:ok, _} = Relationships.follow(local, them)

      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "silence"})

      assert Relationships.following?(local, them)
    end
  end

  describe "applying a suspension" do
    setup %{moderator: mod} do
      local = account_fixture()
      them = remote("bad.example")

      %{local: local, them: them, mod: mod}
    end

    test "suspends the accounts already here", %{moderator: mod, them: them} do
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      assert Accounts.get_account(them.id).suspended_at
    end

    test "severs the follows in both directions", %{moderator: mod, local: local, them: them} do
      other = remote("bad.example")
      {:ok, _} = Relationships.follow(local, them)
      {:ok, _} = Relationships.follow(other, local)

      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      refute Relationships.following?(local, them)
      refute Relationships.following?(other, local)
    end

    test "records what each local account lost", %{moderator: mod, local: local, them: them} do
      # The accounts on the other side cannot be asked afterwards, so the
      # record is the only thing that can answer "who did I follow there".
      {:ok, _} = Relationships.follow(local, them)

      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      assert [severed] = Domains.severed_for(local)
      assert severed.remote_account_id == them.id
      assert severed.direction == "active"
    end

    test "tells the local accounts that lost something", %{
      moderator: mod,
      local: local,
      them: them
    } do
      {:ok, _} = Relationships.follow(local, them)

      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      assert [%{type: "severed_relationships"}] = Notifications.list(local)
    end

    test "tells nobody who lost nothing", %{moderator: mod} do
      bystander = account_fixture()

      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      assert Notifications.list(bystander) == []
    end

    test "records the event even when nothing was following", %{moderator: mod} do
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      assert [event] = Domains.severance_events()
      assert event.target_name == "bad.example"
      assert event.type == "domain_block"
    end
  end

  describe "changing one afterwards" do
    test "raising the severity applies the harder one", %{moderator: mod} do
      local = account_fixture()
      them = remote("bad.example")
      {:ok, _} = Relationships.follow(local, them)
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "silence"})

      {:ok, _} = Domains.update_block(mod, block, %{"severity" => "suspend"})

      assert Accounts.get_account(them.id).suspended_at
      refute Relationships.following?(local, them)
    end

    test "lowering it lifts what the harder one did", %{moderator: mod} do
      # What was severed stays severed, because the relationships are gone and
      # this end cannot recreate consent on the other one.
      them = remote("bad.example")
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      {:ok, _} = Domains.update_block(mod, block, %{"severity" => "silence"})

      account = Accounts.get_account(them.id)

      refute account.suspended_at
      assert account.silenced_at
    end

    test "editing the comment does not re-sever anything", %{moderator: mod} do
      # A severance event is the record of a decision. Writing a new one every
      # time somebody fixes a typo in the note would make the list of what this
      # server has done to people unreadable.
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      {:ok, _} = Domains.update_block(mod, block, %{"public_comment" => "Now with a reason."})

      assert [_one] = Domains.severance_events()
    end

    test "dropping to nothing lifts both", %{moderator: mod} do
      them = remote("bad.example")
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "silence"})

      {:ok, _} = Domains.update_block(mod, block, %{"severity" => "noop"})

      account = Accounts.get_account(them.id)

      refute account.silenced_at
      refute account.suspended_at
    end
  end

  describe "lifting one" do
    test "takes the block off and lets the accounts back", %{moderator: mod} do
      them = remote("bad.example")
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      assert :ok = Domains.unblock(mod, block)

      account = Accounts.get_account(them.id)

      assert Domains.block_for("bad.example") == nil
      refute account.suspended_at
      refute account.purge_after
    end

    test "leaves an account a wider block still covers", %{moderator: mod} do
      # Lifting the block on one subdomain must not quietly lift the block on
      # the whole server it sits under.
      them = remote("ok.bad.example")
      {:ok, _wide} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      {:ok, narrow} =
        Domains.block(mod, %{"domain" => "ok.bad.example", "severity" => "silence"})

      assert :ok = Domains.unblock(mod, narrow)

      assert Accounts.get_account(them.id).suspended_at
    end

    test "leaves an account somebody was silenced for their own reasons", %{moderator: mod} do
      # The domain block covered them, but a moderator had already decided
      # about this account on its own. Lifting the wider decision must not
      # quietly undo the narrower one nobody revisited.
      them = remote("bad.example")
      {:ok, _} = Actions.take(mod, them, "silence", text: "Their own doing.")
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      :ok = Domains.unblock(mod, block)

      account = Accounts.get_account(them.id)

      refute account.suspended_at
      assert account.silenced_at
    end

    test "writes to the audit log", %{moderator: mod} do
      {:ok, block} = Domains.block(mod, %{"domain" => "bad.example"})

      :ok = Domains.unblock(mod, block)

      assert Enum.any?(
               AuditLog.by_actor(mod),
               &(&1.action == "domain_block.undo")
             )
    end
  end

  describe "what a block means elsewhere" do
    test "a suspended domain is refused", %{moderator: mod} do
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      assert Domains.suspended?("bad.example")
      assert Domains.suspended?("users.bad.example")
      refute Domains.accepts_from?("bad.example")
      refute Domains.delivers_to?("bad.example")
    end

    test "a silenced domain still talks to us", %{moderator: mod} do
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "silence"})

      assert Domains.silenced?("bad.example")
      assert Domains.accepts_from?("bad.example")
      assert Domains.delivers_to?("bad.example")
    end

    test "media and reports can be refused on their own", %{moderator: mod} do
      {:ok, _} =
        Domains.block(mod, %{
          "domain" => "bad.example",
          "severity" => "noop",
          "reject_media" => true,
          "reject_reports" => true
        })

      assert Domains.reject_media?("bad.example")
      assert Domains.reject_reports?("bad.example")
      assert Domains.accepts_from?("bad.example")
    end

    test "a domain nobody wrote down is refused nothing" do
      assert Domains.accepts_from?("fine.example")
      assert Domains.delivers_to?("fine.example")
      refute Domains.reject_media?("fine.example")
      refute Domains.reject_reports?("fine.example")
    end
  end

  describe "the public list" do
    test "leaves out what was only written for moderators", %{moderator: mod} do
      {:ok, _} =
        Domains.block(mod, %{
          "domain" => "bad.example",
          "public_comment" => "Spam.",
          "private_comment" => "Reported by three people we know."
        })

      assert [entry] = Domains.public_blocks()
      assert entry.comment == "Spam."
      refute Map.has_key?(entry, :private_comment)
    end

    test "obfuscates a domain that asked to be", %{moderator: mod} do
      {:ok, _} =
        Domains.block(mod, %{"domain" => "bad.example", "obfuscate" => true})

      assert [entry] = Domains.public_blocks()

      refute entry.domain == "bad.example"
      assert entry.domain =~ "*"
      assert String.ends_with?(entry.domain, "example")
    end

    test "leaves out the ones that do nothing visible", %{moderator: mod} do
      # A row that only sets reject_media is a decision about our own storage,
      # not a statement about that server for the world to read.
      {:ok, _} =
        Domains.block(mod, %{
          "domain" => "bad.example",
          "severity" => "noop",
          "reject_media" => true
        })

      assert Domains.public_blocks() == []
    end
  end

  describe "carrying a list between servers" do
    test "exports what was written down", %{moderator: mod} do
      {:ok, _} =
        Domains.block(mod, %{
          "domain" => "bad.example",
          "severity" => "suspend",
          "public_comment" => "Spam."
        })

      csv = Domains.export_csv()

      assert csv =~ "#domain,#severity"
      assert csv =~ "bad.example,suspend"
      assert csv =~ "Spam."
    end

    test "imports one back", %{moderator: mod} do
      csv = """
      #domain,#severity,#reject_media,#reject_reports,#public_comment,#obfuscate
      bad.example,suspend,true,true,Spam.,false
      worse.example,silence,false,false,,false
      """

      assert {:ok, %{created: 2, skipped: 0}} = Domains.import_csv(mod, csv)

      assert Domains.severity("bad.example") == "suspend"
      assert Domains.reject_media?("bad.example")
      assert Domains.severity("worse.example") == "silence"
    end

    test "a round trip says the same thing", %{moderator: mod} do
      {:ok, _} =
        Domains.block(mod, %{
          "domain" => "bad.example",
          "severity" => "suspend",
          "reject_media" => true,
          "public_comment" => "Spam, and a comma, at that."
        })

      csv = Domains.export_csv()
      block = Domains.block_for("bad.example")
      :ok = Domains.unblock(mod, block)

      {:ok, %{created: 1}} = Domains.import_csv(mod, csv)

      restored = Domains.block_for("bad.example")

      assert restored.severity == "suspend"
      assert restored.reject_media
      assert restored.public_comment == "Spam, and a comma, at that."
    end

    test "skips what is already there rather than failing on it", %{moderator: mod} do
      # A shared blocklist is imported again every time it is updated, and
      # refusing the whole file over one row already present is what makes
      # somebody stop importing it.
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "silence"})

      csv = """
      #domain,#severity
      bad.example,suspend
      new.example,suspend
      """

      assert {:ok, %{created: 1, skipped: 1}} = Domains.import_csv(mod, csv)
      assert Domains.severity("bad.example") == "silence"
      assert Domains.severity("new.example") == "suspend"
    end

    test "skips a row it cannot read", %{moderator: mod} do
      csv = """
      #domain,#severity
      ,suspend
      good.example,vanish
      new.example,suspend
      """

      assert {:ok, %{created: 1, skipped: 2}} = Domains.import_csv(mod, csv)
      assert Domains.severity("new.example") == "suspend"
    end
  end

  describe "the allowlist" do
    test "is off unless the server says otherwise" do
      refute Domains.limited_federation?()
      assert Domains.accepts_from?("anybody.example")
    end

    test "refuses everybody who is not on it when it is on", %{moderator: mod} do
      :ok = Settings.put("limited_federation", true)
      {:ok, _} = Domains.allow(mod, "friend.example")

      assert Domains.limited_federation?()
      assert Domains.accepts_from?("friend.example")
      assert Domains.delivers_to?("friend.example")
      refute Domains.accepts_from?("stranger.example")
      refute Domains.delivers_to?("stranger.example")
    end

    test "covers the subdomains of what is on it", %{moderator: mod} do
      :ok = Settings.put("limited_federation", true)
      {:ok, _} = Domains.allow(mod, "friend.example")

      assert Domains.accepts_from?("users.friend.example")
    end

    test "still refuses a domain that is allowed and suspended", %{moderator: mod} do
      # An allow is not an exemption from a block. If both are written down the
      # block is the more recent decision about that server's behaviour.
      :ok = Settings.put("limited_federation", true)
      {:ok, _} = Domains.allow(mod, "friend.example")
      {:ok, _} = Domains.block(mod, %{"domain" => "friend.example", "severity" => "suspend"})

      refute Domains.accepts_from?("friend.example")
    end

    test "can be taken off again", %{moderator: mod} do
      :ok = Settings.put("limited_federation", true)
      {:ok, allow} = Domains.allow(mod, "friend.example")

      :ok = Domains.disallow(mod, allow)

      refute Domains.accepts_from?("friend.example")
    end

    test "this server is never refused by its own allowlist" do
      # Every local delivery decision runs through the same predicate.
      :ok = Settings.put("limited_federation", true)

      assert Domains.accepts_from?(URIs.local_domain())
    end
  end

  describe "what the rest of the server does with a block" do
    test "an inbox refuses an activity from a suspended domain", %{moderator: mod} do
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      assert Inbox.acceptable_actor?("https://bad.example/users/x") == false
      assert Inbox.acceptable_actor?("https://fine.example/users/x")
    end

    test "a report forwarded from a domain that may not send them is dropped", %{moderator: mod} do
      # A server whose reports we do not want is a server whose reports must
      # not reach the queue, not one whose reports a moderator has to sift.
      {:ok, _} =
        Domains.block(mod, %{
          "domain" => "bad.example",
          "severity" => "noop",
          "reject_reports" => true
        })

      target = account_fixture()
      reporter = remote("bad.example")

      assert :ok =
               Flag.handle(
                 %{
                   "type" => "Flag",
                   "actor" => reporter.uri,
                   "object" => [target.uri],
                   "content" => "Look at this."
                 },
                 actor_uri: reporter.uri
               )

      assert Reports.open_count() == 0
    end

    test "delivery skips a suspended domain", %{moderator: mod} do
      {:ok, _} = Domains.block(mod, %{"domain" => "bad.example", "severity" => "suspend"})

      refute Domains.delivers_to?("bad.example")
    end
  end

  describe "delivery to one instance" do
    test "can be stopped by hand", %{moderator: mod} do
      :ok = Domains.stop_delivery(mod, "slow.example")

      assert Availability.unavailable?("slow.example")
      refute Domains.delivers_to?("slow.example")
    end

    test "and is not restarted by them talking to us", %{moderator: mod} do
      # A domain given up on after a week of failures comes back the moment it
      # says something. One an admin stopped on purpose did not mean "until
      # they say something".
      :ok = Domains.stop_delivery(mod, "slow.example")

      :ok = Availability.record_success("slow.example")

      assert Availability.unavailable?("slow.example")
    end

    test "restarting it clears the failures too", %{moderator: mod} do
      :ok = Availability.record_failure("slow.example")
      :ok = Domains.stop_delivery(mod, "slow.example")

      :ok = Domains.restart_delivery(mod, "slow.example")

      refute Availability.unavailable?("slow.example")
      assert Availability.failure_day_count("slow.example") == 0
    end

    test "writes both to the audit log", %{moderator: mod} do
      :ok = Domains.stop_delivery(mod, "slow.example")
      :ok = Domains.restart_delivery(mod, "slow.example")

      actions = Enum.map(AuditLog.by_actor(mod), & &1.action)

      assert "instance.stop_delivery" in actions
      assert "instance.restart_delivery" in actions
    end
  end
end
