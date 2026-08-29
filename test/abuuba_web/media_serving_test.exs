defmodule AbuubaWeb.MediaServingTest do
  use AbuubaWeb.ConnCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Media
  alias Abuuba.Media.Upload

  setup do
    %{author: account_fixture()}
  end

  defp upload(author, name \\ "photo.png", type \\ "image/png") do
    path = Path.join(System.tmp_dir!(), "serving-#{System.unique_integer([:positive])}")
    File.write!(path, "a real file, whatever it claims to be")

    {:ok, attachment} = Media.upload(author, %{path: path, filename: name, content_type: type})

    attachment
  end

  test "the URL an attachment hands out is one this server answers", %{
    conn: conn,
    author: author
  } do
    # Every client and every other server fetches the picture at this address.
    # A stored file nobody can reach is an attachment that is not there.
    attachment = upload(author)

    conn = get(conn, URI.parse(Upload.url(attachment)).path)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") != []
  end

  test "a thumbnail is reachable too", %{conn: conn, author: author} do
    video = upload(author, "clip.mp4", "video/mp4")

    path = Path.join(System.tmp_dir!(), "thumb-#{System.unique_integer([:positive])}")
    File.write!(path, "a picture")

    {:ok, updated} =
      Media.put_thumbnail(video, %{path: path, filename: "t.png", content_type: "image/png"})

    conn = get(conn, URI.parse(Upload.thumbnail_url(updated)).path)

    assert conn.status == 200
  end

  test "will not serve its way out of the media directory", %{conn: conn} do
    # The name in the path comes from a URL, so it is a stranger's to write.
    # Refused as a bad request rather than answered with whatever is up there.
    assert_error_sent 400, fn -> get(conn, "/media/../../../etc/passwd") end
  end

  test "a name nobody stored is a plain miss", %{conn: conn} do
    conn = get(conn, "/media/999999999999.png")

    assert conn.status == 404
  end
end
