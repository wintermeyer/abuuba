defmodule Abuuba.InstanceCommsTest do
  use Abuuba.DataCase, async: true
  use Oban.Testing, repo: Abuuba.Repo

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Instance
  alias Abuuba.Instance.AnnouncementWorker
  alias Abuuba.Invites
  alias Abuuba.Relationships
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings

  setup do
    %{admin: account_fixture()}
  end

  describe "announcements that are written in advance" do
    test "stay unpublished until their time", %{} do
      {:ok, announcement} =
        Instance.create_announcement(%{
          text: "The server is down on Sunday.",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      :ok = perform_job(AnnouncementWorker, %{})

      refute Repo.reload(announcement).published
      assert Instance.announcements() == []
    end

    test "and are published once it arrives" do
      # Otherwise an admin has to be awake at the moment the notice is due,
      # which is exactly the moment they are busy with whatever it is about.
      {:ok, announcement} =
        Instance.create_announcement(%{
          text: "The server is down now.",
          scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      :ok = perform_job(AnnouncementWorker, %{})

      published = Repo.reload(announcement)

      assert published.published
      assert published.published_at
    end

    test "are only published once" do
      {:ok, announcement} =
        Instance.create_announcement(%{
          text: "Once.",
          scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      :ok = perform_job(AnnouncementWorker, %{})
      first = Repo.reload(announcement).published_at
      :ok = perform_job(AnnouncementWorker, %{})

      assert Repo.reload(announcement).published_at == first
    end

    test "reach anybody watching the stream" do
      # Their own topic rather than the public one: a client watching only its
      # own timeline subscribes to nothing public, and is exactly the client a
      # server notice has to reach.
      :ok = Abuuba.Streaming.subscribe(Abuuba.Streaming.announcement_topic())

      {:ok, _} =
        Instance.create_announcement(%{
          text: "Something happened.",
          scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      :ok = perform_job(AnnouncementWorker, %{})

      assert_receive {:streaming, "announcement", _payload}
    end
  end

  describe "rules in more than one language" do
    test "are one rule, not two" do
      {:ok, rule} =
        Settings.create_rule(%{
          text: "Be kind to each other.",
          translations: %{"de" => "Seid nett zueinander."}
        })

      assert Settings.rule_text(rule, "de") == "Seid nett zueinander."
      assert Settings.rule_text(rule, "en") == "Be kind to each other."
    end

    test "fall back to what they were written in" do
      # A rule that disappears for a reader whose language nobody translated is
      # worse than one they have to read in English.
      {:ok, rule} = Settings.create_rule(%{text: "Be kind to each other."})

      assert Settings.rule_text(rule, "fr") == "Be kind to each other."
    end

    test "are listed in the reader's language" do
      {:ok, _} =
        Settings.create_rule(%{
          text: "Be kind.",
          translations: %{"de" => "Sei nett."}
        })

      assert [%{text: "Sei nett."}] = Settings.rules("de")
    end

    test "keep their order whatever the language" do
      {:ok, _} = Settings.create_rule(%{text: "Second", position: 2})
      {:ok, _} = Settings.create_rule(%{text: "First", position: 1})

      assert ["First", "Second"] = Enum.map(Settings.rules("de"), & &1.text)
    end
  end

  describe "terms of service" do
    test "are published with the day they take effect", %{admin: admin} do
      {:ok, terms} =
        Instance.publish_terms(admin, %{
          text: "Do not do anything illegal.",
          effective_date: Date.utc_today()
        })

      assert terms.published_at
      assert Instance.current_terms().id == terms.id
    end

    test "a version that is not in force yet is not the current one", %{admin: admin} do
      # Publishing the next version early is how people get told before it
      # applies, which is the whole point of an effective date.
      {:ok, current} =
        Instance.publish_terms(admin, %{text: "Now", effective_date: Date.utc_today()})

      {:ok, _future} =
        Instance.publish_terms(admin, %{
          text: "Later",
          effective_date: Date.add(Date.utc_today(), 30)
        })

      assert Instance.current_terms().id == current.id
    end

    test "an older version can still be read", %{admin: admin} do
      # "What did I agree to in March" is the question terms exist to answer.
      old = Date.add(Date.utc_today(), -60)
      {:ok, _} = Instance.publish_terms(admin, %{text: "The old text", effective_date: old})
      {:ok, _} = Instance.publish_terms(admin, %{text: "Now", effective_date: Date.utc_today()})

      assert Instance.terms_for(old).text == "The old text"
    end

    test "one version per day", %{admin: admin} do
      {:ok, _} = Instance.publish_terms(admin, %{text: "One", effective_date: Date.utc_today()})

      assert {:error, changeset} =
               Instance.publish_terms(admin, %{text: "Two", effective_date: Date.utc_today()})

      assert %{effective_date: [_]} = errors_on(changeset)
    end

    test "telling everybody is one announcement, not one notice each", %{admin: admin} do
      # There is no mail yet, and a notification per account would write one row
      # per person for something everybody sees in the same place anyway.
      {:ok, terms} =
        Instance.publish_terms(admin, %{text: "New terms", effective_date: Date.utc_today()})

      {:ok, announced} = Instance.announce_terms(terms)

      assert announced.notified_at
      assert [%{published: true}] = Instance.announcements()
    end

    test "and only once", %{admin: admin} do
      {:ok, terms} =
        Instance.publish_terms(admin, %{text: "New terms", effective_date: Date.utc_today()})

      {:ok, terms} = Instance.announce_terms(terms)

      assert {:error, :already_announced} = Instance.announce_terms(terms)
    end

    test "nothing is current on a server that never wrote any" do
      assert Instance.current_terms() == nil
    end
  end

  describe "invites" do
    setup do
      %{inviter: with_permission("invite_users")}
    end

    test "have a code somebody can read out loud", %{inviter: inviter} do
      {:ok, invite} = Invites.create(inviter, %{})

      # No characters that turn into each other on a phone screen or over the
      # phone: an invite is typed by hand more often than it is clicked.
      refute invite.code =~ ~r/[01OIl]/
      assert String.length(invite.code) >= 8
    end

    test "need the permission", %{} do
      assert {:error, :not_allowed} = Invites.create(account_fixture(), %{})
    end

    test "can be used once or many times", %{inviter: inviter} do
      {:ok, invite} = Invites.create(inviter, %{"max_uses" => 1})

      assert {:ok, _} = Invites.claim(invite.code)
      assert {:error, :used_up} = Invites.claim(invite.code)
    end

    test "with no limit by default", %{inviter: inviter} do
      {:ok, invite} = Invites.create(inviter, %{})

      assert {:ok, _} = Invites.claim(invite.code)
      assert {:ok, _} = Invites.claim(invite.code)
    end

    test "stop working when they expire", %{inviter: inviter} do
      {:ok, invite} =
        Invites.create(inviter, %{"expires_at" => DateTime.add(DateTime.utc_now(), -60, :second)})

      assert {:error, :expired} = Invites.claim(invite.code)
    end

    test "a code nobody issued is refused" do
      assert {:error, :not_found} = Invites.claim("NOPENOPE")
    end

    test "can be taken back", %{inviter: inviter} do
      {:ok, invite} = Invites.create(inviter, %{})

      :ok = Invites.delete(inviter, invite)

      assert {:error, :not_found} = Invites.claim(invite.code)
    end

    test "and only by whoever wrote them", %{inviter: inviter} do
      {:ok, invite} = Invites.create(inviter, %{})

      assert {:error, :not_yours} = Invites.delete(with_permission("invite_users"), invite)
    end
  end

  describe "signing up with an invite" do
    setup do
      inviter = with_permission("invite_users")

      :ok = Settings.put_registration_mode("closed")

      %{inviter: inviter}
    end

    test "lets somebody in when nobody else may", %{inviter: inviter} do
      # An invite is a named person vouching, which is what closed registration
      # leaves room for.
      {:ok, invite} = Invites.create(inviter, %{})

      assert {:ok, %{user: user}} = Auth.register(registration_params(invite.code))
      assert user.invite_id == invite.id
    end

    test "and is still refused without one" do
      assert {:error, :registration_closed} = Auth.register(registration_params(nil))
    end

    test "a wrong code does not let anybody in" do
      assert {:error, :invalid_invite} = Auth.register(registration_params("NOTACODE"))
    end

    test "counts against the invite", %{inviter: inviter} do
      {:ok, invite} = Invites.create(inviter, %{"max_uses" => 2})

      {:ok, _} = Auth.register(registration_params(invite.code))

      assert Repo.reload(invite).uses == 1
    end

    test "follows whoever invited them when it says so", %{inviter: inviter} do
      {:ok, invite} = Invites.create(inviter, %{"autofollow" => true})

      {:ok, %{account: account}} = Auth.register(registration_params(invite.code))

      assert Relationships.following?(account, inviter)
    end

    test "and does not otherwise", %{inviter: inviter} do
      {:ok, invite} = Invites.create(inviter, %{})

      {:ok, %{account: account}} = Auth.register(registration_params(invite.code))

      refute Relationships.following?(account, inviter)
    end

    test "an invite still works while sign-ups need approval", %{inviter: inviter} do
      # Somebody vouched for by a person here has already been through the
      # check that approval exists to make.
      :ok = Settings.put_registration_mode("approved")
      {:ok, invite} = Invites.create(inviter, %{})

      {:ok, %{user: user}} = Auth.register(registration_params(invite.code))

      assert user.approved
    end
  end

  defp registration_params(code) do
    unique = System.unique_integer([:positive])

    %{
      "username" => "invited#{unique}",
      "email" => "invited#{unique}@example.test",
      "password" => "a long enough password",
      "agreement" => "true",
      "invite_code" => code
    }
  end

  defp with_permission(permission) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 10,
        permissions: Roles.mask([permission])
      })

    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, _} = Roles.assign(user, role)

    account
  end
end
