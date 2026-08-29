defmodule Abuuba.TranslationTest do
  use Abuuba.DataCase, async: false

  import Abuuba.AccountsFixtures
  import Abuuba.StatusesFixtures

  alias Abuuba.Statuses
  alias Abuuba.Translation
  alias Abuuba.Translation.DeepL
  alias Abuuba.Translation.Fake
  alias Abuuba.Translation.LibreTranslate

  setup do
    on_exit(fn ->
      Application.delete_env(:abuuba, :translation_provider)
      Application.delete_env(:abuuba, Abuuba.Translation.DeepL)
      Application.delete_env(:abuuba, Abuuba.Translation.LibreTranslate)
    end)

    %{account: account_fixture()}
  end

  # A provider that answers from a list, so nothing here reaches the network
  # and the batching can be inspected.
  defp fake_provider(pid) do
    fn texts, source, target, _opts ->
      send(pid, {:translated, texts, source, target})

      {:ok, Enum.map(texts, &("[#{target}] " <> &1))}
    end
  end

  defp with_provider(fun, translate) do
    Application.put_env(:abuuba, :translation_provider, Fake)
    Fake.set(translate)

    fun.()
  end

  describe "whether it is on at all" do
    test "off unless a provider is configured" do
      # A server that quietly offered a translate button nobody set up would
      # answer every press with an error.
      refute Translation.enabled?()
    end

    test "and on once one is" do
      Application.put_env(:abuuba, :translation_provider, Fake)

      assert Translation.enabled?()
    end
  end

  describe "translating a post" do
    test "sends the content, the warning, the poll and the descriptions at once", %{
      account: account
    } do
      # One call rather than five. A provider bills per request as well as per
      # character, and five round trips is five chances to be rate limited.
      status =
        status_fixture(%{
          account_id: account.id,
          text: "hello there",
          spoiler_text: "a warning",
          language: "en"
        })

      {:ok, _poll} =
        Statuses.create_poll(status, %{
          "options" => ["first", "second"],
          "expires_in" => 3600
        })

      me = self()

      with_provider(
        fn ->
          {:ok, translation} = Translation.translate(status, "de")

          assert translation.content =~ "[de]"
          assert translation.spoiler_text == "[de] a warning"
          assert Enum.map(translation.poll.options, & &1.title) == ["[de] first", "[de] second"]
        end,
        fake_provider(me)
      )

      assert_receive {:translated, texts, "en", "de"}
      assert length(texts) == 4
    end

    test "media descriptions travel with it", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "look", language: "en"})

      {:ok, attachment} =
        Abuuba.Media.create_attachment(%{
          account_id: account.id,
          status_id: status.id,
          type: :image,
          processing: :complete,
          description: "a photograph of a cat"
        })

      with_provider(
        fn ->
          {:ok, translation} = Translation.translate(status, "de")

          assert [%{id: id, description: description}] = translation.media_attachments
          assert id == to_string(attachment.id)
          assert description == "[de] a photograph of a cat"
        end,
        fake_provider(self())
      )
    end

    test "custom emoji are marked as not to be translated", %{account: account} do
      # A provider handed `:blobcat:` will happily translate it into something
      # that is no longer a shortcode and no longer renders.
      status =
        status_fixture(%{account_id: account.id, text: "hello :blobcat: there", language: "en"})

      me = self()

      with_provider(
        fn -> {:ok, _} = Translation.translate(status, "de") end,
        fake_provider(me)
      )

      assert_receive {:translated, [content | _rest], _source, _target}
      assert content =~ ~s(<span translate="no">:blobcat:</span>)
    end

    test "the no-translate wrapper never reaches a reader", %{account: account} do
      # It exists for the provider's benefit. Left in, it renders as escaped
      # markup in the middle of somebody's post.
      status =
        status_fixture(%{account_id: account.id, text: "hello :blobcat: there", language: "en"})

      with_provider(
        fn ->
          {:ok, translation} = Translation.translate(status, "de")

          refute translation.content =~ "translate="
          assert translation.content =~ ":blobcat:"
        end,
        fake_provider(self())
      )
    end

    test "empty parts are not sent and come back empty", %{account: account} do
      # A provider handed an empty string bills for the request and answers
      # with whatever its prefix happens to be.
      status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})
      me = self()

      with_provider(
        fn ->
          {:ok, translation} = Translation.translate(status, "de")

          assert translation.spoiler_text == ""
        end,
        fake_provider(me)
      )

      assert_receive {:translated, texts, _source, _target}
      assert texts == ["hello"]
    end

    test "says which language it came from", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})

      with_provider(
        fn ->
          {:ok, translation} = Translation.translate(status, "de")

          assert translation.detected_source_language == "en"
          assert translation.provider
        end,
        fake_provider(self())
      )
    end

    test "refuses a post nobody outside its audience may read", %{account: account} do
      # Translating is asking a third party to read it. A followers-only post
      # is not ours to hand over.
      status =
        status_fixture(%{account_id: account.id, text: "quiet", visibility: :private})

      with_provider(
        fn -> assert {:error, :not_translatable} = Translation.translate(status, "de") end,
        fake_provider(self())
      )
    end

    test "refuses one already in the language asked for", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "hallo", language: "de"})

      with_provider(
        fn -> assert {:error, :same_language} = Translation.translate(status, "de") end,
        fake_provider(self())
      )
    end

    test "refuses when nothing is configured", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})

      assert {:error, :not_configured} = Translation.translate(status, "de")
    end
  end

  describe "the cache" do
    test "means the same post is not sent twice", %{account: account} do
      # These calls are metered. A hundred readers asking for one post is one
      # call, or a translate button that stops working at lunchtime.
      status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})
      me = self()

      with_provider(
        fn ->
          {:ok, first} = Translation.translate(status, "de")
          {:ok, second} = Translation.translate(status, "de")

          assert first.content == second.content
        end,
        fake_provider(me)
      )

      assert_receive {:translated, _texts, _source, _target}
      refute_receive {:translated, _texts, _source, _target}, 50
    end

    test "is per language pair", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})
      me = self()

      with_provider(
        fn ->
          {:ok, german} = Translation.translate(status, "de")
          {:ok, french} = Translation.translate(status, "fr")

          assert german.content != french.content
        end,
        fake_provider(me)
      )

      assert_receive {:translated, _texts, _source, "de"}
      assert_receive {:translated, _texts, _source, "fr"}
    end

    test "an edited post is a different translation", %{account: account} do
      # Keyed on the words rather than on the post, so nothing has to remember
      # to invalidate anything.
      status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})
      me = self()

      with_provider(
        fn ->
          {:ok, _} = Translation.translate(status, "de")
          {:ok, edited} = Statuses.edit_status(status, %{"text" => "hello again"})
          {:ok, translation} = Translation.translate(edited, "de")

          assert translation.content =~ "again"
        end,
        fake_provider(me)
      )

      assert_receive {:translated, _texts, _source, _target}
      assert_receive {:translated, _texts, _source, _target}
    end

    test "an entry past its day is not used", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})
      me = self()

      with_provider(
        fn ->
          {:ok, _} = Translation.translate(status, "de")
          Translation.expire_all()
          {:ok, _} = Translation.translate(status, "de")
        end,
        fake_provider(me)
      )

      assert_receive {:translated, _texts, _source, _target}
      assert_receive {:translated, _texts, _source, _target}
    end
  end

  describe "what a provider can refuse" do
    test "a quota that has run out is said plainly", %{account: account} do
      status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})

      with_provider(
        fn ->
          assert {:error, :quota_exceeded} = Translation.translate(status, "de")
        end,
        fn _texts, _source, _target, _opts -> {:error, :quota_exceeded} end
      )
    end

    test "and a rate limit is not cached", %{account: account} do
      # Caching a failure would turn a minute of being throttled into a day of
      # a broken button.
      status = status_fixture(%{account_id: account.id, text: "hello", language: "en"})
      me = self()

      with_provider(
        fn ->
          assert {:error, :rate_limited} = Translation.translate(status, "de")

          Fake.set(fake_provider(me))

          assert {:ok, _translation} = Translation.translate(status, "de")
        end,
        fn _texts, _source, _target, _opts -> {:error, :rate_limited} end
      )

      assert_receive {:translated, _texts, _source, _target}
    end
  end

  describe "which languages" do
    test "come from the provider and are remembered" do
      me = self()

      Application.put_env(:abuuba, :translation_provider, Fake)

      Fake.set_languages(fn _opts ->
        send(me, :asked)

        {:ok, %{"en" => ["de", "fr"]}}
      end)

      assert Translation.languages() == %{"en" => ["de", "fr"]}
      assert Translation.languages() == %{"en" => ["de", "fr"]}

      assert_receive :asked
      refute_receive :asked, 50
    end

    test "and are empty where nothing is configured" do
      assert Translation.languages() == %{}
    end
  end

  describe "the DeepL adapter" do
    setup do
      Application.put_env(:abuuba, Abuuba.Translation.DeepL, api_key: "a-key")

      :ok
    end

    test "sends the texts as HTML so the no-translate spans are honoured" do
      me = self()

      transport = fn request ->
        send(me, {:request, request})

        {:ok,
         %{
           status: 200,
           body: %{"translations" => [%{"text" => "hallo", "detected_source_language" => "EN"}]}
         }}
      end

      assert {:ok, ["hallo"]} = DeepL.translate(["hello"], "en", "de", transport: transport)

      assert_receive {:request, request}
      assert request.body["tag_handling"] == "html"
      assert request.body["target_lang"] == "DE"
      assert request.headers["authorization"] =~ "DeepL-Auth-Key"
    end

    test "maps a quota answer onto a quota error" do
      # 456 is DeepL's, and a reader should be told the server has run out
      # rather than that something went wrong.
      transport = fn _request -> {:ok, %{status: 456, body: ""}} end

      assert {:error, :quota_exceeded} =
               DeepL.translate(["hello"], "en", "de", transport: transport)
    end

    test "and a rate limit onto a rate limit" do
      transport = fn _request -> {:ok, %{status: 429, body: ""}} end

      assert {:error, :rate_limited} =
               DeepL.translate(["hello"], "en", "de", transport: transport)
    end

    test "a bad key is not a mystery either" do
      transport = fn _request -> {:ok, %{status: 403, body: ""}} end

      assert {:error, :unauthorised} =
               DeepL.translate(["hello"], "en", "de", transport: transport)
    end
  end

  describe "the LibreTranslate adapter" do
    setup do
      Application.put_env(:abuuba, Abuuba.Translation.LibreTranslate,
        endpoint: "https://translate.example",
        api_key: "a-key"
      )

      :ok
    end

    test "sends one request per text, because that is the API it has" do
      me = self()

      transport = fn request ->
        send(me, {:request, request})

        {:ok, %{status: 200, body: %{"translatedText" => "hallo"}}}
      end

      assert {:ok, ["hallo", "hallo"]} =
               LibreTranslate.translate(["hello", "there"], "en", "de", transport: transport)

      assert_receive {:request, request}
      assert request.body["source"] == "en"
      assert request.body["target"] == "de"
      assert request.body["format"] == "html"
    end

    test "maps a rate limit" do
      transport = fn _request -> {:ok, %{status: 429, body: ""}} end

      assert {:error, :rate_limited} =
               LibreTranslate.translate(["hello"], "en", "de", transport: transport)
    end
  end
end
