defmodule CsuiteFinderWeb.PageTest do
  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.Billing.{Plans, Pricing}

  describe "GET /" do
    test "renders the landing page", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "CSuiteFinder"
      assert html =~ ~s|href="/teams"|
      assert html =~ ~s|href="/developers"|
    end

    test "prices the seat from Plans rather than from markup", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # The price, not the prose. The wording around it is the marketing's to
      # change; a test that pins the sentence just breaks when someone edits it.
      assert html =~ "$" <> delimited(Plans.seat_usd())
      assert html =~ ~s|href="/account"|
    end

    test "leaves per-lookup pricing to the developer page", %{conn: conn} do
      # The home page's job is to sort a visitor into one of two products. A
      # salesperson who sees $0.0025 next to $999 does the arithmetic and reads
      # the seat as a rip-off, which is the wrong conversation to start on the
      # first screen — the unit prices belong where they are the offer.
      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "$" <> fmt(Pricing.price_usd("email.find"))
      refute html =~ "$" <> fmt(Pricing.price_usd("phone.find"))
    end
  end

  describe "GET /developers" do
    test "renders the API page", %{conn: conn} do
      html = conn |> get(~p"/developers") |> html_response(200)

      assert html =~ "CSuiteFinder"
      assert html =~ "/csuitefinder/register"
    end

    test "shows the live per-lookup pricing", %{conn: conn} do
      html = conn |> get(~p"/developers") |> html_response(200)

      assert html =~ "$" <> fmt(Pricing.price_usd("email.find"))
      assert html =~ "$" <> fmt(Pricing.price_usd("phone.find"))
      assert html =~ "never expires"
    end

    test "documents every billable endpoint", %{conn: conn} do
      html = conn |> get(~p"/developers") |> html_response(200)

      for endpoint <- Map.keys(Pricing.list()) do
        assert html =~ endpoint, "developer page does not mention #{endpoint}"
      end
    end
  end

  defp fmt(usd), do: :erlang.float_to_binary(usd, [:compact, decimals: 4])

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

      # The account page prices purchases; the amounts come from Pricing.
      for b <- Pricing.bundles() do
        assert html =~ "$" <> delimited(b.usd)
      end
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

  describe "analytics" do
    test "the tag is emitted on every page when configured" do
      Application.put_env(:csuite_finder, :ga_measurement_id, "G-TESTID")
      on_exit(fn -> Application.put_env(:csuite_finder, :ga_measurement_id, nil) end)

      for path <- ["/", "/teams", "/developers", "/start", "/account"] do
        html = build_conn() |> get(path) |> html_response(200)
        assert html =~ "googletagmanager.com/gtag/js?id=G-TESTID", "#{path} is untagged"
        assert html =~ "gtag('config', 'G-TESTID')"
      end
    end

    test "and is absent when it is not, so dev traffic stays out of the data",
         %{conn: conn} do
      # A page silently missing the tag is invisible in the numbers rather than
      # obviously broken, so both directions are worth asserting.
      refute conn |> get(~p"/") |> html_response(200) =~ "googletagmanager"
    end
  end

  describe "the two halves of the business" do
    test "the home page sends each audience somewhere", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|href="/teams"|
      assert html =~ ~s|href="/developers"|
    end

    test "/teams prices a seat from Plans", %{conn: conn} do
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ "$" <> delimited(Plans.seat_usd())
      assert html =~ "per person, per month"

      for item <- Plans.seat().includes do
        assert html =~ item
      end
    end

    test "/teams steers a developer away without quoting them a unit price", %{conn: conn} do
      # A seat sold to someone who wanted an API churns in a month, so the page
      # still points them at the other plan — but a salesperson reading this
      # page must not meet a per-answer price on the way past.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ ~s|href="/developers"|
      refute html =~ "$" <> fmt(Pricing.price_usd("email.find"))
      refute html =~ "$" <> fmt(Pricing.price_usd("phone.find"))
    end

    test "every marketing page shows the same sheet, from one partial", %{conn: conn} do
      # The spreadsheet is the first thing a salesperson recognises, and the
      # number in its status bar is what a seat actually buys — derived, not
      # typed, so it cannot drift from the plan. One partial, three pages: a
      # second copy is a second place to forget to change.
      for path <- ["/", "/teams", "/developers"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s|class="sheet"|, "#{path} has no sheet"
        assert html =~ "Rows <strong>#{delimited(Plans.seat_lookups().emails)}</strong> / month"

        for column <- ~w(Name Title Email Deliverable) do
          assert html =~ "<td>#{column}</td>", "#{path} is missing the #{column} column"
        end

        for row <- CsuiteFinderWeb.SampleSheet.rows() do
          assert html =~ row.name, "#{path} is missing #{row.name}"
          assert html =~ row.title
          assert html =~ row.email
        end
      end
    end

    test "titles are abbreviated the way a sheet abbreviates them", %{conn: _conn} do
      # A column of "Chief Financial Officer" is a column nobody can scan.
      titles = CsuiteFinderWeb.SampleSheet.rows() |> Enum.map(& &1.title)

      assert "CEO" in titles
      assert "CFO" in titles

      for title <- titles do
        assert String.length(title) <= 12, "#{title} is too long to sit in a cell"
        refute title =~ ~r/Chief|Officer|President/i, "#{title} is not abbreviated"
      end
    end

    test "the deliverability column is binary, and never says maybe", %{conn: conn} do
      # An amber "accept-all" tier is a question mark next to an address, and a
      # reader who has to ask what it means stops reading. The column answers
      # the only question they have — will this bounce — and the two that would
      # stay marked as such.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ "<td>Deliverable</td>"
      refute html =~ "Accept-all"

      for row <- CsuiteFinderWeb.SampleSheet.rows() do
        assert row.status in [:deliverable, :undeliverable]
      end

      assert Enum.count(CsuiteFinderWeb.SampleSheet.rows(), &(&1.status == :undeliverable)) == 2
    end

    test "the sheet keeps what the mailbox check actually returned", %{conn: _conn} do
      # The page draws two states; the data behind it still knows which rows were
      # confirmed, which sit on accept-all domains, and which were rejected.
      # Collapsing that in the source as well as the view would lose it for good.
      raws = CsuiteFinderWeb.SampleSheet.rows() |> Enum.map(& &1.raw) |> Enum.frequencies()

      assert Map.keys(raws) |> Enum.sort() == [:accept_all, :confirmed, :rejected]
      assert raws.rejected > 0, "a sheet with no failures in it is a sheet nobody believes"
    end

    test "the sheet says where each title came from", %{conn: _conn} do
      # Enrichment answers for most of them; where it does not, the company's
      # published leadership page does — inferring rather than dropping the row
      # is what the product does everywhere else, and the row records which.
      for row <- CsuiteFinderWeb.SampleSheet.rows() do
        assert row.title_source in [:enrichment, :public_record],
               "#{row.name} does not say where its title came from"
      end

      sources = CsuiteFinderWeb.SampleSheet.rows() |> Enum.map(& &1.title_source)
      assert :enrichment in sources
    end

    test "phone numbers are not sold anywhere in the copy", %{conn: conn} do
      # The endpoints exist and stay documented, but nothing on the site offers
      # a phone number to a buyer: coverage for the people these pages are about
      # is poor enough that promising one sells a disappointment. Guarded here
      # because a sentence like that grows back the first time someone edits the
      # hero.
      for path <- ["/", "/teams", "/account", "/start"] do
        html = conn |> get(path) |> html_response(200)

        refute html =~ ~r/phone/i, "#{path} still sells phone numbers"
        refute html =~ ~r/direct (number|line)/i, "#{path} still sells direct numbers"
      end
    end

    test "but the phone endpoints stay documented for developers", %{conn: conn} do
      # Removing the copy is a positioning decision, not a deprecation. An agent
      # or an integrator reading the reference must still find these.
      html = conn |> get(~p"/developers") |> html_response(200)

      for path <- ~w(/csuitefinder/phone/find /csuitefinder/phone/valid
                     /csuitefinder/phone/name /csuitefinder/phone/enrich
                     /csuitefinder/phone/company) do
        assert html =~ path, "the developer reference dropped #{path}"
      end

      assert conn |> get(~p"/llms.txt") |> response(200) =~ "/csuitefinder/phone/find"
    end

    test "an emailed link puts the reader's own row in the sheet", %{conn: conn} do
      html =
        conn
        |> get(~p"/teams?name=Jane%20Doe&email=jane.doe@acme.com")
        |> html_response(200)

      assert html =~ "Jane Doe"
      assert html =~ "jane.doe@acme.com"
      # Third in the sheet, which is the cell the cursor sits on.
      assert html =~ ~r/row-head">3<\/td>\s*<td>Jane Doe/
      assert html =~ ~s|<tr class="you-row">|
    end

    test "grey for the reader, green for confirmed, red for failed", %{conn: conn} do
      html =
        conn
        |> get(~p"/teams?name=Jane%20Doe&email=jane.doe@acme.com")
        |> html_response(200)

      # The reader's own row is not another result and must not read as one.
      assert html =~ ~s|<tr class="you-row">|
      assert html =~ ~s|<tr class="ok-row">|
      assert html =~ ~s|<tr class="bad-row">|
    end

    test "a name alone is not a row", %{conn: conn} do
      # Without an address there is nothing to put in the Email column, and a
      # half-filled row is worse than none.
      html = conn |> get(~p"/teams?name=Jane%20Doe") |> html_response(200)
      refute html =~ ~s|<tr class="you-row">|
    end

    test "the name is derived from the address when the link carries only one",
         %{conn: conn} do
      html = conn |> get(~p"/teams?email=sam.roe@acme.com") |> html_response(200)

      assert html =~ "Sam Roe"
      assert html =~ ~s|<tr class="you-row">|
    end

    test "neither value can carry markup into the page", %{conn: conn} do
      # Both come from a URL anybody can build, into templates that escape
      # nothing of their own.
      for {name, email} <- [
            {"<script>alert(1)</script>", "jane@acme.com"},
            {"Jane Doe", "\"><script>alert(1)</script>"},
            {"Jane\" onload=\"x", "jane@acme.com"}
          ] do
        html =
          conn
          |> get("/teams?name=#{URI.encode_www_form(name)}&email=#{URI.encode_www_form(email)}")
          |> html_response(200)

        refute html =~ "alert(1)"
        refute html =~ "onload="
      end
    end

    test "the sheet publishes no working address", %{conn: conn} do
      # These are real people. The masking is the only thing standing between a
      # marketing page and ten inboxes, so it is worth a test of its own.
      html = conn |> get(~p"/teams") |> html_response(200)

      for row <- CsuiteFinderWeb.SampleSheet.rows() do
        assert String.contains?(row.email, "•"), "#{row.email} is not masked"
      end

      refute html =~ ~r/[a-z]{4,}\.[a-z]{4,}@[a-z]+\.com/
    end

    test "/teams says the monthly credit does not roll over", %{conn: conn} do
      # A customer who discovers this at renewal feels cheated. It is stated on
      # the page, in the plan box, and in the comparison table.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ "does not roll over"
      assert html =~ "$#{delimited(Plans.seat_usd())} of lookup credit"

      for caveat <- Plans.seat().caveats do
        assert html =~ caveat
      end
    end
  end

  describe "site navigation" do
    test "every page carries a nav, and the pricing link stays on the page", %{conn: conn} do
      # `#pricing` is a bare fragment on purpose: it scrolls down whichever page
      # the visitor is on rather than crossing them into the other audience's
      # plan, which is the one link that would undo the whole split.
      for path <- ["/", "/teams", "/developers", "/start", "/account"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s|class="sitenav"|, "#{path} has no nav"
        assert html =~ ~s|href="#pricing"|, "#{path} has no in-page pricing link"
        assert html =~ ~s|id="pricing"|, "#{path} has nothing for #pricing to land on"
        assert html =~ ~s|href="/account"|, "#{path} is missing the account link"
      end
    end

    test "nav items are tagged with the audience they belong to", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|data-aud="sales"|
      assert html =~ ~s|data-aud="developer"|
      assert html =~ ~s|data-aud="any"|
    end

    test "a page that knows its audience records it for the pages that cannot",
         %{conn: conn} do
      # /account and / cannot know who is looking; /teams and /developers can,
      # and saying so is what makes the rest of the site follow the visitor.
      assert conn |> get(~p"/teams") |> html_response(200) =~ ~s|var FIXED = "sales"|
      assert conn |> get(~p"/developers") |> html_response(200) =~ ~s|var FIXED = "developer"|
      assert conn |> get(~p"/account") |> html_response(200) =~ "var FIXED = null"
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
      # The nav's Pricing item lands on the audience fork, which is where both
      # prices are stated; the per-lookup detail is one click further on.
      assert html =~ ~s|href="/developers"|
    end
  end

  describe "a campaign link that fills in the signup" do
    test "an address in the query string lands in the field", %{conn: conn} do
      html = conn |> get(~p"/account?email=jane.doe@acme.com") |> html_response(200)

      assert html =~ ~s|value="jane.doe@acme.com"|
    end

    test "anything that is not an address is dropped, not printed", %{conn: conn} do
      # This parameter is in a URL anybody can build, and these templates do no
      # escaping of their own — so it is the one input on the site that could
      # put markup into a page.
      for attempt <- [
            "\">   <script>alert(1)</script>",
            "not an email",
            "a@b",
            "<img src=x onerror=alert(1)>",
            String.duplicate("a", 300) <> "@acme.com"
          ] do
        html = conn |> get("/account?email=#{URI.encode_www_form(attempt)}") |> html_response(200)

        assert html =~ ~s|value=""|, "#{attempt} was not rejected"
        refute html =~ "alert(1)"
        refute html =~ "onerror"
      end
    end

    test "the address is remembered across pages, not left in the URL", %{conn: conn} do
      # Picked up wherever the visitor lands, so a link into /teams still fills
      # the signup two clicks later — and taken out of the address bar, because
      # an email in a URL ends up in bookmarks and referrer headers.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ "csf_email"
      assert html =~ "params.delete(\"email\")"
      assert conn |> get(~p"/account") |> html_response(200) =~ "csfPrefillEmail"
    end
  end

  describe "getting started" do
    test "is linked from the foot of the sales and account pages", %{conn: conn} do
      for path <- ["/teams", "/account"] do
        html = conn |> get(path) |> html_response(200)
        footer = html |> String.split("<footer>") |> List.last()

        assert footer =~ ~s|href="/start"|, "#{path} has no getting-started link in its footer"
      end
    end

    test "/start speaks to someone who already has a key", %{conn: conn} do
      # Telling a paying customer to sign up for a free trial is the fastest way
      # to lose them at the last step. The page carries both sets of
      # instructions and shows the one that fits.
      html = conn |> get(~p"/start") |> html_response(200)

      assert html =~ ~s|data-signed="out"|
      assert html =~ ~s|data-signed="in"|
      assert html =~ "CSF_KEY_HERE"
      assert html =~ ~s|localStorage.getItem("csf_api_key")|
    end

    test "and is rendered signed-out, so no-JS still gets a usable page", %{conn: conn} do
      html = conn |> get(~p"/start") |> html_response(200)

      # Every signed-in block ships hidden; the script reveals them.
      for block <- Regex.scan(~r/data-signed="in"[^>]*/, html) do
        assert hd(block) =~ "hidden", "a signed-in block is visible before the script runs"
      end
    end

    test "and never ships a real key in the markup", %{conn: conn} do
      # The substitution happens in the browser from the visitor's own storage.
      # The server has only a hash and must never render one anyway.
      html = conn |> get(~p"/start") |> html_response(200)
      refute html =~ "csf_live_"
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
      end

      assert body =~ "A dollar buys a dollar of credit"

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
      html = conn |> get(~p"/developers") |> html_response(200)

      assert html =~ "What it does"
      # Every documented route needs a description, or the column is decoration.
      assert html =~ "Who works at a company"
      assert html =~ "Is this mailbox real?"
      assert html =~ "The person behind an address"
    end

    test "the table can scroll rather than forcing the page to", %{conn: conn} do
      html = conn |> get(~p"/developers") |> html_response(200)
      assert html =~ ~s|class="table-scroll endpoints"|
    end

    test "does not advertise the cache bypass", %{conn: conn} do
      # A refresh costs us an upstream call and earns the same as a cache hit,
      # so it is not something to put in front of customers.
      for path <- ["/", "/developers", "/start"] do
        refute conn |> get(path) |> html_response(200) =~ "refresh=true"
      end

      refute conn |> get(~p"/llms.txt") |> response(200) =~ "refresh=true"
    end
  end

  describe "llms.txt cannot drift from the router" do
    test "every route it documents is actually routed", %{conn: conn} do
      # An agent follows this file literally. A path that renames without the
      # docs following sends it to a 404 it has no way to recover from.
      routed =
        CsuiteFinderWeb.Router.__routes__()
        |> Enum.map(& &1.path)
        |> MapSet.new()

      documented =
        conn
        |> get(~p"/llms.txt")
        |> response(200)
        |> then(&Regex.scan(~r{/csuitefinder/[a-z/]+}, &1))
        |> List.flatten()
        |> Enum.map(&String.trim_trailing(&1, "/"))
        |> Enum.uniq()

      for path <- documented do
        assert MapSet.member?(routed, path), "llms.txt documents #{path}, which is not routed"
      end
    end

    test "the renamed routes are gone and their replacements are live", %{conn: conn} do
      routed = CsuiteFinderWeb.Router.__routes__() |> Enum.map(& &1.path) |> MapSet.new()

      # /name/who stays routed on purpose: it is published in the treg catalog
      # listing, and a listed endpoint that 404s fails their verification.
      assert MapSet.member?(routed, "/csuitefinder/name/who")
      refute MapSet.member?(routed, "/csuitefinder/phone/who")

      for path <- ~w(/csuitefinder/email/name /csuitefinder/phone/name
                     /csuitefinder/phone/enrich /csuitefinder/phone/company) do
        assert MapSet.member?(routed, path)
      end
    end
  end

  describe "prices are in dollars" do
    test "no public surface still talks about tokens", %{conn: conn} do
      # The only surviving "token" is PayPal's own query parameter, which is
      # their name for an order id and nothing to do with our pricing.
      for path <- ["/", "/developers", "/start", "/account"] do
        html = conn |> get(path) |> html_response(200)
        stripped = String.replace(html, ~r/\?token=|params\.get\("token"\)|order id back as/, "")
        refute stripped =~ ~r/\btokens\b/i, "#{path} still mentions tokens"
      end

      refute conn |> get(~p"/llms.txt") |> response(200) =~ ~r/\btokens\b/i
    end

    test "the headline prices appear where a buyer looks", %{conn: conn} do
      # Rendered from Pricing and Plans, not typed into the markup, so a page
      # cannot advertise a number the invoice disagrees with.
      developers = conn |> get(~p"/developers") |> html_response(200)
      assert developers =~ "$" <> fmt(Pricing.price_usd("email.find"))
      assert developers =~ "$" <> fmt(Pricing.price_usd("phone.find"))

      teams = build_conn() |> get(~p"/teams") |> html_response(200)
      assert teams =~ "$" <> delimited(Plans.seat_usd())
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

    test "the developer page and /start agree with it", %{conn: conn} do
      for path <- ["/developers", "/start"] do
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
