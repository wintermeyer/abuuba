defmodule Abuuba.Security.UploadsTest do
  use AbuubaWeb.ConnCase, async: false

  alias Abuuba.Media.Storage
  alias Abuuba.Media.Upload

  # Uploads are the only bytes a stranger gets to put on this server's own
  # origin, which is where the session cookie lives. Everything here is about
  # keeping them from being read as anything but the file they claimed to be.

  describe "what may be uploaded at all" do
    test "not a type this server does not serve" do
      for type <- ["text/html", "application/javascript", "image/svg+xml", "application/pdf"] do
        assert {:error, _reason} =
                 Upload.store(%{path: "/dev/null", filename: "x", content_type: type}, 1),
               "#{type} was accepted"
      end
    end

    test "and not one with no type at all" do
      assert {:error, _reason} = Upload.store(%{path: "/dev/null", filename: "x"}, 1)
    end
  end

  describe "the name a file is stored under" do
    test "is this server's, not the one that was uploaded" do
      # A stranger's file name is a path, a script, or a very long string.
      # None of those should reach a disk.
      name = Storage.filename("upload.png")

      refute name =~ "/"
      refute name =~ ".."
      refute name =~ "upload"
      assert String.ends_with?(name, ".png")
    end

    test "and the extension follows the checked type, never the uploaded name" do
      # `payload.html` uploaded as `image/png` used to land as an HTML file and
      # be served back as `text/html` from this server's own origin. No header
      # fixes that: at that point the file really is a page.
      assert {:ok, %{file_file_name: file_name}} =
               Upload.store(png_upload("payload.html", "image/png"), 42)

      assert String.ends_with?(file_name, ".png")
      refute String.ends_with?(file_name, ".html")
    end

    test "for every type this server accepts" do
      # A type with no extension of its own would land as `.bin` and be
      # offered as a download rather than played, which is a bug rather than a
      # hole — but it is the same line of code, so it is checked here.
      for type <- Upload.accepted_types() do
        assert {:ok, %{file_file_name: name}} =
                 Upload.store(
                   png_upload("whatever.exe", type),
                   :erlang.unique_integer([:positive])
                 )

        refute String.ends_with?(name, ".exe"), "#{type} kept the uploaded extension"
        refute String.ends_with?(name, ".bin"), "#{type} has no extension of its own"
      end
    end
  end

  describe "how it is served back" do
    test "with the sniffing turned off", %{conn: conn} do
      # The stored type comes from what the upload claimed, so a file whose
      # bytes are HTML can be stored as an image. `nosniff` is what stops a
      # browser looking past that.
      {:ok, stored} = Upload.store(png_upload("x.png", "image/png"), 4242)

      key = Storage.key(4242, "original", stored.file_file_name)

      conn = get(conn, "/media/" <> key)

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "and with a policy that stops it doing anything even if it is read as a page", %{
      conn: conn
    } do
      {:ok, stored} = Upload.store(png_upload("y.png", "image/png"), 4243)

      key = Storage.key(4243, "original", stored.file_file_name)

      conn = get(conn, "/media/" <> key)

      policy = conn |> get_resp_header("content-security-policy") |> List.first()

      assert policy =~ "default-src 'none'"
      assert policy =~ "sandbox"
    end
  end

  # The smallest valid PNG, written to a real file so the pipeline has
  # something to read.
  defp png_upload(filename, content_type) do
    path = Path.join(System.tmp_dir!(), "abuuba-upload-#{System.unique_integer([:positive])}.bin")

    File.write!(
      path,
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
      )
    )

    on_exit(fn -> File.rm(path) end)

    %{path: path, filename: filename, content_type: content_type}
  end
end
