defmodule CsuiteFinder.EmailRetryTest do
  @moduledoc """
  Asking again for someone whose address turned out to be dead.

  We never check an address ourselves, so "dead" always means the customer told
  us — they ran /email/deliverable on what we gave them and it bounced. Asking
  again after that is the demand signal, and handing back the same dead address
  helps nobody. But neither does re-billing them once we have genuinely run out
  of methods, so most of this is about knowing the difference.
  """

  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.{Finder, Repo, TregStub, Verifier}
  alias CsuiteFinder.Cache.Email

  defp one_pattern, do: %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}

  defp two_patterns do
    %{
      "patterns" => [
        %{"pattern" => "[F].[L]", "usagePercentage" => 55.0},
        %{"pattern" => "[F1][L]", "usagePercentage" => 45.0}
      ]
    }
  end

  describe "a second ask for someone whose address bounced" do
    test "buys the answer when the company has no other format to try" do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, one_pattern(), 1_900}

        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => false, "status" => "invalid"}, cost: 1_500), 1_500}

        "treg.people.email.find", _ ->
          {200, TregStub.routed(%{"email" => "jdoe@acme.com"}, cost: 5_000), 5_000}
      end)

      {:ok, first} = Finder.find("Jane Doe", "acme.com")
      assert first.email == "jane.doe@acme.com"

      # The customer checks it and it bounces. That is the only way we ever find
      # out, and it is what makes the next ask worth re-resolving.
      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")

      {:ok, second} = Finder.find("Jane Doe", "acme.com")

      assert second.email == "jdoe@acme.com"
      row = Finder.cached_row("jane doe", "acme.com")
      assert "jane.doe@acme.com" in row.rejected
      assert row.provider_tried
    end

    test "does not rebuild an address already proved dead for that person" do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, two_patterns(), 1_900}

        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => false, "status" => "invalid"}, cost: 1_500), 1_500}
      end)

      {:ok, first} = Finder.find("Jane Doe", "acme.com")
      assert first.email == "jane.doe@acme.com"

      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")

      # The company's other format, not the one she has been proved not to use.
      {:ok, second} = Finder.find("Jane Doe", "acme.com")

      assert second.email == "jdoe@acme.com"
      assert "jane.doe@acme.com" in Finder.cached_row("jane doe", "acme.com").rejected
    end

    test "stops asking once every method has been spent" do
      # Both formats rejected, the paid lookup spent and its answer rejected
      # too. There is nothing left to try, so a third ask must be answered from
      # the cache rather than billed again.
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, one_pattern(), 1_900}

        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => false, "status" => "invalid"}, cost: 1_500), 1_500}

        "treg.people.email.find", _ ->
          {200, TregStub.routed(%{"email" => "jdoe@acme.com"}, cost: 5_000), 5_000}
      end)

      {:ok, _} = Finder.find("Jane Doe", "acme.com")
      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")
      {:ok, _} = Finder.find("Jane Doe", "acme.com")
      {:ok, _, _} = Verifier.verify("jdoe@acme.com")
      spent = TregStub.call_count()

      {:ok, _} = Finder.find("Jane Doe", "acme.com")
      {:ok, _} = Finder.find("Jane Doe", "acme.com")

      assert TregStub.call_count() == spent, "kept paying for a person with nothing left to try"
    end

    test "a confirmed address is never re-resolved" do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, one_pattern(), 1_900}

        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}
      end)

      {:ok, _} = Finder.find("Jane Doe", "acme.com")
      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")
      spent = TregStub.call_count()

      {:ok, again} = Finder.find("Jane Doe", "acme.com")

      assert again.email == "jane.doe@acme.com"
      assert TregStub.call_count() == spent
    end
  end

  describe "when the provider hands back an address we already disproved" do
    test "it is reported as a miss, not sold again" do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, one_pattern(), 1_900}

        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => false, "status" => "invalid"}, cost: 1_500), 1_500}

        # The paid lookup returns exactly the address the customer just proved dead.
        "treg.people.email.find", _ ->
          {200, TregStub.routed(%{"email" => "jane.doe@acme.com"}, cost: 5_000), 5_000}
      end)

      {:ok, _} = Finder.find("Jane Doe", "acme.com")
      {:ok, _, _} = Verifier.verify("jane.doe@acme.com")

      {:ok, result} = Finder.find("Jane Doe", "acme.com")

      refute result.found
      assert Repo.get_by(Email, name_key: "jane doe", domain: "acme.com").found == false
    end
  end
end
