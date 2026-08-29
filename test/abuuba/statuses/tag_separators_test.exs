defmodule Abuuba.Statuses.TagSeparatorsTest do
  @moduledoc """
  Hashtags other people write, in the scripts they write them in.

  The reference implementation allows three separators inside a hashtag
  besides the underscore: the middle dot, the katakana middle dot, and a
  zero-width non-joiner. They are ordinary in Japanese and in several Indic
  scripts. abuuba refused them, so a post carrying one arrived with that
  hashtag missing -- it never appeared under the tag, and the same tag on two
  servers was two different things.
  """
  use Abuuba.DataCase, async: true

  alias Abuuba.Statuses.Formatter
  alias Abuuba.Statuses.Tag

  defp valid?(name), do: Tag.changeset(%Tag{}, %{name: name}).valid?

  test "the separators the rest of the network allows" do
    assert valid?("ドット・区切り"), "the katakana middle dot is refused"
    assert valid?("mid·dot"), "the middle dot is refused"
    assert valid?("zero‌width"), "a zero-width non-joiner is refused"
  end

  test "and the ordinary ones still work" do
    assert valid?("gardening")
    assert valid?("日本語")
    assert valid?("with_underscore")
  end

  test "and the extractor finds exactly what the schema will keep" do
    # The two ends have to agree. A tag this finds and the schema refuses is a
    # link to nothing; one the schema allows and this never finds is a hashtag
    # that only works when somebody else's server sent it.
    assert Formatter.hashtags("a #ドット・区切り post") ==
             ["ドット・区切り"]
  end

  test "and stops at a separator used as punctuation" do
    # `猫・犬` is one hashtag; `#猫・#犬` is two, and the middle dot between
    # them is a list separator rather than part of either.
    assert Formatter.hashtags("#猫・#犬") == ["猫", "犬"]
  end

  test "while a tag that is only digits is still refused" do
    # The control: this is about which characters may join a hashtag, not
    # about giving up on checking them.
    refute valid?("12345")
    refute valid?("")
  end
end
