defmodule Abuuba.Federation.JSONLDTest do
  use ExUnit.Case, async: true

  alias Abuuba.Federation.JSONLD

  @as "https://www.w3.org/ns/activitystreams"

  describe "the context" do
    test "is the bare namespace when a document needs nothing else" do
      # A string rather than a one-element list, because that is what the
      # network sends and what a strict consumer is used to seeing.
      assert JSONLD.context() == @as
    end

    test "carries extension terms in a map after the namespace" do
      assert [@as, terms] = JSONLD.context([:sensitive])
      assert terms["sensitive"] == "as:sensitive"
    end

    test "puts named contexts before the terms that depend on them" do
      # `toot:blurhash` is meaningless until `toot` is defined, and a consumer
      # reads the context in order.
      assert [@as, "https://w3id.org/security/v1", terms] =
               JSONLD.context([:security, :blurhash])

      assert terms["toot"] == "http://joinmastodon.org/ns#"
      assert terms["blurhash"] == "toot:blurhash"
    end

    test "merges the terms of everything asked for into one map" do
      assert [@as, terms] = JSONLD.context([:discoverable, :indexable, :property_value])

      assert terms["discoverable"] == "toot:discoverable"
      assert terms["indexable"] == "toot:indexable"
      assert terms["PropertyValue"] == "schema:PropertyValue"
    end

    test "defines a prefix once however many terms use it" do
      [@as, terms] = JSONLD.context([:blurhash, :focal_point, :discoverable])

      assert terms["toot"] == "http://joinmastodon.org/ns#"
      assert map_size(terms) == 4
    end

    test "does not depend on the order the terms were asked for" do
      assert JSONLD.context([:blurhash, :sensitive]) == JSONLD.context([:sensitive, :blurhash])
    end

    test "refuses a term nobody defined, rather than emitting a context that lies" do
      assert_raise ArgumentError, ~r/nonsense/, fn -> JSONLD.context([:nonsense]) end
    end

    test "gives focalPoint an ordered container, since it is a pair of numbers" do
      [@as, terms] = JSONLD.context([:focal_point])

      assert terms["focalPoint"]["@container"] == "@list"
    end
  end

  describe "documents we will not read" do
    test "one wrapped in @graph" do
      # Plain map access reads the top level. A document whose real content is
      # under @graph would be read as an empty one, so the safe answer is to
      # refuse it rather than to act on what is left.
      assert JSONLD.foreign_shape?(%{"@graph" => [%{"type" => "Create"}]})
    end

    test "one using @included or @reverse" do
      assert JSONLD.foreign_shape?(%{"type" => "Create", "@included" => []})
      assert JSONLD.foreign_shape?(%{"type" => "Create", "@reverse" => %{}})
    end

    test "one hiding the construction inside its object" do
      # The nesting is the dangerous case: the top level looks ordinary and
      # the part that carries meaning is the part we would misread.
      assert JSONLD.foreign_shape?(%{
               "type" => "Create",
               "object" => %{"type" => "Note", "@graph" => []}
             })
    end

    test "one hiding it inside a list" do
      assert JSONLD.foreign_shape?(%{"tag" => [%{"@reverse" => %{}}]})
    end

    test "but not an ordinary activity" do
      refute JSONLD.foreign_shape?(%{
               "@context" => @as,
               "type" => "Create",
               "object" => %{"type" => "Note", "content" => "hello", "tag" => []}
             })
    end

    test "and not a key that merely looks like one" do
      refute JSONLD.foreign_shape?(%{"graph" => %{}, "content" => "@reverse"})
    end

    test "gives up rather than recursing forever on a deeply nested document" do
      # A hostile peer can nest a megabyte of JSON thousands of levels deep.
      # Refusing what we cannot finish checking is the safe direction.
      deep = Enum.reduce(1..500, %{"type" => "Note"}, fn _, acc -> %{"object" => acc} end)

      assert JSONLD.foreign_shape?(deep)
    end
  end
end
