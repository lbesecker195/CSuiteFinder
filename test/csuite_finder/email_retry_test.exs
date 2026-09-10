defmodule CsuiteFinder.EmailRetryTest do
  @moduledoc """
  Asking again for someone whose address turned out to be dead.

  A caller repeating a request is the demand signal: the address we gave them
  does not work. Handing back the same dead address helps nobody — but neither
  does re-billing them on every request once we have genuinely run out of
  methods, so most of this is about knowing the difference.
  """

  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.{Finder, Repo, TregStub}
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
    test "tries a format it has not tried yet" do
      # first.last is rejected on the first ask. The second ask must not simply
      # replay it — the company has another format and nobody has tried it.
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, one_pattern(), 1_900}

        "treg.people.email.verify", %{"email" => "jane.doe@acme.com"} ->
          {200, TregStub.routed(%{"valid" => false, "status" => "invalid"}, cost: 1_500), 1_500}

        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}

        "treg.people.email.find", _ ->
          {200, TregStub.routed(%{"email" => "jdoe@acme.com"}, cost: 5_000), 5_000}
      end)

      {:ok, first} = Finder.find("Jane Doe", "acme.com")
      # Nothing in the pattern worked, so it was bought — and the bought one is
      # checked, because this person's first address was already wrong.
      assert first.email == "jdoe@acme.com"

      row = Finder.cached_row("jane doe", "acme.com")
      assert "jane.doe@acme.com" in row.rejected
      assert row.provider_tried
    end

    test "does not rebuild an address already proved dead for that person" do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, two_patterns(), 1_900}

        "treg.people.email.verify", %{"email" => "jane.doe@acme.com"} ->
          {200, TregStub.routed(%{"valid" => false, "status" => "invalid"}, cost: 1_500), 1_500}

        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}
      end)

      {:ok, result} = Finder.find("Jane Doe", "acme.com")

      # The second format answered; the first is recorded as dead for her.
      assert result.email == "jdoe@acme.com"
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

        # The paid lookup returns exactly the address the mailbox just rejected.
        "treg.people.email.find", _ ->
          {200, TregStub.routed(%{"email" => "jane.doe@acme.com"}, cost: 5_000), 5_000}
      end)

      {:ok, result} = Finder.find("Jane Doe", "acme.com")

      refute result.found
      assert Repo.get_by(Email, name_key: "jane doe", domain: "acme.com").found == false
    end
  end
end
