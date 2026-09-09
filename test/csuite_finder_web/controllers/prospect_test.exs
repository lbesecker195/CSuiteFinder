defmodule CsuiteFinderWeb.ProspectTest do
  @moduledoc """
  `/company/people` is the discovery endpoint — a domain in, named people out.
  It is billed per row, which makes `limit` the spend dial and the clamping
  below load-bearing.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.{Fixtures, Repo, TregStub}
  alias CsuiteFinder.Cache.CompanyPerson

  @page %{
    "data" => %{
      "emails" => [
        %{
          "email" => "jane@acme.com",
          "first_name" => "Jane",
          "last_name" => "Doe",
          "position" => "Chief Executive Officer",
          "department" => "executive",
          "seniority" => "executive",
          "type" => "personal",
          "score" => 95
        },
        %{
          "email" => "bob@acme.com",
          "first_name" => "Bob",
          "last_name" => "Roe",
          "position" => "VP Engineering",
          "department" => "engineering",
          "seniority" => "executive",
          "type" => "personal",
          "score" => 90
        },
        %{
          "email" => "sales@acme.com",
          "first_name" => nil,
          "last_name" => nil,
          "position" => nil,
          "department" => "sales",
          "type" => "generic",
          "score" => 40
        }
      ]
    },
    "meta" => %{"total" => 113}
  }

  setup %{conn: conn} do
    {account, key} = Fixtures.account_with_key(tokens: 400)
    TregStub.stub(fn "tomba.companies.emails.list", _ -> {200, @page, 8_900} end)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> key), account: account}
  end

  describe "GET /csuitefinder/company/people" do
    test "returns named people at a domain", %{conn: conn} do
      body =
        conn |> get(~p"/csuitefinder/company/people?domain=acme.com") |> json_response(200)

      assert body["domain"] == "acme.com"
      assert body["count"] == 3

      assert %{"email" => "jane@acme.com", "position" => "Chief Executive Officer"} =
               hd(body["people"])
    end

    test "filters to a department", %{conn: conn} do
      # Fetch once so the rows exist, then narrow.
      get(conn, ~p"/csuitefinder/company/people?domain=acme.com")

      body =
        conn
        |> get(~p"/csuitefinder/company/people?domain=acme.com&department=executive")
        |> json_response(200)

      assert Enum.map(body["people"], & &1["email"]) == ["jane@acme.com"]
    end

    test "rejects a department the provider does not know", %{conn: conn} do
      body =
        conn
        |> get(~p"/csuitefinder/company/people?domain=acme.com&department=wizards")
        |> json_response(400)

      assert body["error"] == "invalid_department"
      assert body["message"] =~ "executive"
    end

    test "requires a domain", %{conn: conn} do
      assert %{"error" => "missing_params"} =
               conn |> get(~p"/csuitefinder/company/people") |> json_response(400)
    end

    test "discloses no supplier", %{conn: conn} do
      body =
        conn |> get(~p"/csuitefinder/company/people?domain=acme.com") |> json_response(200)

      encoded = String.downcase(Jason.encode!(body))

      for term <- ~w(tomba treg provider raw confidence_source) do
        refute String.contains?(encoded, term), "leaked #{term}"
      end
    end
  end

  describe "billing" do
    test "charges five tokens per person on the phone-included route",
         %{conn: conn, account: account} do
      conn |> get(~p"/csuitefinder/company/people?domain=acme.com") |> json_response(200)

      # Three people at 5 each: the phone is a lookup of its own per person.
      assert Repo.reload(account).token_balance == 385
    end

    test "charges one token per person on the email-only route",
         %{conn: conn, account: account} do
      body =
        conn
        |> get(~p"/csuitefinder/email/company/people?domain=acme.com")
        |> json_response(200)

      assert Repo.reload(account).token_balance == 397
      refute Map.has_key?(hd(body["people"]), "phone")
    end

    test "a second query is served from the stored rows without another sweep",
         %{conn: conn} do
      get(conn, ~p"/csuitefinder/company/people?domain=acme.com")
      calls = TregStub.call_count()

      body =
        conn
        |> get(~p"/csuitefinder/company/people?domain=acme.com&department=engineering")
        |> json_response(200)

      # A narrow query answered out of what the broad one already paid for.
      assert body["count"] == 1
      assert TregStub.call_count() == calls
    end

    test "limit is clamped by the per-row price, not the raw balance", %{conn: conn} do
      # 12 tokens buys two rows at 5 each, or twelve at 1 each. Clamping against
      # the balance alone would hand back twelve rows for 12 tokens on a route
      # that charges 60 for them.
      {_account, key} = Fixtures.account_with_key(tokens: 12)
      poor = put_req_header(build_conn(), "authorization", "Bearer " <> key)

      with_phones =
        poor
        |> get(~p"/csuitefinder/company/people?domain=acme.com&limit=50")
        |> json_response(200)

      assert with_phones["count"] <= 2
    end

    test "an account that cannot afford a single row is refused outright",
         %{conn: conn} do
      {_account, key} = Fixtures.account_with_key(tokens: 2)

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> key)
        |> get(~p"/csuitefinder/company/people?domain=acme.com")
        |> json_response(402)

      assert body["error"] == "insufficient_tokens"
    end

    test "an empty result is not billed", %{conn: conn, account: account} do
      TregStub.stub(fn "tomba.companies.emails.list", _ ->
        {200, %{"data" => %{"emails" => []}, "meta" => %{"total" => 0}}, 0}
      end)

      conn |> get(~p"/csuitefinder/company/people?domain=nobody.com") |> json_response(200)

      assert Repo.reload(account).token_balance == 400
    end
  end

  describe "storage" do
    test "keeps one row per person, reusable across queries", %{conn: conn} do
      get(conn, ~p"/csuitefinder/company/people?domain=acme.com")
      get(conn, ~p"/csuitefinder/company/people?domain=acme.com&refresh=true")

      # Re-sweeping updates rows rather than duplicating them.
      assert Repo.aggregate(CompanyPerson, :count, :id) == 3
    end

    test "survives a provider row with a non-string field", %{conn: conn} do
      # Observed live: phone_number arrives as an object on some rows. One odd
      # row must not fail the insert and lose the page we just paid for.
      TregStub.stub(fn "tomba.companies.emails.list", _ ->
        {200,
         %{
           "data" => %{
             "emails" => [
               %{
                 "email" => "odd@acme.com",
                 "first_name" => "Odd",
                 "last_name" => "One",
                 "phone_number" => %{"raw" => "+1 555"},
                 "department" => "executive"
               }
             ]
           },
           "meta" => %{"total" => 1}
         }, 8_900}
      end)

      body =
        conn |> get(~p"/csuitefinder/company/people?domain=acme.com") |> json_response(200)

      assert body["count"] == 1
    end
  end
end
