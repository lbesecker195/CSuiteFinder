defmodule CsuiteFinderWeb.EmailControllerTest do
  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Cache.{EmailPattern, PersonEnrichment}
  alias CsuiteFinder.{Fixtures, TregStub}

  setup %{conn: conn} do
    {account, key} = Fixtures.account_with_key()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> key)
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn, account: account, key: key}
  end

  defp stub_pattern(pattern, usage \\ 95.0) do
    TregStub.stub(fn
      "thecompaniesapi.companies.email_pattern", _params ->
        {200, %{"patterns" => [%{"pattern" => pattern, "usagePercentage" => usage}]}, 1_900}

      _other, _params ->
        {404, %{}, 0}
    end)
  end

  describe "POST /csuitefinder/email/find" do
    test "builds the address from the company pattern", %{conn: conn} do
      stub_pattern("[F].[L]")

      body =
        conn
        |> post(~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})
        |> json_response(200)

      assert body["email"] == "jane.doe@acme.com"
      assert body["found"]

      # How it was derived, and what it cost us, are ours — not the caller's.
      refute Map.has_key?(body, "source")
      refute Map.has_key?(body, "pattern")
      refute Map.has_key?(body, "cost")

      # The pattern path is still what ran; it is recorded internally.
      row = CsuiteFinder.Finder.cached_row("jane doe", "acme.com")
      assert row.source == "pattern"
      assert row.pattern_used == "{first}.{last}"
      assert row.provider_cost_micro == 1_900
    end

    test "a second person at the same company costs nothing", %{conn: conn} do
      stub_pattern("[F1][L]")

      post(conn, ~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})
      calls_after_first = TregStub.call_count()

      body =
        conn
        |> post(~p"/csuitefinder/email/find", %{full_name: "John Roe", domain: "acme.com"})
        |> json_response(200)

      assert body["email"] == "jroe@acme.com"
      # The pattern was already held; nothing new was bought.
      assert TregStub.call_count() == calls_after_first
      assert CsuiteFinder.Finder.cached_row("john roe", "acme.com").provider_cost_micro == 0
    end

    test "re-asking for the same person hits the email cache", %{conn: conn} do
      stub_pattern("[F].[L]")
      post(conn, ~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})

      body =
        conn
        |> post(~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})
        |> json_response(200)

      assert body["email"] == "jane.doe@acme.com"
      # One upstream call for the pattern, and nothing since.
      assert TregStub.call_count() == 1
    end

    test "falls back to a paid find when the domain has no pattern", %{conn: conn} do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, %{"patterns" => []}, 1_900}

        "treg.people.email.find", _ ->
          {200, TregStub.routed(%{"email" => "jdoe@acme.com"}, cost: 5_000), 5_000}
      end)

      body =
        conn
        |> post(~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})
        |> json_response(200)

      assert body["email"] == "jdoe@acme.com"
      refute Map.has_key?(body, "source")

      row = CsuiteFinder.Finder.cached_row("jane doe", "acme.com")
      assert row.source == "provider"
      assert row.provider_cost_micro == 6_900
    end

    test "learns the pattern from a paid find, so the next colleague is free",
         %{conn: conn} do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ ->
          {200, %{"patterns" => []}, 1_900}

        "treg.people.email.find", _ ->
          {200, TregStub.routed(%{"email" => "jdoe@acme.com"}, cost: 5_000), 5_000}
      end)

      post(conn, ~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})
      after_paid_find = TregStub.call_count()

      body =
        conn
        |> post(~p"/csuitefinder/email/find", %{full_name: "Sam Poe", domain: "acme.com"})
        |> json_response(200)

      assert body["email"] == "spoe@acme.com"
      row = CsuiteFinder.Finder.cached_row("sam poe", "acme.com")
      assert row.source == "pattern"
      assert row.provider_cost_micro == 0
      assert TregStub.call_count() == after_paid_find
    end

    test "rejects a missing parameter", %{conn: conn} do
      assert %{"error" => "missing_params"} =
               conn
               |> post(~p"/csuitefinder/email/find", %{domain: "acme.com"})
               |> json_response(400)
    end

    test "rejects a malformed domain", %{conn: conn} do
      assert %{"error" => "invalid_domain"} =
               conn
               |> post(~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "nope"})
               |> json_response(400)
    end

    test "requires an API key", %{conn: conn} do
      conn
      |> delete_req_header("authorization")
      |> post(~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})
      |> json_response(401)
    end
  end

  describe "POST /csuitefinder/email/deliverable" do
    test "returns a normalised verdict and caches it", %{conn: conn} do
      TregStub.stub(fn "treg.people.email.verify", _ ->
        {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}
      end)

      body =
        conn
        |> post(~p"/csuitefinder/email/deliverable", %{email: "jane@acme.com"})
        |> json_response(200)

      assert body["deliverable"]
      assert body["status"] == "deliverable"

      conn
      |> post(~p"/csuitefinder/email/deliverable", %{email: "jane@acme.com"})
      |> json_response(200)

      # The second call was served from cache: no new upstream request.
      assert TregStub.call_count() == 1
    end

    test "maps an invalid verdict to undeliverable", %{conn: conn} do
      TregStub.stub(fn "treg.people.email.verify", _ ->
        {200, TregStub.routed(%{"valid" => false, "status" => "invalid"}), 1_500}
      end)

      body =
        conn
        |> post(~p"/csuitefinder/email/deliverable", %{email: "nope@acme.com"})
        |> json_response(200)

      refute body["deliverable"]
      assert body["status"] == "undeliverable"
    end
  end

  describe "POST /csuitefinder/email/enrich" do
    test "returns provider data when a provider has the person", %{conn: conn} do
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200,
         TregStub.routed(%{
           "full_name" => "Jane Doe",
           "title" => "CTO",
           "company" => "Acme"
         }), 4_900}
      end)

      body =
        conn
        |> post(~p"/csuitefinder/email/enrich", %{email: "jane@acme.com"})
        |> json_response(200)

      assert body["full_name"] == "Jane Doe"
      assert body["position"] == "CTO"
      refute Map.has_key?(body, "source")
      refute Map.has_key?(body, "provider")
    end

    test "labels the fallback as inferred rather than passing it off as real",
         %{conn: conn} do
      TregStub.stub(fn "treg.people.enrich", _ -> {200, %{"output" => nil}, 0} end)

      body =
        conn
        |> post(~p"/csuitefinder/email/enrich", %{email: "jane.doe@acme.com"})
        |> json_response(200)

      assert body["full_name"] == "Jane Doe"
      assert body["confidence"] in ["low", "medium"]

      # The response no longer distinguishes a guess from a verified record,
      # but the distinction is kept internally — billing depends on it, and an
      # inference must never overwrite real data.
      refute Map.has_key?(body, "source")
      refute Map.has_key?(body, "warning")

      assert CsuiteFinder.Repo.get_by(PersonEnrichment, email: "jane.doe@acme.com").source ==
               "inferred"
    end

    test "invents nobody for a shared mailbox", %{conn: conn} do
      TregStub.stub(fn "treg.people.enrich", _ -> {200, %{"output" => nil}, 0} end)

      body =
        conn
        |> post(~p"/csuitefinder/email/enrich", %{email: "info@acme.com"})
        |> json_response(200)

      refute body["found"]
      refute body["full_name"]
    end
  end

  describe "POST /csuitefinder/email/pattern" do
    test "returns the company pattern with an example", %{conn: conn} do
      stub_pattern("[F].[L]", 97.0)

      body =
        conn
        |> post(~p"/csuitefinder/email/pattern", %{email: "someone@acme.com"})
        |> json_response(200)

      assert body["pattern"] == "{first}.{last}"
      assert body["pattern_provider_notation"] == "[F].[L]"
      assert body["example"] == "jane.doe@acme.com"
      assert body["confidence"] == 0.97
    end

    test "derives the pattern from the person when the domain has none", %{conn: conn} do
      TregStub.stub(fn
        "thecompaniesapi.companies.email_pattern", _ -> {200, %{"patterns" => []}, 1_900}
        "treg.people.enrich", _ -> {200, TregStub.routed(%{"full_name" => "Jane Doe"}), 4_900}
      end)

      body =
        conn
        |> post(~p"/csuitefinder/email/pattern", %{email: "jdoe@acme.com"})
        |> json_response(200)

      # The pattern itself is the product of this endpoint, so it stays.
      assert body["pattern"] == "{f}{last}"
      # Which upstream supplied it does not.
      refute Map.has_key?(body, "source")

      assert CsuiteFinder.Repo.get_by(EmailPattern, domain: "acme.com").source == "observed"
    end
  end
end
