defmodule Abuuba.Accounts.TwoFactorTest do
  use Abuuba.DataCase, async: true

  alias Abuuba.Accounts.Auth
  alias Abuuba.Accounts.RecoveryCode
  alias Abuuba.Accounts.TwoFactor
  alias Abuuba.Accounts.User
  alias Abuuba.Settings

  setup do
    Settings.put_registration_mode(:open)

    {:ok, %{user: user}} =
      Auth.register(
        %{
          "username" => "alice",
          "email" => "alice@example.com",
          "password" => "correct horse battery"
        },
        rules_required: false
      )

    %{user: user}
  end

  defp current_code(secret), do: NimbleTOTP.verification_code(secret)

  describe "enrolment" do
    test "does not switch the requirement on until a code proves it works", %{user: user} do
      {:ok, %{secret: secret, uri: uri, qr_code: qr}} = TwoFactor.begin_totp_enrolment(user)

      reloaded = Repo.get!(User, user.id)

      refute TwoFactor.required?(reloaded),
             "turning it on here would lock somebody out for mis-scanning the QR code"

      assert uri =~ "otpauth://totp/"
      assert uri =~ "abuuba"
      assert qr =~ "<svg"

      assert {:ok, enrolled, _codes} =
               TwoFactor.confirm_totp_enrolment(reloaded, current_code(secret))

      assert TwoFactor.required?(enrolled)
    end

    test "refuses to finish on a wrong code", %{user: user} do
      {:ok, _} = TwoFactor.begin_totp_enrolment(user)
      reloaded = Repo.get!(User, user.id)

      assert TwoFactor.confirm_totp_enrolment(reloaded, "000000") == {:error, :invalid_code}
      refute TwoFactor.required?(Repo.get!(User, user.id))
    end

    test "cannot be finished without being started", %{user: user} do
      assert TwoFactor.confirm_totp_enrolment(user, "123456") == {:error, :not_enrolling}
    end

    test "hands back ten recovery codes, once", %{user: user} do
      {:ok, %{secret: secret}} = TwoFactor.begin_totp_enrolment(user)
      reloaded = Repo.get!(User, user.id)

      {:ok, enrolled, codes} = TwoFactor.confirm_totp_enrolment(reloaded, current_code(secret))

      assert length(codes) == RecoveryCode.code_count()
      assert length(Enum.uniq(codes)) == length(codes)
      assert TwoFactor.unused_recovery_code_count(enrolled) == RecoveryCode.code_count()
    end
  end

  describe "the secret" do
    test "never touches the disk in the clear", %{user: user} do
      {:ok, %{secret: secret}} = TwoFactor.begin_totp_enrolment(user)

      %{rows: [[stored]]} =
        Repo.query!("SELECT otp_secret FROM users WHERE id = $1", [user.id])

      refute stored == secret

      assert Repo.get!(User, user.id).otp_secret == secret,
             "and still round-trips"
    end
  end

  describe "verifying a code" do
    setup %{user: user} do
      {:ok, %{secret: secret}} = TwoFactor.begin_totp_enrolment(user)
      reloaded = Repo.get!(User, user.id)
      {:ok, enrolled, codes} = TwoFactor.confirm_totp_enrolment(reloaded, current_code(secret))

      %{user: enrolled, secret: secret, codes: codes}
    end

    test "accepts the current code", %{user: user, secret: secret} do
      # Enrolment consumed this window, so step past it before checking.
      user = Repo.update!(Ecto.Changeset.change(user, otp_last_used_at: nil))

      assert {:ok, _} = TwoFactor.verify_totp(user, current_code(secret))
    end

    test "refuses the same code twice", %{user: user, secret: secret} do
      user = Repo.update!(Ecto.Changeset.change(user, otp_last_used_at: nil))
      {:ok, user} = TwoFactor.verify_totp(user, current_code(secret))

      assert TwoFactor.verify_totp(user, current_code(secret)) == {:error, :already_used},
             "a code read over a shoulder must not still work for the rest of its window"
    end

    test "refuses a wrong code", %{user: user} do
      user = Repo.update!(Ecto.Changeset.change(user, otp_last_used_at: nil))

      assert TwoFactor.verify_totp(user, "000000") == {:error, :invalid_code}
      assert TwoFactor.verify_totp(user, "") == {:error, :invalid_code}
      assert TwoFactor.verify_totp(user, "not a code") == {:error, :invalid_code}
    end

    test "tolerates a phone clock a window out", %{user: user, secret: secret} do
      # Phones drift, and people start typing at 29 seconds.
      previous = NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30)

      assert TwoFactor.valid_totp?(user, previous)
    end

    test "ignores the spaces authenticator apps put in codes", %{user: user, secret: secret} do
      code = current_code(secret)
      spaced = String.slice(code, 0, 3) <> " " <> String.slice(code, 3, 3)

      assert TwoFactor.valid_totp?(user, spaced)
    end
  end

  describe "recovery codes" do
    setup %{user: user} do
      {:ok, %{secret: secret}} = TwoFactor.begin_totp_enrolment(user)
      reloaded = Repo.get!(User, user.id)
      {:ok, enrolled, codes} = TwoFactor.confirm_totp_enrolment(reloaded, current_code(secret))

      %{user: enrolled, codes: codes}
    end

    test "work once each", %{user: user, codes: [first | rest]} do
      assert TwoFactor.use_recovery_code(user, first) == :ok
      assert TwoFactor.use_recovery_code(user, first) == {:error, :invalid_code}

      assert TwoFactor.unused_recovery_code_count(user) == length(rest)
      assert TwoFactor.use_recovery_code(user, hd(rest)) == :ok
    end

    test "are forgiving about how they were written down", %{user: user, codes: [code | _]} do
      # Read off paper by somebody already locked out and probably flustered.
      assert TwoFactor.use_recovery_code(user, String.upcase(code)) == :ok
    end

    test "refuse anything that is not one", %{user: user} do
      assert TwoFactor.use_recovery_code(user, "nonsense") == {:error, :invalid_code}
      assert TwoFactor.use_recovery_code(user, "") == {:error, :invalid_code}
    end

    test "belong to one user only", %{user: user, codes: [code | _]} do
      {:ok, %{user: other}} =
        Auth.register(
          %{
            "username" => "bob",
            "email" => "bob@example.com",
            "password" => "correct horse battery"
          },
          rules_required: false
        )

      assert TwoFactor.use_recovery_code(other, code) == {:error, :invalid_code}
      assert TwoFactor.use_recovery_code(user, code) == :ok
    end

    test "are never stored in readable form", %{user: user, codes: [code | _]} do
      %{rows: rows} =
        Repo.query!("SELECT hashed_code FROM recovery_codes WHERE user_id = $1", [user.id])

      refute code in List.flatten(rows)
    end

    test "regenerating retires the old set", %{user: user, codes: [old | _]} do
      {:ok, fresh} = TwoFactor.regenerate_recovery_codes(user)

      assert TwoFactor.use_recovery_code(user, old) == {:error, :invalid_code}
      assert TwoFactor.use_recovery_code(user, hd(fresh)) == :ok
    end

    test "avoid the characters people misread", %{codes: codes} do
      for code <- codes do
        refute code =~ ~r/[01lIoO]/, "#{code} contains a character that gets misread"
      end
    end
  end

  describe "turning it off" do
    test "takes everything belonging to it with it", %{user: user} do
      {:ok, %{secret: secret}} = TwoFactor.begin_totp_enrolment(user)
      reloaded = Repo.get!(User, user.id)

      {:ok, enrolled, [code | _]} =
        TwoFactor.confirm_totp_enrolment(reloaded, current_code(secret))

      {:ok, disabled} = TwoFactor.disable(enrolled)

      refute TwoFactor.required?(disabled)
      assert disabled.otp_secret == nil
      assert TwoFactor.unused_recovery_code_count(disabled) == 0
      assert TwoFactor.use_recovery_code(disabled, code) == {:error, :invalid_code}
    end
  end

  describe "security keys" do
    test "are stored and listed", %{user: user} do
      assert {:ok, credential} =
               TwoFactor.add_webauthn_credential(user, %{
                 credential_id: <<1, 2, 3>>,
                 public_key: <<4, 5, 6>>,
                 nickname: "yubikey"
               })

      assert Enum.map(TwoFactor.webauthn_credentials(user), & &1.id) == [credential.id]
    end

    test "cannot be registered twice", %{user: user} do
      {:ok, _} =
        TwoFactor.add_webauthn_credential(user, %{
          credential_id: <<1, 2, 3>>,
          public_key: <<4, 5, 6>>
        })

      assert {:error, changeset} =
               TwoFactor.add_webauthn_credential(user, %{
                 credential_id: <<1, 2, 3>>,
                 public_key: <<7, 8, 9>>
               })

      assert errors_on(changeset).credential_id != []
    end

    test "a counter that goes backwards is refused as a clone", %{user: user} do
      {:ok, credential} =
        TwoFactor.add_webauthn_credential(user, %{
          credential_id: <<1>>,
          public_key: <<2>>,
          sign_count: 5
        })

      assert {:ok, advanced} = TwoFactor.record_webauthn_use(credential, 6)

      assert TwoFactor.record_webauthn_use(advanced, 6) == {:error, :possible_clone}
      assert TwoFactor.record_webauthn_use(advanced, 3) == {:error, :possible_clone}
    end

    test "a key that does not count at all is still accepted", %{user: user} do
      # Reporting zero forever is allowed by the spec; only going backwards is
      # evidence of anything.
      {:ok, credential} =
        TwoFactor.add_webauthn_credential(user, %{credential_id: <<9>>, public_key: <<9>>})

      assert {:ok, _} = TwoFactor.record_webauthn_use(credential, 0)
      assert {:ok, _} = TwoFactor.record_webauthn_use(credential, 0)
    end

    test "go away with the user", %{user: user} do
      {:ok, _} =
        TwoFactor.add_webauthn_credential(user, %{credential_id: <<1>>, public_key: <<2>>})

      Repo.delete!(user)

      assert Repo.query!("SELECT count(*) FROM webauthn_credentials").rows == [[0]]
    end
  end
end
