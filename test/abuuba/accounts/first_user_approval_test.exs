defmodule Abuuba.Accounts.FirstUserApprovalTest do
  @moduledoc """
  The first account on a development server is not left waiting for itself.

  It is made an admin, and on a server that moderates sign-ups it is also the
  only account that could approve the queue it is sitting in. Email is still
  confirmed by following the link, which is a different question from whether a
  moderator wants you here.
  """

  use Abuuba.DataCase, async: false

  alias Abuuba.Accounts.Auth
  alias Abuuba.Settings

  setup do
    Settings.put_registration_mode(:approved)
    on_exit(fn -> Application.delete_env(:abuuba, :first_user_is_admin) end)

    :ok
  end

  defp register(username) do
    {:ok, %{user: user}} =
      Auth.register(
        %{
          "username" => username,
          "email" => "#{username}@example.com",
          "password" => "correct horse battery",
          "invite_reason" => "I am setting this server up"
        },
        rules_required: false
      )

    user
  end

  describe "on a development server" do
    setup do
      Application.put_env(:abuuba, :first_user_is_admin, true)

      :ok
    end

    test "the first account is let in without waiting for a moderator" do
      user = register("founder")

      assert user.approved
      assert user.approved_at
    end

    test "and still has to confirm the address" do
      # A different question from whether a moderator wants you here, and the
      # link is in the development mailbox.
      user = register("founder")

      refute user.confirmed_at
    end

    test "and can sign in once the address is confirmed" do
      # The end of the chain, and the thing the deadlock actually broke: an
      # account made admin and then left in a queue only it could empty.
      user = register("founder")

      assert {:error, :unconfirmed} = Auth.check_sign_in(user)

      {:ok, token} = Auth.create_confirmation_token(user)
      {:ok, confirmed} = Auth.confirm_user(token)

      assert :ok = Auth.check_sign_in(confirmed)
    end

    test "the second account waits like anybody else" do
      register("founder")
      second = register("latecomer")

      refute second.approved
      refute second.approved_at
    end

    test "and is still stopped at the door after confirming" do
      # The positive control's mirror: if the branch above ever stopped
      # discriminating, everybody would sail through and the tests that only
      # check the founder would all still pass.
      register("founder")
      second = register("latecomer")

      {:ok, token} = Auth.create_confirmation_token(second)
      {:ok, confirmed} = Auth.confirm_user(token)

      assert {:error, :pending_approval} = Auth.check_sign_in(confirmed)
    end
  end

  describe "anywhere else" do
    test "the first account waits like anybody else" do
      Application.put_env(:abuuba, :first_user_is_admin, false)

      user = register("founder")

      refute user.approved
      refute user.approved_at
    end
  end

  describe "when the server is not moderating sign-ups at all" do
    test "nothing about approval changes" do
      # The positive control for the whole file: with the queue switched off,
      # every account is approved anyway, so a test suite that only ever ran
      # this way would prove nothing about the branch above.
      Settings.put_registration_mode(:open)
      Application.put_env(:abuuba, :first_user_is_admin, true)

      assert register("founder").approved
      assert register("second").approved
    end
  end
end
