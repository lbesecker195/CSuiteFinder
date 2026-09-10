defmodule CsuiteFinder.GrantedCreditTest do
  @moduledoc """
  Credit has two lifetimes, and the rules that keep them apart.

  A seat's monthly allowance and the free trial expire; anything bought outright
  does not. Getting the order of spending wrong, or the expiry check wrong, takes
  money from a customer — so each rule gets its own test.
  """

  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.{Accounts, Billing, Repo}
  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing.{Plans, Pricing}

  defp account(attrs \\ %{}) do
    {:ok, account} =
      Accounts.create_account(
        Map.merge(%{email: "grant#{System.unique_integer([:positive])}@test.com"}, attrs)
      )

    account
  end

  defp reload(%Account{id: id}), do: Repo.get!(Account, id)

  defp spend(account, micro) do
    {:ok, event} =
      Billing.settle(%{
        account: account,
        endpoint: "phone.find",
        found: true,
        units: div(micro, Pricing.charge_for("phone.find"))
      })

    event
  end

  describe "what an account can spend" do
    test "a live grant counts towards the balance" do
      account =
        account()
        |> Billing.grant(Pricing.micro(5), DateTime.add(DateTime.utc_now(), 3600))
        |> elem(1)

      assert Billing.available_micro(account) == Pricing.micro(5)
      assert Billing.ensure_funds(account, "phone.find") == :ok
    end

    test "an expired grant counts for nothing" do
      account =
        account()
        |> Billing.grant(Pricing.micro(5), DateTime.add(DateTime.utc_now(), -1))
        |> elem(1)

      assert Billing.available_micro(account) == 0
      assert Billing.live_grant_micro(account) == 0

      assert {:error, :insufficient_credit, details} =
               Billing.ensure_funds(account, "phone.find")

      assert details.reason == "no_balance"
    end

    test "a grant with no expiry is open-ended" do
      account = account() |> Billing.grant(Pricing.micro(5), nil) |> elem(1)
      assert Billing.available_micro(account) == Pricing.micro(5)
    end

    test "the two pools add up" do
      account = account()
      {:ok, account} = Billing.credit(account, Pricing.micro(2))
      {:ok, account} = Billing.grant(account, Pricing.micro(3), Plans.seat_grant_expires_at())

      assert Billing.available_micro(account) == Pricing.micro(5)

      balances = Billing.balances(account)
      assert balances.available_usd == 5.0
      assert balances.purchased_usd == 2.0
      assert balances.granted_usd == 3.0
      assert balances.granted_expires_at
    end
  end

  describe "spending order" do
    test "granted credit is spent before purchased credit" do
      # The whole point: granted credit has a deadline, so spending it first is
      # the only order that never destroys value the customer paid for.
      account = account()
      {:ok, account} = Billing.credit(account, Pricing.micro(1))
      {:ok, account} = Billing.grant(account, Pricing.micro(1), Plans.seat_grant_expires_at())

      spend(account, Pricing.micro(1))
      account = reload(account)

      assert account.granted_micro == 0
      assert account.balance_micro == Pricing.micro(1)
    end

    test "a spend larger than the grant takes the remainder from the purchase" do
      account = account()
      {:ok, account} = Billing.credit(account, Pricing.micro(10))
      {:ok, account} = Billing.grant(account, Pricing.micro(4), Plans.seat_grant_expires_at())

      spend(account, Pricing.micro(6))
      account = reload(account)

      assert account.granted_micro == 0
      assert account.balance_micro == Pricing.micro(8)
    end

    test "an expired grant is not spent, and does not subsidise a spend" do
      account = account()
      {:ok, account} = Billing.credit(account, Pricing.micro(10))

      {:ok, account} =
        Billing.grant(account, Pricing.micro(4), DateTime.add(DateTime.utc_now(), -1))

      spend(account, Pricing.micro(4))
      account = reload(account)

      # The lapsed 4 is still in the column and still worth nothing; the whole
      # charge came out of what was bought.
      assert account.granted_micro == Pricing.micro(4)
      assert account.balance_micro == Pricing.micro(6)
      assert Billing.available_micro(account) == Pricing.micro(6)
    end

    test "purchased credit survives the grant expiring" do
      account = account()
      {:ok, account} = Billing.credit(account, Pricing.micro(50))

      {:ok, account} =
        Billing.grant(account, Pricing.micro(999), DateTime.add(DateTime.utc_now(), 1))

      Process.sleep(1_100)
      account = reload(account)

      assert Billing.live_grant_micro(account) == 0
      assert Billing.available_micro(account) == Pricing.micro(50)
      assert Billing.ensure_funds(account, "phone.find") == :ok
    end

    test "an account cannot overdraw across both pools" do
      account = account()
      {:ok, account} = Billing.credit(account, Pricing.micro(1))
      {:ok, account} = Billing.grant(account, Pricing.micro(1), Plans.seat_grant_expires_at())

      # Ask for three dollars' worth against two dollars of credit.
      {:ok, event} =
        Billing.settle(%{
          account: account,
          endpoint: "phone.find",
          found: true,
          units: div(Pricing.micro(3), Pricing.charge_for("phone.find"))
        })

      assert event.charged_micro == 0
      account = reload(account)
      assert account.balance_micro == Pricing.micro(1)
      assert account.granted_micro == Pricing.micro(1)
    end
  end

  describe "grants do not roll over" do
    test "a second grant replaces the first rather than adding to it" do
      account = account()

      {:ok, account} =
        Billing.grant(account, Plans.seat_grant_micro(), Plans.seat_grant_expires_at())

      {:ok, account} =
        Billing.grant(account, Plans.seat_grant_micro(), Plans.seat_grant_expires_at())

      assert account.granted_micro == Plans.seat_grant_micro()
    end

    test "an unspent month does not carry into the next one" do
      account = account()
      {:ok, account} = Billing.grant(account, Pricing.micro(999), Plans.seat_grant_expires_at())

      spend(account, Pricing.micro(9))
      account = reload(account)
      assert account.granted_micro == Pricing.micro(990)

      # Next month's payment.
      {:ok, account} = Billing.grant(account, Pricing.micro(999), Plans.seat_grant_expires_at())
      assert account.granted_micro == Pricing.micro(999)
    end

    test "renewing a grant leaves purchased credit alone" do
      account = account()
      {:ok, account} = Billing.credit(account, Pricing.micro(2_000))
      {:ok, account} = Billing.grant(account, Pricing.micro(999), Plans.seat_grant_expires_at())

      assert account.balance_micro == Pricing.micro(2_000)
      assert Billing.available_micro(account) == Pricing.micro(2_999)
    end
  end

  describe "the free trial" do
    test "registering grants nothing at all" do
      # There is no free tier. An account starts empty and stays empty until a
      # trial is bought, which is the point of removing the free one.
      {:ok, %{account: account}} =
        Accounts.register(%{
          email: "trial#{System.unique_integer([:positive])}@test.com",
          audience: "developer"
        })

      assert account.balance_micro == 0
      assert account.granted_micro == 0
      assert account.granted_expires_at == nil
      assert account.trial_granted_at == nil
    end

    test "a bought trial is spendable while it lasts and worthless after" do
      {:ok, %{account: account}} =
        Accounts.register(%{
          email: "trial#{System.unique_integer([:positive])}@test.com",
          audience: "developer"
        })

      # Empty until paid for.
      assert {:error, :insufficient_credit, _} = Billing.ensure_funds(account, "email.find")

      {:ok, account} =
        Billing.grant(account, Pricing.trial_micro(), Pricing.trial_expires_at())

      assert Billing.ensure_funds(account, "email.find") == :ok

      expired = %{account | granted_expires_at: DateTime.add(DateTime.utc_now(), -1)}
      assert {:error, :insufficient_credit, _} = Billing.ensure_funds(expired, "email.find")
    end
  end
end
