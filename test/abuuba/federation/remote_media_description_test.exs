defmodule Abuuba.Federation.RemoteMediaDescriptionTest do
  @moduledoc """
  Alt text somebody else wrote is cut, not refused.

  `Abuuba.Federation.Limits` has had a bound for this since it was written and
  nothing called it, so a description longer than ours are allowed to be was
  handed straight to a changeset that refuses at the same number. The field a
  picture can least spare was the one that went.
  """
  use Abuuba.DataCase, async: true

  alias Abuuba.Federation.Limits

  test "a description longer than the limit is cut to it" do
    long = String.duplicate("a", Limits.media_description_characters() + 500)

    assert String.length(Limits.media_description(long)) ==
             Limits.media_description_characters()
  end

  test "and an ordinary one is left alone" do
    # The control: this cuts what is too long rather than everything.
    assert Limits.media_description("a cat asleep on a keyboard") ==
             "a cat asleep on a keyboard"
  end

  test "and a missing one is empty rather than nil" do
    # `description` is written to a column with a default; nil would override
    # it and raise where the column is NOT NULL.
    assert Limits.media_description(nil) == ""
  end
end
