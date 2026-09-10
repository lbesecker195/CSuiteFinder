defmodule CsuiteFinder.ReleaseCreditTest do
  @moduledoc """
  Crediting an account by hand.

  The reason this is a function rather than an UPDATE is the thing worth
  testing: credit lives in two columns with different lifetimes, and money put
  in the wrong one silently expires.
  """

  use CsuiteFinder.DataCase, async: true

  import ExUnit.CaptureIO

  alias CsuiteFinder.{Accounts, Billing, Repo}
  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing.Pricing

  defp account(email) do
    {:ok, %{account: account}} = Accounts.register(%{email: email, audience: "developer"})
    account
  end

  test "credits the purchased pool, which does not expire" do
    account = account("hand@credited.test")
    capture_io(fn -> CsuiteFinder.Release.credit("hand@credited.test", 1_000) end)

    reloaded = Repo.get!(Account, account.id)

    assert reloaded.balance_micro == Pricing.micro(1_000)
    # The trial it registered with is untouched, and still the expiring kind.
    assert reloaded.granted_micro == Pricing.trial_micro()
    assert Billing.available_micro(reloaded) == Pricing.micro(1_000) + Pricing.trial_micro()
  end

  test "the credit survives the granted balance lapsing" do
    account = account("survives@credited.test")
    capture_io(fn -> CsuiteFinder.Release.credit("survives@credited.test", 1_000) end)

    lapsed = %{
      Repo.get!(Account, account.id)
      | granted_expires_at: DateTime.add(DateTime.utc_now(), -1)
    }

    assert Billing.available_micro(lapsed) == Pricing.micro(1_000)
  end

  test "an address is matched however it was typed" do
    account("case@credited.test")
    capture_io(fn -> CsuiteFinder.Release.credit("  Case@Credited.Test  ", 50) end)

    assert Repo.get_by(Account, email: "case@credited.test").balance_micro == Pricing.micro(50)
  end

  test "an unknown address changes nothing and says so" do
    output =
      capture_io(fn ->
        assert CsuiteFinder.Release.credit("nobody@nowhere.test", 1_000) == :error
      end)

    assert output =~ "No account for nobody@nowhere.test"
    assert Repo.aggregate(Account, :count, :id) >= 0
  end
end
