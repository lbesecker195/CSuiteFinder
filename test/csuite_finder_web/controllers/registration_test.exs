defmodule CsuiteFinderWeb.RegistrationTest do
  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Accounts
  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.{Repo, TregStub}

  describe "POST /csuitefinder/register" do
    test "issues a key and the free trial in one call", %{conn: conn} do
      body =
        conn
        |> post(~p"/csuitefinder/register", %{email: "new@company.com"})
        |> json_response(201)

      assert body["credit_granted_usd"] == 1.0
      assert body["balance_usd"] == 1.0
      assert String.starts_with?(body["api_key"], "csf_live_")
      assert body["api_key_notice"] =~ "shown once"
    end

    test "the issued key works immediately", %{conn: conn} do
      key =
        conn
        |> post(~p"/csuitefinder/register", %{email: "new@company.com"})
        |> json_response(201)
        |> Map.fetch!("api_key")

      TregStub.stub(fn
        "treg.people.email.verify", _ ->
          {200, TregStub.routed(%{"valid" => true, "status" => "valid"}, cost: 1_500), 1_500}

        "thecompaniesapi.companies.email_pattern", _ ->
          {200, %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}, 1_900}
      end)

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> key)
        |> get(~p"/csuitefinder/email/find?full_name=Jane%20Doe&domain=acme.com")
        |> json_response(200)

      assert body["email"] == "jane.doe@acme.com"
    end

    test "the trial is enough to actually try the API" do
      # $1 at $0.0025 an address is 400 real lookups, with every follow-up
      # endpoint included on top.
      assert div(Pricing.trial_micro(), Pricing.charge_for("email.find")) == 400
    end

    test "rejects a duplicate email rather than granting a second trial",
         %{conn: conn} do
      post(conn, ~p"/csuitefinder/register", %{email: "dup@company.com"})

      body =
        conn
        |> post(~p"/csuitefinder/register", %{email: "dup@company.com"})
        |> json_response(422)

      assert body["error"] == "registration_failed"
      assert body["details"]["email"]
    end

    test "rejects a malformed email", %{conn: conn} do
      conn
      |> post(~p"/csuitefinder/register", %{email: "not-an-email"})
      |> json_response(422)
    end

    test "stores only the hash of the issued key", %{conn: conn} do
      key =
        conn
        |> post(~p"/csuitefinder/register", %{email: "new@company.com"})
        |> json_response(201)
        |> Map.fetch!("api_key")

      refute Enum.any?(Repo.all(Accounts.ApiKey), &(&1.key_hash == key))
      assert {:ok, _account, _key} = Accounts.authenticate(key)
    end
  end

  describe "bundle minimum" do
    test "refuses a purchase below $1,000 before PayPal is involved", %{conn: conn} do
      body =
        conn
        |> post(~p"/csuitefinder/register", %{email: "buyer@company.com"})
        |> json_response(201)

      response =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> body["api_key"])
        |> post(~p"/csuitefinder/billing/topup", %{amount_usd: 50})
        |> json_response(400)

      assert response["error"] == "below_minimum_purchase"
      assert response["minimum_usd"] == 1_000
    end
  end
end
