defmodule CsuiteFinder.Ssa.ThrottleTest do
  @moduledoc """
  Batching, because the service asks for it and cannot enforce it.

  Their endpoint returns 204 whatever you send, so a caller that ignores the
  rate guidance never finds out. That makes this our job rather than theirs: one
  ping every ten seconds carrying totals, not one per billable request.
  """

  use ExUnit.Case, async: false

  alias CsuiteFinder.Ssa.Throttle

  setup do
    # Flush whatever a previous test left behind, so counts start at zero.
    Throttle.flush()
    :ok
  end

  describe "a batch" do
    test "adds up the interval rather than sending each call" do
      for _ <- 1..5, do: Throttle.record("email.find", true, false, 1)
      Throttle.record("email.find", false, true, 3)

      sent = Throttle.flush()

      assert sent.calls == 6
      assert sent.units == 8
      assert sent.found == 5
      assert sent.cached == 1
    end

    test "labels the interval with its busiest endpoint" do
      for _ <- 1..3, do: Throttle.record("company.people", true, false, 1)
      Throttle.record("email.find", true, false, 1)

      assert Throttle.flush().endpoint == "company.people"
    end

    test "and says nothing at all when nothing happened" do
      # An idle service should be silent. Reporting zero every ten seconds fills
      # a dashboard with the absence of news.
      assert Throttle.flush() == %{}
    end
  end

  describe "recording" do
    test "never raises, and never blocks the caller" do
      # This sits inside Billing.settle/1, on the path of a paid lookup. It has
      # to be incapable of failing that request.
      assert Throttle.record("email.find", true, false, 1) == :ok
      assert Throttle.record("email.find", true, false, 1_000_000) == :ok
    end

    test "and the process survives nonsense" do
      Throttle.record("", false, false, 1)
      Throttle.flush()

      assert Process.alive?(Process.whereis(Throttle))
    end
  end
end
