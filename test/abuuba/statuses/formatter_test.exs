defmodule Abuuba.Statuses.FormatterTest do
  use Abuuba.DataCase, async: true

  import Abuuba.AccountsFixtures

  alias Abuuba.Federation.URIs
  alias Abuuba.Instance
  alias Abuuba.Statuses.Formatter

  describe "links" do
    test "a URL somebody typed becomes one" do
      html = Formatter.to_html("look at https://example.com/page")

      assert html =~ ~s(<a href="https://example.com/page")
      assert html =~ ~s(rel="nofollow noopener noreferrer")
      assert html =~ ~s(target="_blank")
    end

    test "and the full stop after it is not part of it" do
      html = Formatter.to_html("read https://example.com/page.")

      assert html =~ ~s(href="https://example.com/page")
      refute html =~ ~s(href="https://example.com/page.")
      assert html =~ "</a>."
    end

    test "a bracket that belongs to the address is kept" do
      # `~s|...|` rather than `~s(...)`: the URL has brackets in it, and a paren
      # sigil closes on the first of them and reports a syntax error many lines
      # further down.
      html = Formatter.to_html("see https://en.wikipedia.org/wiki/Elixir_(programming_language)")

      assert html =~ ~s|href="https://en.wikipedia.org/wiki/Elixir_(programming_language)"|
    end

    test "and one that belongs to the sentence is not" do
      html = Formatter.to_html("(see https://example.com/page)")

      assert html =~ ~s|href="https://example.com/page"|
      refute html =~ ~s|href="https://example.com/page)"|
      assert html =~ "</a>)"
    end

    test "and a comma after a bracket is handled too" do
      html =
        Formatter.to_html(
          "see https://en.wikipedia.org/wiki/Elixir_(programming_language), then stop"
        )

      assert html =~ ~s|href="https://en.wikipedia.org/wiki/Elixir_(programming_language)"|
      assert html =~ "</a>, then stop"
    end

    test "a hashtag inside a URL is left alone" do
      # The hashtag pass runs after the URL pass, and without keeping it out of
      # the anchors it would rewrite the inside of the href it had just made.
      html = Formatter.to_html("see https://example.com/docs#install")

      assert html =~ ~s(href="https://example.com/docs#install")
      refute html =~ ~s(class="hashtag")
    end

    test "and a hashtag beside one is still linked" do
      # The control: the test above passes on a version that stopped linking
      # hashtags entirely.
      html = Formatter.to_html("see https://example.com/docs and #install")

      assert html =~ ~s(href="https://example.com/docs")
      assert html =~ ~s(class="hashtag")
    end

    test "markup in a URL cannot escape the attribute" do
      html = Formatter.to_html(~s|https://example.com/"onmouseover="alert(1)|)

      refute html =~ "onmouseover=\"alert"
    end
  end

  describe "somebody else's markup" do
    test "keeps a link and gives it the same rel a local one gets" do
      # The same timeline used to open one link in a new tab and the one under
      # it in the same tab, depending on which server wrote the post.
      html = Formatter.sanitize(~s|<p>see <a href="https://ok.example">this</a></p>|)

      assert html =~ ~s|href="https://ok.example"|
      assert html =~ ~s|rel="nofollow noopener noreferrer"|
      assert html =~ ~s|target="_blank"|
    end

    test "and the marking does not put anything back that was stripped" do
      html =
        Formatter.sanitize(
          ~s|<a href="https://ok.example" onclick="alert(1)" rel="me" target="_self">ok</a>|
        )

      refute html =~ "onclick"
      refute html =~ ~s|rel="me"|
      refute html =~ "_self"
    end

    test "sanitising twice is the same as sanitising once" do
      # A remote account's note is sanitised on the way in and sanitised again
      # when the profile renders it, and since #288 the sanitiser *adds*
      # attributes. Somebody has to be able to see that running it twice is
      # safe without working out why.
      once = Formatter.sanitize(~s|<p>see <a href="https://ok.example">this</a></p>|)

      assert Formatter.sanitize(once) == once
    end

    test "and what the local path produced survives a pass unchanged" do
      # This is the one with teeth. The property holds because the sanitiser
      # strips `rel` and `target` before the marking puts them back, so a
      # second *sanitising* pass is harmless however the two are ordered --
      # I checked, by reordering them and by marking before and after, and the
      # test above stayed green each time. What it cannot survive is the
      # marking running twice without a strip between, and that is what this
      # catches: the local path hands it markup that is already marked.
      html = Formatter.to_html("see https://ok.example")

      assert Formatter.sanitize(html) == html
    end

    test "a javascript href is still dropped" do
      # The control on the other side: marking runs after the sanitiser, so it
      # must not resurrect an address the sanitiser refused.
      html = Formatter.sanitize(~s|<a href="javascript:alert(1)">click</a>|)

      refute html =~ "javascript:"
    end
  end

  describe "how long a post is" do
    test "a URL counts as twenty-three, whatever its length" do
      long = "https://example.com/" <> String.duplicate("a", 200)

      assert Formatter.length("x " <> long) == 2 + Formatter.url_length()
    end

    test "and a short one counts as twenty-three too" do
      # Upstream rounds both ways: a link is 23 to the person composing, so it
      # is 23 to the server refusing.
      assert Formatter.length("https://a.co") == Formatter.url_length()
    end

    test "a mention counts without the domain" do
      assert Formatter.length("@alice@remote.example hello") ==
               String.length("@alice hello")
    end

    test "and ordinary text counts by graphemes" do
      assert Formatter.length("Grüße 日本語") == String.length("Grüße 日本語")
    end
  end

  describe "reading what somebody typed" do
    test "finds a local handle and one on another server" do
      assert Formatter.mentions("hi @alice and @bob@other.example") == [
               "alice",
               "bob@other.example"
             ]
    end

    test "names somebody once however often they are named" do
      assert Formatter.mentions("@alice @alice") == ["alice"]
    end

    test "an address is not a mention" do
      # Otherwise every posted email address addresses somebody.
      assert Formatter.mentions("write to me@example.com") == []
    end

    test "finds hashtags, casefolded" do
      assert Formatter.hashtags("#Elixir and #elixir and #Phoenix") == ["elixir", "phoenix"]
    end

    test "accepts a hashtag that is not in English" do
      assert Formatter.hashtags("#Grüße #日本語") == ["grüße", "日本語"]
    end

    test "refuses a hashtag made only of digits, which is a number somebody wrote" do
      assert Formatter.hashtags("#1 #2024 #covid19") == ["covid19"]
    end

    test "finds shortcodes" do
      assert Formatter.shortcodes("hello :wave: :wave: :party:") == ["wave", "party"]
    end
  end

  describe "cleaning another server's markup" do
    test "takes out a script" do
      dirty = "<p>hello</p><script>alert(1)</script>"

      refute Formatter.sanitize(dirty) =~ "script"
    end

    test "takes out an inline handler" do
      dirty = ~S|<img src="x" onerror="alert(1)">|

      refute Formatter.sanitize(dirty) =~ "onerror"
    end

    test "takes out a link that runs code, which is a script differently spelled" do
      dirty = ~S|<a href="javascript:alert(1)">x</a>|

      refute Formatter.sanitize(dirty) =~ "javascript"
    end

    test "takes out styling, which is where a sanitiser is most often wrong" do
      # CVE-2026-68747 was a bypass of html_sanitize_ex's CSS allow-list. The
      # profile used here permits no `style` at all, so the hole never reached
      # us — but the reason it never reached us is a property of our own code
      # and belongs in our own suite, not in a version number in mix.lock.
      dirty = ~s|<p style="position:fixed;top:0;width:100%">give me your password</p>|

      cleaned = Formatter.sanitize(dirty)

      refute cleaned =~ "style"
      refute cleaned =~ "position"
      assert cleaned =~ "give me your password"
    end

    test "keeps the markup a post is actually written in" do
      cleaned = Formatter.sanitize(~S|<p>hi <a href="https://a.test/@bob">@bob</a></p>|)

      assert cleaned =~ "<p>"
      assert cleaned =~ "https://a.test/@bob"
    end

    test "an empty document is not an error" do
      assert Formatter.sanitize(nil) == ""
    end
  end

  describe "the counter" do
    test "counts what was typed" do
      assert Formatter.length("hello") == 5
    end

    test "counts a remote mention as the name alone" do
      # Charging somebody for a domain they did not choose would make a
      # conversation with people on long domains impossible.
      assert Formatter.length("@bob@very-long-domain.example") == String.length("@bob")
    end

    test "counts characters, not bytes" do
      assert Formatter.length("äöü🎉") == 4
    end

    test "an empty box is zero" do
      assert Formatter.length(nil) == 0
    end
  end

  describe "rendering" do
    test "links a local mention to the account" do
      account = account_fixture(%{username: "alice"})

      html = Formatter.to_html("hi @alice")

      assert html =~ ~s(class="mention")
      assert html =~ URIs.profile_url(account)
      assert html =~ ">@alice</a>"
    end

    test "leaves a mention of nobody as typed" do
      # Linking to a profile that does not exist is worse than plain text.
      assert Formatter.to_html("hi @nobody") == "<p>hi @nobody</p>"
    end

    test "links a hashtag to its timeline" do
      html = Formatter.to_html("about #Elixir")

      assert html =~ ~s(href="#{URIs.base_url()}/tags/elixir")
      assert html =~ ">#Elixir</a>"
    end

    test "renders a known emoji as its picture" do
      {:ok, _} =
        Instance.put_custom_emoji(%{
          shortcode: "wave",
          image_url: "https://example.test/wave.png"
        })

      html = Formatter.to_html("hello :wave:")

      assert html =~ ~s(<img src="https://example.test/wave.png")
      assert html =~ ~s(alt=":wave:")
    end

    test "leaves a shortcode nobody has a picture for as the word it is" do
      assert Formatter.to_html("that is a :shrug:") == "<p>that is a :shrug:</p>"
    end

    test "escapes markup before it can reach anybody" do
      html = Formatter.to_html("<script>alert(1)</script>")

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "markup written around a mention cannot escape through the link" do
      account_fixture(%{username: "alice"})

      html = Formatter.to_html(~s(<b>@alice</b>))

      refute html =~ "<b>"
      assert html =~ ~s(class="mention")
    end

    test "a blank line starts a paragraph and a single newline breaks the line" do
      assert Formatter.to_html("one\ntwo\n\nthree") == "<p>one<br />two</p><p>three</p>"
    end

    test "an empty box renders to nothing" do
      assert Formatter.to_html("") == ""
      assert Formatter.to_html(nil) == ""
    end

    test "cannot be broken out of by a URL with a quote in it" do
      # An emoji picture is fetched from another server, so its address is not
      # ours. Interpolated unescaped it would end the attribute and start a new
      # one, which is a script tag away from being everybody's problem.
      html =
        Formatter.to_html("hi :x:",
          emojis: %{"x" => "https://evil.test/a.png\" onerror=\"alert(1)"}
        )

      refute html =~ ~s(" onerror=")
      assert html =~ "&quot;"
    end

    test "cannot be broken out of by a profile address with a quote in it" do
      html =
        Formatter.to_html("hi @bob", accounts: %{"bob" => "/a\" onmouseover=\"alert(1)"})

      refute html =~ ~s(" onmouseover=")
      assert html =~ "&quot;"
    end

    test "takes accounts it was handed rather than looking them up" do
      html = Formatter.to_html("hi @alice", accounts: %{"alice" => "https://x.test/@alice"})

      assert html =~ ~s(href="https://x.test/@alice")
    end
  end
end
