defmodule CsuiteFinderWeb.BillingTest do
  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.{Accounts, Fixtures, Repo, TregStub}

  describe "metering" do
    test "charges for an answer and debits the balance", %{conn: conn} do
      {account, key} = Fixtures.account_with_key(usd: 1.0)

      TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}, 1_900}
      end)

      conn
      |> put_req_header("authorization", "Bearer " <> key)
      |> post(~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})
      |> json_response(200)

      # $0.01 for email.find.
      # A found email costs $0.0025.
      assert Repo.reload(account).balance_micro == 1_000_000 - 2_500
    end

    test "does not charge for a guess", %{conn: conn} do
      {account, key} = Fixtures.account_with_key(usd: 1.0)
      TregStub.stub(fn "treg.people.enrich", _ -> {200, %{"output" => nil}, 0} end)

      conn
      |> put_req_header("authorization", "Bearer " <> key)
      |> post(~p"/csuitefinder/email/enrich", %{email: "jane.doe@acme.com"})
      |> json_response(200)

      assert Repo.reload(account).balance_micro == 1_000_000
    end

    test "refuses the lookup before spending when the account is empty", %{conn: conn} do
      {_account, key} = Fixtures.account_with_key(usd: 0.0)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> post(~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})
        |> json_response(402)

      assert body["error"] == "insufficient_credit"
      # Crucially, nothing was bought upstream for a customer who cannot pay.
      assert TregStub.call_count() == 0
    end

    test "a cache hit is still billed", %{conn: conn} do
      {account, key} = Fixtures.account_with_key(usd: 1.0)
      conn = put_req_header(conn, "authorization", "Bearer " <> key)

      TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}, 1_900}
      end)

      post(conn, ~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})
      post(conn, ~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"})

      assert Repo.reload(account).balance_micro == 1_000_000 - 5_000
    end
  end

  describe "included endpoints" do
    test "cost nothing but still need a balance", %{conn: conn} do
      {account, key} = Fixtures.account_with_key(usd: 0.025)

      TregStub.stub(fn "treg.people.email.verify", _ ->
        {200, TregStub.routed(%{"valid" => true, "status" => "valid"}), 1_500}
      end)

      conn
      |> put_req_header("authorization", "Bearer " <> key)
      |> post(~p"/csuitefinder/email/deliverable", %{email: "jane@acme.com"})
      |> json_response(200)

      assert Repo.reload(account).balance_micro == 25_000
    end

    test "are refused at a zero balance rather than served free", %{conn: conn} do
      # The point of the gate: these calls cost us real money upstream, so an
      # account that has spent down to nothing must not keep unlimited access.
      {_account, key} = Fixtures.account_with_key(usd: 0.0)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> post(~p"/csuitefinder/company/info", %{email: "jane@acme.com"})
        |> json_response(402)

      assert body["error"] == "insufficient_credit"
      assert body["metered"] == false
      assert body["reason"] == "no_balance"
      assert body["message"] =~ "included"
      assert TregStub.call_count() == 0
    end

    test "any positive balance unlocks all of them", %{conn: conn} do
      {account, key} = Fixtures.account_with_key(usd: 0.0025)
      conn = put_req_header(conn, "authorization", "Bearer " <> key)

      TregStub.stub(fn
        "treg.people.enrich", _ -> {200, TregStub.routed(%{"full_name" => "Jane Doe"}), 4_900}
        "treg.companies.enrich", _ -> {200, TregStub.routed(%{"name" => "Acme"}), 1_900}
      end)

      json_response(post(conn, ~p"/csuitefinder/email/enrich", %{email: "jane@acme.com"}), 200)
      json_response(post(conn, ~p"/csuitefinder/name/who", %{email: "jane@acme.com"}), 200)
      json_response(post(conn, ~p"/csuitefinder/company/info", %{email: "jane@acme.com"}), 200)

      assert Repo.reload(account).balance_micro == 2_500
    end

    test "the last of the credit still buys a find, and then finds stop", %{conn: conn} do
      {account, key} = Fixtures.account_with_key(usd: 0.0025)
      conn = put_req_header(conn, "authorization", "Bearer " <> key)

      TregStub.stub(fn "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}, 1_900}
      end)

      json_response(
        post(conn, ~p"/csuitefinder/email/find", %{full_name: "Jane Doe", domain: "acme.com"}),
        200
      )

      assert Repo.reload(account).balance_micro == 0

      body =
        conn
        |> post(~p"/csuitefinder/email/find", %{full_name: "Sam Poe", domain: "acme.com"})
        |> json_response(402)

      assert body["reason"] == "no_balance"
    end
  end

  describe "keys" do
    test "a revoked key stops working", %{conn: conn} do
      {_account, key} = Fixtures.account_with_key()
      {:ok, _account, api_key} = Accounts.authenticate(key)
      {:ok, _} = Accounts.revoke_api_key(api_key)

      conn
      |> put_req_header("authorization", "Bearer " <> key)
      |> get(~p"/csuitefinder/billing/balance")
      |> json_response(401)
    end

    test "the plaintext key is not recoverable from storage" do
      {_account, key} = Fixtures.account_with_key()
      stored = Repo.all(Accounts.ApiKey)

      refute Enum.any?(stored, &(&1.key_hash == key))
    end
  end

  describe "GET /csuitefinder/billing/balance" do
    test "reports the balance and price list", %{conn: conn} do
      {_account, key} = Fixtures.account_with_key(usd: 5.0)

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> get(~p"/csuitefinder/billing/balance")
        |> json_response(200)

      assert body["balance_usd"] == 5.0
      assert body["prices_usd"]["email.find"] == 0.0025
      assert body["prices_usd"]["phone.find"] == 0.025
      assert body["prices_usd"]["company.info"] == 0
    end
  end
end
