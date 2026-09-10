defmodule CsuiteFinder.DurableCacheTest do
  @moduledoc """
  The cache keeps its last known value forever: TTLs decide when we look again,
  never whether we still hold the answer.
  """

  use CsuiteFinder.DataCase, async: true

  import Ecto.Query

  alias CsuiteFinder.Cache.{EmailPattern, PersonEnrichment}
  alias CsuiteFinder.{Companies, PatternStore, People, Repo, TregStub, Verifier}

  defp expire!(schema) do
    past = DateTime.add(DateTime.utc_now(), -1, :day)
    Repo.update_all(from(r in schema), set: [expires_at: past])
  end

  describe "a refresh that finds nothing keeps the old value" do
    test "email patterns survive a provider going empty" do
      TregStub.stub(fn
        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}

        "thecompaniesapi.companies.email_pattern", _ ->
          {200, %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}, 1_900}
      end)

      {:ok, first, _} = PatternStore.get_or_fetch("acme.com")
      assert first.pattern == "{first}.{last}"

      expire!(EmailPattern)

      TregStub.stub(fn
        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}

        "thecompaniesapi.companies.email_pattern", _ ->
          {200, %{"patterns" => []}, 1_900}
      end)

      {:ok, second, _} = PatternStore.get_or_fetch("acme.com")

      # The known pattern is still here, and is now flagged as unconfirmed.
      assert second.pattern == "{first}.{last}"
      assert second.found
      assert second.refresh_failures == 1
      assert second.last_found_at
      assert CsuiteFinder.Cache.stale?(second)
    end

    test "a failed refresh backs off instead of re-asking every request" do
      TregStub.stub(fn
        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}

        "thecompaniesapi.companies.email_pattern", _ ->
          {200, %{"patterns" => [%{"pattern" => "[F]", "usagePercentage" => 90.0}]}, 1_900}
      end)

      PatternStore.get_or_fetch("acme.com")
      expire!(EmailPattern)

      TregStub.stub(fn
        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}

        "thecompaniesapi.companies.email_pattern", _ ->
          {200, %{"patterns" => []}, 1_900}
      end)

      PatternStore.get_or_fetch("acme.com")
      calls = TregStub.call_count()

      # Still inside the backoff window: served from the retained value.
      {:ok, row, lookup} = PatternStore.get_or_fetch("acme.com")
      assert row.pattern == "{first}"
      assert lookup.cached
      assert TregStub.call_count() == calls
    end

    test "verifications keep their last verdict when the verifier goes dark" do
      TregStub.stub(fn "treg.people.email.verify", _ ->
        {200, TregStub.routed(%{"valid" => true, "status" => "valid"}), 1_500}
      end)

      {:ok, first, _} = Verifier.verify("jane@acme.com")
      assert first.status == "deliverable"

      expire!(CsuiteFinder.Cache.EmailVerification)
      TregStub.stub(fn "treg.people.email.verify", _ -> {500, %{"error" => "down"}, 0} end)

      {:ok, second, _} = Verifier.verify("jane@acme.com")

      assert second.status == "deliverable"
      assert second.refresh_failures == 1
    end

    test "company profiles survive an empty refresh" do
      TregStub.stub(fn "treg.companies.enrich", _ ->
        {200, TregStub.routed(%{"name" => "Acme Inc", "employee_count" => 500}), 1_900}
      end)

      {:ok, first, _} = Companies.info("acme.com")
      assert first.name == "Acme Inc"

      expire!(CsuiteFinder.Cache.CompanyProfile)
      TregStub.stub(fn "treg.companies.enrich", _ -> {200, %{"output" => nil}, 0} end)

      {:ok, second, _} = Companies.info("acme.com")
      assert second.name == "Acme Inc"
      assert second.employee_count == 500
    end
  end

  describe "an inferred guess never displaces real data" do
    test "a provider record survives a missed refresh" do
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200, TregStub.routed(%{"full_name" => "Jane Doe", "title" => "CTO"}), 4_900}
      end)

      {:ok, first, _} = People.enrich("jane.doe@acme.com")
      assert first.source == "provider"
      assert first.position == "CTO"

      expire!(PersonEnrichment)
      TregStub.stub(fn "treg.people.enrich", _ -> {200, %{"output" => nil}, 0} end)

      {:ok, second, _} = People.enrich("jane.doe@acme.com")

      # The inference would have produced "Jane Doe" with no title and
      # source "inferred". The real record wins.
      assert second.source == "provider"
      assert second.position == "CTO"
      assert second.refresh_failures == 1
    end

    test "an inference is still stored when there is nothing to protect" do
      TregStub.stub(fn "treg.people.enrich", _ -> {200, %{"output" => nil}, 0} end)

      {:ok, row, _} = People.enrich("sam.poe@acme.com")

      assert row.source == "inferred"
      assert row.full_name == "Sam Poe"
      refute row.last_found_at
    end

    test "a later provider answer replaces the earlier guess" do
      TregStub.stub(fn "treg.people.enrich", _ -> {200, %{"output" => nil}, 0} end)
      {:ok, guess, _} = People.enrich("sam.poe@acme.com")
      assert guess.source == "inferred"

      expire!(PersonEnrichment)

      TregStub.stub(fn "treg.people.enrich", _ ->
        {200, TregStub.routed(%{"full_name" => "Samuel Poe", "title" => "CFO"}), 4_900}
      end)

      {:ok, real, _} = People.enrich("sam.poe@acme.com")
      assert real.source == "provider"
      assert real.full_name == "Samuel Poe"
      assert real.refresh_failures == 0
    end
  end
end
