defmodule CsuiteFinder.AudienceTest do
  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.{Accounts, Audience}

  describe "casting" do
    test "known audiences survive untouched" do
      assert Audience.cast("sales") == "sales"
      assert Audience.cast("developer") == "developer"
      assert Audience.cast(:developer) == "developer"
      assert Audience.cast(" Developer ") == "developer"
    end

    test "anything else becomes sales" do
      # When in doubt, quote the price that is safe to show anybody. This runs
      # on browser-supplied input, so it has to be total.
      for value <- [nil, "", "  ", "dev", "marketing", 42, %{}, [], :wat] do
        assert Audience.cast(value) == "sales", "#{inspect(value)} should fall back to sales"
      end
    end

    test "each audience has a landing page" do
      assert Audience.home("developer") == "/developers"
      assert Audience.home("sales") == "/teams"
      assert Audience.home(nil) == "/teams"
    end
  end

  describe "on an account" do
    test "registering records the audience it was asked for" do
      {:ok, %{account: account}} =
        Accounts.register(%{
          email: "dev#{System.unique_integer([:positive])}@test.com",
          audience: "developer"
        })

      assert account.audience == "developer"
    end

    test "registering without one lands on sales" do
      {:ok, %{account: account}} =
        Accounts.register(%{email: "who#{System.unique_integer([:positive])}@test.com"})

      assert account.audience == "sales"
    end

    test "a nonsense audience does not fail the signup" do
      # Losing a customer over a bad query parameter would be a worse outcome
      # than showing them the wrong price list for a minute.
      {:ok, %{account: account}} =
        Accounts.register(%{
          email: "odd#{System.unique_integer([:positive])}@test.com",
          audience: "gardening"
        })

      assert account.audience == "sales"
    end

    test "an account can move between the two halves" do
      {:ok, %{account: account}} =
        Accounts.register(%{email: "move#{System.unique_integer([:positive])}@test.com"})

      {:ok, account} = Accounts.set_audience(account, "developer")
      assert account.audience == "developer"

      {:ok, account} = Accounts.set_audience(account, "nonsense")
      assert account.audience == "sales"
    end
  end
end
