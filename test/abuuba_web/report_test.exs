defmodule AbuubaWeb.ReportTest do
  @moduledoc """
  Telling a moderator about somebody, from the pages rather than from an app.

  `POST /api/v1/reports` has always answered and `/admin/reports` is a full
  triage queue with categories, evidence, rule attribution and forwarding.
  Nothing in this server's own interface could put anything into it, so the
  queue could only be filled by an API client and a person reading a post here
  had no way to say anything about it.

  The steps are the ones the reference implementation settled on, because a
  report is read by a moderator who has to decide something and the shape of
  what they are given is what makes that possible: a category, the posts it is
  about, which rules if any, and a sentence in the reporter's own words.

  The first option files no report. "I do not like it" is not a moderation
  problem, and offering mute and block there is what stops the queue filling
  with reports that only ever needed a button the reader had not found.
  """
  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Moderation.Reports
  alias Abuuba.Relationships
  alias Abuuba.Settings

  setup %{conn: conn} do
    reporter = account_fixture(%{username: "reporter"})

    user =
      user_fixture(%{account_id: reporter.id, approved: true, confirmed_at: DateTime.utc_now()})

    subject = account_fixture(%{username: "subject", display_name: "The Subject"})
    status = status_fixture(%{account_id: subject.id, text: "the post in question"})

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))

    %{conn: conn, reporter: reporter, subject: subject, status: status}
  end

  defp filed(reporter) do
    Reports.list(%{limit: 10}) |> Enum.filter(&(&1.account_id == reporter.id))
  end

  describe "the page" do
    test "names who it is about", %{conn: conn, subject: subject} do
      {:ok, _live, html} = live(conn, ~p"/report/@#{subject.username}")

      assert html =~ "The Subject"
      assert html =~ "@#{subject.username}"
    end

    test "refuses to be a page about somebody who does not exist", %{conn: conn} do
      assert_raise AbuubaWeb.NotFound, fn -> live(conn, ~p"/report/@nobodyhere") end
    end

    test "refuses to be a page about yourself", %{conn: conn, reporter: reporter} do
      # Nothing a moderator can do with it, and the mute and block it offers
      # would be a person blocking themselves.
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/report/@#{reporter.username}")

      assert to == ~p"/@#{reporter.username}"
    end

    test "is not a page for somebody signed out", %{subject: subject} do
      assert {:error, {:redirect, %{to: to}}} =
               live(Phoenix.ConnTest.build_conn(), ~p"/report/@#{subject.username}")

      assert to == ~p"/login"
    end
  end

  describe "a category that is a moderation problem" do
    test "files the report, with the comment", %{conn: conn, reporter: reporter, subject: subject} do
      {:ok, live, _html} = live(conn, ~p"/report/@#{subject.username}")

      live |> element("button[phx-click='category'][phx-value-category='spam']") |> render_click()
      live |> element("button[phx-click='to_comment']") |> render_click()

      live
      |> form("#report-form", report: %{"comment" => "they posted the same link nine times"})
      |> render_submit()

      assert [report] = filed(reporter)
      assert report.category == "spam"
      assert report.target_account_id == subject.id
      assert report.comment =~ "nine times"
    end

    test "and the posts that were ticked as evidence", %{
      conn: conn,
      reporter: reporter,
      subject: subject,
      status: status
    } do
      {:ok, live, _html} = live(conn, ~p"/report/@#{subject.username}?status=#{status.id}")

      live |> element("button[phx-click='category'][phx-value-category='spam']") |> render_click()
      live |> element("button[phx-click='to_comment']") |> render_click()
      live |> form("#report-form", report: %{"comment" => ""}) |> render_submit()

      assert [report] = filed(reporter)
      assert report.status_ids == [status.id]
    end

    test "and nothing when the reader ticks nothing", %{
      conn: conn,
      reporter: reporter,
      subject: subject,
      status: status
    } do
      {:ok, live, _html} = live(conn, ~p"/report/@#{subject.username}")

      live
      |> element("button[phx-click='category'][phx-value-category='other']")
      |> render_click()

      live |> element("button[phx-click='to_comment']") |> render_click()
      live |> form("#report-form", report: %{"comment" => ""}) |> render_submit()

      assert [report] = filed(reporter)
      assert report.status_ids == []
      assert status
    end
  end

  describe "the rules step" do
    test "is offered only when the server has rules", %{conn: conn, subject: subject} do
      {:ok, live, html} = live(conn, ~p"/report/@#{subject.username}")

      refute html =~ "violates"

      {:ok, _rule} = Settings.create_rule(%{"text" => "Be kind to one another"})

      {:ok, live2, html2} = live(conn, ~p"/report/@#{subject.username}")

      assert html2 =~ "rules"
      assert live && live2
    end

    test "records which rules were named", %{
      conn: conn,
      reporter: reporter,
      subject: subject
    } do
      {:ok, rule} = Settings.create_rule(%{"text" => "Be kind to one another"})

      {:ok, live, _html} = live(conn, ~p"/report/@#{subject.username}")

      live
      |> element("button[phx-click='category'][phx-value-category='violation']")
      |> render_click()

      live
      |> form("#rules-form", report: %{"rule_ids" => [to_string(rule.id)]})
      |> render_submit()

      live |> element("button[phx-click='to_comment']") |> render_click()
      live |> form("#report-form", report: %{"comment" => ""}) |> render_submit()

      assert [report] = filed(reporter)
      assert report.category == "violation"
      assert report.rule_ids == [rule.id]
    end
  end

  describe "\"I do not like it\"" do
    test "files nothing at all", %{conn: conn, reporter: reporter, subject: subject} do
      {:ok, live, _html} = live(conn, ~p"/report/@#{subject.username}")

      live
      |> element("button[phx-click='category'][phx-value-category='dislike']")
      |> render_click()

      assert filed(reporter) == []
    end

    test "and offers the buttons that actually answer it", %{conn: conn, subject: subject} do
      {:ok, live, _html} = live(conn, ~p"/report/@#{subject.username}")

      html =
        live
        |> element("button[phx-click='category'][phx-value-category='dislike']")
        |> render_click()

      assert html =~ "Mute"
      assert html =~ "Block"
    end

    test "and muting from there works", %{conn: conn, reporter: reporter, subject: subject} do
      {:ok, live, _html} = live(conn, ~p"/report/@#{subject.username}")

      live
      |> element("button[phx-click='category'][phx-value-category='dislike']")
      |> render_click()

      live |> element("button[phx-click='mute']") |> render_click()

      assert Relationships.muting?(reporter.id, subject.id)
    end
  end

  describe "after a report is filed" do
    test "the same buttons are offered, because the wait is real", %{
      conn: conn,
      reporter: reporter,
      subject: subject
    } do
      {:ok, live, _html} = live(conn, ~p"/report/@#{subject.username}")

      live |> element("button[phx-click='category'][phx-value-category='spam']") |> render_click()
      live |> element("button[phx-click='to_comment']") |> render_click()

      html = live |> form("#report-form", report: %{"comment" => ""}) |> render_submit()

      assert html =~ "Block"

      live |> element("button[phx-click='block']") |> render_click()

      assert Relationships.blocking?(reporter.id, subject.id)
    end
  end
end
