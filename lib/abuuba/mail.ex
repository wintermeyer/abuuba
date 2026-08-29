defmodule Abuuba.Mail do
  @moduledoc """
  Everything the messages this server sends have in common.

  The sender name and address, and applying the recipient's language before the
  text is built rather than taking whatever the sending process happened to be
  set to. A confirmation arriving in English after somebody filled in a German
  page is a small thing that reads as carelessness.

  One module rather than one per kind of mail, so that anything true of all
  outgoing mail — the sender, a `List-Unsubscribe` header, a Reply-To — is
  changed once instead of drifting apart between them.
  """

  import Swoosh.Email

  alias Abuuba.Federation.URIs
  alias Abuuba.I18n
  alias Abuuba.Mailer
  alias Abuuba.Settings
  alias AbuubaWeb.Plugs.Locale

  @doc """
  Sends one message.

  The text is expected to be built already, and in the right language: see
  `in_locale/2`.

  `:unsubscribe_url` puts `List-Unsubscribe` on the message. Mail clients read
  it to offer their own "unsubscribe" button, and a bulk message without one is
  a message people report as spam because that is the only button they have.
  Only the header, deliberately: `List-Unsubscribe-Post` promises a URL that
  answers a POST from the mail provider with no session behind it, and ours is
  a page a person opens.
  """
  @spec deliver(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver(address, subject, body, opts \\ []) do
    email =
      new()
      |> to(address)
      |> from({site_title(), sender_address()})
      |> subject(subject)
      |> text_body(body)
      |> header("Message-ID", message_id())
      |> unsubscribable(Keyword.get(opts, :unsubscribe_url))

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Builds a message in `locale` and sends it.

  `build` returns `{subject, body}` and runs with the locale applied, which is
  what makes `gettext/1` inside it produce the recipient's language.
  """
  @spec deliver_in_locale(String.t(), String.t() | nil, (-> {String.t(), String.t()}), keyword()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_in_locale(address, locale, build, opts \\ []) do
    {subject, body} = in_locale(locale, build)

    deliver(address, subject, body, opts)
  end

  @doc """
  Runs `build` with `locale` applied, then puts back whatever the process had.

  Without restoring it, sending a German email from inside an English request
  would leave the rest of that request in German.
  """
  @spec in_locale(String.t() | nil, (-> result)) :: result when result: term()
  def in_locale(locale, build) do
    previous = Gettext.get_locale(AbuubaWeb.Gettext)
    Locale.put_locale(I18n.resolve(user_locale: locale))

    try do
      build.()
    after
      Locale.put_locale(previous)
    end
  end

  @doc """
  The name this server signs its mail with.
  """
  @spec site_title() :: String.t()
  def site_title, do: Settings.get("site_title")

  @doc """
  The address it sends from.
  """
  @spec sender_address() :: String.t()
  def sender_address, do: Application.get_env(:abuuba, :sender_email, "noreply@localhost")

  # Angle brackets because RFC 2369 says so: the value is a list of URIs and a
  # bare one is not one.
  # Set here rather than left to the SMTP library, which builds one from
  # `inet:gethostname()`. On a container that is the container id -- a token
  # with no dot in it, so not a domain at all -- and a Message-ID whose domain
  # is not a domain is a spam signal on mail nobody can afford to have filed as
  # junk. `docker compose up -d` is the documented way to run this.
  defp message_id do
    "<#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}@#{URIs.local_host()}>"
  end

  defp unsubscribable(email, nil), do: email
  defp unsubscribable(email, url), do: header(email, "List-Unsubscribe", "<" <> url <> ">")
end
