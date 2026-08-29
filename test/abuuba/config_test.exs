defmodule Abuuba.ConfigTest do
  @moduledoc """
  What `config/runtime.exs` has to set up for a production release.

  A test rather than a comment, because the file is only ever read when a
  release boots: nothing in the suite executes it, so a variable that is
  documented and read by nobody looks exactly like one that works.
  """

  use ExUnit.Case, async: true

  @runtime File.read!("config/runtime.exs")

  describe "the production block" do
    test "gives the federation layer the domain this server calls itself" do
      # Without it, `Abuuba.Federation.URIs.local_domain/0` raises on the first
      # outward-facing URI — which is every actor document, every activity id
      # and every WebFinger answer. The server starts, serves its own pages,
      # and fails at the one job that makes it a fediverse server.
      assert @runtime =~ "local_domain:"
      assert @runtime =~ "LOCAL_DOMAIN"
    end

    test "and the scheme those URIs are written with" do
      assert @runtime =~ "local_scheme:"
    end

    test "and a mail transport that actually delivers" do
      # The default adapter keeps mail in memory. A production server running
      # on it accepts sign-ups and never sends the confirmation, which looks
      # to the person signing up like the address they typed was wrong.
      assert @runtime =~ "MAIL_ADAPTER"
      assert @runtime =~ "MAIL_FROM"
      assert @runtime =~ "sender_email:"
    end

    test "and the two secrets that have no safe default" do
      assert @runtime =~ "SECRET_KEY_BASE"
      assert @runtime =~ "CLOAK_KEY"
    end
  end

  describe "every variable the deployment documents" do
    # The other direction: a name in the docs that the code never reads is a
    # setting an operator will believe they have configured.
    @documented ~w(DATABASE_URL SECRET_KEY_BASE CLOAK_KEY PHX_HOST LOCAL_DOMAIN
                   URI_SCHEME MEDIA_ROOT MEDIA_STORAGE MEDIA_ALIAS_HOST
                   MAIL_FROM MAIL_ADAPTER SMTP_RELAY SMTP_PORT SMTP_USERNAME
                   SMTP_PASSWORD MAILGUN_API_KEY MAILGUN_DOMAIN POOL_SIZE PORT
                   ECTO_IPV6 TRANSLATION_PROVIDER HCAPTCHA_SITE_KEY
                   HCAPTCHA_SECRET S3_BUCKET S3_REGION S3_ENDPOINT
                   S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY DNS_CLUSTER_QUERY)

    test "is one runtime.exs actually reads" do
      for name <- @documented do
        assert @runtime =~ name,
               "#{name} is documented in docs/deploy.md but config/runtime.exs never reads it"
      end
    end
  end
end
