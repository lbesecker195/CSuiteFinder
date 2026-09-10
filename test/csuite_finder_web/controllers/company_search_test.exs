defmodule CsuiteFinderWeb.CompanySearchTest do
  @moduledoc """
  `/company/search` — account lists, the top of the funnel.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.{Fixtures, Repo, TregStub}
  alias CsuiteFinder.Cache.{CompanyProfile, CompanySearch}

  defp signed_in(conn, opts \\ []) do
    {account, key} = Fixtures.account_with_key(Keyword.put_new(opts, :usd, 10.0))
    {account, put_req_header(conn, "authorization", "Bearer " <> key)}
  end

  defp stub_companies(rows) do
    TregStub.stub(fn "treg.companies.search", _ -> {200, %{"companies" => rows}, 3_800} end)
  end

  @fintechs [
    %{
      "name" => "Stripe",
      "domain" => "stripe.com",
      "industry" => "fintech",
      "employee_count" => 8000,
      "country" => "US"
    },
    %{
      "name" => "Wise",
      "domain" => "wise.com",
      "industry" => "fintech",
      "employee_count" => 5000,
      "country" => "GB"
    }
  ]

  describe "searching" do
    test "returns companies for an industry", %{conn: conn} do
      stub_companies(@fintechs)
      {_account, conn} = signed_in(conn)

      body =
        conn
        |> get(~p"/csuitefinder/company/search?industry=fintech")
        |> json_response(200)

      assert body["count"] == 2
      assert [first, second] = body["companies"]
      assert first["domain"] == "stripe.com"
      assert first["name"] == "Stripe"
      assert second["domain"] == "wise.com"
    end

    test "keeps the provider's order, which is relevance order", %{conn: conn} do
      stub_companies(@fintechs)
      {_account, conn} = signed_in(conn)

      body = conn |> get(~p"/csuitefinder/company/search?industry=fintech") |> json_response(200)
      assert Enum.map(body["companies"], & &1["domain"]) == ["stripe.com", "wise.com"]
    end

    test "points at what to do with a domain next", %{conn: conn} do
      # A list of companies is not a workflow until the caller knows the domain
      # is the input to everything else.
      stub_companies(@fintechs)
      {_account, conn} = signed_in(conn)

      body = conn |> get(~p"/csuitefinder/company/search?industry=fintech") |> json_response(200)
      assert body["next"]["people"] =~ "/company/people"
    end

    test "a search with no filters at all is refused", %{conn: conn} do
      # An unfiltered search is a request to buy a random page of the internet.
      {_account, conn} = signed_in(conn)
      assert conn |> get(~p"/csuitefinder/company/search") |> json_response(400)
    end
  end

  describe "what comes back from fifteen different providers" do
    test "a website is reduced to a domain", %{conn: conn} do
      stub_companies([%{"name" => "Acme", "website" => "https://www.acme.co.uk/about"}])
      {_account, conn} = signed_in(conn)

      body = conn |> get(~p"/csuitefinder/company/search?industry=widgets") |> json_response(200)
      assert [%{"domain" => "acme.co.uk"}] = body["companies"]
    end

    test "a row we cannot address is dropped", %{conn: conn} do
      # A company with no domain is not an account: nothing else in the API can
      # take it as input.
      stub_companies([%{"name" => "No Domain Ltd"}, %{"name" => "Acme", "domain" => "acme.com"}])
      {_account, conn} = signed_in(conn)

      body = conn |> get(~p"/csuitefinder/company/search?industry=widgets") |> json_response(200)
      assert [%{"domain" => "acme.com"}] = body["companies"]
    end

    test "the same company twice is returned once", %{conn: conn} do
      stub_companies([
        %{"name" => "Acme", "domain" => "acme.com"},
        %{"name" => "Acme Inc", "domain" => "acme.com"}
      ])

      {_account, conn} = signed_in(conn)
      body = conn |> get(~p"/csuitefinder/company/search?industry=widgets") |> json_response(200)
      assert body["count"] == 1
    end
  end

  describe "headcount" do
    test "filters out companies outside the band" do
      stub_companies([
        %{"name" => "Tiny", "domain" => "tiny.com", "employee_count" => 4},
        %{"name" => "Right", "domain" => "right.com", "employee_count" => 120},
        %{"name" => "Huge", "domain" => "huge.com", "employee_count" => 90_000}
      ])

      {:ok, rows, _} = CsuiteFinder.CompanySearch.search(%{industry: "widgets", size: "50-200"})
      assert Enum.map(rows, & &1.domain) == ["right.com"]
    end

    test "keeps a company whose headcount the provider did not report" do
      # Silence is not evidence of size, and dropping the row would quietly
      # shrink every list for the providers that do not return a headcount.
      stub_companies([%{"name" => "Quiet", "domain" => "quiet.com"}])

      {:ok, rows, _} = CsuiteFinder.CompanySearch.search(%{industry: "widgets", size: "50-200"})
      assert Enum.map(rows, & &1.domain) == ["quiet.com"]
    end

    test "an open-ended band works" do
      stub_companies([
        %{"name" => "Small", "domain" => "small.com", "employee_count" => 20},
        %{"name" => "Big", "domain" => "big.com", "employee_count" => 5_000}
      ])

      {:ok, rows, _} = CsuiteFinder.CompanySearch.search(%{industry: "widgets", size: "1000+"})
      assert Enum.map(rows, & &1.domain) == ["big.com"]
    end
  end

  describe "caching" do
    test "the same question twice is one purchase" do
      stub_companies(@fintechs)

      {:ok, _, first} = CsuiteFinder.CompanySearch.search(%{industry: "fintech"})
      refute first.cached

      TregStub.stub(fn "treg.companies.search", _ -> {200, %{"companies" => []}, 3_800} end)
      {:ok, rows, second} = CsuiteFinder.CompanySearch.search(%{industry: "fintech"})

      assert second.cached
      assert Enum.map(rows, & &1.domain) == ["stripe.com", "wise.com"]
    end

    test "spelling the same question differently is still one purchase" do
      stub_companies(@fintechs)

      {:ok, _, _} = CsuiteFinder.CompanySearch.search(%{industry: "Fintech"})
      {:ok, _, second} = CsuiteFinder.CompanySearch.search(%{industry: "  fintech "})

      assert second.cached
    end

    test "a different question is a different purchase" do
      stub_companies(@fintechs)

      {:ok, _, _} = CsuiteFinder.CompanySearch.search(%{industry: "fintech"})
      {:ok, _, second} = CsuiteFinder.CompanySearch.search(%{industry: "logistics"})

      refute second.cached
    end

    test "companies land in the same table /company/info reads" do
      # A domain discovered by a search is a company the rest of the API knows.
      stub_companies(@fintechs)
      {:ok, _, _} = CsuiteFinder.CompanySearch.search(%{industry: "fintech"})

      assert %CompanyProfile{name: "Stripe", industry: "fintech"} =
               Repo.get_by(CompanyProfile, domain: "stripe.com")

      assert Repo.aggregate(CompanySearch, :count, :id) == 1
    end

    test "discovery never erases what an enrichment already paid for" do
      # A search row is thinner than a profile. Merging rather than replacing is
      # what stops a cheap list wiping a bought record.
      Repo.insert!(
        CompanyProfile.changeset(%CompanyProfile{}, %{
          domain: "stripe.com",
          name: "Stripe",
          source: "provider",
          found: true,
          founded_year: 2010,
          description: "Payments infrastructure"
        })
      )

      stub_companies(@fintechs)
      {:ok, _, _} = CsuiteFinder.CompanySearch.search(%{industry: "fintech"})

      row = Repo.get_by(CompanyProfile, domain: "stripe.com")
      assert row.founded_year == 2010
      assert row.description == "Payments infrastructure"
      assert row.employee_count == 8000
    end
  end

  describe "billing" do
    test "bills per company returned", %{conn: conn} do
      stub_companies(@fintechs)
      {account, conn} = signed_in(conn, usd: 1.0)

      conn |> get(~p"/csuitefinder/company/search?industry=fintech") |> json_response(200)

      spent = Pricing.micro(1.0) - Repo.reload(account).balance_micro
      assert spent == Pricing.charge_for("company.search") * 2
    end

    test "a search that matches nothing is free", %{conn: conn} do
      TregStub.stub(fn "treg.companies.search", _ -> {200, %{"companies" => []}, 3_800} end)
      {account, conn} = signed_in(conn, usd: 1.0)

      conn |> get(~p"/csuitefinder/company/search?industry=nothing") |> json_response(200)

      assert Repo.reload(account).balance_micro == Pricing.micro(1.0)
    end

    test "you cannot ask for more rows than you can pay for", %{conn: conn} do
      rows =
        for n <- 1..30, do: %{"name" => "Co #{n}", "domain" => "co#{n}.example"}

      stub_companies(rows)
      # Two companies' worth of credit, thirty asked for.
      {_account, conn} = signed_in(conn, usd: 0.005)

      body =
        conn
        |> get(~p"/csuitefinder/company/search?industry=widgets&limit=30")
        |> json_response(200)

      assert body["count"] == 2
    end
  end

  describe "the supplier stays ours" do
    test "no provider name reaches the response", %{conn: conn} do
      stub_companies(@fintechs)
      {_account, conn} = signed_in(conn)

      encoded =
        conn
        |> get(~p"/csuitefinder/company/search?industry=fintech")
        |> json_response(200)
        |> Jason.encode!()
        |> String.downcase()

      for term <- ~w(treg thecompaniesapi apollo pdl lusha coresignal provider) do
        refute String.contains?(encoded, term), "response mentioned #{term}"
      end
    end
  end
end
