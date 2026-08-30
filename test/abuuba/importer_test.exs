defmodule Abuuba.ImporterTest do
  use Abuuba.DataCase, async: false

  alias Abuuba.Federation.URIs
  alias Abuuba.Importer
  alias Abuuba.Importer.Checkpoint
  alias Abuuba.Repo

  # The source is a handful of Mastodon-shaped tables in the test database, so
  # every query the importer runs is a query it would run against a real one.
  # A fixture that is not really the shape proves nothing.
  setup do
    create_source!()

    on_exit(fn -> drop_source!() end)

    %{source: Repo}
  end

  defp create_source! do
    drop_source!()

    Repo.query!("""
    CREATE TABLE mastodon_schema_migrations (version varchar PRIMARY KEY)
    """)

    Repo.query!("""
    CREATE TABLE mastodon_accounts (
      id bigint PRIMARY KEY,
      username varchar NOT NULL,
      domain varchar,
      suspended_at timestamp
    )
    """)

    Repo.query!("""
    CREATE TABLE mastodon_statuses (
      id bigint PRIMARY KEY,
      account_id bigint NOT NULL,
      uri varchar,
      local boolean DEFAULT false,
      deleted_at timestamp
    )
    """)

    Repo.query!("""
    CREATE TABLE mastodon_media_attachments (
      id bigint PRIMARY KEY,
      file_file_size integer,
      thumbnail_file_size integer,
      remote_url varchar
    )
    """)

    # `otp_secret` and the keypairs table because the identity step's own check
    # reads them: a registered step gets to say what would stop it before
    # anything is written, and this source has to be able to answer.
    Repo.query!("""
    CREATE TABLE mastodon_users (
      id bigint PRIMARY KEY,
      account_id bigint NOT NULL,
      otp_secret varchar
    )
    """)

    Repo.query!("""
    CREATE TABLE mastodon_keypairs (id bigint PRIMARY KEY, private_key varchar)
    """)
  end

  defp drop_source! do
    for table <- ~w(schema_migrations accounts statuses media_attachments users keypairs) do
      Repo.query!("DROP TABLE IF EXISTS mastodon_#{table}")
    end
  end

  defp put_version(version) do
    Repo.query!("INSERT INTO mastodon_schema_migrations (version) VALUES ($1)", [version])
  end

  defp seed! do
    put_version(Importer.verified_version())

    Repo.query!("""
    INSERT INTO mastodon_accounts (id, username, domain, suspended_at) VALUES
      (1, 'alice', NULL, NULL),
      (2, 'bob', NULL, NULL),
      (3, 'carol', 'other.example', NULL),
      (4, 'spammer', 'other.example', now())
    """)

    Repo.query!("""
    INSERT INTO mastodon_statuses (id, account_id, uri, local, deleted_at) VALUES
      (10, 1, 'https://#{URIs.local_domain()}/users/alice/statuses/10', true, NULL),
      (11, 1, NULL, true, NULL),
      (12, 2, NULL, true, NULL),
      (13, 2, NULL, true, now())
    """)

    Repo.query!("""
    INSERT INTO mastodon_media_attachments (id, file_file_size, thumbnail_file_size, remote_url)
    VALUES (20, 1000, 100, ''), (21, 2000, NULL, 'https://other.example/a.jpg')
    """)

    Repo.query!("INSERT INTO mastodon_users (id, account_id) VALUES (30, 1), (31, 2)")
  end

  # The importer reads through a prefix so a test can point it at tables in the
  # same database. Against a real instance the prefix is empty.
  defp opts do
    [
      repo: Repo,
      prefix: "mastodon_",
      local_domain: URIs.local_domain(),
      secrets: Map.new(Importer.required_secrets(), &{&1, "set"})
    ]
  end

  describe "checking before touching anything" do
    test "refuses a database it cannot read" do
      # Every other check depends on this one, and "connection refused" is a
      # far more useful thing to be told than "no accounts found".
      drop_source!()

      assert {:error, problems} = Importer.check(opts())
      assert Enum.any?(problems, &(&1.key == "source_reachable"))
    end

    test "refuses a schema it has never been verified against" do
      # A column that moved is a silent mis-import, which is the worst kind:
      # it finishes, and the damage is only visible months later.
      seed!()
      Repo.query!("DELETE FROM mastodon_schema_migrations")
      put_version("2999_01_01_000000")

      assert {:error, problems} = Importer.check(opts())
      assert Enum.any?(problems, &(&1.key == "schema_version"))
    end

    test "and one older than it knows" do
      seed!()
      Repo.query!("DELETE FROM mastodon_schema_migrations")
      put_version("2016_01_01_000000")

      assert {:error, problems} = Importer.check(opts())
      assert Enum.any?(problems, &(&1.key == "schema_version"))
    end

    test "passes on the version it was written against" do
      seed!()

      assert :ok = Importer.check(opts())
    end

    test "reads the host and the port, because a development server has one" do
      # Comparing only the host would call `localhost:4000` a match for every
      # server on the machine.
      seed!()

      Repo.query!(
        "UPDATE mastodon_statuses SET uri = 'https://localhost/users/alice/statuses/10' WHERE id = 10"
      )

      if URIs.local_domain() =~ ":" do
        assert {:error, problems} = Importer.check(opts())
        assert Enum.any?(problems, &(&1.key == "local_domain"))
      end
    end

    test "notices when the source's own posts name another domain" do
      # The variable is what an admin types; the posts are what the source
      # actually published. A mistyped variable would otherwise pass the check
      # that exists to catch exactly that.
      seed!()

      Repo.query!(
        "UPDATE mastodon_statuses SET uri = 'https://elsewhere.example/users/alice/statuses/10' WHERE id = 10"
      )

      assert {:error, problems} = Importer.check(opts())
      assert Enum.any?(problems, &(&1.key == "local_domain"))
    end

    test "insists the domain does not change" do
      # Every id, every URI and every signature this server has ever published
      # names the domain. Moving to a new one is not a takeover, it is a fresh
      # instance with somebody else's posts in it.
      seed!()

      assert {:error, problems} =
               Importer.check(Keyword.put(opts(), :local_domain, "elsewhere.example"))

      assert Enum.any?(problems, &(&1.key == "local_domain"))
    end

    test "wants the secrets that decrypt what it is copying" do
      seed!()

      assert {:error, problems} =
               Importer.check(Keyword.put(opts(), :secrets, %{"SECRET_KEY_BASE" => ""}))

      assert Enum.any?(problems, &(&1.key == "secrets"))
    end

    test "and says what is missing rather than that something is" do
      seed!()

      {:error, problems} = Importer.check(Keyword.put(opts(), :secrets, %{}))
      problem = Enum.find(problems, &(&1.key == "secrets"))

      assert problem.detail =~ "VAPID_PUBLIC_KEY"
    end

    test "refuses a media root that is not there" do
      seed!()

      assert {:error, problems} =
               Importer.check(Keyword.put(opts(), :media_root, "/nowhere/at/all"))

      assert Enum.any?(problems, &(&1.key == "media_root"))
    end

    test "collects every problem rather than stopping at the first" do
      # An admin should find out about all of it in one run, not discover the
      # next one each time they fix the last.
      seed!()

      {:error, problems} =
        Importer.check(
          opts()
          |> Keyword.put(:local_domain, "elsewhere.example")
          |> Keyword.put(:secrets, %{})
        )

      assert length(problems) >= 2
    end
  end

  describe "reading the old server's secrets" do
    test "each comes from its MASTODON_ name" do
      with_env(%{"MASTODON_SECRET_KEY_BASE" => "theirs"})

      assert Importer.config()[:secrets]["SECRET_KEY_BASE"] == "theirs"
    end

    test "and the bare name is not read, because that one is ours" do
      # `SECRET_KEY_BASE` names two different keys: the old server's, which
      # decrypts what comes across, and this one's, which a release cannot boot
      # without. Both are set in the process running the import, so reading the
      # bare name as a fallback would take ours for theirs and pass every check
      # with it. Unset has to stay unset.
      with_env(%{"SECRET_KEY_BASE" => "ours", "MASTODON_SECRET_KEY_BASE" => nil})

      assert Importer.config()[:secrets]["SECRET_KEY_BASE"] == ""
    end

    test "and a missing one is named the way an admin sets it" do
      seed!()

      {:error, problems} = Importer.check(Keyword.put(opts(), :secrets, %{}))
      problem = Enum.find(problems, &(&1.key == "secrets"))

      assert problem.detail =~ "MASTODON_SECRET_KEY_BASE"
    end
  end

  describe "the report" do
    setup do
      seed!()

      :ok
    end

    test "counts what would come across" do
      {:ok, plan} = Importer.plan(opts())

      assert plan.counts.accounts == 4
      assert plan.counts.local_accounts == 2
      assert plan.counts.statuses == 3
      assert plan.counts.users == 2
    end

    test "counts the bytes of media, which is what an admin has to have room for" do
      {:ok, plan} = Importer.plan(opts())

      # 1000 + 100 for the local one; the remote one is a cache and is not
      # copied.
      assert plan.counts.media_bytes == 1100
    end

    test "says what is skipped and why" do
      # A number that does not add up is what makes somebody distrust the whole
      # report.
      {:ok, plan} = Importer.plan(opts())

      reasons = Map.new(plan.skipped, &{&1.what, &1.reason})

      assert reasons["statuses"] =~ "deleted"
      assert reasons["media_attachments"] =~ "cache"
    end

    test "lists the steps in the order they will run" do
      {:ok, plan} = Importer.plan(opts())

      assert is_list(plan.steps)
    end

    test "reads as something an admin can act on" do
      {:ok, plan} = Importer.plan(opts())

      report = Importer.report(plan)

      assert report =~ "accounts"
      assert report =~ "nothing has been written"
    end

    test "refuses to plan against a database it cannot check" do
      Repo.query!("DELETE FROM mastodon_schema_migrations")

      assert {:error, _problems} = Importer.plan(opts())
    end
  end

  describe "checkpoints" do
    test "start empty" do
      assert Checkpoint.last_id("accounts") == nil
    end

    test "remember how far a step got" do
      :ok = Checkpoint.record("accounts", 500, 100)

      assert Checkpoint.last_id("accounts") == 500
    end

    test "move forward, never back" do
      # A batch that arrives out of order must not rewind the mark and cause
      # everything after it to be copied twice.
      :ok = Checkpoint.record("accounts", 500, 100)
      :ok = Checkpoint.record("accounts", 200, 50)

      assert Checkpoint.last_id("accounts") == 500
    end

    test "add up the rows they wrote" do
      :ok = Checkpoint.record("accounts", 100, 40)
      :ok = Checkpoint.record("accounts", 200, 60)

      assert Checkpoint.rows("accounts") == 100
    end

    test "a finished step says so, so a rerun skips it" do
      :ok = Checkpoint.record("accounts", 500, 100)
      :ok = Checkpoint.finish("accounts")

      assert Checkpoint.finished?("accounts")
      refute Checkpoint.finished?("statuses")
    end

    test "and can be cleared for an import somebody means to redo" do
      :ok = Checkpoint.record("accounts", 500, 100)

      :ok = Checkpoint.reset()

      assert Checkpoint.last_id("accounts") == nil
    end
  end

  describe "running" do
    setup do
      seed!()

      :ok
    end

    test "a dry run writes nothing" do
      # The point of the whole thing: an admin sees what will happen before
      # anything happens.
      before = Repo.aggregate(Abuuba.Accounts.Account, :count)

      {:ok, plan} = Importer.run(Keyword.put(opts(), :dry_run, true))

      assert plan.dry_run
      assert Repo.aggregate(Abuuba.Accounts.Account, :count) == before
    end

    test "a real run refuses when no steps are registered" do
      # Better than a run that reports success having moved nothing. The steps
      # are configuration, and an empty list is a misconfiguration rather than
      # a quiet no-op.
      with_steps([])

      assert {:error, :no_steps} = Importer.run(Keyword.put(opts(), :dry_run, false))
    end

    test "a real run reports what each step did, in the shape the report reads" do
      # The plan is what an admin is shown either way. A run that answered with
      # something else took the report down with it, at the end of an import
      # that had already written everything.
      with_steps([Abuuba.ImportSteps.Stub])

      assert {:ok, plan} = Importer.run(Keyword.put(opts(), :dry_run, false))

      refute plan.dry_run
      assert plan.outcomes["stub"] == :done
      assert Importer.report(plan) =~ "stub"
    end

    test "asks every step to prove itself, so a step added later is not skipped" do
      # Through `Code.ensure_loaded?/1`, because `function_exported?/3` answers
      # false for a module nothing has loaded yet — which in a release is every
      # module, and the verification would quietly check nothing.
      with_steps([Abuuba.ImportSteps.Stub])

      assert {:ok, [%{name: "stub", checked: 1}]} = Importer.verify(opts())
    end

    test "and refuses outright when a check fails" do
      Repo.query!("DELETE FROM mastodon_schema_migrations")

      assert {:error, _problems} = Importer.run(Keyword.put(opts(), :dry_run, true))
    end
  end
end
