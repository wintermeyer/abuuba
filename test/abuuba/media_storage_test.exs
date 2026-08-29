defmodule Abuuba.MediaStorageTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Media
  alias Abuuba.Media.Storage
  alias Abuuba.Media.Storage.Local
  alias Abuuba.Media.Storage.S3
  alias Abuuba.Media.VacuumWorker
  alias Abuuba.Repo

  setup do
    root =
      Path.join(System.tmp_dir!(), "abuuba-storage-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.get_env(:abuuba, :media_root)
    Application.put_env(:abuuba, :media_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if previous, do: Application.put_env(:abuuba, :media_root, previous)
      Application.delete_env(:abuuba, :media_alias_host)
      Application.delete_env(:abuuba, Abuuba.Media.Storage.S3)
      Application.delete_env(:abuuba, :media_storage)
      Abuuba.Settings.put("content_retention_days", 0)
    end)

    %{root: root, account: account_fixture()}
  end

  defp source_file(root, content \\ "some bytes") do
    path = Path.join(root, "source-#{System.unique_integer([:positive])}.bin")
    File.write!(path, content)

    path
  end

  describe "the path layout" do
    test "is the reference implementation's, because the importer copies trees" do
      # A directory tree that is byte-for-byte what Mastodon wrote can be moved
      # across without rewriting a single path.
      key = Storage.key(3_815_271, "original", "abcdef.jpg")

      assert key == "media_attachments/files/003/815/271/original/abcdef.jpg"
    end

    test "pads short ids to nine digits" do
      assert Storage.key(1, "original", "a.jpg") ==
               "media_attachments/files/000/000/001/original/a.jpg"
    end

    test "and keeps going for long ones" do
      # A snowflake is eighteen digits, which is six groups rather than three.
      key = Storage.key(117_046_773_101_850_564, "original", "a.jpg")

      assert key == "media_attachments/files/117/046/773/101/850/564/original/a.jpg"
    end

    test "styles are their own directory" do
      assert Storage.key(1, "small", "a.jpg") =~ "/small/a.jpg"
    end

    test "somebody else's media goes under cache" do
      # Remote media is a copy of something that still exists elsewhere, and the
      # prefix is what makes a whole tree of it safe to delete.
      key = Storage.key(1, "original", "a.jpg", remote: true)

      assert key == "cache/media_attachments/files/000/000/001/original/a.jpg"
    end
  end

  describe "names on disk" do
    test "are random rather than what was uploaded" do
      # A filename arrives from a stranger. Keeping it hands them a say in the
      # URL, and two people uploading holiday.jpg would collide.
      first = Storage.filename("holiday.jpg")
      second = Storage.filename("holiday.jpg")

      refute first == "holiday.jpg"
      refute first == second
      assert Path.extname(first) == ".jpg"
    end

    test "keep an extension a browser can act on" do
      assert Path.extname(Storage.filename("clip.MP4")) == ".mp4"
    end

    test "refuse anything that is not a plain extension" do
      # `..` in an extension is a path, and a path is how a file lands
      # somewhere it was never meant to.
      assert Path.extname(Storage.filename("evil.jpg/../../passwd")) in ["", ".bin"]
    end
  end

  describe "the local adapter" do
    test "writes, reads back and deletes", %{root: root} do
      key = "media_attachments/files/000/000/001/original/a.bin"
      source = source_file(root, "hello")

      assert :ok = Local.put(key, source, [])
      assert File.read!(Path.join(root, key)) == "hello"
      assert Local.exists?(key)

      assert :ok = Local.delete(key)
      refute Local.exists?(key)
    end

    test "makes the directories it needs", %{root: root} do
      key = "media_attachments/files/999/888/777/original/a.bin"

      assert :ok = Local.put(key, source_file(root), [])
      assert File.exists?(Path.join(root, key))
    end

    test "refuses a key that climbs out of the root", %{root: root} do
      # The key is derived from an id here, but a storage backend that trusts
      # its caller is one bad caller away from writing anywhere on the disk.
      assert {:error, :bad_key} = Local.put("../escaped.bin", source_file(root), [])
      refute File.exists?(Path.join(Path.dirname(root), "escaped.bin"))
    end

    test "deleting something that is not there is not an error" do
      # The sweeper and somebody changing their mind both arrive here.
      assert :ok = Local.delete("media_attachments/files/000/000/002/original/gone.bin")
    end

    test "serves from the server's own address" do
      key = "media_attachments/files/000/000/001/original/a.jpg"

      assert Local.url(key) =~ "/media/#{key}"
    end

    test "and escapes a key that came from somewhere else" do
      # Same reason as the bucket: an imported tree carries names this server
      # did not generate, and a space in one of them is not an address.
      assert Local.url("a b/c+d.jpg") =~ "/media/a%20b/c%2Bd.jpg"
    end
  end

  describe "a CDN in front" do
    test "changes where clients are sent" do
      Application.put_env(:abuuba, :media_alias_host, "https://cdn.example")

      key = "media_attachments/files/000/000/001/original/a.jpg"

      assert Storage.url(key) == "https://cdn.example/media/#{key}"
    end

    test "and is off by default" do
      assert Storage.url("media_attachments/files/000/000/001/original/a.jpg") =~ "/media/"
    end
  end

  describe "the S3 adapter" do
    setup do
      Application.put_env(:abuuba, Abuuba.Media.Storage.S3,
        bucket: "abuuba-test",
        region: "eu-central-1",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      )

      :ok
    end

    test "puts an object with an immutable cache header", %{root: root} do
      # Every object is named after an id that is never reused, so a cached
      # copy can never be the wrong picture.
      me = self()

      send_request = fn request ->
        send(me, {:request, request})

        {:ok, %{status: 200, body: ""}}
      end

      key = "media_attachments/files/000/000/001/original/a.jpg"

      assert :ok = S3.put(key, source_file(root, "bytes"), transport: send_request)

      assert_receive {:request, request}
      assert request.method == :put
      assert request.url =~ "abuuba-test"
      assert request.url =~ key
      assert request.headers["cache-control"] == "public, max-age=31536000, immutable"
      assert request.headers["authorization"] =~ "AWS4-HMAC-SHA256"
    end

    test "signs differently for a different object", %{root: root} do
      signatures =
        for key <- ["a/one.jpg", "a/two.jpg"] do
          me = self()

          transport = fn request ->
            send(me, {:signature, request.headers["authorization"]})

            {:ok, %{status: 200, body: ""}}
          end

          :ok = S3.put(key, source_file(root, "bytes"), transport: transport)

          receive do
            {:signature, signature} -> signature
          end
        end

      assert length(Enum.uniq(signatures)) == 2
    end

    test "a key that needs escaping is escaped in the address" do
      # The importer copies the tree of an existing Mastodon instance, so a key
      # is not always one this server generated. An address with a space in it
      # is not an address, and Req refuses to send it at all.
      assert S3.url("a b/c+d.jpg") =~ "a%20b/c%2Bd.jpg"
    end

    test "signs the path it actually asks for, bucket included", %{root: root} do
      # Against anything that is not AWS -- MinIO, Garage, Ceph, and every
      # other bucket somebody self-hosts -- the endpoint is a plain host and
      # the bucket is the first segment of the path. The signature has to
      # cover that segment, because the server signs what it received.
      #
      # Two buckets on one endpoint is what makes this visible without a live
      # server: the host header is identical, so the only difference between
      # the two requests is the bucket in the path. Signing the key alone
      # produced one signature for both, and a real bucket answered 403.
      key = "media_attachments/files/000/000/001/original/a.jpg"
      now = ~U[2026-08-13 10:00:00Z]

      signatures =
        for bucket <- ["abuuba-one", "abuuba-two"] do
          Application.put_env(:abuuba, Abuuba.Media.Storage.S3,
            bucket: bucket,
            region: "eu-central-1",
            endpoint: "http://localhost:9000",
            access_key_id: "AKIAIOSFODNN7EXAMPLE",
            secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
          )

          me = self()

          transport = fn request ->
            send(me, {:signed, request.headers["authorization"], request.url})

            {:ok, %{status: 200, body: ""}}
          end

          :ok = S3.put(key, source_file(root, "bytes"), transport: transport, now: now)

          assert_receive {:signed, signature, url}
          assert url =~ bucket, "the bucket is in the path this request asks for"
          assert is_binary(signature)

          signature
        end

      assert length(Enum.uniq(signatures)) == 2,
             "the same signature for two buckets: the path signed is not the path requested"
    end

    test "a refusal from the service is a refusal here", %{root: root} do
      # Silently carrying on would leave an attachment pointing at an object
      # that was never written.
      transport = fn _request -> {:ok, %{status: 403, body: "no"}} end

      assert {:error, _reason} = S3.put("a/one.jpg", source_file(root), transport: transport)
    end

    test "serves from the bucket unless an alias says otherwise" do
      key = "media_attachments/files/000/000/001/original/a.jpg"

      assert S3.url(key) =~ "abuuba-test"

      Application.put_env(:abuuba, :media_alias_host, "https://cdn.example")

      assert S3.url(key) == "https://cdn.example/#{key}"
    end
  end

  describe "which backend is in force" do
    test "is local unless the server says otherwise" do
      assert Storage.adapter() == Local
    end

    test "and can be switched" do
      Application.put_env(:abuuba, :media_storage, S3)

      assert Storage.adapter() == S3
    end
  end

  describe "the remote media cache" do
    setup %{account: account} do
      %{account: account}
    end

    test "holds copies of somebody else's files", %{root: root, account: account} do
      remote = remote_attachment(account, root)

      assert Storage.remote?(remote)
      assert Media.cached_bytes() > 0
    end

    test "old copies are dropped and can be fetched again", %{root: root, account: account} do
      # Remote media is re-fetchable from where it came from, which is what
      # makes dropping it safe and a local file's deletion permanent.
      remote = remote_attachment(account, root)
      age(remote, 40)

      assert {:ok, 1} = Media.vacuum_remote_media(30)

      reloaded = Repo.reload(remote)

      assert reloaded.file_file_name == nil
      assert reloaded.remote_url != ""
    end

    test "recent ones are left alone", %{root: root, account: account} do
      remote = remote_attachment(account, root)

      assert {:ok, 0} = Media.vacuum_remote_media(30)
      assert Repo.reload(remote).file_file_name
    end

    test "our own files are never dropped", %{root: root, account: account} do
      # A local file has nowhere to be fetched back from, so dropping it is
      # deleting somebody's picture.
      local = local_attachment(account, root)
      age(local, 400)

      assert {:ok, 0} = Media.vacuum_remote_media(30)
      assert Repo.reload(local).file_file_name
    end

    test "a retention of zero keeps everything", %{root: root, account: account} do
      remote = remote_attachment(account, root)
      age(remote, 400)

      assert {:ok, 0} = Media.vacuum_remote_media(0)
      assert Repo.reload(remote).file_file_name
    end
  end

  describe "the vacuum worker" do
    test "does nothing until an admin sets a retention", %{root: root, account: account} do
      # Somebody who has not chosen a number has not chosen to delete anything.
      remote = remote_attachment(account, root)
      age(remote, 400)

      assert :ok = VacuumWorker.perform(%Oban.Job{args: %{}})
      assert Repo.reload(remote).file_file_name
    end

    test "and drops old copies once one is set", %{root: root, account: account} do
      remote = remote_attachment(account, root)
      age(remote, 400)
      :ok = Abuuba.Settings.put("content_retention_days", 30)

      assert :ok = VacuumWorker.perform(%Oban.Job{args: %{}})
      refute Repo.reload(remote).file_file_name
    end
  end

  defp remote_attachment(account, root) do
    {:ok, attachment} =
      Media.create_attachment(%{
        account_id: account.id,
        type: :image,
        processing: :complete,
        remote_url: "https://other.example/media/a.jpg",
        file_file_size: 10
      })

    store_file(attachment, root)
  end

  defp local_attachment(account, root) do
    {:ok, attachment} =
      Media.create_attachment(%{
        account_id: account.id,
        type: :image,
        processing: :complete,
        file_file_size: 10
      })

    store_file(attachment, root)
  end

  defp store_file(attachment, root) do
    name = Storage.filename("a.jpg")
    key = Storage.key(attachment.id, "original", name, remote: Storage.remote?(attachment))

    :ok = Storage.put(key, source_file(root, "ten bytes!"), [])

    {:ok, stored} =
      attachment
      |> Ecto.Changeset.change(file_file_name: name)
      |> Repo.update()

    stored
  end

  defp age(attachment, days) do
    when_written = DateTime.add(DateTime.utc_now(), -days, :day)

    {:ok, aged} =
      attachment |> Ecto.Changeset.change(inserted_at: when_written) |> Repo.update()

    aged
  end
end
