defmodule Abuuba.SignupTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Moderation.AuditLog
  alias Abuuba.Moderation.Signup
  alias Abuuba.Moderation.Signup.Captcha
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Settings

  setup do
    %{admin: account_fixture()}
  end

  describe "email domains" do
    test "a blocked one is refused", %{admin: admin} do
      {:ok, _} = Signup.block_email_domain(admin, %{"domain" => "spam.example"})

      assert {:error, :email_domain_blocked} = Signup.check(%{email: "someone@spam.example"})
    end

    test "and so is a subdomain of it", %{admin: admin} do
      # Otherwise a block is undone by whoever runs the domain pointing a
      # subdomain at the same mail server.
      {:ok, _} = Signup.block_email_domain(admin, %{"domain" => "spam.example"})

      assert {:error, :email_domain_blocked} = Signup.check(%{email: "someone@mail.spam.example"})
    end

    test "a domain that merely ends the same way is not", %{admin: admin} do
      {:ok, _} = Signup.block_email_domain(admin, %{"domain" => "spam.example"})

      assert :ok = Signup.check(%{email: "someone@notspam.example"})
    end

    test "the mail servers behind it are blocked too", %{admin: admin} do
      # A disposable-address service runs a thousand domains off one set of MX
      # records, and blocking them one at a time is a game nobody wins.
      {:ok, _} = Signup.block_email_domain(admin, %{"domain" => "spam.example"})

      resolver = fn "throwaway.example" -> ["mx.spam.example"] end

      assert {:error, :email_domain_blocked} =
               Signup.check(%{email: "someone@throwaway.example"}, resolver: resolver)
    end

    test "a domain nobody blocked passes whatever its mail servers are", %{} do
      resolver = fn "fine.example" -> ["mx.fine.example"] end

      assert :ok = Signup.check(%{email: "someone@fine.example"}, resolver: resolver)
    end

    test "the soft answer asks for approval instead of refusing", %{admin: admin} do
      # A university one spammer used is not a university that should be shut
      # out.
      {:ok, _} =
        Signup.block_email_domain(admin, %{
          "domain" => "university.example",
          "allow_with_approval" => true
        })

      assert {:approval, :email_domain} = Signup.check(%{email: "someone@university.example"})
    end
  end

  describe "canonical email addresses" do
    test "recognise the same address written differently", %{admin: admin} do
      {:ok, _} = Signup.block_email(admin, "A.Person+spam@gmail.com")

      assert {:error, :email_blocked} = Signup.check(%{email: "aperson@gmail.com"})
    end

    test "and leave everybody else alone", %{admin: admin} do
      {:ok, _} = Signup.block_email(admin, "aperson@gmail.com")

      assert :ok = Signup.check(%{email: "anotherperson@gmail.com"})
    end

    test "only fold the dots where the provider does", %{admin: admin} do
      # A dot means something at most providers. Folding it everywhere would
      # block strangers who happen to share a spelling.
      {:ok, _} = Signup.block_email(admin, "a.person@elsewhere.example")

      assert :ok = Signup.check(%{email: "aperson@elsewhere.example"})
    end

    test "are stored as a hash rather than an address", %{admin: admin} do
      {:ok, block} = Signup.block_email(admin, "aperson@gmail.com")

      refute block.canonical_email_hash =~ "aperson"
      refute block.canonical_email_hash =~ "gmail"
    end

    test "suspending an account can add one", %{admin: admin} do
      account = account_fixture()
      user = user_fixture(%{account_id: account.id, approved: true})

      :ok = Signup.block_email_of(admin, user)

      assert {:error, :email_blocked} = Signup.check(%{email: user.email})
    end
  end

  describe "addresses" do
    test "a blocked range refuses a sign-up", %{admin: admin} do
      {:ok, _} =
        Signup.block_ip(admin, %{"cidr" => "203.0.113.0/24", "severity" => "sign_up_block"})

      assert {:error, :ip_blocked} = Signup.check(%{ip: "203.0.113.9"})
    end

    test "and lets an address outside it through", %{admin: admin} do
      {:ok, _} =
        Signup.block_ip(admin, %{"cidr" => "203.0.113.0/24", "severity" => "sign_up_block"})

      assert :ok = Signup.check(%{ip: "198.51.100.9"})
    end

    test "the middle severity asks for approval", %{admin: admin} do
      # Most of what an admin wants is "make these ones ask", not "shut the
      # door".
      {:ok, _} = Signup.block_ip(admin, %{"cidr" => "203.0.113.0/24"})

      assert {:approval, :ip} = Signup.check(%{ip: "203.0.113.9"})
    end

    test "the hardest one keeps them out of the whole server", %{admin: admin} do
      {:ok, _} = Signup.block_ip(admin, %{"cidr" => "203.0.113.9/32", "severity" => "no_access"})

      assert Signup.blocked_from_access?("203.0.113.9")
      refute Signup.blocked_from_access?("203.0.113.10")
    end

    test "a signup block does not shut the door on reading", %{admin: admin} do
      {:ok, _} =
        Signup.block_ip(admin, %{"cidr" => "203.0.113.0/24", "severity" => "sign_up_block"})

      refute Signup.blocked_from_access?("203.0.113.9")
    end

    test "an expired one is not a block at all", %{admin: admin} do
      # A residential address is somebody else's next month, and a permanent
      # block on one is a punishment aimed at a stranger.
      {:ok, _} =
        Signup.block_ip(admin, %{
          "cidr" => "203.0.113.0/24",
          "severity" => "sign_up_block",
          "expires_at" => DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert :ok = Signup.check(%{ip: "203.0.113.9"})
    end

    test "a single address without a mask is one address", %{admin: admin} do
      {:ok, _} = Signup.block_ip(admin, %{"cidr" => "203.0.113.9", "severity" => "sign_up_block"})

      assert {:error, :ip_blocked} = Signup.check(%{ip: "203.0.113.9"})
      assert :ok = Signup.check(%{ip: "203.0.113.10"})
    end

    test "v6 works the same way", %{admin: admin} do
      {:ok, _} =
        Signup.block_ip(admin, %{"cidr" => "2001:db8::/32", "severity" => "sign_up_block"})

      assert {:error, :ip_blocked} = Signup.check(%{ip: "2001:db8::1"})
      assert :ok = Signup.check(%{ip: "2001:db9::1"})
    end

    test "a range nobody can read is refused rather than stored", %{admin: admin} do
      assert {:error, changeset} = Signup.block_ip(admin, %{"cidr" => "not an address"})
      assert %{cidr: [_]} = errors_on(changeset)
    end
  end

  describe "usernames" do
    test "an exact block refuses that name", %{admin: admin} do
      {:ok, _} = Signup.block_username(admin, %{"username" => "admin"})

      assert {:error, :username_blocked} = Signup.check(%{username: "admin"})
      assert :ok = Signup.check(%{username: "administrator"})
    end

    test "a partial one refuses anything containing it", %{admin: admin} do
      {:ok, _} = Signup.block_username(admin, %{"username" => "support", "exact" => false})

      assert {:error, :username_blocked} = Signup.check(%{username: "abuuba_support_team"})
    end

    test "letters that look alike are the same letter", %{admin: admin} do
      # A name spelled with a Cyrillic "а" is the same name to a reader, which
      # is the entire point of spelling it that way.
      {:ok, _} = Signup.block_username(admin, %{"username" => "admin"})

      assert {:error, :username_blocked} = Signup.check(%{username: "аdmin"})
    end

    test "and so is a name in different case", %{admin: admin} do
      {:ok, _} = Signup.block_username(admin, %{"username" => "admin"})

      assert {:error, :username_blocked} = Signup.check(%{username: "AdMiN"})
    end
  end

  describe "several answers at once" do
    test "a refusal beats a request for approval", %{admin: admin} do
      {:ok, _} =
        Signup.block_email_domain(admin, %{
          "domain" => "iffy.example",
          "allow_with_approval" => true
        })

      {:ok, _} =
        Signup.block_ip(admin, %{"cidr" => "203.0.113.0/24", "severity" => "sign_up_block"})

      assert {:error, :ip_blocked} =
               Signup.check(%{email: "someone@iffy.example", ip: "203.0.113.9"})
    end

    test "and nothing at all passes", %{} do
      assert :ok =
               Signup.check(%{email: "someone@fine.example", ip: "198.51.100.1", username: "jo"})
    end
  end

  describe "registering with all this in force" do
    setup do
      :ok = Settings.put_registration_mode("open")
    end

    test "a blocked domain is refused with a message about the field", %{admin: admin} do
      {:ok, _} = Signup.block_email_domain(admin, %{"domain" => "spam.example"})

      assert {:error, changeset} = Auth.register(params(%{"email" => "jo@spam.example"}))
      assert %{email: [_]} = errors_on(changeset)
    end

    test "a blocked username likewise", %{admin: admin} do
      {:ok, _} = Signup.block_username(admin, %{"username" => "admin"})

      assert {:error, changeset} = Auth.register(params(%{"username" => "admin"}))
      assert %{username: [_]} = errors_on(changeset)
    end

    test "an address that only needs approval gets in but waits", %{admin: admin} do
      {:ok, _} = Signup.block_ip(admin, %{"cidr" => "203.0.113.0/24"})

      assert {:ok, %{user: user}} = Auth.register(params(%{}), ip: "203.0.113.9")

      refute user.approved
    end

    test "and the address is remembered", %{} do
      assert {:ok, %{user: user}} = Auth.register(params(%{}), ip: "198.51.100.7")

      assert Repo.reload(user).sign_up_ip == "198.51.100.7"
    end
  end

  describe "closing the door when nobody is watching" do
    test "an open server with no moderator for a week closes itself" do
      # An open server left unattended fills with spam registrations within
      # days, and the admin who forgot about it is the one who finds out.
      :ok = Settings.put_registration_mode("open")

      assert :closed = Signup.close_if_unattended(DateTime.utc_now())
      assert Settings.registration_mode() == :closed
    end

    test "and says so, so nobody thinks it was them" do
      :ok = Settings.put_registration_mode("open")

      :closed = Signup.close_if_unattended(DateTime.utc_now())

      assert [%{action: "registrations.auto_close"}] = AuditLog.by_actor(nil)
    end

    test "a server somebody is watching stays open", %{} do
      :ok = Settings.put_registration_mode("open")
      moderator_seen_today()

      assert :open = Signup.close_if_unattended(DateTime.utc_now())
      assert Settings.registration_mode() == :open
    end

    test "a server that is already closed is left alone" do
      :ok = Settings.put_registration_mode("approved")

      assert :unchanged = Signup.close_if_unattended(DateTime.utc_now())
      assert Settings.registration_mode() == :approved
    end
  end

  describe "the puzzle" do
    test "is off unless somebody configured it" do
      # A server that quietly required a puzzle nobody set up would refuse
      # every sign-up with no explanation.
      refute Captcha.enabled?()
      assert Captcha.verify(nil) == :ok
    end

    test "refuses a missing answer once it is on" do
      with_captcha(fn ->
        assert {:error, :captcha_missing} = Captcha.verify(nil)
      end)
    end

    test "accepts one the checker agrees with" do
      with_captcha(fn ->
        post = fn _url, _form -> {:ok, %{"success" => true}} end

        assert :ok = Captcha.verify("an-answer", post: post)
      end)
    end

    test "refuses one it does not" do
      with_captcha(fn ->
        post = fn _url, _form -> {:ok, %{"success" => false}} end

        assert {:error, :captcha_failed} = Captcha.verify("an-answer", post: post)
      end)
    end

    test "refuses when the checker cannot be reached" do
      # A check that cannot be made must not pass, or the puzzle is decoration.
      with_captcha(fn ->
        post = fn _url, _form -> {:error, :timeout} end

        assert {:error, :captcha_unavailable} = Captcha.verify("an-answer", post: post)
      end)
    end
  end

  defp with_captcha(fun) do
    previous = Application.get_env(:abuuba, Captcha)
    Application.put_env(:abuuba, Captcha, site_key: "site", secret: "secret")

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:abuuba, Captcha, previous),
        else: Application.delete_env(:abuuba, Captcha)
    end
  end

  defp params(overrides) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        "username" => "person#{unique}",
        "email" => "person#{unique}@example.test",
        "password" => "a long enough password",
        "agreement" => "true"
      },
      overrides
    )
  end

  defp moderator_seen_today do
    {:ok, role} =
      Roles.create(%{
        name: "Moderator #{System.unique_integer([:positive])}",
        position: 10,
        permissions: Roles.mask(["manage_reports"])
      })

    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, user} = Roles.assign(user, role)

    user
    |> Ecto.Changeset.change(last_signed_in_at: DateTime.utc_now())
    |> Repo.update()
  end
end
