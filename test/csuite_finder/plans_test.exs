defmodule CsuiteFinder.PlansTest do
  use ExUnit.Case, async: true

  alias CsuiteFinder.Billing.{Plans, Pricing}

  describe "a seat" do
    test "grants exactly what it costs" do
      # $999 buys $999 of credit. Any other ratio is a number a buyer will work
      # out for themselves and hold against us.
      assert Plans.seat_grant_micro() == Plans.seat_micro()
      assert Pricing.usd(Plans.seat_grant_micro()) == Plans.seat_usd() / 1
    end

    test "its credit lasts a month" do
      from = ~U[2026-01-15 12:00:00.000000Z]
      assert Plans.seat_grant_expires_at(from) == ~U[2026-02-15 12:00:00.000000Z]
    end

    test "the page copy states the expiry rather than burying it" do
      caveats = Enum.join(Plans.seat().caveats, " ")

      assert caveats =~ "does not roll over"
      assert caveats =~ "never expires"
    end

    test "what it buys is derived from the live prices" do
      lookups = Plans.seat_lookups()

      assert lookups.emails == div(Plans.seat_micro(), Pricing.charge_for("email.find"))
      assert lookups.phones == div(Plans.seat_micro(), Pricing.charge_for("phone.find"))
    end

    test "the comparison table is honest about the per-lookup price being the same" do
      row = Enum.find(Plans.comparison(), &(&1.question == "What a lookup costs"))
      assert row.seat =~ "The same"

      expiry = Enum.find(Plans.comparison(), &(&1.question == "When it expires"))
      assert expiry.seat =~ "does not roll over"
      assert expiry.credit == "Never"
    end
  end

  describe "the free trial" do
    test "is bought rather than given, and it expires" do
      assert Pricing.trial_usd() == 29.99
      assert Pricing.trial_months() == 1
    end

    test "expires a month after it is granted" do
      from = ~U[2026-03-31 09:00:00.000000Z]
      # A month from the 31st lands on the last day of the shorter month rather
      # than overflowing into May.
      assert Pricing.trial_expires_at(from) == ~U[2026-04-30 09:00:00.000000Z]
    end
  end
end
