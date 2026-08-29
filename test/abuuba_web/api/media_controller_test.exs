defmodule AbuubaWeb.API.MediaControllerTest do
  use AbuubaWeb.ConnCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Media
  alias Abuuba.OAuth

  # A real one-pixel PNG. The pipeline reads what it is handed, so a file with
  # the right magic bytes and random noise behind them is a file that fails
  # processing, which is a different test than this one.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  @not_really_a_png <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(64)

  setup %{conn: conn} do
    account = account_fixture()

    user =
      user_fixture(%{account_id: account.id, approved: true, confirmed_at: DateTime.utc_now()})

    {:ok, application, _secret} =
      OAuth.create_application(%{name: "test", redirect_uris: "urn:ietf:wg:oauth:2.0:oob"})

    {:ok, _token, raw} = OAuth.issue_token(application, user, ["read", "write"])

    root = Path.join(System.tmp_dir!(), "abuuba-media-test-#{System.unique_integer([:positive])}")
    Application.put_env(:abuuba, :media_root, root)
    on_exit(fn -> File.rm_rf(root) end)

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> raw),
      anon: build_conn(),
      account: account,
      application: application
    }
  end

  defp upload_file(content \\ @png, opts \\ []) do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    # A test that uploads forty files should not leave forty behind.
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{
      path: path,
      filename: Keyword.get(opts, :filename, "picture.png"),
      content_type: Keyword.get(opts, :content_type, "image/png")
    }
  end

  describe "uploading" do
    test "something that is not the picture it claims to be is recorded as failed", %{conn: conn} do
      # The magic bytes are a claim, not a picture. Reading it is the only way
      # to find out, and the answer belongs in the attachment's state rather
      # than in a crashed worker.
      body =
        json_response(
          post(conn, "/api/v2/media", %{"file" => upload_file(@not_really_a_png)}),
          202
        )

      assert Abuuba.Media.get_attachment(String.to_integer(body["id"])).processing == :failed
    end

    test "v2 answers 202 with the attachment", %{conn: conn} do
      conn = post(conn, "/api/v2/media", %{"file" => upload_file()})

      body = json_response(conn, 202)

      assert body["type"] == "image"
      assert is_binary(body["id"])
    end

    test "a small image is finished inside the request", %{conn: conn} do
      # Making somebody poll for an ordinary photo turns one post into two
      # round trips for no reason.
      body = json_response(post(conn, "/api/v2/media", %{"file" => upload_file()}), 202)

      assert body["url"]
    end

    test "v1 answers 200 for something it could finish", %{conn: conn} do
      assert json_response(post(conn, "/api/v1/media", %{"file" => upload_file()}), 200)["url"]
    end

    test "refuses a content type nobody should serve", %{conn: conn} do
      # An allow list: what is safe to serve is small and known, and what is
      # not grows with every format anybody invents.
      file = upload_file("<script>", filename: "x.html", content_type: "text/html")

      assert json_response(post(conn, "/api/v2/media", %{"file" => file}), 422)["error"] =~
               "content type"
    end

    test "refuses a request carrying no file", %{conn: conn} do
      assert json_response(post(conn, "/api/v2/media", %{}), 422)["error"] =~ "file is required"
    end

    test "needs a token", %{anon: anon} do
      assert json_response(post(anon, "/api/v2/media", %{"file" => upload_file()}), 422)["error"]
    end

    test "stores under a name of ours, never the one uploaded", %{conn: conn} do
      # A filename arrives from a stranger and can carry `..`, a null byte, or
      # somebody else's name. The stored name is random and only the extension
      # survives.
      file = upload_file(@png, filename: "../../etc/passwd.png")

      body = json_response(post(conn, "/api/v2/media", %{"file" => file}), 202)

      # The id is in the path as three-digit groups, which is the reference
      # implementation's layout and what lets a media tree be copied across.
      assert body["url"] =~ "media_attachments/files/"
      refute body["url"] =~ ".."
      refute body["url"] =~ "passwd"
    end
  end

  describe "polling" do
    test "206 while it is not ready, 200 once it is", %{conn: conn, account: account} do
      # A client that reads 200 attaches it, and the post federates with a URL
      # that serves nothing.
      {:ok, attachment} =
        Media.create_attachment(%{account_id: account.id, type: :video, processing: :queued})

      conn_206 = get(conn, "/api/v1/media/#{attachment.id}")

      assert conn_206.status == 206
      refute json_response(conn_206, 206)["url"]

      {:ok, _} = Media.set_processing(attachment, :complete)

      assert json_response(get(conn, "/api/v1/media/#{attachment.id}"), 200)
    end

    test "somebody else's upload is not there", %{conn: conn} do
      {:ok, theirs} = Media.create_attachment(%{account_id: account_fixture().id, type: :image})

      assert json_response(get(conn, "/api/v1/media/#{theirs.id}"), 404)["error"]
    end
  end

  describe "changing an upload" do
    setup %{conn: conn} do
      body = json_response(post(conn, "/api/v2/media", %{"file" => upload_file()}), 202)

      %{id: body["id"]}
    end

    test "the description", %{conn: conn, id: id} do
      conn = put(conn, "/api/v1/media/#{id}", %{"description" => "a cat"})

      assert json_response(conn, 200)["description"] == "a cat"
    end

    test "the focal point", %{conn: conn, id: id} do
      # Where the interesting part of a picture is, so a crop keeps a face
      # rather than an elbow.
      conn = put(conn, "/api/v1/media/#{id}", %{"focus" => "0.5,-0.25"})

      assert %{"focus" => %{"x" => 0.5, "y" => -0.25}} = json_response(conn, 200)["meta"]
    end

    test "a focal point outside the picture is clamped", %{conn: conn, id: id} do
      conn = put(conn, "/api/v1/media/#{id}", %{"focus" => "9,-9"})

      assert %{"focus" => %{"x" => 1.0, "y" => -1.0}} = json_response(conn, 200)["meta"]
    end

    test "nonsense where a focal point belongs does not raise", %{conn: conn, id: id} do
      conn = put(conn, "/api/v1/media/#{id}", %{"focus" => "banana"})

      assert json_response(conn, 200)["meta"]["focus"] == %{"x" => 0.0, "y" => 0.0}
    end
  end

  describe "the upload budget" do
    test "is narrower than the general API one", %{conn: conn} do
      # Thirty uploads in half an hour, per account. Processing a file costs
      # this server real work, so it is bounded separately from the general
      # 1,500-per-five-minutes budget the rest of the API shares.
      results =
        for _ <- 1..40 do
          post(conn, "/api/v2/media", %{"file" => upload_file()}).status
        end

      assert 429 in results

      # The positive control: the first ones were accepted, so the 429 is a
      # budget running out rather than uploading being broken.
      assert 202 in results
    end
  end

  describe "deleting an upload" do
    test "forgets one nobody posted", %{conn: conn} do
      body = json_response(post(conn, "/api/v2/media", %{"file" => upload_file()}), 202)

      assert delete(conn, "/api/v1/media/#{body["id"]}").status == 204
      assert json_response(get(conn, "/api/v1/media/#{body["id"]}"), 404)["error"]
    end

    test "refuses one already in a post", %{conn: conn, account: account} do
      # A picture in a post is part of the post, and removing it here would
      # leave the post pointing at nothing.
      status = Abuuba.StatusesFixtures.status_fixture(%{account_id: account.id})

      {:ok, attachment} =
        Media.create_attachment(%{account_id: account.id, type: :image, status_id: status.id})

      # An attached upload is not reachable through this endpoint at all, which
      # is the same refusal one step earlier.
      assert json_response(delete(conn, "/api/v1/media/#{attachment.id}"), 404)["error"]
    end
  end

  describe "a post carrying pictures" do
    test "renders them", %{conn: conn, account: account} do
      status = Abuuba.StatusesFixtures.status_fixture(%{account_id: account.id})

      {:ok, _} =
        Media.create_attachment(%{
          account_id: account.id,
          status_id: status.id,
          type: :image,
          processing: :complete,
          file_file_name: "1.png"
        })

      body = json_response(get(conn, "/api/v1/statuses/#{status.id}"), 200)

      assert [%{"type" => "image"}] = body["media_attachments"]
    end
  end
end
