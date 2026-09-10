defmodule CsuiteFinder.InferredTitleTest do
  @moduledoc """
  Where the model fallback meets the two contexts that use it.

  The thing worth testing is not that it works — it is that a guess never comes
  back wearing a provider's clothes.
  """

  use CsuiteFinder.DataCase, async: false

  alias CsuiteFinder.{Inference, InferenceStub, PatternStore, People, TregStub}

  setup do
    on_exit(fn ->
      InferenceStub.reset()

      Application.put_env(
        :csuite_finder,
        Inference,
        Keyword.put(Application.get_env(:csuite_finder, Inference, []), :api_key, nil)
      )
    end)
  end

  describe "a job title the provider did not give us" do
    test "is filled in and marked as inferred" do
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200, %{"output" => %{"full_name" => "Jane Doe", "company_name" => "Acme"}}, 4_000}
      end)

      InferenceStub.stub("CFO")

      {:ok, row, _} = People.enrich("jane.doe@acme.com")

      assert row.position == "CFO"
      assert row.position_source == "inferred"
    end

    test "never overwrites a title the provider did give us" do
      # A provider's stated position is evidence. A model's is a guess, and the
      # guess does not get to win.
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200, %{"output" => %{"full_name" => "Jane Doe", "position" => "Head of Platform"}},
         4_000}
      end)

      InferenceStub.stub("CFO")

      {:ok, row, _} = People.enrich("jane.doe@acme.com")

      assert row.position == "Head of Platform"
      assert row.position_source == "provider"
    end

    test "the caller is told the title is a guess" do
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200, %{"output" => %{"full_name" => "Jane Doe"}}, 4_000}
      end)

      InferenceStub.stub("CEO")
      {:ok, row, lookup} = People.enrich("jane.doe@acme.com")

      assert People.present(row, lookup).position_inferred == true
    end

    test "and told when it is not" do
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200, %{"output" => %{"full_name" => "Jane Doe", "position" => "CTO"}}, 4_000}
      end)

      {:ok, row, lookup} = People.enrich("jane.doe@acme.com")
      assert People.present(row, lookup).position_inferred == false
    end

    test "an unavailable model leaves the row exactly as the provider left it" do
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200, %{"output" => %{"full_name" => "Jane Doe"}}, 4_000}
      end)

      {:ok, row, _} = People.enrich("jane.doe@acme.com")

      assert row.position == nil
      assert row.full_name == "Jane Doe"
    end

    test "what the question cost is added to what the lookup cost" do
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200, %{"output" => %{"full_name" => "Jane Doe"}}, 4_000}
      end)

      InferenceStub.stub("CFO")
      {:ok, row, _} = People.enrich("jane.doe@acme.com")

      # The provider's 4,000 plus the model's own tokens, so the margin the
      # dashboard reports stays true.
      assert row.provider_cost_micro > 4_000
    end
  end

  describe "an email pattern nobody sells" do
    test "is inferred, stored and marked" do
      TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => []}, 1_900}
      end)

      InferenceStub.stub("{first}.{last}")

      {:ok, row, _} = PatternStore.get_or_fetch("nowhere-ltd.example")

      assert row.found
      assert row.pattern == "{first}.{last}"
      assert row.source == "inferred"
    end

    test "carries a confidence that says it is a guess" do
      TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => []}, 1_900}
      end)

      InferenceStub.stub("{f}{last}")
      {:ok, row, _} = PatternStore.get_or_fetch("nowhere2-ltd.example")

      assert row.confidence <= 0.5
    end

    test "a provider's pattern is never replaced by a guess" do
      TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 92.0}]}, 1_900}
      end)

      InferenceStub.stub("{f}{last}")
      {:ok, row, _} = PatternStore.get_or_fetch("real-co.example")

      assert row.pattern == "{first}.{last}"
      assert row.source == "thecompaniesapi"
    end

    test "a refused guess is stored as the miss it is" do
      TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => []}, 1_900}
      end)

      InferenceStub.stub("no idea sorry")
      {:ok, row, _} = PatternStore.get_or_fetch("unknowable.example")

      refute row.found
      assert row.pattern == nil
    end

    test "the guess is cached, so the second caller does not pay to ask again" do
      TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => []}, 1_900}
      end)

      InferenceStub.stub("{first}{last}")
      {:ok, _, first} = PatternStore.get_or_fetch("cached-co.example")
      refute first.cached

      InferenceStub.reset()
      {:ok, row, second} = PatternStore.get_or_fetch("cached-co.example")

      assert second.cached
      assert row.pattern == "{first}{last}"
    end
  end
end
