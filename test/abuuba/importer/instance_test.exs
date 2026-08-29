defmodule Abuuba.Importer.InstanceTest do
  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts.Account
  alias Abuuba.Importer.Checkpoint
  alias Abuuba.Importer.Instance
  alias Abuuba.Instance.Announcement
  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Invites.Invite
  alias Abuuba.MastodonSource, as: Source
  alias Abuuba.Moderation.Appeal
  alias Abuuba.Moderation.DomainBlock
  alias Abuuba.Moderation.Report
  alias Abuuba.Moderation.Signup.IPBlock
  alias Abuuba.Moderation.Strike
  alias Abuuba.Repo
  alias Abuuba.Settings
  alias Abuuba.Settings.InstanceSetting
  alias Abuuba.Settings.ServerRule
  alias Abuuba.Webhooks.Webhook

  @now ~N[2026-01-01 00:00:00]

  setup do
    Source.create!()
    seed_target!()
    seed_source!()

    on_exit(&Source.drop!/0)

    :ok
  end

  defp opts, do: [repo: Repo, prefix: Source.prefix()]

  describe "how the server was run" do
    test "settings this server understands come across" do
      :ok = Instance.run(opts())

      # Through the reader the rest of the server uses, so a setting that is
      # stored but unreadable would fail here.
      assert Settings.get("site_title") == "Here"
      assert Settings.get("registration_mode") == "approved"
    end

    test "and one it does not is left rather than written" do
      # A setting nothing honours reads as though it is in force, which is
      # worse than an absent one.
      :ok = Instance.run(opts())

      assert is_nil(Settings.get("something_the_importer_never_writes"))
    end

    test "a server that takes nobody is spelled the way this one spells it" do
      # `none` there, `closed` here. Copying the word across would leave a mode
      # nothing recognises, which reads as open.
      :ok = Instance.run(opts())

      assert Settings.get("registration_mode") == "approved"

      Repo.delete_all(InstanceSetting)

      Repo.query!(
        "UPDATE mastodon_settings SET value = '--- none\n' WHERE var = 'registrations_mode'"
      )

      Checkpoint.reset()

      :ok = Instance.run(opts())

      assert Settings.get("registration_mode") == "closed"
    end

    test "rules keep their order, which is the order people read them in" do
      :ok = Instance.run(opts())

      assert %ServerRule{text: "Be kind", position: 1} = Repo.get(ServerRule, 10)
    end

    test "emojis point at the image the source stored" do
      :ok = Instance.run(opts())

      emoji = Repo.get(CustomEmoji, 20)

      assert emoji.shortcode == "party"
      assert emoji.image_url =~ "custom_emojis/images/000/000/020/original/party.png"
    end

    test "and somebody else's is fetched again rather than looked for in a cache" do
      # Cached copies of other servers' files are not copied by the import, so
      # a local cache path would be an address with nothing behind it.
      :ok = Instance.run(opts())

      assert Repo.get(CustomEmoji, 21).image_url == "https://other.example/emoji/wave.png"
    end
  end

  describe "moderation" do
    test "domain blocks keep their severity and their reasoning" do
      :ok = Instance.run(opts())

      block = Repo.get(DomainBlock, 30)

      assert block.domain == "bad.example"
      assert block.severity == "suspend"
      assert block.public_comment == "spam"
    end

    test "an address block keeps the range, not just the address" do
      :ok = Instance.run(opts())

      assert %IPBlock{cidr: "198.51.100.0/24", severity: "no_access"} = Repo.get(IPBlock, 40)
    end

    test "reports keep who was reported and what came of it" do
      :ok = Instance.run(opts())

      report = Repo.get(Report, 50)

      assert report.target_account_id == 2
      assert report.category == "spam"
      assert report.action_taken_by_account_id == 1
    end

    test "strikes keep the report they came from and the action taken" do
      :ok = Instance.run(opts())

      strike = Repo.get(Strike, 60)

      assert strike.report_id == 50
      assert strike.action == "suspend"
      assert strike.target_account_id == 2
    end

    test "the older name for marking posts sensitive means the same thing" do
      :ok = Instance.run(opts())

      assert Repo.get(Strike, 61).action == "mark_statuses_as_sensitive"
    end

    test "a strike whose moderator has since left is still moderation history" do
      # The column is nullable on both sides for exactly this reason, and
      # dropping the row would also drop the appeal hanging off it.
      :ok = Instance.run(opts())

      assert %Strike{account_id: nil, target_account_id: 2} = Repo.get(Strike, 62)
      assert Repo.get(Appeal, 90)
    end

    test "an appeal against a strike that did not come across is left behind" do
      # Writing it would point at a row that is not there, which is a foreign
      # key violation that takes the whole batch with it.
      :ok = Instance.run(opts())

      assert is_nil(Repo.get(Appeal, 91))
    end

    test "notes about accounts and about reports land in one place" do
      :ok = Instance.run(opts())

      # The two source tables have their own id sequences, so both hold a row
      # numbered 65. Paging over the pair on that number would drop one of
      # them at a page boundary.
      rows = Repo.query!("SELECT target_type, target_id FROM moderation_notes ORDER BY 1").rows

      assert [["account", 2], ["report", 50]] = rows
    end
  end

  describe "the rest" do
    test "invites keep their code, which somebody has already handed out" do
      :ok = Instance.run(opts())

      assert %Invite{code: "comeonin", uses: 3, account_id: 1} = Repo.get(Invite, 70)
    end

    test "announcements keep whether they were published" do
      :ok = Instance.run(opts())

      assert %Announcement{published: true, text: "Downtime tonight"} = Repo.get(Announcement, 80)
    end

    test "webhooks come across, so an integration keeps working" do
      # An admin's webhooks are how moderation tooling and chat rooms hear
      # about this server. Dropping them silently means the integration stops
      # and nothing says why: no error, no empty screen, just a room that goes
      # quiet.
      :ok = Instance.run(opts())

      assert %Webhook{
               url: "https://ops.example/hook",
               enabled: true,
               secret: "s3cret-and-long-enough"
             } = webhook = Repo.get(Webhook, 90)

      # The event names are the same seven words on both sides, so they copy
      # across rather than being translated.
      assert webhook.events == ["account.created", "report.created"]
    end

    test "and a disabled one stays disabled" do
      # Re-enabling somebody's switched-off webhook on their behalf would start
      # posting to an endpoint they had deliberately quietened.
      :ok = Instance.run(opts())

      assert %Webhook{enabled: false} = Repo.get(Webhook, 91)
    end

    test "run twice without doubling anything" do
      :ok = Instance.run(opts())
      :ok = Instance.run(opts())

      assert Repo.aggregate(ServerRule, :count) == 1
      assert Repo.aggregate(DomainBlock, :count) == 1
    end
  end

  ## Fixtures

  defp seed_target! do
    Repo.insert_all(Account, [
      %{
        id: 1,
        username: "mod",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: 2,
        username: "spammer",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    Repo.insert_all("users", [
      %{
        id: 30,
        account_id: 1,
        email: "mod@example.com",
        approved: true,
        settings: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])
  end

  defp seed_source! do
    # The invite names the user who made it, and the user is what carries the
    # account: the same join the import does.
    Source.insert!("users", %{
      "id" => 30,
      "account_id" => 1,
      "email" => "mod@example.com",
      "created_at" => @now,
      "updated_at" => @now
    })

    for {var, value} <- [
          {"site_title", "--- Here\n"},
          {"registrations_mode", "--- approved\n"},
          {"custom_css", "--- body { color: red }\n"}
        ] do
      Source.insert!("settings", %{
        "id" => :erlang.phash2(var, 100_000),
        "var" => var,
        "value" => value,
        "created_at" => @now,
        "updated_at" => @now
      })
    end

    Source.insert!("rules", %{
      "id" => 10,
      "text" => "Be kind",
      "priority" => 1,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("custom_emojis", %{
      "id" => 20,
      "shortcode" => "party",
      "image_file_name" => "party.png",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("custom_emojis", %{
      "id" => 21,
      "shortcode" => "wave",
      "domain" => "other.example",
      "image_file_name" => "wave.png",
      "image_remote_url" => "https://other.example/emoji/wave.png",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("domain_blocks", %{
      "id" => 30,
      "domain" => "bad.example",
      "severity" => 1,
      "public_comment" => "spam",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("webhooks", %{
      "id" => 90,
      "url" => "https://ops.example/hook",
      "events" => ["account.created", "report.created"],
      "secret" => "s3cret-and-long-enough",
      "enabled" => true,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("webhooks", %{
      "id" => 91,
      "url" => "https://quiet.example/hook",
      "events" => ["status.created"],
      "secret" => "another-long-secret",
      "enabled" => false,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("ip_blocks", %{
      "id" => 40,
      "ip" => %Postgrex.INET{address: {198, 51, 100, 0}, netmask: 24},
      "severity" => 9_999,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("reports", %{
      "id" => 50,
      "account_id" => 1,
      "target_account_id" => 2,
      "category" => 1_000,
      "action_taken_at" => @now,
      "action_taken_by_account_id" => 1,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("account_warnings", %{
      "id" => 60,
      "account_id" => 1,
      "target_account_id" => 2,
      "action" => 4_000,
      "report_id" => 50,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("account_warnings", %{
      "id" => 61,
      "account_id" => 1,
      "target_account_id" => 2,
      "action" => 2_000,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("account_warnings", %{
      "id" => 62,
      "account_id" => nil,
      "target_account_id" => 2,
      "action" => 0,
      "created_at" => @now,
      "updated_at" => @now
    })

    # Against a warning with no target, which is not imported.
    Source.insert!("account_warnings", %{
      "id" => 63,
      "account_id" => 1,
      "target_account_id" => nil,
      "action" => 0,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("appeals", %{
      "id" => 90,
      "account_id" => 2,
      "account_warning_id" => 62,
      "text" => "it was not me",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("appeals", %{
      "id" => 91,
      "account_id" => 2,
      "account_warning_id" => 63,
      "text" => "orphaned",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("account_moderation_notes", %{
      "id" => 65,
      "account_id" => 1,
      "target_account_id" => 2,
      "content" => "seen before",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("report_notes", %{
      "id" => 65,
      "account_id" => 1,
      "report_id" => 50,
      "content" => "handled",
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("invites", %{
      "id" => 70,
      "user_id" => 30,
      "code" => "comeonin",
      "uses" => 3,
      "created_at" => @now,
      "updated_at" => @now
    })

    Source.insert!("announcements", %{
      "id" => 80,
      "text" => "Downtime tonight",
      "published" => true,
      "created_at" => @now,
      "updated_at" => @now
    })
  end
end
