defmodule CsuiteFinder.CacheTest do
  use ExUnit.Case, async: true

  alias CsuiteFinder.Cache

  describe "normalize_domain/1" do
    test "strips scheme, www, path, query and port" do
      assert {:ok, "stripe.com"} = Cache.normalize_domain("https://WWW.Stripe.com/careers?a=1")
      assert {:ok, "stripe.com"} = Cache.normalize_domain("stripe.com:443")
      assert {:ok, "stripe.com"} = Cache.normalize_domain("  Stripe.COM  ")
    end

    test "keeps subdomains that are not www" do
      assert {:ok, "mail.acme.co.uk"} = Cache.normalize_domain("mail.acme.co.uk")
    end

    test "rejects things that are not domains" do
      assert {:error, :invalid_domain} = Cache.normalize_domain("localhost")
      assert {:error, :invalid_domain} = Cache.normalize_domain("not a domain")
      assert {:error, :invalid_domain} = Cache.normalize_domain("")
      assert {:error, :invalid_domain} = Cache.normalize_domain(nil)
    end
  end

  describe "normalize_email/1" do
    test "lowercases and returns the domain alongside" do
      assert {:ok, "jane@acme.com", "acme.com"} = Cache.normalize_email("  Jane@ACME.com ")
    end

    test "rejects malformed addresses" do
      assert {:error, :invalid_email} = Cache.normalize_email("jane")
      assert {:error, :invalid_email} = Cache.normalize_email("jane@")
      assert {:error, :invalid_email} = Cache.normalize_email("@acme.com")
      assert {:error, :invalid_email} = Cache.normalize_email("a b@acme.com")
      assert {:error, :invalid_email} = Cache.normalize_email("jane@acme@x.com")
    end
  end

  describe "fresh?/1" do
    test "nil is never fresh" do
      refute Cache.fresh?(nil)
    end

    test "an expired row is not fresh" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      refute Cache.fresh?(%{expires_at: past})
    end

    test "a future expiry is fresh" do
      future = DateTime.add(DateTime.utc_now(), 60, :second)
      assert Cache.fresh?(%{expires_at: future})
    end
  end
end
