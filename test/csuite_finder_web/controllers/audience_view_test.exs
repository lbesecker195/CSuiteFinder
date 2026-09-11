defmodule CsuiteFinderWeb.AudienceViewTest do
  @moduledoc """
  What each audience is shown, and — more to the point — what it is not.

  A salesperson who meets a fraction-of-a-cent price next to $999 does the
  arithmetic and stops reading, so the API's own responses withhold it rather
  than relying on a page to hide it.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.Fixtures

  defp balance(conn, key) do
    conn
    |> put_req_header("authorization", "Bearer " <> key)
    |> get(~p"/csuitefinder/billing/balance")
    |> json_response(200)
  end

  describe "the balance endpoint" do
    test "quotes a developer their per-answer prices", %{conn: conn} do
      {_account, key} = Fixtures.account_with_key(usd: 5.0, audience: "developer")
      body = balance(conn, key)

      assert body["audience"] == "developer"
      assert body["prices_usd"]["email.find"] == Pricing.price_usd("email.find")
      assert body["terms"]["prices_usd"]
    end

    test "quotes a seat holder the seat, and no unit price anywhere", %{conn: conn} do
      {_account, key} = Fixtures.account_with_key(usd: 5.0, audience: "sales")
      body = balance(conn, key)

      assert body["audience"] == "sales"
      assert body["balance_usd"] == 5.0
      refute body["prices_usd"]
      refute body["terms"]["prices_usd"]
      assert body["terms"]["seat_usd_per_month"] == CsuiteFinder.Billing.Plans.seat_usd()

      # Nothing in the whole response should read as a per-answer rate.
      refute Jason.encode!(body) =~ "0.0025"
    end
  end

  describe "the usage endpoint" do
    test "breaks spend down per endpoint for a developer", %{conn: conn} do
      {_account, key} = Fixtures.account_with_key(usd: 5.0, audience: "developer")

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> get(~p"/csuitefinder/billing/usage")
        |> json_response(200)

      assert Map.has_key?(body["totals"], "charged_usd")
    end

    test "withholds the per-endpoint spend from a seat holder", %{conn: conn} do
      # Charge ÷ answers is the unit price. A seat holder still gets the total
      # and the call counts, which is what they actually want to know.
      {account, key} = Fixtures.account_with_key(usd: 5.0, audience: "sales")

      {:ok, _} =
        CsuiteFinder.Billing.settle(%{
          account: account,
          endpoint: "email.find",
          found: true
        })

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> get(~p"/csuitefinder/billing/usage")
        |> json_response(200)

      [row] = body["by_endpoint"]
      assert row["endpoint"] == "email.find"
      assert row["calls"] == 1
      refute Map.has_key?(row, "charged_micro")
      assert Map.has_key?(body["totals"], "credit_used_usd")
    end
  end

  describe "switching sides" do
    test "an account can ask for the other half's view", %{conn: conn} do
      {_account, key} = Fixtures.account_with_key(usd: 5.0, audience: "sales")

      body =
        conn
        |> put_req_header("authorization", "Bearer " <> key)
        |> post(~p"/csuitefinder/billing/audience", %{"audience" => "developer"})
        |> json_response(200)

      assert body["audience"] == "developer"
      assert body["terms"]["prices_usd"]

      # And it sticks for the next request.
      assert balance(build_conn(), key)["audience"] == "developer"
    end

    test "an unauthenticated switch is refused", %{conn: conn} do
      assert conn
             |> post(~p"/csuitefinder/billing/audience", %{"audience" => "developer"})
             |> json_response(401)
    end
  end

  describe "registration" do
    test "carries the audience the visitor signed up under", %{conn: conn} do
      body =
        conn
        |> post(~p"/csuitefinder/register", %{
          "email" => "signup#{System.unique_integer([:positive])}@test.com",
          "audience" => "developer"
        })
        |> json_response(201)

      assert body["audience"] == "developer"
    end

    test "defaults to sales when the visitor did not come through a door", %{conn: conn} do
      body =
        conn
        |> post(~p"/csuitefinder/register", %{
          "email" => "signup#{System.unique_integer([:positive])}@test.com"
        })
        |> json_response(201)

      assert body["audience"] == "sales"
    end
  end

  describe "what a seat holder is never quoted" do
    test "no per-answer price in the llms.txt commands", %{conn: conn} do
      # A seat holder has a month of credit and no meter. A running total beside
      # every command reads as money about to be charged, and puts them off a
      # thing they have already paid for.
      body = conn |> get(~p"/llms.txt") |> response(200)
      [_, commands] = String.split(body, "## Commands", parts: 2)
      [commands, _] = String.split(commands, "## Endpoints", parts: 2)

      refute commands =~ "$"
      assert commands =~ "Included in your seat"
    end

    test "but a developer is, because they are spending a balance", %{conn: conn} do
      body = conn |> get(~p"/llms.txt?audience=developer") |> response(200)
      [_, commands] = String.split(body, "## Commands", parts: 2)
      [commands, _] = String.split(commands, "## Endpoints", parts: 2)

      assert commands =~ "per person returned"
      assert commands =~ "$"
      refute commands =~ "Included in your seat"
    end

    test "and /start ships the sales wording visible, developer wording hidden",
         %{conn: conn} do
      # /start is reachable from the sales footer, so it cannot fix itself to
      # the developer audience. Without script the safe half is what shows.
      html = conn |> get(~p"/start") |> html_response(200)

      assert html =~ ~s|data-aud="developer" hidden|
      refute html =~ ~s|data-aud="sales" hidden|
    end
  end
end
