defmodule Abuuba.ListsAndFiltersTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Filters
  alias Abuuba.Filters.Filter
  alias Abuuba.Lists
  alias Abuuba.Relationships

  setup do
    %{owner: account_fixture(), member: account_fixture()}
  end

  describe "lists" do
    test "are created and read back by title", %{owner: owner} do
      {:ok, list} = Lists.create(owner, %{"title" => "Cycling"})

      assert list.title == "Cycling"
      assert list.replies_policy == "list"
      refute list.exclusive
      assert Enum.map(Lists.all(owner), & &1.id) == [list.id]
    end

    test "belong to one account", %{owner: owner} do
      {:ok, _} = Lists.create(owner, %{"title" => "Mine"})

      assert Lists.all(account_fixture()) == []
      assert Lists.get(account_fixture(), Lists.all(owner) |> hd() |> Map.get(:id)) == nil
    end

    test "cannot share a title with another of your own", %{owner: owner} do
      {:ok, _} = Lists.create(owner, %{"title" => "Cycling"})

      assert {:error, changeset} = Lists.create(owner, %{"title" => "Cycling"})
      assert %{title: [_]} = errors_on(changeset)
    end

    test "refuse a reply policy nobody defined", %{owner: owner} do
      assert {:error, changeset} =
               Lists.create(owner, %{"title" => "x", "replies_policy" => "maybe"})

      assert %{replies_policy: [_]} = errors_on(changeset)
    end

    test "take people the owner already follows", %{owner: owner, member: member} do
      {:ok, _} = Relationships.follow(owner, member)
      {:ok, list} = Lists.create(owner, %{"title" => "Cycling"})

      assert :ok = Lists.add(list, [member.id])
      assert Enum.map(Lists.members(list), & &1.id) == [member.id]
    end

    test "refuse somebody the owner does not follow", %{owner: owner, member: member} do
      # A list is a way of reading what you already receive. Adding somebody
      # you do not follow would be a follow with none of a follow's
      # consequences: nothing delivered, and nobody told.
      {:ok, list} = Lists.create(owner, %{"title" => "Cycling"})

      assert Lists.add(list, [member.id]) == {:error, :not_following}
      assert Lists.members(list) == []
    end

    test "adding twice is not two memberships", %{owner: owner, member: member} do
      {:ok, _} = Relationships.follow(owner, member)
      {:ok, list} = Lists.create(owner, %{"title" => "Cycling"})

      :ok = Lists.add(list, [member.id])
      :ok = Lists.add(list, [member.id])

      assert length(Lists.members(list)) == 1
    end

    test "removing takes somebody out without unfollowing them", %{
      owner: owner,
      member: member
    } do
      {:ok, _} = Relationships.follow(owner, member)
      {:ok, list} = Lists.create(owner, %{"title" => "Cycling"})
      :ok = Lists.add(list, [member.id])

      assert :ok = Lists.remove(list, [member.id])
      assert Lists.members(list) == []
      assert Relationships.following?(owner, member)
    end

    test "say which lists somebody is in", %{owner: owner, member: member} do
      {:ok, _} = Relationships.follow(owner, member)
      {:ok, one} = Lists.create(owner, %{"title" => "A"})
      {:ok, _two} = Lists.create(owner, %{"title" => "B"})
      :ok = Lists.add(one, [member.id])

      assert Enum.map(Lists.containing(owner, member), & &1.id) == [one.id]
    end

    test "an exclusive list names who a home timeline should leave out", %{
      owner: owner,
      member: member
    } do
      {:ok, _} = Relationships.follow(owner, member)
      {:ok, list} = Lists.create(owner, %{"title" => "Noisy", "exclusive" => true})
      :ok = Lists.add(list, [member.id])

      assert Lists.exclusive_member_ids(owner) == [member.id]
    end

    test "a plain list names nobody to leave out", %{owner: owner, member: member} do
      {:ok, _} = Relationships.follow(owner, member)
      {:ok, list} = Lists.create(owner, %{"title" => "Quiet"})
      :ok = Lists.add(list, [member.id])

      assert Lists.exclusive_member_ids(owner) == []
    end
  end

  describe "filters" do
    setup %{owner: owner} do
      {:ok, filter} =
        Filters.create(owner, %{
          "title" => "Elections",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "election"}]
        })

      %{filter: filter}
    end

    test "carry their keywords", %{filter: filter} do
      assert [%{keyword: "election"}] = filter.keywords
      assert filter.filter_action == "warn"
    end

    test "arrive when the client numbers them, as the documented call does",
         %{owner: owner} do
      # `keywords_attributes[0][keyword]=x` is the form the API documentation
      # uses and the one an ordinary HTTP library produces, and Phoenix hands
      # it over as a map keyed by the index rather than a list. Reading only
      # the list answered "keyword can't be blank" for a keyword the client had
      # plainly sent -- a filter that saved with nothing to look for.
      assert {:ok, filter} =
               Filters.create(owner, %{
                 "title" => "Numbered",
                 "context" => ["home"],
                 "keywords_attributes" => %{
                   "0" => %{"keyword" => "first"},
                   "1" => %{"keyword" => "second", "whole_word" => "false"}
                 }
               })

      # Each numbered entry keeps its own settings rather than the first one's.
      assert [%{keyword: "first", whole_word: true}, %{keyword: "second", whole_word: false}] =
               Enum.sort_by(filter.keywords, & &1.keyword)
    end

    test "in the order the client numbered them, past nine", %{owner: owner} do
      # String order puts "10" before "2", which would file a client's tenth
      # keyword third. Nothing downstream reads the order today, but a filter
      # is a list somebody edits by index.
      numbered = for n <- 0..10, into: %{}, do: {to_string(n), %{"keyword" => "w#{n}"}}

      assert {:ok, filter} =
               Filters.create(owner, %{
                 "title" => "Eleven",
                 "context" => ["home"],
                 "keywords_attributes" => numbered
               })

      assert Enum.map(filter.keywords, & &1.keyword) == for(n <- 0..10, do: "w#{n}")
    end

    test "and the same when the client edits them", %{filter: filter} do
      assert {:ok, filter} =
               Filters.update(filter, %{
                 "keywords_attributes" => %{"0" => %{"keyword" => "replaced"}}
               })

      assert [%{keyword: "replaced"}] = filter.keywords
    end

    test "a spelling that cannot be stored fails the whole write", %{owner: owner} do
      # Skipping it would leave a rule that reads as saved and looks for less
      # than it was asked to look for, which is a filter quietly not working.
      assert {:error, changeset} =
               Filters.create(owner, %{
                 "title" => "Long",
                 "context" => ["home"],
                 "keywords_attributes" => [
                   %{"keyword" => "fine"},
                   %{"keyword" => String.duplicate("x", 600)}
                 ]
               })

      assert %{keyword: [_]} = errors_on(changeset)
      assert Filters.all(owner) |> Enum.filter(&(&1.title == "Long")) == []
    end

    test "an entry that is not a keyword at all fails the whole write", %{owner: owner} do
      # Same principle as the one above: saving the rest would leave a rule
      # that reads as saved and looks for less than it was asked to.
      assert {:error, changeset} =
               Filters.create(owner, %{
                 "title" => "Rubbish",
                 "context" => ["home"],
                 "keywords_attributes" => %{"0" => %{"keyword" => "fine"}, "1" => "hello"}
               })

      # Only the keyword: a `filter_id` error would name something the client
      # never sent and cannot fix.
      assert %{keyword: [_]} = errors_on(changeset)
      refute Map.has_key?(errors_on(changeset), :filter_id)
      assert Enum.filter(Filters.all(owner), &(&1.title == "Rubbish")) == []
    end

    test "keeps a long keyword the reference implementation would keep", %{owner: owner} do
      # 512 characters, which is that limit exactly. Ours used to be 100, so a
      # client offering the documented box got a database error.
      keyword = String.duplicate("x", 512)

      assert {:ok, filter} =
               Filters.create(owner, %{
                 "title" => String.duplicate("t", 256),
                 "context" => ["home"],
                 "keywords_attributes" => [%{"keyword" => keyword}]
               })

      assert [%{keyword: ^keyword}] = filter.keywords
    end

    test "looks for whole words unless told otherwise", %{owner: owner} do
      # What the reference implementation defaults to, and therefore what a
      # client that omits the parameter is written against.
      {:ok, filter} =
        Filters.create(owner, %{
          "title" => "Cats",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "cat"}]
        })

      assert [%{whole_word: true}] = filter.keywords
    end

    test "need somewhere to apply", %{owner: owner} do
      # A filter with no context is a rule somebody wrote and will never see
      # the effect of.
      assert {:error, changeset} = Filters.create(owner, %{"title" => "x", "context" => []})
      assert %{context: [_]} = errors_on(changeset)
    end

    test "refuse a context nobody defined", %{owner: owner} do
      assert {:error, changeset} =
               Filters.create(owner, %{"title" => "x", "context" => ["everywhere"]})

      assert %{context: [_]} = errors_on(changeset)
    end

    test "match a post in the context they apply to", %{owner: owner} do
      status = status_fixture(%{account_id: account_fixture().id, text: "the ELECTION is soon"})

      assert [%{title: "Elections"}] = Filters.matching(owner, status, "home")
      assert Filters.matching(owner, status, "public") == []
    end

    test "match the content warning as well as the text", %{owner: owner} do
      # A warning is exactly where somebody names the topic being filtered, so
      # ignoring it lets the one post that announced the subject through.
      status =
        status_fixture(%{
          account_id: account_fixture().id,
          text: "anyway",
          spoiler_text: "election"
        })

      assert [_] = Filters.matching(owner, status, "home")
    end

    test "catch a boost of a post they named", %{owner: owner} do
      # Somebody who asked not to see a post did not ask to see it through
      # whoever boosted it.
      author = account_fixture()
      status = status_fixture(%{account_id: author.id, text: "nothing matching here"})

      {:ok, filter} =
        Filters.create(owner, %{
          "title" => "That one",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "unrelated"}]
        })

      {:ok, _} = Filters.add_status(filter, %{"status_id" => status.id})

      {:ok, boost} = Abuuba.Statuses.boost(account_fixture(), status)

      assert [%{title: "That one"}] = Filters.matching(owner, boost, "home")
    end

    test "leave a post alone when nothing matches", %{owner: owner} do
      status = status_fixture(%{account_id: account_fixture().id, text: "cats"})

      assert Filters.matching(owner, status, "home") == []
    end

    test "match only whole words when asked", %{owner: owner} do
      # "cat" matching "concatenate" is almost never what somebody meant.
      {:ok, _} =
        Filters.create(owner, %{
          "title" => "Cats",
          "context" => ["home"],
          "keywords_attributes" => [%{"keyword" => "cat", "whole_word" => true}]
        })

      loose = status_fixture(%{account_id: account_fixture().id, text: "concatenate"})
      exact = status_fixture(%{account_id: account_fixture().id, text: "a cat, then"})

      refute Enum.any?(Filters.matching(owner, loose, "home"), &(&1.title == "Cats"))
      assert Enum.any?(Filters.matching(owner, exact, "home"), &(&1.title == "Cats"))
    end

    test "stop matching once they have run out", %{owner: owner} do
      {:ok, _} =
        Filters.create(owner, %{
          "title" => "Temporary",
          "context" => ["home"],
          "expires_at" => DateTime.add(DateTime.utc_now(), -60, :second),
          "keywords_attributes" => [%{"keyword" => "sport"}]
        })

      status = status_fixture(%{account_id: account_fixture().id, text: "sport"})

      assert Filters.matching(owner, status, "home") == []
    end

    test "one with no expiry never runs out", %{filter: filter} do
      refute Filter.expired?(filter)
    end

    test "are one person's, not everybody's", %{owner: _owner} do
      status = status_fixture(%{account_id: account_fixture().id, text: "election"})

      assert Filters.matching(account_fixture(), status, "home") == []
      assert Filters.matching(nil, status, "home") == []
    end

    test "a keyword can be added and removed on its own", %{owner: owner, filter: filter} do
      {:ok, keyword} = Filters.add_keyword(filter, %{"keyword" => "ballot"})

      status = status_fixture(%{account_id: account_fixture().id, text: "ballot"})
      assert [_] = Filters.matching(owner, status, "home")

      {:ok, _} = Filters.delete_keyword(keyword)

      assert Filters.matching(owner, status, "home") == []
    end

    test "somebody else's keyword is not reachable", %{filter: filter} do
      {:ok, keyword} = Filters.add_keyword(filter, %{"keyword" => "ballot"})

      assert Filters.get_keyword(account_fixture(), keyword.id) == nil
    end

    test "updating replaces the keywords when new ones are given", %{
      owner: owner,
      filter: filter
    } do
      {:ok, updated} =
        Filters.update(filter, %{"keywords_attributes" => [%{"keyword" => "ballot"}]})

      assert Enum.map(updated.keywords, & &1.keyword) == ["ballot"]

      status = status_fixture(%{account_id: account_fixture().id, text: "election"})
      assert Filters.matching(owner, status, "home") == []
    end

    test "updating leaves the keywords alone when none are given", %{filter: filter} do
      {:ok, updated} = Filters.update(filter, %{"title" => "Renamed"})

      assert updated.title == "Renamed"
      assert Enum.map(updated.keywords, & &1.keyword) == ["election"]
    end
  end
end
