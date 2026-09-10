defmodule CsuiteFinder.VerificationLearningTest do
  @moduledoc """
  What a customer's own deliverability check teaches us.

  We never verify an address we generate — checking every one would cost more
  than the address sells for. But a customer checking one before they send it
  is going to happen anyway, and it tells us the same thing for free. These
  tests are about making sure that free signal is actually banked.
  """

  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.{Finder, PatternStore, TregStub, Verifier}

  defp one_pattern, do: %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}

  defp two_patterns do
    %{
      "patterns" => [
        %{"pattern" => "[F].[L]", "usagePercentage" => 55.0},
        %{"pattern" => "[F1][L]", "usagePercentage" => 45.0}
      ]
    }
  end

  defp stub(patterns, verdict) do
    TregStub.stub(fn
      "thecompaniesapi.companies.email_pattern", _ ->
        {200, patterns, 1_900}

      "treg.people.email.verify", %{"email" => email} ->
        {200, TregStub.routed(verdict.(email), cost: 1_500), 1_500}

      "treg.people.email.find", _ ->
        {200, TregStub.routed(%{"email" => "bought@acme.com"}, cost: 5_000), 5_000}
    end)
  end

  describe "finding an address" do
    test "never spends a check of its own" do
      # The whole business model in one assertion: one call for the format, and
      # nothing else. A generated address goes back unverified.
      stub(one_pattern(), fn _ -> %{"valid" => true, "status" => "valid"} end)

      {:ok, result} = Finder.find("Jane Doe", "acme.com")

      assert result.email == "jane.doe@acme.com"
      assert TregStub.call_count() == 1
      assert Finder.cached_row("jane doe", "acme.com").provider_cost_micro == 1_900
    end
  end

  describe "when the customer checks one" do
    test "a confirmed address marks the format as landing on that domain" do
      stub(one_pattern(), fn _ -> %{"valid" => true, "status" => "valid"} end)
      {:ok, _} = Finder.find("Jane Doe", "acme.com")

      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")

      [ratio] = PatternStore.ratios("acme.com")
      assert ratio.pattern == "{first}.{last}"
      assert ratio.deliverable == 1
      assert ratio.share == 1.0
      assert Finder.cached_row("jane doe", "acme.com").verification_status == "deliverable"
    end

    test "a rejected address marks the format against, and the person for retry" do
      stub(one_pattern(), fn _ -> %{"valid" => false, "status" => "invalid"} end)
      {:ok, _} = Finder.find("Jane Doe", "acme.com")

      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")

      [ratio] = PatternStore.ratios("acme.com")
      assert ratio.undeliverable == 1
      assert ratio.share == 0.0

      row = Finder.cached_row("jane doe", "acme.com")
      assert row.verification_status == "undeliverable"
      assert "jane.doe@acme.com" in row.rejected
    end

    test "a catch-all domain teaches nothing about the format, and says so" do
      # Every address is accepted there, so a "deliverable" is true of every
      # candidate equally. Recording it would poison the ranking.
      stub(one_pattern(), fn _ ->
        %{"valid" => true, "status" => "accept_all", "catch_all" => true}
      end)

      {:ok, _} = Finder.find("Jane Doe", "acme.com")
      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")

      assert PatternStore.ratios("acme.com") == []
      assert PatternStore.catch_all?("acme.com")
      assert Finder.cached_row("jane doe", "acme.com").verification_status == "accept_all"
    end

    test "an address we never generated is checked without teaching anything" do
      # No cached person means no name, and without a name there is no format to
      # derive. The check still answers the caller.
      stub(one_pattern(), fn _ -> %{"valid" => true, "status" => "valid"} end)

      {:ok, row, _} = Verifier.verify("someone@elsewhere.example")

      assert row.status == "deliverable"
      assert PatternStore.ratios("elsewhere.example") == []
    end
  end

  describe "what the ratios then do" do
    test "rank the formats for everyone else at that company" do
      # first.last is the provider's favourite. A customer's check proves it
      # wrong, and the next person at that company is built the other way.
      stub(two_patterns(), fn
        "jane.doe@acme.com" -> %{"valid" => false, "status" => "invalid"}
        _ -> %{"valid" => true, "status" => "valid"}
      end)

      {:ok, first} = Finder.find("Jane Doe", "acme.com")
      assert first.email == "jane.doe@acme.com"

      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")

      {:ok, second} = Finder.find("Sam Roe", "acme.com")
      assert second.email == "sroe@acme.com", "the disproved format was used again"
    end

    test "are reported on /email/pattern once there is evidence" do
      stub(one_pattern(), fn _ -> %{"valid" => true, "status" => "valid"} end)
      {:ok, _} = Finder.find("Jane Doe", "acme.com")

      {:ok, before, _} = PatternStore.for_email("jane.doe@acme.com")
      assert before.delivery == []

      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")

      {:ok, after_check, _} = PatternStore.for_email("jane.doe@acme.com")
      assert [%{pattern: "{first}.{last}", deliverable: 1}] = after_check.delivery
    end
  end
end
