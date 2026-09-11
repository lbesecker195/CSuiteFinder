defmodule CsuiteFinder.SubscriptionsTest do
  @moduledoc """
  What a seat subscription does to an account's credit.

  PayPal itself is not exercised here — these are the rules that run *after* it
  tells us money moved, which is where a mistake costs a customer their month.
  """

  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.{Accounts, Billing, Repo}
  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing.{Plans, Pricing, Subscription, Subscriptions}

  defp account do
    {:ok, account} =
      Accounts.create_account(%{email: "seat#{System.unique_integer([:positive])}@test.com"})

    account
  end

  defp subscription(account, attrs \\ %{}) do
    seats = Map.get(attrs, :seats, 1)

    {:ok, subscription} =
      %Subscription{}
      |> Subscription.changeset(
        Map.merge(
          %{
            account_id: account.id,
            provider_ref: "I-#{System.unique_integer([:positive])}",
            seats: seats,
            status: "pending",
            grant_micro_per_period: Plans.seat_grant_micro() * seats
          },
          attrs
        )
      )
      |> Repo.insert()

    subscription
  end

  defp reload(%Account{id: id}), do: Repo.get!(Account, id)

  describe "a payment grants the month" do
    test "one seat grants one seat's credit and marks the subscription active" do
      account = account()
      subscription = subscription(account)

      {:ok, updated} = Subscriptions.record_payment(subscription.provider_ref, "SALE-1")

      assert updated.status == "active"
      assert updated.last_payment_id == "SALE-1"

      account = reload(account)
      assert account.granted_micro == Plans.seat_grant_micro()
      assert Pricing.usd(account.granted_micro) == Plans.seat_usd() / 1
    end

    test "the grant expires, so it cannot be banked" do
      account = account()
      subscription = subscription(account)

      Subscriptions.record_payment(subscription.provider_ref, "SALE-1")
      account = reload(account)

      assert account.granted_expires_at
      assert DateTime.compare(account.granted_expires_at, DateTime.utc_now()) == :gt
      # A month out, not a year.
      assert DateTime.diff(account.granted_expires_at, DateTime.utc_now(), :day) <= 31
    end

    test "seats multiply the grant" do
      account = account()
      subscription = subscription(account, %{seats: 4})

      Subscriptions.record_payment(subscription.provider_ref, "SALE-1")

      assert reload(account).granted_micro == Plans.seat_grant_micro() * 4
    end

    test "PayPal's next billing time is used as the expiry when it sends one" do
      account = account()
      subscription = subscription(account)
      period_end = DateTime.add(DateTime.utc_now(), 20 * 86_400)

      Subscriptions.record_payment(subscription.provider_ref, "SALE-1", period_end)

      assert DateTime.diff(reload(account).granted_expires_at, period_end) == 0
    end
  end

  describe "webhooks that arrive more than once" do
    test "a repeated payment id does not re-grant or re-date the month" do
      # PayPal retries. Re-dating the expiry from a retry would silently extend
      # a month the customer is already halfway through.
      account = account()
      subscription = subscription(account)

      {:ok, first} = Subscriptions.record_payment(subscription.provider_ref, "SALE-1")

      assert {:error, :already_granted} =
               Subscriptions.record_payment(subscription.provider_ref, "SALE-1")

      account = reload(account)
      assert account.granted_micro == Plans.seat_grant_micro()
      assert DateTime.diff(account.granted_expires_at, first.current_period_end) == 0
    end

    test "a new payment replaces the month rather than stacking on it" do
      account = account()
      subscription = subscription(account)

      Subscriptions.record_payment(subscription.provider_ref, "SALE-1")
      # Half the month gets used.
      {:ok, _} =
        Billing.settle(%{
          account: reload(account),
          endpoint: "phone.find",
          found: true,
          units: div(Pricing.micro(400), Pricing.charge_for("phone.find"))
        })

      assert reload(account).granted_micro < Plans.seat_grant_micro()

      Subscriptions.record_payment(subscription.provider_ref, "SALE-2")
      assert reload(account).granted_micro == Plans.seat_grant_micro()
    end

    test "an unknown subscription is reported, not crashed on" do
      assert {:error, :unknown_subscription} = Subscriptions.record_payment("I-nope", "SALE-1")
    end
  end

  describe "purchased credit is untouched" do
    test "a seat grant does not disturb credit the account bought" do
      account = account()
      {:ok, account} = Billing.credit(account, Pricing.micro(2_000))
      subscription = subscription(account)

      Subscriptions.record_payment(subscription.provider_ref, "SALE-1")

      account = reload(account)
      assert account.balance_micro == Pricing.micro(2_000)
      assert Billing.available_micro(account) == Pricing.micro(2_000) + Plans.seat_grant_micro()
    end
  end

  describe "ending a subscription" do
    test "a cancellation does not claw back the month already paid for" do
      account = account()
      subscription = subscription(account)
      Subscriptions.record_payment(subscription.provider_ref, "SALE-1")

      {:ok, cancelled} =
        Subscriptions.set_status(subscription.provider_ref, "CANCELLED")

      assert cancelled.status == "cancelled"
      assert reload(account).granted_micro == Plans.seat_grant_micro()
    end

    test "PayPal's shouted statuses are stored lower-case" do
      account = account()
      subscription = subscription(account)

      for {sent, stored} <- [{"SUSPENDED", "suspended"}, {"EXPIRED", "expired"}] do
        {:ok, updated} = Subscriptions.set_status(subscription.provider_ref, sent)
        assert updated.status == stored
      end
    end

    test "a status we do not recognise is recorded rather than crashing a webhook" do
      account = account()
      subscription = subscription(account)

      {:ok, updated} = Subscriptions.set_status(subscription.provider_ref, "WAT")
      assert updated.status == "pending"
    end
  end

  describe "reading a subscription back" do
    test "for_account returns the newest one" do
      account = account()
      subscription(account)
      newest = subscription(account)

      assert Subscriptions.for_account(account).id == newest.id
    end

    test "an account with no subscription has none" do
      assert Subscriptions.for_account(account()) == nil
    end

    test "next_billing parses PayPal's timestamp and shrugs at anything else" do
      assert %DateTime{} =
               Subscriptions.next_billing(%{
                 "billing_info" => %{"next_billing_time" => "2026-10-09T00:00:00Z"}
               })

      assert Subscriptions.next_billing(%{"billing_info" => %{}}) == nil
      assert Subscriptions.next_billing(%{}) == nil
    end
  end
end
