defmodule CsuiteFinder.CostModelTest do
  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.CostModel

  describe "difficulty weighting" do
    test "a hit after prior failures counts for more than an easy hit" do
      CostModel.record_attempt("cap", "easy", true, prior_failures: 0, cost_micro: 1_000)
      CostModel.record_attempt("cap", "hard", true, prior_failures: 3, cost_micro: 1_000)

      %{weighted_hit_rate: easy} = by_provider("cap", "easy")
      %{weighted_hit_rate: hard} = by_provider("cap", "hard")

      # Same raw record (1 for 1), but the late hit carries more evidence.
      assert hard > easy
    end

    test "records the whole waterfall from a treg response" do
      tried = [
        %{"endpoint_id" => "a", "outcome" => "miss", "charged_micro" => 0},
        %{"endpoint_id" => "b", "outcome" => "miss", "charged_micro" => 0},
        %{"endpoint_id" => "c", "outcome" => "hit", "charged_micro" => 5_000}
      ]

      CostModel.record_waterfall("people.email.find", tried)

      assert %{hits: 0, attempts: 1} = by_provider("people.email.find", "a")
      assert %{hits: 1, attempts: 1} = by_provider("people.email.find", "c")

      # "c" answered what two others could not, so its hit is weighted 3x.
      assert by_provider("people.email.find", "c").weighted_hit_rate > 0.7
    end
  end

  describe "ranking" do
    test "orders by what an answer actually cost, so a cheap miss is still cheap" do
      # Cheap and often misses. A miss on a per-success provider is free, so
      # asking it first costs nothing but a round trip — we simply fall through.
      for _ <- 1..9, do: CostModel.record_attempt("cap", "cheap", false, cost_micro: 0)
      CostModel.record_attempt("cap", "cheap", true, cost_micro: 1_000)

      # Pricier but reliable.
      for _ <- 1..10, do: CostModel.record_attempt("cap", "solid", true, cost_micro: 5_000)

      assert [first, second] = CostModel.ranked("cap")
      assert first.provider == "cheap"
      assert second.provider == "solid"
      assert first.cost_micro_per_hit < second.cost_micro_per_hit

      # Worth the arithmetic, because the old order looked defensible:
      # cheap first  = 0.1 * $0.001 + 0.9 * (0.92 * $0.005) = $0.00424
      # solid first  = 0.92 * $0.005 + 0.08 * (0.1 * $0.001) = $0.00461
      # Dividing cost per hit by the hit rate charged `cheap` twice for the
      # same weakness and sent every lookup to the dearer provider first.
    end

    test "a provider that bills for its misses is penalised without any correction" do
      # Per-call billing pays on a miss, and those payments are already inside
      # cost per hit — total spent over answers received. No second adjustment
      # is needed, and applying one would double count.
      for _ <- 1..8, do: CostModel.record_attempt("cap", "per_call", false, cost_micro: 2_000)
      for _ <- 1..2, do: CostModel.record_attempt("cap", "per_call", true, cost_micro: 2_000)

      for _ <- 1..10, do: CostModel.record_attempt("cap", "per_success", true, cost_micro: 5_000)

      assert [first, second] = CostModel.ranked("cap")
      assert first.provider == "per_success"
      # $0.002 a call, ten calls, two answers — $0.01 an answer, not $0.002.
      assert second.cost_micro_per_hit == 10_000.0
    end

    test "a provider that has never hit ranks last, not first" do
      # Regression: per-success providers bill nothing on a miss, so a provider
      # that always misses has spent $0 — naive cost/hit arithmetic reads that
      # as free and would rank it above everything that works. Its cost is a
      # guess rather than a measurement, and a guess does not outrank evidence.
      for _ <- 1..20, do: CostModel.record_attempt("cap", "broken", false, cost_micro: 0)
      CostModel.record_attempt("cap", "works", true, cost_micro: 9_000)

      assert [first | _] = ranked = CostModel.ranked("cap")
      assert first.provider == "works"
      assert List.last(ranked).provider == "broken"
      assert List.last(ranked).cost_is_estimated
    end

    test "smoothing keeps a lucky single sample from beating a long record" do
      CostModel.record_attempt("cap", "newcomer", true, cost_micro: 1_000)

      for _ <- 1..50, do: CostModel.record_attempt("cap", "veteran", true, cost_micro: 1_000)

      veteran = by_provider("cap", "veteran")
      newcomer = by_provider("cap", "newcomer")

      assert newcomer.raw_hit_rate == veteran.raw_hit_rate
      assert veteran.weighted_hit_rate > newcomer.weighted_hit_rate
    end
  end

  describe "expected_cost_micro/1" do
    test "discounts later providers by the chance of reaching them" do
      for _ <- 1..10, do: CostModel.record_attempt("cap", "first", true, cost_micro: 2_000)
      for _ <- 1..10, do: CostModel.record_attempt("cap", "second", true, cost_micro: 50_000)

      # The expensive provider is only reached when the first one misses, so the
      # blended estimate stays near the cheap one rather than averaging the two.
      assert CostModel.expected_cost_micro("cap") < 26_000
    end

    test "is zero for a capability we have never called" do
      assert CostModel.expected_cost_micro("never.called") == 0.0
    end
  end

  defp by_provider(capability, provider) do
    capability |> CostModel.ranked() |> Enum.find(&(&1.provider == provider))
  end
end
