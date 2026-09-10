defmodule CsuiteFinder.PatternConfirmationTest do
  @moduledoc """
  Checking a constructed address against the mailbox before returning it.

  A pattern is a statement about a company, not about a person, and companies
  keep exceptions. These tests are mostly about *when we decline to spend* —
  a check that cannot change the answer is money for nothing.
  """

  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.{Finder, PatternStore, Repo, TregStub}
  alias CsuiteFinder.Cache.EmailPattern

  # Two plausible formats for one domain, so a check has something to decide.
  defp two_patterns do
    %{
      "patterns" => [
        %{"pattern" => "[F].[L]", "usagePercentage" => 55.0},
        %{"pattern" => "[F1][L]", "usagePercentage" => 45.0}
      ]
    }
  end

  defp verifier(answers) do
    TregStub.stub(fn
      "thecompaniesapi.companies.email_pattern", _ ->
        {200, two_patterns(), 1_900}

      "treg.people.email.verify", %{"email" => email} ->
        {200, TregStub.routed(answers.(email), cost: 1_500), 1_500}

      "treg.people.email.find", _ ->
        {200, TregStub.routed(%{"email" => "bought@acme.com"}, cost: 5_000), 5_000}
    end)
  end

  describe "choosing between formats" do
    test "returns the one the mailbox accepts, not the one ranked highest" do
      # The provider's favourite is first.last; the mailbox says otherwise.
      verifier(fn
        "jdoe@acme.com" -> %{"valid" => true, "status" => "valid"}
        _ -> %{"valid" => false, "status" => "invalid"}
      end)

      {:ok, result} = Finder.find("Jane Doe", "acme.com")

      assert result.email == "jdoe@acme.com"
      assert result.verification_status == "deliverable"
    end

    test "records what each format did, so the next person skips the loser" do
      verifier(fn
        "jdoe@acme.com" -> %{"valid" => true, "status" => "valid"}
        _ -> %{"valid" => false, "status" => "invalid"}
      end)

      {:ok, _} = Finder.find("Jane Doe", "acme.com")

      ratios = PatternStore.ratios("acme.com")
      winner = Enum.find(ratios, &(&1.pattern == "{f}{last}"))
      loser = Enum.find(ratios, &(&1.pattern == "{first}.{last}"))

      assert winner.deliverable == 1
      assert winner.share == 1.0
      assert loser.undeliverable == 1
      assert loser.share == 0.0
    end

    test "a format proved on this domain is not paid to be re-checked" do
      # Anything in the {f}{last} shape lands here; first.last does not.
      verifier(fn email ->
        if email in ["jdoe@acme.com", "sroe@acme.com"],
          do: %{"valid" => true, "status" => "valid"},
          else: %{"valid" => false, "status" => "invalid"}
      end)

      {:ok, _} = Finder.find("Jane Doe", "acme.com")
      after_first = TregStub.call_count()

      {:ok, second} = Finder.find("Sam Roe", "acme.com")

      assert second.email == "sroe@acme.com"
      assert TregStub.call_count() == after_first, "the company was checked twice"
    end

    test "when every format is rejected, the answer is bought rather than guessed" do
      # Our guesses are disproved. Returning one anyway would be handing over an
      # address we have just been told does not exist.
      verifier(fn _ -> %{"valid" => false, "status" => "invalid"} end)

      {:ok, result} = Finder.find("Jane Doe", "acme.com")

      assert result.email == "bought@acme.com"
      assert result.source == "provider"
    end
  end

  describe "domains that accept everything" do
    test "stop after one check, because no check can discriminate" do
      verifier(fn _ -> %{"valid" => true, "status" => "accept_all", "catch_all" => true} end)

      {:ok, result} = Finder.find("Jane Doe", "acme.com")
      after_first = TregStub.call_count()

      # The top-ranked format, marked as unconfirmed rather than confirmed.
      assert result.email == "jane.doe@acme.com"
      assert result.verification_status == "accept_all"
      assert PatternStore.catch_all?("acme.com")

      # And the next person is not checked at all.
      {:ok, _} = Finder.find("Sam Roe", "acme.com")
      assert TregStub.call_count() == after_first
    end

    test "the fact is reported on /email/pattern" do
      verifier(fn _ -> %{"valid" => true, "status" => "accept_all", "catch_all" => true} end)
      {:ok, _} = Finder.find("Jane Doe", "acme.com")

      {:ok, answer, _} = PatternStore.for_email("someone@acme.com")
      assert answer.accepts_all == true
    end
  end

  describe "a provider returning several addresses for one person" do
    test "the deliverable one is returned and cached; the others are not" do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, %{"patterns" => []}, 1_900}

        "treg.people.email.find", _ ->
          {200,
           TregStub.routed(
             %{"email" => "wrong@acme.com", "emails" => ["wrong@acme.com", "right@acme.com"]},
             cost: 5_000
           ), 5_000}

        "treg.people.email.verify", %{"email" => "right@acme.com"} ->
          {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}

        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => false, "status" => "invalid"}, cost: 1_500), 1_500}
      end)

      {:ok, result} = Finder.find("Jane Doe", "acme.com")

      assert result.email == "right@acme.com"
      assert Finder.cached_row("jane doe", "acme.com").email == "right@acme.com"
    end
  end

  describe "when the check itself is unavailable" do
    test "a verifier outage does not turn a resolvable address into a miss" do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, two_patterns(), 1_900}

        "treg.people.email.verify", _ ->
          {500, %{"error" => "down"}, 0}
      end)

      {:ok, result} = Finder.find("Jane Doe", "acme.com")

      assert result.email == "jane.doe@acme.com"
      assert result.found
    end
  end

  describe "the ratios" do
    test "are empty until something has actually been checked" do
      Repo.insert!(
        EmailPattern.changeset(%EmailPattern{}, %{
          domain: "unchecked.com",
          pattern: "{first}.{last}",
          source: "thecompaniesapi",
          found: true,
          expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
        })
      )

      assert PatternStore.ratios("unchecked.com") == []
    end
  end
end
