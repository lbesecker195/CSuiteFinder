defmodule CsuiteFinder.PricingTest do
  use ExUnit.Case, async: true

  alias CsuiteFinder.Billing.Pricing

  test "a token is $0.0025" do
    assert Pricing.token_price_usd() == 0.0025
    assert Pricing.micro_per_token() == 2_500
  end

  test "a dollar buys 400 tokens" do
    assert Pricing.tokens_for_usd(1) == 400
    assert Pricing.usd_for_tokens(400) == 1.0
  end

  test "the minimum bundle is $1,000 and buys 400,000 tokens" do
    assert Pricing.min_bundle_usd() == 1_000
    assert {:ok, 400_000} = Pricing.validate_bundle(1_000)
  end

  test "bundles above the minimum are accepted" do
    assert {:ok, 1_000_000} = Pricing.validate_bundle(2_500)
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
