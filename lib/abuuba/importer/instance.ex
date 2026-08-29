defmodule Abuuba.Importer.Instance do
  @moduledoc """
  How the server itself was run, and every decision made while running it.

  A takeover that arrives with an empty moderation history is one where every
  block has to be argued again, every strike is invisible to the moderator who
  has to judge the next one, and the domain blocks that made the place liveable
  are gone. None of it is recoverable and all of it is somebody's work.

  ## Settings are translated, not copied

  The source keeps them as one row per key with a YAML-ish value; abuuba keeps
  the same shape but a smaller set of keys. Only the keys that mean something
  here come across, and the rest are left rather than written into a table that
  nothing reads — a setting nothing honours is worse than an absent one,
  because it reads as though it is in force.

  ## Moderation history keeps its authors

  A strike names the moderator who issued it and the report it came from. Those
  references are what make the history readable a year later, so they are
  carried rather than flattened into text.
  """

  @behaviour Abuuba.Importer.Step

  alias Abuuba.Importer.Batch
  alias Abuuba.Importer.Source
  alias Abuuba.Instance.Announcement
  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Instance.TermsOfService
  alias Abuuba.Invites.Invite
  alias Abuuba.Media.Storage
  alias Abuuba.Moderation.Appeal
  alias Abuuba.Moderation.DomainAllow
  alias Abuuba.Moderation.DomainBlock
  alias Abuuba.Moderation.Report
  alias Abuuba.Moderation.Signup.CanonicalEmailBlock
  alias Abuuba.Moderation.Signup.EmailDomainBlock
  alias Abuuba.Moderation.Signup.IPBlock
  alias Abuuba.Moderation.Signup.UsernameBlock
  alias Abuuba.Moderation.Strike
  alias Abuuba.Settings.InstanceSetting
  alias Abuuba.Settings.ServerRule
  alias Abuuba.Webhooks.Webhook

  # What the source calls a setting, and what abuuba calls the same thing. Only
  # the ones abuuba actually reads: see the moduledoc.
  @settings %{
    "site_title" => "site_title",
    "site_short_description" => "site_short_description",
    "site_contact_email" => "site_contact_email",
    "site_contact_username" => "site_contact_username",
    "registrations_mode" => "registration_mode",
    "closed_registrations_message" => "closed_registrations_message",
    "require_invite_text" => "require_invite_text",
    "show_domain_blocks" => "show_domain_blocks",
    "show_domain_blocks_rationale" => "show_domain_blocks_rationale",
    "media_cache_retention_period" => "media_cache_retention_period",
    "content_cache_retention_period" => "content_cache_retention_period",
    "backups_retention_period" => "backups_retention_period",
    "trends" => "trends_enabled",
    "trendable_by_default" => "trendable_by_default",
    "noindex" => "noindex",
    "theme" => "theme"
  }

  @impl Abuuba.Importer.Step
  @spec run(keyword()) :: :ok | {:error, {atom(), term()}}
  def run(opts), do: Batch.run_parts(opts, parts())

  # Reports before strikes, because a strike names one; strikes before appeals,
  # for the same reason.
  defp parts do
    [
      {:settings, &copy_settings/2},
      {:rules, &copy_rules/2},
      {:terms_of_service, &copy_terms/2},
      {:custom_emojis, &copy_emojis/2},
      {:domain_blocks, &copy_domain_blocks/2},
      {:domain_allows, &copy_domain_allows/2},
      {:email_domain_blocks, &copy_email_blocks/2},
      {:canonical_email_blocks, &copy_canonical_blocks/2},
      {:ip_blocks, &copy_ip_blocks/2},
      {:username_blocks, &copy_username_blocks/2},
      {:invites, &copy_invites/2},
      {:announcements, &copy_announcements/2},
      {:announcement_reactions, &copy_reactions/2},
      {:announcement_dismissals, &copy_dismissals/2},
      {:reports, &copy_reports/2},
      {:strikes, &copy_strikes/2},
      {:appeals, &copy_appeals/2},
      {:account_notes, &copy_account_notes/2},
      {:report_notes, &copy_report_notes/2},
      {:audit_log, &copy_audit_log/2},
      {:relays, &copy_relays/2},
      {:webhooks, &copy_webhooks/2}
    ]
  end

  ## Settings and rules

  defp copy_settings(opts, name) do
    sql = "SELECT * FROM #{table(opts, "settings")}"

    copy(opts, name, InstanceSetting, sql, fn row ->
      case Map.fetch(@settings, row["var"]) do
        {:ok, key} ->
          %{
            key: key,
            # Wrapped, because that is the shape `Abuuba.Settings` reads: the
            # column holds a document rather than a scalar so that a setting
            # can grow a second field without a migration.
            value: %{"value" => setting_value(key, value(row["value"]))},
            # Nullable over there and required here. A setting with no time is
            # still a setting, and refusing it would take the first part of
            # this step down over a column nothing reads.
            inserted_at: at(row["created_at"]) || DateTime.utc_now(),
            updated_at: at(row["updated_at"]) || DateTime.utc_now()
          }

        :error ->
          nil
      end
    end)
  end

  # Stored as a YAML scalar on the source, which for every key that matters is
  # a quoted string, a bare word, or a number. Anything with a newline in it is
  # a structure abuuba has no counterpart for and is dropped rather than stored
  # half-read.
  defp value(nil), do: ""

  defp value(raw) do
    trimmed =
      raw
      |> String.replace_prefix("--- ", "")
      |> String.trim()
      |> String.trim("\n")

    cond do
      String.contains?(trimmed, "\n") -> ""
      trimmed in ["'true'", "true"] -> "true"
      trimmed in ["'false'", "false"] -> "false"
      true -> String.trim(trimmed, "'")
    end
  end

  # The two projects spell one of these differently: a server taking nobody
  # calls it `none` over there and `closed` here, and copying the word across
  # would leave a mode nothing recognises, which reads as open.
  defp setting_value("registration_mode", "none"), do: "closed"
  defp setting_value(_key, value), do: value

  defp copy_rules(opts, name) do
    sql = "SELECT * FROM #{table(opts, "rules")}"

    copy(opts, name, ServerRule, sql, fn row ->
      %{
        id: row["id"],
        text: row["text"] || "",
        hint: row["hint"] || "",
        position: row["priority"] || 0,
        deleted_at: at(row["deleted_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_terms(opts, name) do
    sql = "SELECT * FROM #{table(opts, "terms_of_services")}"

    copy(opts, name, TermsOfService, sql, fn row ->
      # A draft nobody has dated is not terms anybody agreed to.
      if row["effective_date"] do
        %{
          id: row["id"],
          text: row["text"] || "",
          effective_date: row["effective_date"],
          published_at: at(row["published_at"]),
          notified_at: at(row["notification_sent_at"]),
          inserted_at: at(row["created_at"]),
          updated_at: at(row["updated_at"])
        }
      end
    end)
  end

  ## Emojis

  # The image is a file in the tree that gets copied, so the URL is built from
  # the path the source gave it rather than from anything new.
  defp copy_emojis(opts, name) do
    sql = "SELECT * FROM #{table(opts, "custom_emojis")}"

    copy(opts, name, CustomEmoji, sql, fn row ->
      # An emoji with no image is one nothing can render, so it is skipped
      # rather than written as a broken row.
      case emoji_url(row) do
        nil -> nil
        url -> emoji_row(row, url)
      end
    end)
  end

  defp emoji_row(row, url) do
    %{
      id: row["id"],
      shortcode: row["shortcode"],
      domain: presence(row["domain"]),
      image_url: url,
      # abuuba keeps a still copy for people who asked not to see animation.
      # The source generates one on demand from the same file, so until one
      # is made the original stands in.
      static_url: url,
      visible_in_picker: row["visible_in_picker"] != false,
      disabled: row["disabled"] == true,
      category: nil,
      inserted_at: at(row["created_at"]),
      updated_at: at(row["updated_at"])
    }
  end

  # Somebody else's emoji is a cached copy of their file, and cached files are
  # not copied by the import — they are re-fetched. So the address that keeps
  # working is the one it can be fetched from again, and the local path is only
  # used for emoji this server made.
  defp emoji_url(%{"domain" => domain} = row) when is_binary(domain) and domain != "" do
    presence(row["image_remote_url"])
  end

  defp emoji_url(%{"image_file_name" => file} = row) when is_binary(file) and file != "" do
    Storage.url("custom_emojis/images/#{Storage.partition(row["id"])}/original/#{file}")
  end

  defp emoji_url(row), do: presence(row["image_remote_url"])

  ## Blocks

  defp copy_domain_blocks(opts, name) do
    sql = "SELECT * FROM #{table(opts, "domain_blocks")}"

    copy(opts, name, DomainBlock, sql, fn row ->
      %{
        id: row["id"],
        domain: row["domain"],
        severity: severity(row["severity"]),
        reject_media: row["reject_media"] == true,
        reject_reports: row["reject_reports"] == true,
        private_comment: presence(row["private_comment"]),
        public_comment: presence(row["public_comment"]),
        obfuscate: row["obfuscate"] == true,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_domain_allows(opts, name) do
    sql = "SELECT * FROM #{table(opts, "domain_allows")}"

    copy(opts, name, DomainAllow, sql, fn row ->
      %{
        id: row["id"],
        domain: row["domain"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_email_blocks(opts, name) do
    sql = "SELECT * FROM #{table(opts, "email_domain_blocks")}"

    copy(opts, name, EmailDomainBlock, sql, fn row ->
      %{
        id: row["id"],
        domain: row["domain"],
        allow_with_approval: row["allow_with_approval"] == true,
        comment: nil,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_canonical_blocks(opts, name) do
    sql = "SELECT * FROM #{table(opts, "canonical_email_blocks")}"

    copy(opts, name, CanonicalEmailBlock, sql, fn row ->
      %{
        id: row["id"],
        canonical_email_hash: row["canonical_email_hash"],
        reference_account_id: row["reference_account_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_ip_blocks(opts, name) do
    sql =
      "SELECT id, host(ip) AS ip, masklen(ip) AS masklen, severity, expires_at, comment, " <>
        "created_at, updated_at FROM #{table(opts, "ip_blocks")}"

    copy(opts, name, IPBlock, sql, fn row ->
      %{
        id: row["id"],
        cidr: "#{row["ip"]}/#{row["masklen"]}",
        severity: ip_severity(row["severity"]),
        comment: row["comment"] || "",
        expires_at: at(row["expires_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # An admin's webhooks are how moderation tooling and chat rooms hear about
  # this server. Both sides spell the seven event names identically, so they
  # copy across rather than being translated; the source's payload `template`
  # has no counterpart here and is the one thing left behind.
  defp copy_webhooks(opts, name) do
    sql = "SELECT * FROM #{table(opts, "webhooks")}"

    copy(opts, name, Webhook, sql, fn row ->
      %{
        id: row["id"],
        url: row["url"],
        events: row["events"] || [],
        secret: row["secret"] || "",
        enabled: row["enabled"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_username_blocks(opts, name) do
    sql = "SELECT * FROM #{table(opts, "username_blocks")}"

    copy(opts, name, UsernameBlock, sql, fn row ->
      %{
        id: row["id"],
        username: row["username"],
        exact: row["exact"] == true,
        comment: nil,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  ## Invites and announcements

  defp copy_invites(opts, name) do
    sql = """
    SELECT i.*, u.account_id AS account_id
    FROM #{table(opts, "invites")} i
    JOIN #{table(opts, "users")} u ON u.id = i.user_id
    """

    copy(opts, name, Invite, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        code: row["code"],
        comment: presence(row["comment"]),
        expires_at: at(row["expires_at"]),
        max_uses: row["max_uses"],
        uses: row["uses"] || 0,
        autofollow: row["autofollow"] == true,
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_announcements(opts, name) do
    sql = "SELECT * FROM #{table(opts, "announcements")}"

    copy(opts, name, Announcement, sql, fn row ->
      %{
        id: row["id"],
        text: row["text"] || "",
        published: row["published"] == true,
        all_day: row["all_day"] == true,
        scheduled_at: at(row["scheduled_at"]),
        starts_at: at(row["starts_at"]),
        ends_at: at(row["ends_at"]),
        published_at: at(row["published_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_reactions(opts, name) do
    sql = """
    SELECT * FROM #{table(opts, "announcement_reactions")}
    WHERE account_id IS NOT NULL AND announcement_id IS NOT NULL
    """

    copy(opts, name, "announcement_reactions", sql, fn row ->
      %{
        announcement_id: row["announcement_id"],
        account_id: row["account_id"],
        name: row["name"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # A mute over there and a dismissal here: the same row, saying somebody has
  # seen the announcement and does not want it again.
  defp copy_dismissals(opts, name) do
    sql = """
    SELECT * FROM #{table(opts, "announcement_mutes")}
    WHERE account_id IS NOT NULL AND announcement_id IS NOT NULL
    """

    copy(opts, name, "announcement_dismissals", sql, fn row ->
      %{
        announcement_id: row["announcement_id"],
        account_id: row["account_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  ## Moderation history

  defp copy_reports(opts, name) do
    sql = "SELECT * FROM #{table(opts, "reports")}"

    copy(opts, name, Report, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        target_account_id: row["target_account_id"],
        comment: row["comment"] || "",
        uri: presence(row["uri"]),
        forwarded: row["forwarded"] == true,
        category: category(row["category"]),
        status_ids: row["status_ids"] || [],
        rule_ids: row["rule_ids"] || [],
        assigned_account_id: row["assigned_account_id"],
        action_taken_at: at(row["action_taken_at"]),
        action_taken_by_account_id: row["action_taken_by_account_id"],
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_strikes(opts, name) do
    # The moderator column is nullable on both sides, because a moderator can
    # leave and the record of what they did stays. Only the account the strike
    # was against has to be there.
    sql = """
    SELECT * FROM #{table(opts, "account_warnings")}
    WHERE target_account_id IS NOT NULL
    """

    copy(opts, name, Strike, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        target_account_id: row["target_account_id"],
        action: strike_action(row["action"]),
        text: row["text"] || "",
        status_ids: row["status_ids"] || [],
        report_id: row["report_id"],
        overruled_at: at(row["overruled_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_appeals(opts, name) do
    # Joined to the strikes under the same condition they were copied under: an
    # appeal against a strike that did not come across would point at a row
    # that is not there.
    sql = """
    SELECT a.* FROM #{table(opts, "appeals")} a
    JOIN #{table(opts, "account_warnings")} w
      ON w.id = a.account_warning_id AND w.target_account_id IS NOT NULL
    """

    copy(opts, name, Appeal, sql, fn row ->
      %{
        id: row["id"],
        account_id: row["account_id"],
        account_warning_id: row["account_warning_id"],
        text: row["text"] || "",
        approved_at: at(row["approved_at"]),
        approved_by_account_id: row["approved_by_account_id"],
        rejected_at: at(row["rejected_at"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  # Two tables over there, one here: a note about an account and a note about a
  # report are the same thing said about different subjects, and abuuba says
  # which with a column.
  #
  # Copied as two parts rather than one union, because the two source tables
  # have their own id sequences and both start at one. Paging over the pair on
  # that number would drop whichever of a colliding pair fell on the far side
  # of a page boundary.
  defp copy_account_notes(opts, name) do
    sql = "SELECT * FROM #{table(opts, "account_moderation_notes")}"

    copy(opts, name, "moderation_notes", sql, &note(&1, "account", &1["target_account_id"]))
  end

  defp copy_report_notes(opts, name) do
    sql = "SELECT * FROM #{table(opts, "report_notes")}"

    copy(opts, name, "moderation_notes", sql, &note(&1, "report", &1["report_id"]))
  end

  defp note(row, target_type, target_id) do
    %{
      account_id: row["account_id"],
      target_type: target_type,
      target_id: target_id,
      content: row["content"],
      inserted_at: at(row["created_at"]),
      updated_at: at(row["updated_at"])
    }
  end

  defp copy_audit_log(opts, name) do
    sql = "SELECT * FROM #{table(opts, "admin_action_logs")} WHERE account_id IS NOT NULL"

    copy(opts, name, "audit_log_entries", sql, fn row ->
      %{
        account_id: row["account_id"],
        action: row["action"],
        # Both required here. An entry the source wrote without a subject is
        # still a record that somebody did something, and saying the subject is
        # unknown is more honest than dropping the line.
        target_type: presence(row["target_type"]) || "unknown",
        target_id: row["target_id"] || 0,
        target_label: presence(row["human_identifier"]),
        details: %{},
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  defp copy_relays(opts, name) do
    sql = "SELECT * FROM #{table(opts, "relays")}"

    copy(opts, name, Abuuba.Federation.Relay, sql, fn row ->
      %{
        id: row["id"],
        inbox_url: row["inbox_url"],
        state: relay_state(row["state"]),
        follow_activity_id: presence(row["follow_activity_id"]),
        inserted_at: at(row["created_at"]),
        updated_at: at(row["updated_at"])
      }
    end)
  end

  ## The enums

  defp severity(1), do: "suspend"
  defp severity(2), do: "noop"
  defp severity(_silence), do: "silence"

  defp ip_severity(5_500), do: "sign_up_block"
  defp ip_severity(9_999), do: "no_access"
  defp ip_severity(_approval), do: "sign_up_requires_approval"

  defp category(1_000), do: "spam"
  defp category(1_500), do: "legal"
  defp category(2_000), do: "violation"
  defp category(_other), do: "other"

  defp strike_action(1_000), do: "disable"
  # `sensitive` and `mark_statuses_as_sensitive` are the same decision under
  # two names on the source; abuuba keeps only the longer one.
  defp strike_action(action) when action in [1_250, 2_000], do: "mark_statuses_as_sensitive"
  defp strike_action(1_500), do: "delete_statuses"
  defp strike_action(3_000), do: "silence"
  defp strike_action(4_000), do: "suspend"
  defp strike_action(_none), do: "none"

  defp relay_state(1), do: :pending
  defp relay_state(2), do: :accepted
  defp relay_state(3), do: :rejected
  defp relay_state(_idle), do: :idle

  ## Plumbing

  defp copy(opts, part, target, sql, mapper),
    do: Batch.copy(opts, step_name(part), target, sql, mapper)

  defp step_name(part), do: Batch.step_name(:instance, part)

  defp table(opts, name), do: Source.table(opts, name)

  defp presence(value), do: Source.presence(value)

  defp at(value), do: Source.at(value)
end
