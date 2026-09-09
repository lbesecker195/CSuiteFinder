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

  defp delimited(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  describe "GET /account" do
    test "renders the account page", %{conn: conn} do
      html = conn |> get(~p"/account") |> html_response(200)

      assert html =~ "Your account"
      assert html =~ "Create account"
      assert html =~ "Buy tokens"
    end

    test "prices the bundles from the live constants", %{conn: conn} do
      html = conn |> get(~p"/account") |> html_response(200)

      # Every bundle Pricing sells, with the token count it will actually credit.
      for b <- Pricing.bundles() do
        assert html =~ "$" <> delimited(b.usd)
        assert html =~ delimited(b.tokens) <> " tokens"
      end

      assert html =~ "1,000,000 tokens"
      assert html =~ "better rate"
      assert html =~ to_string(Pricing.trial_tokens())
    end

    test "never embeds a key — the browser supplies its own", %{conn: conn} do
      html = conn |> get(~p"/account") |> html_response(200)

      refute html =~ "csf_live_" <> "e"
      assert html =~ "localStorage"
    end

    test "is reachable from the landing page", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s|href="/account"|
    end
  end

  describe "site navigation" do
    test "every page carries the same three header items", %{conn: conn} do
      for path <- ["/", "/start", "/account"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s|class="sitenav"|, "#{path} has no nav"

        for href <- ["/start", "/#pricing", "/account"] do
          assert html =~ ~s|href="#{href}"|, "#{path} is missing #{href}"
        end
      end
    end

    test "the account item is rendered signed-out and swapped client-side", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # Server-rendered as the signed-out label, because the key lives only in
      # the browser — and a browser that blocks storage still gets a usable one.
      assert html =~ "Register / Log in"
      assert html =~ ~s|id="nav-account"|
      assert html =~ ~s|localStorage.getItem("csf_api_key")|
      assert html =~ ~s|"Dashboard"|
    end

    test "the pricing link has something to land on", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s|id="pricing"|
      # Docs left the nav but must stay reachable from the page itself.
      assert html =~ ~s|id="developers"|
      assert html =~ ~s|href="#developers"|
    end
  end

  describe "GET /llms.txt" do
    test "serves an agent-readable description as plain text", %{conn: conn} do
      conn = get(conn, ~p"/llms.txt")

      assert response_content_type(conn, :txt) =~ "text/plain"
      body = response(conn, 200)

      assert body =~ "# CSuiteFinder"
      assert body =~ "/csuitefinder/email/find"
      assert body =~ "Authorization: Bearer"
    end

    test "quotes the same prices the invoice uses", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      for b <- Pricing.bundles() do
        assert body =~ "$" <> delimited(b.usd)
        assert body =~ delimited(b.tokens) <> " tokens"
      end

      assert body =~ to_string(Pricing.trial_tokens())
    end

    test "says plainly that it is not a prospect database", %{conn: conn} do
      # Agents otherwise waste turns hunting for a people-search endpoint that
      # does not exist.
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "prospect database"
      assert body =~ "no people-search endpoint"
      assert body =~ "It resolves an address for someone you can already NAME"
    end

    test "names no supplier", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200) |> String.downcase()

      for term <- ~w(treg thecompaniesapi trykitt tomba hunter findymail leadmagic) do
        refute String.contains?(body, term), "llms.txt mentioned #{term}"
      end
    end
  end

  describe "GET /start" do
    test "renders the getting-started page", %{conn: conn} do
      html = conn |> get(~p"/start") |> html_response(200)

      assert html =~ "Get started"
      assert html =~ "/llms.txt"
      assert html =~ to_string(Pricing.trial_tokens())
    end

    test "offers a path for people without an assistant", %{conn: conn} do
      html = conn |> get(~p"/start") |> html_response(200)

      assert html =~ "In your browser"
      assert html =~ ~s|href="/account"|
      assert html =~ "curl"
    end

    test "is linked from the home page", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s|href="/start"|
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
