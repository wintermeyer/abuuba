defmodule Abuuba.I18nTest do
  use ExUnit.Case, async: true

  alias Abuuba.I18n

  describe "resolve/1" do
    test "prefers what the person actually chose" do
      assert I18n.resolve(
               user_locale: "de",
               session_locale: "en",
               accept_language: "en-GB,en;q=0.9"
             ) == "de"
    end

    test "falls back to a choice made in this session" do
      assert I18n.resolve(session_locale: "de", accept_language: "en") == "de"
    end

    test "then honours the browser" do
      assert I18n.resolve(accept_language: "de-AT,de;q=0.9,en;q=0.8") == "de"
    end

    test "and ends at English" do
      assert I18n.resolve() == "en"
      assert I18n.resolve(accept_language: "fr,es;q=0.9") == "en"
    end

    test "ignores a stored preference we cannot honour" do
      # A locale from a stale session or a hand-edited row would otherwise
      # reach Gettext, which answers unknown locales in msgids.
      assert I18n.resolve(user_locale: "klingon", accept_language: "de") == "de"
      assert I18n.resolve(user_locale: nil, session_locale: "", accept_language: nil) == "en"
      assert I18n.resolve(user_locale: :de) == "en"
    end
  end

  describe "from_accept_language/1" do
    test "takes the highest quality match" do
      assert I18n.from_accept_language("en;q=0.6,de;q=0.9") == "de"
      assert I18n.from_accept_language("de;q=0.2,en;q=0.8") == "en"
    end

    test "treats a missing q as the strongest preference" do
      assert I18n.from_accept_language("de,en;q=0.9") == "de"
    end

    test "matches a regional tag to its language" do
      # A browser asking for Austrian German should not be answered in English
      # for want of an Austrian catalogue.
      assert I18n.from_accept_language("de-AT") == "de"
      assert I18n.from_accept_language("DE-ch") == "de"
    end

    test "skips languages we do not have" do
      assert I18n.from_accept_language("fr-FR,fr;q=0.9,de;q=0.1") == "de"
      assert I18n.from_accept_language("fr,es,it") == nil
    end

    test "treats q=0 as a refusal, not a weak preference" do
      assert I18n.from_accept_language("de;q=0") == nil
      assert I18n.from_accept_language("de;q=0,en;q=0.1") == "en"
    end

    test "does not read * as a preference for anything in particular" do
      assert I18n.from_accept_language("*") == nil
    end

    test "survives a header that is not one" do
      for junk <- ["", "   ", ";;;", "de;q=nonsense", "de;q=9", nil, 42] do
        assert I18n.from_accept_language(junk) in [nil, "de"]
      end
    end
  end

  describe "known?/1" do
    test "accepts what we ship and nothing else" do
      assert I18n.known?("en")
      assert I18n.known?("de")

      refute I18n.known?("de-AT")
      refute I18n.known?("")
      refute I18n.known?(nil)
      refute I18n.known?(:de)
    end
  end

  test "German is a shipped language, not the default" do
    assert I18n.default_locale() == "en"
    assert "de" in I18n.known_locales()
  end
end
