defmodule CsuiteFinder.PricingTest do
  use ExUnit.Case, async: true

  alias CsuiteFinder.Billing.Pricing

  describe "prices" do
    test "an email address is $0.0025 and a phone number is $0.025" do
      assert Pricing.price_usd("email.find") == 0.0025
      assert Pricing.price_usd("phone.find") == 0.025
    end

    test "a phone costs ten times an address" do
      # Scarcer data, dearer providers, and no pattern to derive it from.
      assert Pricing.charge_for("phone.find") == Pricing.charge_for("email.find") * 10
    end

    test "the per-person sweep routes match their single-lookup equivalents" do
      assert Pricing.charge_for("company.people") == Pricing.charge_for("phone.find")
      assert Pricing.charge_for("email.company.people") == Pricing.charge_for("email.find")
    end

    test "everything else is included" do
      for endpoint <- ~w(email.deliverable email.enrich email.pattern name.who
                         company.info company.find phone.valid) do
        assert Pricing.charge_for(endpoint) == 0, "#{endpoint} should be included"
        refute Pricing.metered?(endpoint)
      end
    end

    test "an unknown endpoint is free rather than guessed at" do
      assert Pricing.charge_for("nope") == 0
    end

    test "only answers are billable" do
      assert Pricing.billable?("email.find", true)
      refute Pricing.billable?("email.find", false)
    end
  end

  describe "money is held as integers" do
    test "micro-USD round-trips" do
      # $0.0025 has no exact binary representation; the integer does.
      assert Pricing.micro(0.0025) == 2_500
      assert Pricing.usd(2_500) == 0.0025
      assert Pricing.usd(Pricing.micro(1_000)) == 1_000.0
    end
  end

  describe "purchases" do
    test "the minimum is $1,000" do
      assert Pricing.min_bundle_usd() == 1_000
      assert {:error, :below_minimum, %{minimum_usd: 1_000}} = Pricing.validate_bundle(500)
    end

    test "a dollar buys a dollar of credit, at every size" do
      # No volume tier. Whatever is paid is what is credited, so the purchase
      # page and the capture path cannot quote different numbers.
      for usd <- [1_000, 1_500, 2_000, 3_000, 6_000, 10_000] do
        assert Pricing.credit_for_purchase(usd) == Pricing.micro(usd)
      end
    end

    test "the amounts offered are $1,000, $2,000 and $3,000" do
      assert Enum.map(Pricing.bundles(), & &1.usd) == [1_000, 2_000, 3_000]
      assert Enum.all?(Pricing.bundles(), &(&1.credit_usd == &1.usd))
    end

    test "each says what it buys in things customers care about" do
      [smallest | _] = Pricing.bundles()

      assert smallest.usd == 1_000
      assert smallest.emails == 400_000
      assert smallest.phones == 40_000
    end
  end

  describe "the free trial" do
    test "is $1 of real credit" do
      assert Pricing.trial_usd() == 1.0
      assert Pricing.trial_micro() == 1_000_000
    end

    test "buys 400 email lookups" do
      assert div(Pricing.trial_micro(), Pricing.charge_for("email.find")) == 400
    end
  end

  describe "terms/0" do
    test "publishes dollars, with no token vocabulary left" do
      terms = Pricing.terms()

      assert terms.currency == "USD"
      assert terms.prices_usd["phone.find"] == 0.025
      assert terms.free_trial_usd == 1.0
      refute Jason.encode!(terms) =~ "token"
    end
  end
end
