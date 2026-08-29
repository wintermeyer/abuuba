defmodule AbuubaWeb.AdminEmojiTest do
  @moduledoc """
  Adding, disabling and removing this server's own custom emoji.
  """

  use AbuubaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts.Auth
  alias Abuuba.Cache
  alias Abuuba.Instance
  alias Abuuba.Instance.CustomEmoji
  alias Abuuba.Instance.EmojiImages
  alias Abuuba.Media.Storage
  alias Abuuba.Repo
  alias Abuuba.Roles
  alias Abuuba.Statuses.Formatter

  # A real one-pixel PNG. The pipeline reads what it is handed, so noise behind
  # the right magic bytes is a different test than this one.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "abuuba-emoji-test-#{System.unique_integer([:positive])}")
    Application.put_env(:abuuba, :media_root, root)
    on_exit(fn -> File.rm_rf(root) end)

    %{conn: log_in(conn, staff(["manage_custom_emojis"]))}
  end

  defp staff(permissions) do
    {:ok, role} =
      Roles.create(%{
        name: "Role #{System.unique_integer([:positive])}",
        position: 900,
        permissions: Roles.mask(permissions)
      })

    user =
      user_fixture(%{
        account_id: account_fixture().id,
        approved: true,
        confirmed_at: DateTime.utc_now()
      })

    {:ok, user} = Roles.assign(user, role)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Auth.create_session_token(user))
  end

  defp upload(live, shortcode, opts \\ []) do
    entry =
      file_input(live, "#emoji-form", :image, [
        %{
          name: Keyword.get(opts, :filename, "blobcat.png"),
          content: Keyword.get(opts, :content, @png),
          type: Keyword.get(opts, :type, "image/png")
        }
      ])

    render_upload(entry, Keyword.get(opts, :filename, "blobcat.png"))

    live
    |> form("#emoji-form", %{
      "emoji" => %{"shortcode" => shortcode, "category" => Keyword.get(opts, :category, "")}
    })
    |> render_submit()
  end

  describe "adding one" do
    test "puts it in the picker", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      upload(live, "blobcat")

      assert [%CustomEmoji{} = emoji] = Repo.all(CustomEmoji)
      assert emoji.shortcode == "blobcat"
      assert emoji.domain == nil
      refute emoji.disabled

      # Served from this server, so the picture survives the server it came
      # from going away — which is the whole difference from copying a URL.
      assert emoji.image_url =~ "/media/"
      assert emoji in Instance.custom_emojis()
    end

    test "keeps the category somebody typed", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      upload(live, "blobcat", category: "Reactions")

      assert [%{category: "Reactions"}] = Repo.all(CustomEmoji)
    end

    test "refuses a shortcode that is not one", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      html = upload(live, "not a shortcode")

      assert html =~ "letters, numbers and underscores"
      assert Repo.all(CustomEmoji) == []
    end

    test "refuses a file that is not a picture", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      html =
        upload(live, "blobcat", content: "not a picture", type: "text/plain", filename: "x.txt")

      assert html =~ "PNG or a GIF" or html =~ "not accepted"
      assert Repo.all(CustomEmoji) == []
    end

    test "replaces the one already using that shortcode", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      upload(live, "blobcat")
      [before] = Repo.all(CustomEmoji)

      upload(live, "blobcat")

      # One shortcode is one picture here. A second row would be a name the
      # picker could not choose between.
      assert [after_upload] = Repo.all(CustomEmoji)
      assert after_upload.id == before.id
    end

    test "leaves another server's emoji of the same name alone", %{conn: conn} do
      Repo.insert!(%CustomEmoji{
        shortcode: "blobcat",
        domain: "elsewhere.example",
        image_url: "https://elsewhere.example/blobcat.png",
        static_url: "https://elsewhere.example/blobcat.png"
      })

      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      upload(live, "blobcat")

      # `:blobcat:` here and `:blobcat:` there are two pictures with one name,
      # and theirs is what their posts render with.
      assert Repo.aggregate(CustomEmoji, :count) == 2
    end
  end

  # Through the same path the admin screen uses, so the test exercises the
  # wiring rather than `EmojiImages.store/3` on its own. Returns the storage
  # key of what was written.
  defp upload_emoji(_conn, shortcode, name, bytes) do
    previous = Instance.local_emoji_image_url(shortcode)

    {:ok, emoji} =
      Instance.put_local_emoji(%{"shortcode" => shortcode, "image_url" => "pending"})

    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}.png")
    File.write!(path, bytes)

    {:ok, url} =
      EmojiImages.store(
        emoji.id,
        %{path: path, filename: "#{name}.png", content_type: "image/png"},
        replacing: previous
      )

    {:ok, _} =
      Instance.put_local_emoji(%{
        "shortcode" => shortcode,
        "image_url" => url,
        "static_url" => url
      })

    File.rm(path)

    url |> String.split("/media/", parts: 2) |> List.last()
  end

  describe "the list" do
    setup do
      {:ok, emoji} =
        Instance.put_custom_emoji(%{
          shortcode: "blobcat",
          image_url: "http://abuuba.test/media/custom_emojis/1/original/blobcat.png",
          static_url: "http://abuuba.test/media/custom_emojis/1/original/blobcat.png"
        })

      %{emoji: emoji}
    end

    test "stops offering one without touching the posts that used it", %{
      conn: conn,
      emoji: emoji
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      live
      |> element("button[phx-click='toggle_offered'][phx-value-id='#{emoji.id}']")
      |> render_click()

      refute Repo.reload!(emoji).visible_in_picker
      refute Repo.reload!(emoji).disabled

      # Out of the picker, and still in the list every post renders from --
      # which is the difference between this button and the one below it.
      refute Enum.any?(Instance.offered_custom_emojis(), &(&1.id == emoji.id))
      assert Enum.any?(Instance.custom_emojis(), &(&1.id == emoji.id))
    end

    test "offers it again", %{conn: conn, emoji: emoji} do
      emoji |> Ecto.Changeset.change(visible_in_picker: false) |> Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      live
      |> element("button[phx-click='toggle_offered'][phx-value-id='#{emoji.id}']")
      |> render_click()

      assert Repo.reload!(emoji).visible_in_picker
      assert Enum.any?(Instance.offered_custom_emojis(), &(&1.id == emoji.id))
    end

    test "turns one off, which does take it out of the posts that used it", %{
      conn: conn,
      emoji: emoji
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      live
      |> element("button[phx-click='toggle_emoji'][phx-value-id='#{emoji.id}']")
      |> render_click()

      assert Repo.reload!(emoji).disabled

      # The row survives, so turning it back on restores every post at once.
      assert Repo.get(CustomEmoji, emoji.id)
      refute Enum.any?(Instance.custom_emojis(), &(&1.id == emoji.id))
    end

    test "puts it back", %{conn: conn, emoji: emoji} do
      emoji |> Ecto.Changeset.change(disabled: true) |> Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      live
      |> element("button[phx-click='toggle_emoji'][phx-value-id='#{emoji.id}']")
      |> render_click()

      refute Repo.reload!(emoji).disabled
    end

    test "an unoffered one still renders in a post, and is not in the API list", %{
      emoji: emoji
    } do
      html = Formatter.to_html("hello :blobcat:")
      assert html =~ emoji.image_url

      assert build_conn()
             |> get(~p"/api/v1/custom_emojis")
             |> json_response(200)
             |> Enum.any?(&(&1["shortcode"] == "blobcat"))

      emoji |> Ecto.Changeset.change(visible_in_picker: false) |> Repo.update!()
      Cache.invalidate(:custom_emojis)

      # The point of the flag: an old post is untouched, a new one is not
      # offered the name.
      assert Formatter.to_html("hello :blobcat:") =~ emoji.image_url

      refute build_conn()
             |> get(~p"/api/v1/custom_emojis")
             |> json_response(200)
             |> Enum.any?(&(&1["shortcode"] == "blobcat"))
    end

    test "replacing a picture takes the old file with it", %{conn: conn} do
      # The key is a hash of the file, so a new picture is written beside the
      # old one rather than over it, and nothing else would ever reclaim it.
      shortcode = "swap#{System.unique_integer([:positive])}"

      first = upload_emoji(conn, shortcode, "one", "PNG-ONE")
      assert Storage.exists?(first)

      second = upload_emoji(conn, shortcode, "two", "PNG-TWO")

      # The control: the new one is there, so the refute is about the old file
      # going rather than about neither being written.
      assert second != first
      assert Storage.exists?(second)
      refute Storage.exists?(first)
    end

    test "deletes one", %{conn: conn, emoji: emoji} do
      {:ok, live, _html} = live(conn, ~p"/admin/emoji")

      live
      |> element("button[phx-click='delete_emoji'][phx-value-id='#{emoji.id}']")
      |> render_click()

      refute Repo.get(CustomEmoji, emoji.id)
    end

    test "shows this server's own and what it has seen elsewhere", %{conn: conn} do
      Repo.insert!(%CustomEmoji{
        shortcode: "partyparrot",
        domain: "elsewhere.example",
        image_url: "https://elsewhere.example/parrot.gif",
        static_url: "https://elsewhere.example/parrot.gif"
      })

      {:ok, _live, html} = live(conn, ~p"/admin/emoji")

      assert html =~ "blobcat"
      assert html =~ "elsewhere.example"
    end
  end

  describe "who may" do
    test "a moderator without the permission cannot open it", %{conn: _conn} do
      plain = log_in(build_conn(), staff(["manage_users"]))

      assert {:error, {:live_redirect, _}} = live(plain, ~p"/admin/emoji")
    end

    test "nor delete one by sending the event", %{conn: _conn} do
      {:ok, emoji} =
        Instance.put_custom_emoji(%{
          shortcode: "safe",
          image_url: "http://abuuba.test/x.png",
          static_url: "http://abuuba.test/x.png"
        })

      moderator = log_in(build_conn(), staff(["manage_users"]))
      {:ok, live, _html} = live(moderator, ~p"/admin/accounts")

      render_click(live, "delete_emoji", %{"id" => to_string(emoji.id)})

      assert Repo.get(CustomEmoji, emoji.id)
    end
  end
end
