defmodule CsuiteFinder.AnnualSeatRefreshTest do
  @moduledoc """
  The twelve monthly grants an annual seat is owed.

  A monthly seat grants when its invoice is paid and the two line up. An annual
  seat is invoiced once, so eleven of its twelve grants have no payment to ride
  on. Everything here is about handing those out exactly once each — the failure
  that matters is not a missed grant, which the next hour fixes, but a repeated
  one, which gives away $999.
  """

  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.{Accounts, Billing, Repo}
  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing.{Plans, Subscription, Subscriptions}

  defp account do
    {:ok, account} =
      Accounts.create_account(%{email: "annual#{System.unique_integer([:positive])}@test.com"})

    account
  end

  defp seat(account, attrs \\ %{}) do
    {:ok, subscription} =
      %Subscription{}
      |> Subscription.changeset(
        Map.merge(
          %{
            account_id: account.id,
            provider: "stripe",
            provider_ref: "sub_#{System.unique_integer([:positive])}",
            interval: "year",
            status: "active",
            seats: 1,
            grant_micro_per_period: Plans.seat_grant_micro(),
            current_period_end: DateTime.shift(DateTime.utc_now(), year: 1)
          },
          attrs
        )
      )
      |> Repo.insert()

    subscription
  end

  defp granted(account), do: Repo.get!(Account, account.id) |> Billing.live_grant_micro()

  describe "an annual seat" do
    test "is topped up for the month" do
      acct = account()
      seat(acct)

      assert Subscriptions.refresh_annual_seats() == 1
      assert granted(acct) == Plans.seat_grant_micro()
    end

    test "is not topped up twice in the same month" do
      acct = account()
      seat(acct)

      assert Subscriptions.refresh_annual_seats() == 1
      # The hourly tick, an hour later. Nothing is owed until next month.
      assert Subscriptions.refresh_annual_seats() == 0
      assert granted(acct) == Plans.seat_grant_micro()
    end

    test "is topped up again next month" do
      acct = account()
      sub = seat(acct)

      assert Subscriptions.refresh_annual_seats() == 1

      next = Date.utc_today() |> Date.shift(month: 1)
      assert Subscriptions.refresh_annual_seats(next) == 1

      # Replaced, not stacked. A seat is a month of capacity, not a balance —
      # if these accumulated, a year of unused seat would buy $11,988 of lookups
      # in the final week against one year's revenue.
      assert granted(acct) == Plans.seat_grant_micro()
      assert Repo.get!(Subscription, sub.id).refreshed_for == Date.beginning_of_month(next)
    end

    test "gets its credit dated a month out, not a year" do
      acct = account()
      seat(acct)
      Subscriptions.refresh_annual_seats()

      expires = Repo.get!(Account, acct.id).granted_expires_at
      days = DateTime.diff(expires, DateTime.utc_now(), :day)

      assert days <= 32, "an annual seat was handed a #{days}-day grant"
    end

    test "is never handed credit that outlives the year it paid for" do
      acct = account()
      # Paid up for another fortnight only.
      ends = DateTime.shift(DateTime.utc_now(), day: 14)
      seat(acct, %{current_period_end: ends})

      assert Subscriptions.refresh_annual_seats() == 1

      expires = Repo.get!(Account, acct.id).granted_expires_at
      assert DateTime.compare(expires, ends) in [:lt, :eq]
    end
  end

  describe "what the refresher leaves alone" do
    test "a monthly seat, which its own payment already grants" do
      acct = account()
      seat(acct, %{interval: "month"})

      assert Subscriptions.refresh_annual_seats() == 0
      assert granted(acct) == 0
    end

    test "a cancelled seat" do
      acct = account()
      seat(acct, %{status: "cancelled"})

      assert Subscriptions.refresh_annual_seats() == 0
      assert granted(acct) == 0
    end

    test "a seat whose paid year has run out" do
      acct = account()
      seat(acct, %{current_period_end: DateTime.shift(DateTime.utc_now(), day: -1)})

      assert Subscriptions.refresh_annual_seats() == 0
      assert granted(acct) == 0
    end
  end

  describe "the first month" do
    test "comes from the payment, and the refresher does not add a second" do
      acct = account()
      sub = seat(acct, %{status: "pending", current_period_end: nil})

      {:ok, _} = Subscriptions.record_payment(sub.provider_ref, "in_first", nil)

      assert granted(acct) == Plans.seat_grant_micro()

      # The tick half an hour later must not read the payment's grant as a month
      # still owed.
      assert Subscriptions.refresh_annual_seats() == 0
      assert granted(acct) == Plans.seat_grant_micro()
    end

    test "of an annual seat is a month of credit, not a year of it" do
      acct = account()
      sub = seat(acct, %{status: "pending", current_period_end: nil})

      {:ok, _} = Subscriptions.record_payment(sub.provider_ref, "in_first", nil)

      expires = Repo.get!(Account, acct.id).granted_expires_at
      days = DateTime.diff(expires, DateTime.utc_now(), :day)

      assert days <= 32,
             "a $9,990 payment granted #{days} days of credit in one go, " <>
               "which is the whole year's allowance up front"
    end
  end
end
