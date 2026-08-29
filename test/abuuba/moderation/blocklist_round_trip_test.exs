defmodule Abuuba.Moderation.BlocklistRoundTripTest do
  @moduledoc """
  A blocklist this server wrote can be read back by this server.

  Two importers existed. The one the admin screen calls reads three columns --
  domain, severity, public comment -- and the format everybody shares, which is
  also the one `export_csv/0` writes, puts `reject_media` third. So a list
  exported here and imported here came back with "true" as its public comment
  and the media, report and obfuscation decisions gone.

  The other importer reads the format correctly, is tested, is what the admin
  documentation names, and nothing called it.
  """
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Moderation.Domains

  test "the flags survive going out and coming back" do
    moderator = account_fixture()

    {:ok, _} =
      Domains.block(moderator, %{
        "domain" => "noisy.example",
        "severity" => "silence",
        "reject_media" => true,
        "reject_reports" => true,
        "public_comment" => "spam",
        "obfuscate" => true
      })

    csv = Domains.export_csv()

    # The same file arriving at a server that has not decided about this
    # domain yet, which is what a shared list is for.
    :ok = Domains.unblock(moderator, Domains.block_for("noisy.example"))
    assert Domains.block_for("noisy.example") == nil

    {:ok, %{created: 1}} = Domains.import_csv(moderator, csv)

    block = Domains.block_for("noisy.example")

    assert block.severity == "silence"
    assert block.public_comment == "spam", "the comment was read from the wrong column"
    assert block.reject_media
    assert block.reject_reports
    assert block.obfuscate
  end

  test "and the screen an admin actually uses does the same" do
    # The one that matters: the round trip above is worth nothing if the button
    # in the admin area calls something else, which is exactly what it used to
    # do. Kept as its own test so that pointing the screen somewhere new fails
    # here rather than in production.
    moderator = account_fixture()

    {:ok, _} =
      Domains.block(moderator, %{
        "domain" => "loud.example",
        "severity" => "suspend",
        "reject_media" => true,
        "reject_reports" => true,
        "public_comment" => "shared list",
        "obfuscate" => true
      })

    # Both ends through the calls the admin screens actually make: the file the
    # download button sends, read by the button that imports one.
    csv = Domains.export_csv()
    :ok = Domains.unblock(moderator, Domains.block_for("loud.example"))

    {:ok, %{created: 1}} = Domains.import_csv(moderator, csv)

    block = Domains.block_for("loud.example")

    assert block.public_comment == "shared list",
           "the admin screen's importer read the comment from the wrong column"

    assert block.reject_media
    assert block.reject_reports
    assert block.obfuscate
  end
end
