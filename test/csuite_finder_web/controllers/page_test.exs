defmodule CsuiteFinderWeb.PageTest do
  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Billing.Pricing

  describe "GET /" do
    test "renders the landing page", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "CSuiteFinder"
      assert html =~ "/csuitefinder/register"
    end

    test "shows the live pricing rather than numbers typed into markup",
         %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "0.0025"
      assert html =~ "$1,000"
      assert html =~ "400,000"
      assert html =~ to_string(Pricing.trial_tokens())
    end

    test "documents every billable endpoint", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      for endpoint <- Map.keys(Pricing.list()) do
        assert html =~ endpoint, "landing page does not mention #{endpoint}"
      end
    end
  end

  describe "GET /csuitefinder/pricing" do
    test "publishes the same terms as JSON", %{conn: conn} do
      body = conn |> get(~p"/csuitefinder/pricing") |> json_response(200)

      assert body["token_price_usd"] == 0.0025
      assert body["minimum_bundle_usd"] == 1_000
      assert body["tokens_per_minimum_bundle"] == 400_000
      assert body["free_trial_tokens"] == 400
      assert body["prices_in_tokens"]["email.find"] == 1
      assert body["prices_in_tokens"]["email.enrich"] == 0
    end
  end
end
