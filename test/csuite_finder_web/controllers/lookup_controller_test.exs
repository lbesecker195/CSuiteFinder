defmodule CsuiteFinderWeb.LookupControllerTest do
  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.{Fixtures, TregStub}

  setup %{conn: conn} do
    {account, key} = Fixtures.account_with_key()
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> key), account: account}
  end

  describe "GET /csuitefinder/name/who" do
    test "returns the identity fields only", %{conn: conn} do
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200,
         TregStub.routed(%{
           "full_name" => "Jane Doe",
           "first_name" => "Jane",
           "last_name" => "Doe",
           "title" => "CTO",
           "company" => "Acme"
         }), 4_900}
      end)

      body = conn |> get(~p"/csuitefinder/name/who?email=jane@acme.com") |> json_response(200)

      assert body["full_name"] == "Jane Doe"
      assert body["first_name"] == "Jane"
      assert body["source"] == "provider"
      # The narrower endpoint does not carry the full employment record.
      refute Map.has_key?(body, "seniority")
      refute Map.has_key?(body, "phone")
    end

    test "shares the enrichment cache rather than paying twice", %{conn: conn} do
      TregStub.stub(fn "treg.people.enrich", _ ->
        {200, TregStub.routed(%{"full_name" => "Jane Doe"}), 4_900}
      end)

      get(conn, ~p"/csuitefinder/email/enrich?email=jane@acme.com")
      body = conn |> get(~p"/csuitefinder/name/who?email=jane@acme.com") |> json_response(200)

      assert body["cached"]
      assert body["cost"]["provider_micro"] == 0
      assert TregStub.call_count() == 1
    end

    test "warns when the answer is inferred", %{conn: conn} do
      TregStub.stub(fn "treg.people.enrich", _ -> {200, %{"output" => nil}, 0} end)

      body =
        conn |> get(~p"/csuitefinder/name/who?email=jane.doe@acme.com") |> json_response(200)

      assert body["source"] == "inferred"
      assert body["warning"] =~ "Derived from the address"
    end
  end

  describe "GET /csuitefinder/company/find" do
    test "identifies the company behind an address", %{conn: conn} do
      TregStub.stub(fn "treg.companies.enrich", _ ->
        {200,
         TregStub.routed(%{
           "name" => "Acme Inc",
           "website" => "acme.com",
           "linkedin_url" => "https://linkedin.com/company/acme",
           "industry" => "software",
           "employee_count" => 500
         }), 1_900}
      end)

      body =
        conn |> get(~p"/csuitefinder/company/find?email=jane@acme.com") |> json_response(200)

      assert body["name"] == "Acme Inc"
      assert body["domain"] == "acme.com"
      assert body["linkedin_url"] == "https://linkedin.com/company/acme"
      assert body["queried_email"] == "jane@acme.com"

      # Identity only — the full profile is what /company/info is for.
      refute Map.has_key?(body, "industry")
      refute Map.has_key?(body, "employee_count")
      refute Map.has_key?(body, "description")
    end

    test "shares the cache with /company/info", %{conn: conn} do
      TregStub.stub(fn "treg.companies.enrich", _ ->
        {200, TregStub.routed(%{"name" => "Acme Inc"}), 1_900}
      end)

      get(conn, ~p"/csuitefinder/company/info?email=jane@acme.com")

      body =
        conn |> get(~p"/csuitefinder/company/find?email=bob@acme.com") |> json_response(200)

      assert body["name"] == "Acme Inc"
      assert body["cached"]
      assert TregStub.call_count() == 1
    end

    test "is free", %{conn: conn, account: account} do
      TregStub.stub(fn "treg.companies.enrich", _ ->
        {200, TregStub.routed(%{"name" => "Acme Inc"}), 1_900}
      end)

      before = CsuiteFinder.Repo.reload(account).token_balance
      get(conn, ~p"/csuitefinder/company/find?email=jane@acme.com")

      assert CsuiteFinder.Repo.reload(account).token_balance == before
    end

    test "says so for a consumer mailbox", %{conn: conn} do
      body =
        conn |> get(~p"/csuitefinder/company/find?email=jane@gmail.com") |> json_response(200)

      refute body["found"]
      assert body["note"] =~ "consumer email provider"
      assert TregStub.call_count() == 0
    end

    test "requires an email", %{conn: conn} do
      assert %{"error" => "missing_params"} =
               conn |> get(~p"/csuitefinder/company/find") |> json_response(400)
    end
  end

  describe "GET /csuitefinder/company/info" do
    test "returns the company behind an address", %{conn: conn} do
      TregStub.stub(fn "treg.companies.enrich", _ ->
        {200,
         TregStub.routed(%{
           "name" => "Acme Inc",
           "industry" => "software",
           "employee_count" => 500,
           "founded_year" => 2010
         }), 1_900}
      end)

      body =
        conn |> get(~p"/csuitefinder/company/info?email=jane@acme.com") |> json_response(200)

      assert body["name"] == "Acme Inc"
      assert body["employee_count"] == 500
      assert body["domain"] == "acme.com"
    end

    test "caches per domain, so a colleague is free", %{conn: conn} do
      TregStub.stub(fn "treg.companies.enrich", _ ->
        {200, TregStub.routed(%{"name" => "Acme Inc"}), 1_900}
      end)

      get(conn, ~p"/csuitefinder/company/info?email=jane@acme.com")
      body = conn |> get(~p"/csuitefinder/company/info?email=bob@acme.com") |> json_response(200)

      assert body["cached"]
      assert TregStub.call_count() == 1
    end

    test "does not bill a lookup for a consumer mailbox", %{conn: conn} do
      body =
        conn |> get(~p"/csuitefinder/company/info?email=jane@gmail.com") |> json_response(200)

      refute body["found"]
      assert body["note"] =~ "consumer email provider"
      assert TregStub.call_count() == 0
    end

    test "accepts a bare domain too", %{conn: conn} do
      TregStub.stub(fn "treg.companies.enrich", _ ->
        {200, TregStub.routed(%{"name" => "Acme Inc"}), 1_900}
      end)

      body = conn |> get(~p"/csuitefinder/company/info?domain=acme.com") |> json_response(200)
      assert body["name"] == "Acme Inc"
    end
  end
end
