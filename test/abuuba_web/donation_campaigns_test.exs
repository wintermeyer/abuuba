defmodule AbuubaWeb.DonationCampaignsTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Admin
  alias Abuuba.Instance.DonationCampaign
  alias Abuuba.OAuth
  alias Abuuba.Settings

  setup %{conn: conn} do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    on_exit(&clear/0)
    clear()

    %{conn: put_req_header(conn, "authorization", "Bearer " <> raw), account: account}
  end

  defp clear do
    Settings.put("donation_campaign_message", "")
    Settings.put("donation_campaign_button_text", "")
    Settings.put("donation_campaign_url", "")
  end

  defp write(message, url, button \\ "") do
    Settings.put("donation_campaign_message", message)
    Settings.put("donation_campaign_url", url)
    Settings.put("donation_campaign_button_text", button)
  end

  describe "what counts as a campaign" do
    test "nothing written is no campaign" do
      assert is_nil(DonationCampaign.current())
    end

    test "a message with nowhere to go is no campaign" do
      write("Help pay for the server", "")

      assert is_nil(DonationCampaign.current())
    end

    test "a link with nothing to say is no campaign" do
      write("", "https://example.com/donate")

      assert is_nil(DonationCampaign.current())
    end

    test "a link that is not http is no campaign" do
      # An admin's typo must not become a link every client on this server
      # renders.
      write("Help pay for the server", "javascript:alert(1)")

      assert is_nil(DonationCampaign.current())
    end

    test "both written is a campaign" do
      write("Help pay for the server", "https://example.com/donate")

      campaign = DonationCampaign.current()
      assert campaign["message"] == "Help pay for the server"
      assert campaign["url"] == "https://example.com/donate"
    end

    test "the button says something even when the admin did not" do
      write("Help pay for the server", "https://example.com/donate")

      assert DonationCampaign.current()["button_text"] != ""
    end
  end

  describe "the id" do
    test "does not change between reads, so a dismissal sticks" do
      write("Help pay for the server", "https://example.com/donate")

      assert DonationCampaign.current()["id"] == DonationCampaign.current()["id"]
    end

    test "changes when the admin rewrites the appeal, so it is shown again" do
      write("Help pay for the server", "https://example.com/donate")
      before = DonationCampaign.current()["id"]

      write("We need a bigger disk", "https://example.com/donate")

      refute DonationCampaign.current()["id"] == before
    end
  end

  describe "GET /api/v1/donation_campaigns" do
    test "answers 204 where there is nothing to show", %{conn: conn} do
      assert conn |> get(~p"/api/v1/donation_campaigns") |> response(204)
    end

    test "answers with the campaign where there is one", %{conn: conn} do
      write("Help pay for the server", "https://example.com/donate", "Chip in")

      body = conn |> get(~p"/api/v1/donation_campaigns") |> json_response(200)

      assert body["message"] == "Help pay for the server"
      assert body["url"] == "https://example.com/donate"
      assert body["button_text"] == "Chip in"
      assert body["id"]
      assert body["locale"]
    end

    test "refuses anonymously" do
      write("Help pay for the server", "https://example.com/donate")

      build_conn() |> get(~p"/api/v1/donation_campaigns") |> json_response(422)
    end
  end

  describe "what an admin may write" do
    setup do
      %{moderator: account_fixture()}
    end

    test "a good link is stored", %{moderator: moderator} do
      :ok =
        Admin.put_settings(moderator, %{
          "donation_campaign_url" => "https://example.com/donate"
        })

      assert Settings.get("donation_campaign_url") == "https://example.com/donate"
    end

    test "a bad link is refused rather than stored", %{moderator: moderator} do
      Settings.put("donation_campaign_url", "https://example.com/donate")

      :ok = Admin.put_settings(moderator, %{"donation_campaign_url" => "javascript:alert(1)"})

      assert Settings.get("donation_campaign_url") == "https://example.com/donate"
    end

    test "an empty link is how the campaign comes down", %{moderator: moderator} do
      Settings.put("donation_campaign_url", "https://example.com/donate")

      :ok = Admin.put_settings(moderator, %{"donation_campaign_url" => ""})

      assert Settings.get("donation_campaign_url") == ""
    end
  end
end
