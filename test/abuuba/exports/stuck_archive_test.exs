defmodule Abuuba.Exports.StuckArchiveTest do
  @moduledoc """
  A build that was killed does not leave somebody's account on the disk.

  The archive is written first and the row is told about it second, so a job
  that dies in between -- a deploy, a node restart, an Oban timeout -- leaves a
  zip that no row points at. The sweep that releases stuck rows marked them
  failed and stopped there, and the sweep that deletes files works from
  `expires_at`, which a stuck row has never had.

  What was left behind is not a temporary file. It is every post, every
  message and every follow of one person, in one zip, readable by whoever ends
  up on that disk.
  """
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.Exports
  alias Abuuba.Exports.Export

  setup do
    dir = Path.join(System.tmp_dir!(), "abuuba-export-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:abuuba, :export_dir)
    Application.put_env(:abuuba, :export_dir, dir)

    on_exit(fn ->
      if previous, do: Application.put_env(:abuuba, :export_dir, previous)
      File.rm_rf(dir)
    end)

    %{dir: dir, account: account_fixture()}
  end

  defp stalled_export(account) do
    long_ago = DateTime.add(DateTime.utc_now(), -(Export.stall_hours() + 1) * 3600, :second)

    {:ok, export} =
      %Export{}
      |> Export.changeset(%{account_id: account.id, state: "running"})
      |> Repo.insert()

    # The row has not been told where the file is, which is the whole point:
    # the job died between writing it and saying so.
    {:ok, export} =
      export |> Ecto.Changeset.change(updated_at: long_ago) |> Repo.update()

    export
  end

  test "the archive goes when the row is released", %{dir: dir, account: account} do
    export = stalled_export(account)
    orphan = Path.join(dir, "#{export.id}-abcdef.zip")
    File.write!(orphan, "somebody's whole account")

    Exports.sweep()

    refute File.exists?(orphan), "a killed build left an archive nobody can reach"
    assert Repo.reload(export).state == "failed"
  end

  test "and a file belonging to somebody else's export is left alone", %{
    dir: dir,
    account: account
  } do
    # The control: the sweep removes what belongs to the rows it released, not
    # everything in the directory. Another account's archive is being built
    # while this one is swept.
    export = stalled_export(account)
    File.write!(Path.join(dir, "#{export.id}-abcdef.zip"), "stale")

    other = Path.join(dir, "999999-fedcba.zip")
    File.write!(other, "somebody else's, still being written")

    Exports.sweep()

    assert File.exists?(other), "the sweep took an archive that was not its to take"
  end
end
