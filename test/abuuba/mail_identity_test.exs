defmodule Abuuba.MailIdentityTest do
  @moduledoc """
  Outgoing mail names this instance, not the machine it happens to run on.

  When no `Message-ID` is set, the SMTP library builds one from the host's own
  name -- `inet:gethostname()` by way of `smtp_util:guess_FQDN/0`. On a server
  with a real FQDN that is merely wrong; inside a container it is the container
  id, a bare token with no dot in it, so every confirmation and password reset
  goes out stamped `<hash@f4127dfa3209>`.

  A `Message-ID` whose domain is not a domain is a spam signal, and abuuba's
  documented deployment is `docker compose up -d`. Mail that is filed as junk
  fails exactly as completely as mail that was never sent, and more quietly.
  """
  use Abuuba.DataCase, async: true

  alias Abuuba.Federation.URIs

  test "a message is identified by this instance's domain" do
    {:ok, email} = Abuuba.Mail.deliver("someone@example.com", "Confirm", "A link.")

    assert [_local, domain] = String.split(email.headers["Message-ID"], "@")
    assert String.trim_trailing(domain, ">") == URIs.local_host()
  end

  test "and is wrapped in angle brackets, because that is the syntax" do
    {:ok, email} = Abuuba.Mail.deliver("someone@example.com", "Confirm", "A link.")

    assert email.headers["Message-ID"] =~ ~r/^<[^<>@]+@[^<>@]+>$/
  end

  test "and no two messages share one" do
    # A repeated Message-ID is how a threading client hides the second mail as
    # a duplicate of the first, which for two password resets is the newer one
    # disappearing.
    for _ <- 1..2 do
      {:ok, email} = Abuuba.Mail.deliver("someone@example.com", "Confirm", "A link.")
      email.headers["Message-ID"]
    end
    |> Enum.uniq()
    |> length()
    |> then(&assert(&1 == 2))
  end
end
