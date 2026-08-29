defmodule Abuuba.Interop.SuiteTest do
  use ExUnit.Case, async: true

  alias Abuuba.Interop.Report
  alias Abuuba.Interop.Suite

  describe "the list of scenarios" do
    test "covers everything two servers have to agree about" do
      # The point of the list being a list: a scenario that stops being run
      # should be a missing row in a report rather than a thing nobody
      # remembered. This is the check that nothing quietly leaves it.
      ids = Enum.map(Suite.scenarios(), & &1.id)

      for expected <- [
            :follow_out,
            :follow_in,
            :follow_locked,
            :post_propagation,
            :reply,
            :boost,
            :edit,
            :delete,
            :media,
            :content_warning,
            :poll,
            :quote,
            :move,
            :domain_block,
            :signatures,
            :authorized_fetch
          ] do
        assert expected in ids, "the suite no longer runs #{expected}"
      end
    end

    test "says what each one proves, in a sentence somebody can read" do
      for scenario <- Suite.scenarios() do
        assert is_binary(scenario.proves) and scenario.proves != "",
               "#{scenario.id} does not say what it proves"
      end
    end

    test "runs a follow before it expects a post to arrive" do
      # Ordered rather than sorted: a report that fails everything because step
      # one failed is easier to read than sixteen unrelated failures.
      ids = Enum.map(Suite.scenarios(), & &1.id)

      assert Enum.find_index(ids, &(&1 == :follow_out)) <
               Enum.find_index(ids, &(&1 == :post_propagation))
    end

    test "and every scenario has a shell script to run it" do
      # A scenario in the list with nothing behind it is worse than one that is
      # missing: the report would show it as not run and nobody would look.
      for scenario <- Suite.scenarios() do
        path = Path.join(["test", "interop", "scenarios", "#{scenario.id}.sh"])

        assert File.exists?(path), "#{scenario.id} is in the suite but #{path} is missing"
      end
    end
  end

  describe "which implementation is asked what" do
    test "everything, unless the scenario says otherwise" do
      assert Suite.applies?(Suite.scenario(:follow_out), :gotosocial)
      assert Suite.applies?(Suite.scenario(:follow_out), :akkoma)
    end

    test "and a feature a server does not have is not asked of it" do
      # Asking a server about a feature it does not implement produces a
      # failure that means nothing.
      refute Suite.applies?(Suite.scenario(:quote), :gotosocial)
      assert Suite.applies?(Suite.scenario(:quote), :mastodon)
    end

    test "so each implementation has its own list" do
      assert length(Suite.for_implementation(:mastodon)) >
               length(Suite.for_implementation(:gotosocial))
    end
  end

  describe "the report" do
    test "shows a scenario that was not run as such, not as a pass" do
      # Three outcomes, not two. Collapsing "not run" into either of the others
      # is how a suite quietly stops testing something.
      report = Report.render(%{results: %{{:follow_out, :mastodon} => :pass}})

      assert report =~ "pass"
      assert report =~ "not run"
    end

    test "marks a scenario an implementation is not asked with a dot" do
      report = Report.render(%{results: %{}})

      assert report =~ "·"
    end

    test "puts the reason for a failure under the matrix, where it fits" do
      report =
        Report.render(%{
          results: %{{:boost, :akkoma} => {:fail, "the Announce never arrived"}}
        })

      assert report =~ "**fail**"
      assert report =~ "What failed"
      assert report =~ "the Announce never arrived"
    end

    test "says which versions it ran against" do
      # A protocol result without a version is a result about nothing in
      # particular.
      report = Report.render(%{versions: %{"Mastodon" => "v4.4.7"}})

      assert report =~ "v4.4.7"
    end

    test "and says so when it does not know" do
      assert Report.render(%{}) =~ "missing from this run"
    end

    test "does not tell the reader which server is wrong" do
      # A disagreement is a disagreement. Which of the two is at fault is a
      # question this suite deliberately does not answer.
      report = Report.render(%{results: %{{:boost, :akkoma} => {:fail, "no Announce"}}})

      assert report =~ "deliberately does not answer"
    end
  end
end
