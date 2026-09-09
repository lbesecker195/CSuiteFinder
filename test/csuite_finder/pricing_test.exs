defmodule CsuiteFinder.PricingTest do
  use ExUnit.Case, async: true

  alias CsuiteFinder.Billing.Pricing

  test "a token is $0.0025" do
    assert Pricing.token_price_usd() == 0.0025
    assert Pricing.micro_per_token() == 2_500
  end

  test "a dollar is worth 400 tokens at list price" do
    assert Pricing.tokens_for_usd(1) == 400
    assert Pricing.usd_for_tokens(400) == 1.0
  end

  test "the minimum bundle is $1,000 and buys 400,000 tokens" do
    assert Pricing.min_bundle_usd() == 1_000
    assert {:ok, 400_000} = Pricing.validate_bundle(1_000)
  end

  describe "volume tiers" do
    test "the offered bundles are $1k/400k, $2k/1M and $3k/1.5M" do
      assert [
               %{usd: 1_000, tokens: 400_000},
               %{usd: 2_000, tokens: 1_000_000},
               %{usd: 3_000, tokens: 1_500_000}
             ] = Enum.map(Pricing.bundles(), &Map.take(&1, [:usd, :tokens]))
    end

    test "$2,000 and above is priced at $0.002 a token" do
      assert Pricing.tokens_for_purchase(2_000) == 1_000_000
      assert Pricing.tokens_for_purchase(3_000) == 1_500_000
      assert Pricing.tokens_for_purchase(5_000) == 2_500_000
    end

    test "below $2,000 stays at the $0.0025 list rate" do
      assert Pricing.tokens_for_purchase(1_000) == 400_000
      assert Pricing.tokens_for_purchase(1_500) == 600_000
    end

    test "more money never buys fewer tokens" do
      amounts = [1_000, 1_500, 1_999, 2_000, 2_500, 3_000, 10_000]
      tokens = Enum.map(amounts, &Pricing.tokens_for_purchase/1)
      assert tokens == Enum.sort(tokens)
    end

    test "a purchase is credited at the tier, not the list rate" do
      # The bug this guards: crediting $2,000 through the flat list rate would
      # hand over 800,000 tokens instead of the 1,000,000 that was quoted.
      assert Pricing.tokens_for_purchase(2_000) > Pricing.tokens_for_usd(2_000)
      assert {:ok, 1_000_000} = Pricing.validate_bundle(2_000)
    end
  end

  test "a purchase under the minimum is refused with the terms" do
    assert {:error, :below_minimum, details} = Pricing.validate_bundle(50)
    assert details.minimum_usd == 1_000
    assert details.requested_usd == 50
  end

  test "the free trial is $1 of tokens, which is 400 emails" do
    assert Pricing.trial_tokens() == 400
    assert Pricing.usd_for_tokens(Pricing.trial_tokens()) == 1.0
    assert div(Pricing.trial_tokens(), Pricing.charge_for("email.find")) == 400
  end

  test "a found email costs one token" do
    assert Pricing.charge_for("email.find") == 1
    assert Pricing.usd_for_tokens(1) == 0.0025
    assert Pricing.metered?("email.find")
  end

  test "every other endpoint is included" do
    for endpoint <- ~w(email.deliverable email.enrich email.pattern name.who company.info) do
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
