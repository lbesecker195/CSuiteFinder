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
      assert html =~ "free credit"
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
      assert html =~ "Buy credit"
    end

    test "prices the bundles from the live constants", %{conn: conn} do
      html = conn |> get(~p"/account") |> html_response(200)

      # Every purchase Pricing sells, with the credit it will actually grant.
      for b <- Pricing.bundles() do
        assert html =~ "$" <> delimited(b.usd)
        assert html =~ "$" <> delimited(b.credit_usd) <> " of credit"
      end

      # The bonus is the volume discount, stated as money.
      assert html =~ "+$500 free"
      assert html =~ "0.0025"
      assert html =~ "0.025"
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
        assert body =~ "$" <> delimited(b.credit_usd) <> " of credit"
      end

      assert body =~ "of free credit"
    end

    test "documents the discovery route, so an agent knows where to start", %{conn: conn} do
      # An agent holding only a company domain needs to be told this exists,
      # or it will try to guess names to feed /email/find.
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "/csuitefinder/company/people"
      assert body =~ "department=executive"
      assert body =~ "This is the discovery route"
    end

    test "names no supplier", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200) |> String.downcase()

      for term <- ~w(treg thecompaniesapi trykitt tomba hunter findymail leadmagic) do
        refute String.contains?(body, term), "llms.txt mentioned #{term}"
      end
    end
  end

  describe "the developer endpoint reference" do
    test "says what each endpoint does, not just its shape", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "What it does"
      # Every documented route needs a description, or the column is decoration.
      assert html =~ "Who works at a company"
      assert html =~ "Is this mailbox real?"
      assert html =~ "The person behind an address"
    end

    test "the table can scroll rather than forcing the page to", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s|class="table-scroll endpoints"|
    end

    test "does not advertise the cache bypass", %{conn: conn} do
      # A refresh costs us an upstream call and earns the same as a cache hit,
      # so it is not something to put in front of customers.
      for path <- ["/", "/start"] do
        refute conn |> get(path) |> html_response(200) =~ "refresh=true"
      end

      refute conn |> get(~p"/llms.txt") |> response(200) =~ "refresh=true"
    end
  end

  describe "prices are in dollars" do
    test "no public surface still talks about tokens", %{conn: conn} do
      # The only surviving "token" is PayPal's own query parameter, which is
      # their name for an order id and nothing to do with our pricing.
      for path <- ["/", "/start", "/account"] do
        html = conn |> get(path) |> html_response(200)
        stripped = String.replace(html, ~r/\?token=|params\.get\("token"\)|order id back as/, "")
        refute stripped =~ ~r/\btokens\b/i, "#{path} still mentions tokens"
      end

      refute conn |> get(~p"/llms.txt") |> response(200) =~ ~r/\btokens\b/i
    end

    test "the headline prices appear where a buyer looks", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "0.0025"
      assert html =~ "0.025"
      assert html =~ "of credit"
    end
  end

  describe "printed URLs" do
    test "use the configured public URL, not the request's Host header", %{conn: conn} do
      # The Host header is caller-controlled. Deriving documentation URLs from it
      # means a forged Host hands the reader a link to someone else's server.
      body =
        conn
        |> Map.put(:host, "evil.example.com")
        |> get(~p"/llms.txt")
        |> response(200)

      assert body =~ "https://csuitefinder.test"
      refute body =~ "evil.example.com"
      refute body =~ "localhost"
    end

    test "the home page and /start agree with it", %{conn: conn} do
      for path <- ["/", "/start"] do
        html = conn |> get(path) |> html_response(200)
        assert html =~ "https://csuitefinder.test", "#{path} printed a different base URL"
        refute html =~ "localhost", "#{path} printed a localhost URL"
      end
    end
  end

  describe "GET /start" do
    test "renders the getting-started page", %{conn: conn} do
      html = conn |> get(~p"/start") |> html_response(200)

      assert html =~ "Get started"
      assert html =~ "/llms.txt"
      assert html =~ "free credit"
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

      assert body["currency"] == "USD"
      assert body["prices_usd"]["email.find"] == 0.0025
      assert body["prices_usd"]["phone.find"] == 0.025
      assert body["prices_usd"]["email.enrich"] == 0
      assert body["minimum_purchase_usd"] == 1_000
      assert body["free_trial_usd"] == 1.0
      # No token vocabulary left anywhere in the published terms.
      refute Jason.encode!(body) =~ "token"
    end
  end
end
