defmodule Abuuba.MastodonSource do
  @moduledoc """
  Mastodon-shaped tables in the test database.

  The importer's tests read through a table prefix, so every query a step runs
  against these is the query it would run against a real instance. A fixture
  that is not really the shape proves nothing, so the columns here are the
  columns Mastodon has, with the types it gives them: integers where it stores
  an enum as a number, `varchar[]` where it stores a list, `inet` for an
  address.

  Only the columns the importer reads. Mastodon's `statuses` table has
  twenty-four and this one has all of those; its `accounts` table has fifty and
  this one has the half the import touches. Adding a column here because a step
  started reading it is the point at which somebody notices the step is reading
  something that might not be there.
  """

  alias Abuuba.Repo

  @tables ~w(
    accounts users user_roles keypairs
    oauth_applications oauth_access_tokens oauth_access_grants web_push_subscriptions
    statuses status_edits mentions tags statuses_tags featured_tags favourites bookmarks
    polls poll_votes status_pins conversations account_conversations media_attachments
    preview_cards preview_cards_statuses status_stats account_stats quotes tombstones
    follows follow_requests blocks mutes account_domain_blocks lists list_accounts
    custom_filters custom_filter_keywords custom_filter_statuses markers scheduled_statuses
    notification_policies notification_requests notifications account_notes tag_follows
    conversation_mutes collections collection_items email_subscriptions
    relationship_severance_events severed_relationships
    settings rules custom_emojis domain_blocks domain_allows email_domain_blocks
    canonical_email_blocks ip_blocks username_blocks invites announcements
    announcement_reactions announcement_mutes reports account_warnings appeals relays
    terms_of_services account_moderation_notes report_notes admin_action_logs
    webhooks
    schema_migrations
  )

  @prefix "mastodon_"

  @doc """
  The prefix the tables are created under.
  """
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  Creates every table an import reads.
  """
  @spec create!() :: :ok
  def create! do
    drop!()

    Enum.each(statements(), &Repo.query!/1)

    :ok
  end

  @doc """
  Removes them again.
  """
  @spec drop!() :: :ok
  def drop! do
    Enum.each(@tables, &Repo.query!("DROP TABLE IF EXISTS #{@prefix}#{&1} CASCADE"))

    :ok
  end

  @doc """
  Inserts a row, taking the column names from the map.
  """
  @spec insert!(String.t(), map()) :: :ok
  def insert!(table, attrs) do
    columns = Map.keys(attrs)
    placeholders = Enum.map_join(1..length(columns), ", ", &"$#{&1}")

    Repo.query!(
      "INSERT INTO #{@prefix}#{table} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders})",
      Map.values(attrs)
    )

    :ok
  end

  ## The schema

  defp statements do
    [
      """
      CREATE TABLE #{@prefix}schema_migrations (version varchar PRIMARY KEY)
      """,
      """
      CREATE TABLE #{@prefix}accounts (
        id bigint PRIMARY KEY,
        username varchar NOT NULL,
        domain varchar,
        actor_type varchar,
        display_name varchar DEFAULT '',
        note text DEFAULT '',
        uri varchar DEFAULT '',
        url varchar,
        inbox_url varchar DEFAULT '',
        shared_inbox_url varchar DEFAULT '',
        outbox_url varchar DEFAULT '',
        followers_url varchar DEFAULT '',
        following_url varchar,
        suspended_at timestamp,
        silenced_at timestamp,
        sensitized_at timestamp,
        also_known_as varchar[],
        locked boolean DEFAULT false,
        discoverable boolean,
        indexable boolean DEFAULT false,
        hide_collections boolean,
        moved_to_account_id bigint,
        id_scheme integer DEFAULT 0,
        fields jsonb,
        private_key text,
        public_key text DEFAULT '',
        last_webfingered_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}users (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        email varchar DEFAULT '' NOT NULL,
        encrypted_password varchar DEFAULT '' NOT NULL,
        confirmed_at timestamp,
        confirmation_sent_at timestamp,
        approved boolean DEFAULT true NOT NULL,
        disabled boolean DEFAULT false NOT NULL,
        role_id bigint,
        invite_id bigint,
        locale varchar,
        settings text,
        sign_up_ip inet,
        current_sign_in_at timestamp,
        otp_secret varchar,
        otp_required_for_login boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}user_roles (
        id bigint PRIMARY KEY,
        name varchar DEFAULT '' NOT NULL,
        color varchar DEFAULT '' NOT NULL,
        position integer DEFAULT 0 NOT NULL,
        permissions bigint DEFAULT 0 NOT NULL,
        highlighted boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}keypairs (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        type integer DEFAULT 0 NOT NULL,
        public_key varchar NOT NULL,
        private_key varchar,
        local_fragment varchar,
        uri varchar,
        revoked boolean DEFAULT false NOT NULL,
        expires_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}oauth_applications (
        id bigint PRIMARY KEY,
        name varchar NOT NULL,
        uid varchar NOT NULL,
        secret varchar NOT NULL,
        redirect_uri text NOT NULL,
        scopes varchar DEFAULT '' NOT NULL,
        website varchar,
        owner_id bigint,
        owner_type varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}oauth_access_tokens (
        id bigint PRIMARY KEY,
        token varchar NOT NULL,
        application_id bigint,
        resource_owner_id bigint,
        scopes varchar,
        expires_in integer,
        revoked_at timestamp,
        last_used_at timestamp,
        created_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}oauth_access_grants (
        id bigint PRIMARY KEY,
        token varchar NOT NULL,
        application_id bigint NOT NULL,
        resource_owner_id bigint NOT NULL,
        redirect_uri text NOT NULL,
        scopes varchar,
        code_challenge varchar,
        code_challenge_method varchar,
        expires_in integer NOT NULL,
        revoked_at timestamp,
        created_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}web_push_subscriptions (
        id bigint PRIMARY KEY,
        endpoint varchar NOT NULL,
        key_p256dh varchar NOT NULL,
        key_auth varchar NOT NULL,
        data json,
        access_token_id bigint,
        user_id bigint,
        standard boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}statuses (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        uri varchar,
        url varchar,
        text text DEFAULT '',
        spoiler_text text DEFAULT '',
        language varchar,
        local boolean,
        sensitive boolean DEFAULT false,
        visibility integer DEFAULT 0 NOT NULL,
        quote_approval_policy integer DEFAULT 0 NOT NULL,
        reblog_of_id bigint,
        in_reply_to_id bigint,
        in_reply_to_account_id bigint,
        conversation_id bigint,
        ordered_media_attachment_ids bigint[],
        poll_id bigint,
        deleted_at timestamp,
        edited_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}status_edits (
        id bigint PRIMARY KEY,
        status_id bigint NOT NULL,
        account_id bigint,
        text text DEFAULT '',
        spoiler_text text DEFAULT '',
        sensitive boolean DEFAULT false,
        ordered_media_attachment_ids bigint[],
        media_descriptions varchar[],
        poll_options varchar[],
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}mentions (
        id bigint PRIMARY KEY,
        status_id bigint,
        account_id bigint,
        silent boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}tags (
        id bigint PRIMARY KEY,
        name varchar DEFAULT '' NOT NULL,
        display_name varchar,
        usable boolean,
        trendable boolean,
        listable boolean,
        reviewed_at timestamp,
        requested_review_at timestamp,
        last_status_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}statuses_tags (
        status_id bigint NOT NULL,
        tag_id bigint NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}featured_tags (
        id bigint PRIMARY KEY,
        account_id bigint,
        tag_id bigint,
        name varchar,
        statuses_count bigint DEFAULT 0,
        last_status_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}favourites (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        status_id bigint NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}bookmarks (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        status_id bigint NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}polls (
        id bigint PRIMARY KEY,
        account_id bigint,
        status_id bigint,
        expires_at timestamp,
        options varchar[] DEFAULT '{}' NOT NULL,
        cached_tallies bigint[] DEFAULT '{}' NOT NULL,
        multiple boolean DEFAULT false NOT NULL,
        hide_totals boolean DEFAULT false NOT NULL,
        votes_count bigint DEFAULT 0 NOT NULL,
        voters_count bigint,
        last_fetched_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}poll_votes (
        id bigint PRIMARY KEY,
        account_id bigint,
        poll_id bigint,
        choice integer DEFAULT 0 NOT NULL,
        uri varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}status_pins (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        status_id bigint NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}conversations (
        id bigint PRIMARY KEY,
        uri varchar,
        parent_status_id bigint,
        parent_account_id bigint,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}account_conversations (
        id bigint PRIMARY KEY,
        account_id bigint,
        conversation_id bigint,
        participant_account_ids bigint[] DEFAULT '{}' NOT NULL,
        status_ids bigint[] DEFAULT '{}' NOT NULL,
        last_status_id bigint,
        lock_version integer DEFAULT 0 NOT NULL,
        unread boolean DEFAULT false NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}media_attachments (
        id bigint PRIMARY KEY,
        status_id bigint,
        account_id bigint,
        scheduled_status_id bigint,
        file_file_name varchar,
        file_content_type varchar,
        file_file_size integer,
        file_updated_at timestamp,
        file_storage_schema_version integer,
        thumbnail_file_name varchar,
        thumbnail_content_type varchar,
        thumbnail_file_size integer,
        thumbnail_storage_schema_version integer,
        remote_url varchar DEFAULT '',
        thumbnail_remote_url varchar,
        shortcode varchar,
        type integer DEFAULT 3 NOT NULL,
        processing integer,
        file_meta json,
        description text,
        blurhash varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}preview_cards (
        id bigint PRIMARY KEY,
        url varchar DEFAULT '' NOT NULL,
        title varchar DEFAULT '' NOT NULL,
        description varchar DEFAULT '' NOT NULL,
        type integer DEFAULT 0 NOT NULL,
        author_name varchar,
        author_url varchar,
        provider_name varchar,
        provider_url varchar,
        author_account_id bigint,
        html text,
        width integer,
        height integer,
        image_file_name varchar,
        image_content_type varchar,
        image_file_size integer,
        image_storage_schema_version integer,
        image_description varchar,
        blurhash varchar,
        embed_url varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}preview_cards_statuses (
        preview_card_id bigint NOT NULL,
        status_id bigint NOT NULL,
        url varchar
      )
      """,
      """
      CREATE TABLE #{@prefix}status_stats (
        id bigint PRIMARY KEY,
        status_id bigint NOT NULL,
        replies_count bigint DEFAULT 0 NOT NULL,
        reblogs_count bigint DEFAULT 0 NOT NULL,
        favourites_count bigint DEFAULT 0 NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}account_stats (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        statuses_count bigint DEFAULT 0 NOT NULL,
        following_count bigint DEFAULT 0 NOT NULL,
        followers_count bigint DEFAULT 0 NOT NULL,
        last_status_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}quotes (
        id bigint PRIMARY KEY,
        status_id bigint NOT NULL,
        quoted_status_id bigint,
        account_id bigint NOT NULL,
        quoted_account_id bigint,
        activity_uri varchar,
        approval_uri varchar,
        state integer DEFAULT 0 NOT NULL,
        legacy boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}tombstones (
        id bigint PRIMARY KEY,
        account_id bigint,
        uri varchar NOT NULL,
        by_moderator boolean,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}follows (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        target_account_id bigint NOT NULL,
        show_reblogs boolean DEFAULT true NOT NULL,
        notify boolean DEFAULT false NOT NULL,
        languages varchar[],
        uri varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}follow_requests (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        target_account_id bigint NOT NULL,
        show_reblogs boolean DEFAULT true NOT NULL,
        notify boolean DEFAULT false NOT NULL,
        languages varchar[],
        uri varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}blocks (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        target_account_id bigint NOT NULL,
        uri varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}mutes (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        target_account_id bigint NOT NULL,
        hide_notifications boolean DEFAULT true NOT NULL,
        expires_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}account_domain_blocks (
        id bigint PRIMARY KEY,
        account_id bigint,
        domain varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}lists (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        title varchar DEFAULT '' NOT NULL,
        replies_policy integer DEFAULT 0 NOT NULL,
        exclusive boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}list_accounts (
        id bigint PRIMARY KEY,
        list_id bigint NOT NULL,
        account_id bigint NOT NULL,
        follow_id bigint,
        follow_request_id bigint
      )
      """,
      """
      CREATE TABLE #{@prefix}custom_filters (
        id bigint PRIMARY KEY,
        account_id bigint,
        expires_at timestamp,
        phrase text DEFAULT '' NOT NULL,
        context varchar[] DEFAULT '{}' NOT NULL,
        action integer DEFAULT 0 NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}custom_filter_keywords (
        id bigint PRIMARY KEY,
        custom_filter_id bigint NOT NULL,
        keyword text DEFAULT '' NOT NULL,
        whole_word boolean DEFAULT true NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}custom_filter_statuses (
        id bigint PRIMARY KEY,
        custom_filter_id bigint NOT NULL,
        status_id bigint NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}markers (
        id bigint PRIMARY KEY,
        user_id bigint,
        timeline varchar DEFAULT '' NOT NULL,
        last_read_id bigint DEFAULT 0 NOT NULL,
        lock_version integer DEFAULT 0 NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}scheduled_statuses (
        id bigint PRIMARY KEY,
        account_id bigint,
        scheduled_at timestamp,
        params jsonb
      )
      """,
      """
      CREATE TABLE #{@prefix}notification_policies (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        for_not_following integer DEFAULT 0 NOT NULL,
        for_not_followers integer DEFAULT 0 NOT NULL,
        for_new_accounts integer DEFAULT 0 NOT NULL,
        for_private_mentions integer DEFAULT 1 NOT NULL,
        for_limited_accounts integer DEFAULT 1 NOT NULL,
        for_bots integer DEFAULT 0 NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}notification_requests (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        from_account_id bigint NOT NULL,
        last_status_id bigint,
        notifications_count bigint DEFAULT 0 NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}notifications (
        id bigint PRIMARY KEY,
        activity_id bigint NOT NULL,
        activity_type varchar NOT NULL,
        account_id bigint NOT NULL,
        from_account_id bigint NOT NULL,
        type varchar,
        filtered boolean DEFAULT false NOT NULL,
        group_key varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}account_notes (
        id bigint PRIMARY KEY,
        account_id bigint,
        target_account_id bigint,
        comment text DEFAULT '' NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}tag_follows (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        tag_id bigint NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}conversation_mutes (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        conversation_id bigint NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}settings (
        id bigint PRIMARY KEY,
        var varchar NOT NULL,
        value text,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}rules (
        id bigint PRIMARY KEY,
        priority integer DEFAULT 0 NOT NULL,
        deleted_at timestamp,
        text text DEFAULT '' NOT NULL,
        hint text DEFAULT '' NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}custom_emojis (
        id bigint PRIMARY KEY,
        shortcode varchar DEFAULT '' NOT NULL,
        domain varchar,
        image_file_name varchar,
        image_content_type varchar,
        image_file_size integer,
        image_remote_url varchar,
        image_storage_schema_version integer,
        disabled boolean DEFAULT false NOT NULL,
        visible_in_picker boolean DEFAULT true NOT NULL,
        uri varchar,
        category_id bigint,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}domain_blocks (
        id bigint PRIMARY KEY,
        domain varchar DEFAULT '' NOT NULL,
        severity integer DEFAULT 0,
        reject_media boolean DEFAULT false NOT NULL,
        reject_reports boolean DEFAULT false NOT NULL,
        private_comment text,
        public_comment text,
        obfuscate boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}domain_allows (
        id bigint PRIMARY KEY,
        domain varchar DEFAULT '' NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}email_domain_blocks (
        id bigint PRIMARY KEY,
        domain varchar DEFAULT '' NOT NULL,
        parent_id bigint,
        allow_with_approval boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}canonical_email_blocks (
        id bigint PRIMARY KEY,
        canonical_email_hash varchar DEFAULT '' NOT NULL,
        reference_account_id bigint,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}ip_blocks (
        id bigint PRIMARY KEY,
        ip inet DEFAULT '0.0.0.0' NOT NULL,
        severity integer DEFAULT 0 NOT NULL,
        expires_at timestamp,
        comment text DEFAULT '' NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}webhooks (
        id bigint PRIMARY KEY,
        url varchar NOT NULL,
        events varchar[] DEFAULT '{}' NOT NULL,
        secret varchar DEFAULT '' NOT NULL,
        enabled boolean DEFAULT true NOT NULL,
        template text,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}collections (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        name varchar NOT NULL,
        description text,
        description_html text,
        discoverable boolean DEFAULT true NOT NULL,
        sensitive boolean DEFAULT false NOT NULL,
        local boolean DEFAULT true NOT NULL,
        language varchar,
        item_count integer DEFAULT 0 NOT NULL,
        original_number_of_items integer,
        tag_id bigint,
        uri varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}collection_items (
        id bigint PRIMARY KEY,
        collection_id bigint NOT NULL,
        account_id bigint,
        object_uri varchar,
        activity_uri varchar,
        approval_uri varchar,
        approval_last_verified_at timestamp,
        position integer DEFAULT 1 NOT NULL,
        state integer DEFAULT 0 NOT NULL,
        uri varchar,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}email_subscriptions (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        email varchar NOT NULL,
        locale varchar NOT NULL,
        confirmation_token varchar,
        confirmed_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}relationship_severance_events (
        id bigint PRIMARY KEY,
        type integer NOT NULL,
        target_name varchar NOT NULL,
        purged boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}severed_relationships (
        id bigint PRIMARY KEY,
        relationship_severance_event_id bigint NOT NULL,
        local_account_id bigint NOT NULL,
        remote_account_id bigint NOT NULL,
        direction integer NOT NULL,
        show_reblogs boolean,
        notify boolean,
        languages varchar[],
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}username_blocks (
        id bigint PRIMARY KEY,
        username varchar NOT NULL,
        normalized_username varchar,
        exact boolean DEFAULT false NOT NULL,
        allow_with_approval boolean DEFAULT false NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}invites (
        id bigint PRIMARY KEY,
        user_id bigint NOT NULL,
        code varchar DEFAULT '' NOT NULL,
        expires_at timestamp,
        max_uses integer,
        uses integer DEFAULT 0 NOT NULL,
        autofollow boolean DEFAULT false NOT NULL,
        comment text,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}announcements (
        id bigint PRIMARY KEY,
        text text DEFAULT '' NOT NULL,
        published boolean DEFAULT false NOT NULL,
        all_day boolean DEFAULT false NOT NULL,
        scheduled_at timestamp,
        starts_at timestamp,
        ends_at timestamp,
        published_at timestamp,
        notification_sent_at timestamp,
        status_ids bigint[],
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}announcement_reactions (
        id bigint PRIMARY KEY,
        account_id bigint,
        announcement_id bigint,
        name varchar DEFAULT '' NOT NULL,
        custom_emoji_id bigint,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}announcement_mutes (
        id bigint PRIMARY KEY,
        account_id bigint,
        announcement_id bigint,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}reports (
        id bigint PRIMARY KEY,
        status_ids bigint[] DEFAULT '{}' NOT NULL,
        comment text DEFAULT '' NOT NULL,
        action_taken_at timestamp,
        account_id bigint NOT NULL,
        action_taken_by_account_id bigint,
        target_account_id bigint NOT NULL,
        assigned_account_id bigint,
        uri varchar,
        forwarded boolean,
        category integer DEFAULT 0 NOT NULL,
        rule_ids bigint[],
        application_id bigint,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}account_warnings (
        id bigint PRIMARY KEY,
        account_id bigint,
        target_account_id bigint,
        action integer DEFAULT 0 NOT NULL,
        text text DEFAULT '' NOT NULL,
        report_id bigint,
        status_ids bigint[],
        overruled_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}appeals (
        id bigint PRIMARY KEY,
        account_id bigint NOT NULL,
        account_warning_id bigint NOT NULL,
        text text DEFAULT '' NOT NULL,
        approved_at timestamp,
        approved_by_account_id bigint,
        rejected_at timestamp,
        rejected_by_account_id bigint,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}relays (
        id bigint PRIMARY KEY,
        inbox_url varchar DEFAULT '' NOT NULL,
        follow_activity_id varchar,
        state integer DEFAULT 0 NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}terms_of_services (
        id bigint PRIMARY KEY,
        text text DEFAULT '' NOT NULL,
        changelog text DEFAULT '' NOT NULL,
        published_at timestamp,
        effective_date date,
        notification_sent_at timestamp,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}account_moderation_notes (
        id bigint PRIMARY KEY,
        content text NOT NULL,
        account_id bigint NOT NULL,
        target_account_id bigint NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}report_notes (
        id bigint PRIMARY KEY,
        content text NOT NULL,
        report_id bigint NOT NULL,
        account_id bigint NOT NULL,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      """
      CREATE TABLE #{@prefix}admin_action_logs (
        id bigint PRIMARY KEY,
        account_id bigint,
        action varchar DEFAULT '' NOT NULL,
        target_type varchar,
        target_id bigint,
        human_identifier varchar,
        route_param varchar,
        permalink varchar,
        recorded_changes text,
        created_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """
    ]
  end
end
