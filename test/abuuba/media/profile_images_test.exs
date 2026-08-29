defmodule Abuuba.Media.ProfileImagesTest do
  @moduledoc """
  Avatars and headers.

  They did not exist: the account entity returned an empty string for all four
  fields, `update_credentials` took neither picture, and nothing stored one. So
  every client rendered every abuuba account as a blank square, permanently.
  """

  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Accounts
  alias Abuuba.Federation.Actor
  alias Abuuba.Media.ProfileImages
  alias Abuuba.Media.Storage
  alias AbuubaWeb.API.Entities

  @fixture_dir Path.join(System.tmp_dir!(), "abuuba-profile-images-test")

  setup do
    File.mkdir_p!(@fixture_dir)
    on_exit(fn -> File.rm_rf(@fixture_dir) end)

    %{account: account_fixture(%{username: "alice"})}
  end

  # A real picture, because the whole path goes through an image library and a
  # handful of bytes pretending to be a PNG would not survive it.
  # Derived from the URL rather than rebuilt, so the test cannot pass while it
  # and the storage layer disagree about where a file lives.
  defp stored_key(account, kind) do
    account
    |> ProfileImages.url(kind)
    |> String.split("/media/", parts: 2)
    |> List.last()
  end

  defp picture(name, opts \\ []) do
    path = Path.join(@fixture_dir, name)
    width = Keyword.get(opts, :width, 800)
    height = Keyword.get(opts, :height, 800)

    {_output, 0} =
      System.cmd("ffmpeg", [
        "-y",
        "-f",
        "lavfi",
        "-i",
        "color=c=blue:s=#{width}x#{height}",
        "-frames:v",
        "1",
        path
      ])

    %Plug.Upload{path: path, filename: name, content_type: MIME.from_path(name)}
  end

  describe "storing one" do
    test "an uploaded avatar comes back as a URL", %{account: account} do
      assert {:ok, attrs} = ProfileImages.store(account, :avatar, picture("avatar.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      url = ProfileImages.url(account, :avatar)

      assert url =~ "/accounts/avatars/"
      refute url == ""
    end

    test "and a header does too", %{account: account} do
      assert {:ok, attrs} = ProfileImages.store(account, :header, picture("header.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      assert ProfileImages.url(account, :header) =~ "/accounts/headers/"
    end

    test "a still picture is its own static copy", %{account: account} do
      # Writing a second identical file would double the disk for nothing.
      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("avatar.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      assert ProfileImages.url(account, :avatar, :static) ==
               ProfileImages.url(account, :avatar)
    end

    test "something that is not a picture is refused", %{account: account} do
      path = Path.join(@fixture_dir, "note.txt")
      File.write!(path, "not a picture")

      upload = %Plug.Upload{path: path, filename: "note.txt", content_type: "text/plain"}

      assert {:error, :unsupported} = ProfileImages.store(account, :avatar, upload)
    end

    test "an account with no picture has an empty string, not a null", %{account: account} do
      # Every client reads these as strings, and a null is what makes one of
      # them render the word "null" in an image tag.
      assert ProfileImages.url(account, :avatar) == ""
      assert ProfileImages.url(account, :header, :static) == ""
    end
  end

  describe "replacing one" do
    test "takes the file it replaced with it", %{account: account} do
      # The storage key carries the filename, so a differently named upload
      # writes beside the old file rather than over it -- and nothing reclaims
      # that, because the orphan sweep looks for attachment rows with no post
      # and a profile picture has never been one. Every change of picture was
      # a permanent file.
      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("first.png"))
      {:ok, account} = Accounts.update_account(account, attrs)
      first = stored_key(account, :avatar)

      assert Storage.exists?(first)

      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("second.png"))
      {:ok, account} = Accounts.update_account(account, attrs)
      second = stored_key(account, :avatar)

      # The control: the new one is there, so the refute below is about the old
      # file going rather than about neither being written.
      assert second != first
      assert Storage.exists?(second)
      refute Storage.exists?(first)
    end

    test "and leaves the other picture alone", %{account: account} do
      {:ok, attrs} = ProfileImages.store(account, :header, picture("banner.png"))
      {:ok, account} = Accounts.update_account(account, attrs)
      header = stored_key(account, :header)

      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("face.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("face-two.png"))
      {:ok, _account} = Accounts.update_account(account, attrs)

      assert Storage.exists?(header)
    end

    test "and keeps a picture uploaded under the same name", %{account: account} do
      # Same key, so the new file has already been written over the old one and
      # there is nothing to delete. Deleting it here would delete what was just
      # stored.
      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("same.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("same.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      assert Storage.exists?(stored_key(account, :avatar))
    end
  end

  describe "removing one" do
    test "clears the columns", %{account: account} do
      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("avatar.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      {:ok, account} = Accounts.update_account(account, ProfileImages.remove(account, :avatar))

      assert ProfileImages.url(account, :avatar) == ""
    end
  end

  describe "the account entity" do
    test "carries all four fields", %{account: account} do
      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("avatar.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      entity = Entities.account(account, account)

      assert entity["avatar"] =~ "/accounts/avatars/"
      assert entity["avatar_static"] =~ "/accounts/avatars/"
      # No header was uploaded, so those two are empty rather than absent.
      assert entity["header"] == ""
      assert entity["header_static"] == ""
    end
  end

  describe "a remote account" do
    test "keeps the addresses its own server published" do
      remote =
        remote_account_fixture(%{
          domain: "peer.example",
          uri: "https://peer.example/users/bob",
          avatar_remote_url: "https://peer.example/avatars/bob.png",
          header_remote_url: "https://peer.example/headers/bob.png"
        })

      assert ProfileImages.url(remote, :avatar) == "https://peer.example/avatars/bob.png"
      assert ProfileImages.url(remote, :header) == "https://peer.example/headers/bob.png"
    end

    test "reads them out of an actor document in either shape" do
      attrs =
        ProfileImages.remote_attrs(%{
          "icon" => %{"type" => "Image", "url" => "https://peer.example/a.png"},
          "image" => "https://peer.example/h.png"
        })

      assert attrs.avatar_remote_url == "https://peer.example/a.png"
      assert attrs.header_remote_url == "https://peer.example/h.png"
    end

    test "and an actor with no pictures gets nulls rather than a crash" do
      assert ProfileImages.remote_attrs(%{}) == %{
               avatar_remote_url: nil,
               header_remote_url: nil
             }
    end
  end

  describe "the actor document" do
    test "publishes the pictures, so peers can show them", %{account: account} do
      {:ok, attrs} = ProfileImages.store(account, :avatar, picture("avatar.png"))
      {:ok, account} = Accounts.update_account(account, attrs)

      document = Actor.render(account)

      assert %{"type" => "Image", "url" => url} = document["icon"]
      assert url =~ "/accounts/avatars/"
    end

    test "and leaves them out entirely when there are none", %{account: account} do
      document = Actor.render(account)

      refute Map.has_key?(document, "icon")
      refute Map.has_key?(document, "image")
    end
  end
end
