defmodule Abuuba.Importer.BatchTest do
  use Abuuba.DataCase, async: false

  alias Abuuba.Importer.Batch
  alias Abuuba.Importer.Checkpoint
  alias Abuuba.Repo
  alias Abuuba.Roles.Role

  # More rows than fit in one page, because everything this module exists for
  # happens at the boundary between pages: the mark that says where to carry on
  # from, and the overlap a second run sees.
  @rows 620

  setup do
    Repo.query!("DROP TABLE IF EXISTS source_roles")
    Repo.query!("CREATE TABLE source_roles (id bigint PRIMARY KEY, name varchar NOT NULL)")

    Repo.query!(
      "INSERT INTO source_roles (id, name) SELECT i, 'role-' || i FROM generate_series(1, $1) AS i",
      [@rows]
    )

    on_exit(fn -> Repo.query!("DROP TABLE IF EXISTS source_roles") end)

    :ok
  end

  defp opts, do: [repo: Repo]

  defp copy(step \\ "test/roles") do
    Batch.copy(opts(), step, Role, "SELECT * FROM source_roles", fn row ->
      %{
        id: row["id"],
        name: row["name"],
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    end)
  end

  test "copies every row, not only the first page" do
    assert :ok = copy()

    assert Repo.aggregate(Role, :count) == @rows
  end

  test "leaves a mark saying how far it got, and says it finished" do
    :ok = copy()

    assert Checkpoint.last_id("test/roles") == @rows
    assert Checkpoint.rows("test/roles") == @rows
    assert Checkpoint.finished?("test/roles")
  end

  test "carries on from the mark rather than starting over" do
    # What an interrupted takeover does on its second attempt. Half the table
    # is already here; the rest has to arrive without the first half arriving
    # twice.
    :ok = Checkpoint.record("test/roles", 300, 300)

    assert :ok = copy()

    assert Repo.aggregate(Role, :count) == @rows - 300
    assert Repo.get(Role, 301)
    refute Repo.get(Role, 300)
  end

  test "a second run over the same rows writes nothing twice" do
    :ok = copy()
    :ok = Checkpoint.reset()

    assert :ok = copy()

    assert Repo.aggregate(Role, :count) == @rows
  end

  test "stops at the first row it cannot map" do
    # And stops there: mapping the rest of the page to find out how many other
    # rows are bad is work nobody asked for, on an import that is about to
    # stop anyway.
    assert {:error, :nope} =
             Batch.copy(opts(), "test/roles", Role, "SELECT * FROM source_roles", fn row ->
               if row["id"] == 5, do: {:error, :nope}, else: %{id: row["id"], name: row["name"]}
             end)

    assert Repo.aggregate(Role, :count) == 0
    refute Checkpoint.finished?("test/roles")
  end

  test "the mark and the rows it accounts for move together" do
    # Otherwise an import killed between the two resumes from before rows it
    # has already written, and every part whose target has no natural key to
    # conflict on doubles them.
    :ok = copy()

    assert Checkpoint.last_id("test/roles") == @rows
    assert Repo.aggregate(Role, :count) == @rows

    # A builder that fails partway leaves neither the rows of its page nor a
    # mark claiming they were written.
    :ok = Checkpoint.reset()
    Repo.delete_all(Role)

    assert {:error, :nope} =
             Batch.copy(opts(), "test/roles", Role, "SELECT * FROM source_roles", fn row ->
               if row["id"] > 500,
                 do: {:error, :nope},
                 else: %{
                   id: row["id"],
                   name: row["name"],
                   inserted_at: DateTime.utc_now(),
                   updated_at: DateTime.utc_now()
                 }
             end)

    assert Checkpoint.last_id("test/roles") == 500
    assert Repo.aggregate(Role, :count) == 500
  end

  test "names a checkpoint after the step and the part" do
    assert Batch.step_name(:identity, :accounts) == "identity/accounts"
  end
end
