defmodule Abuuba.ActionLimitsTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures

  alias Abuuba.ActionLimits
  alias Abuuba.RateLimit

  setup do
    RateLimit.reset()
    :ok
  end

  describe "how much one account may do" do
    test "an ordinary amount of posting is fine" do
      account = account_fixture()

      for _ <- 1..50, do: assert(ActionLimits.take(account, :statuses) == :ok)
    end

    test "three hundred posts in three hours is a spam run" do
      account = account_fixture()

      for _ <- 1..300, do: ActionLimits.take(account, :statuses)

      assert ActionLimits.take(account, :statuses) == {:error, :rate_limited}
    end

    test "four hundred follows in a day is somebody building a list" do
      # Follow everybody, unfollow whoever does not follow back. The limit is
      # what makes that not worth scripting.
      account = account_fixture()

      for _ <- 1..400, do: ActionLimits.take(account, :follows)

      assert ActionLimits.take(account, :follows) == {:error, :rate_limited}
    end

    test "one account's budget is not another's" do
      one = account_fixture()
      other = account_fixture()

      for _ <- 1..301, do: ActionLimits.take(one, :statuses)

      assert ActionLimits.take(one, :statuses) == {:error, :rate_limited}
      assert ActionLimits.take(other, :statuses) == :ok
    end

    test "the families do not share a budget" do
      account = account_fixture()

      for _ <- 1..301, do: ActionLimits.take(account, :statuses)

      assert ActionLimits.take(account, :follows) == :ok
    end

    test "an account id works as well as an account" do
      # Callers that already loaded the id should not have to load the row.
      account = account_fixture()

      assert ActionLimits.take(account.id, :reports) == :ok
    end

    test "a family nobody defined is a mistake in our code, not a refusal" do
      # Returning `:ok` for a typo would silently remove a limit.
      assert_raise KeyError, fn -> ActionLimits.take(account_fixture(), :nonsense) end
    end
  end

  describe "the limits themselves" do
    test "match the reference implementation, so an acceptable account stays one" do
      assert ActionLimits.family(:statuses) == {300, 3 * 60 * 60 * 1000}
      assert ActionLimits.family(:follows) == {400, 24 * 60 * 60 * 1000}
      assert ActionLimits.family(:reports) == {400, 24 * 60 * 60 * 1000}
    end
  end
end
