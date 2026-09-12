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
      assert html =~ "/csuitefinder/email/find"
    end

    test "sends a reader to the account page for the token the example needs",
         %{conn: conn} do
      # The register call is no longer shown here — an agent gets it from
      # llms.txt, and a person wants the key rather than the call that mints
      # one. So the link that hands out the key has to stay, or the very next
      # thing on the page is a request the reader cannot make.
      html = conn |> get(~p"/developers") |> html_response(200)

      refute html =~ "/csuitefinder/register"
      assert html =~ ~s|<a href="/account">|
      assert html =~ "Authorization: Bearer"
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

    test "prices are grouped by family, product families first", %{conn: conn} do
      # Alphabetical buries each family's headline price among its free ones.
      html = conn |> get(~p"/developers") |> html_response(200)

      families =
        Regex.scan(~r{<th colspan="2" scope="colgroup">([a-z]+)</th>}, html)
        |> Enum.map(&List.last/1)

      assert Enum.take(families, 3) == ~w(email phone company)
      # Anything else falls in behind, alphabetically, without this list being
      # edited — which is the bit that has to keep working as endpoints are added.
      rest = Enum.drop(families, 3)
      assert rest == Enum.sort(rest)
    end

    test "the flagship leads its family and the odd one out sinks", %{conn: conn} do
      # Price order with two deliberate exceptions: email.find is what people
      # buy, so it goes first whatever it costs, and email.linkedin is six times
      # dearer for a question most callers do not have, so leading with it would
      # price the whole family wrong in the reader's head.
      html = conn |> get(~p"/developers") |> html_response(200)

      [_, email_block | _] = String.split(html, ~s|scope="colgroup">|)

      endpoints =
        Regex.scan(~r{<code>(email[\w.]+)</code>}, email_block) |> Enum.map(&List.last/1)

      assert hd(endpoints) == "email.find"
      assert List.last(endpoints) == "email.linkedin"
    end

    test "and dearest first in between", %{conn: conn} do
      html = conn |> get(~p"/developers") |> html_response(200)

      # The phone family has no exceptions, so it shows the plain rule.
      [_, _email, phone | _] = String.split(html, ~s|scope="colgroup">|)

      prices =
        Regex.scan(~r{<td class="num">(?:\$([\d.]+)|included)</td>}, phone)
        |> Enum.map(fn
          [_, value] -> String.to_float(value)
          [_] -> 0.0
        end)

      assert prices == Enum.sort(prices, :desc), "phone prices are not descending"
      assert hd(prices) == Pricing.price_usd("phone.find")
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
      assert html =~ "Buy credit"

      # Self-registration is gone from this page — accounts are opened by us —
      # so what has to be here is the way to ask for one.
      assert html =~ CsuiteFinderWeb.Layout.sales_href()
      refute html =~ "Create account"
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

    test "and its status bar quotes the product that page sells", %{conn: conn} do
      # The rows are shared; the figure under them is not. A monthly allowance
      # is what a seat buys, and quoting it to somebody buying credit per answer
      # is quoting them the wrong product's number.
      monthly = "Rows <strong>#{delimited(Plans.seat_lookups().emails)}</strong> / month"

      for path <- ["/", "/teams"] do
        assert conn |> get(path) |> html_response(200) =~ monthly,
               "#{path} should quote the seat's monthly rows"
      end

      developers = conn |> get(~p"/developers") |> html_response(200)

      assert developers =~ "<strong>$#{fmt(Pricing.price_usd("email.find"))}</strong> / email"
      refute developers =~ monthly
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
      assert html =~ ~r/<tr class="[^"]*\byou-row\b/
    end

    test "grey for the reader, green for confirmed, red for failed", %{conn: conn} do
      html =
        conn
        |> get(~p"/teams?name=Jane%20Doe&email=jane.doe@acme.com")
        |> html_response(200)

      # The reader's own row is not another result and must not read as one.
      assert html =~ ~r/<tr class="[^"]*\byou-row\b/
      assert html =~ ~r/<tr class="[^"]*\bok-row\b/
      assert html =~ ~r/<tr class="[^"]*\bbad-row\b/
    end

    test "a name alone is not a row", %{conn: conn} do
      # Without an address there is nothing to put in the Email column, and a
      # half-filled row is worse than none.
      html = conn |> get(~p"/teams?name=Jane%20Doe") |> html_response(200)
      refute html =~ ~r/<tr class="[^"]*\byou-row\b/
    end

    test "the name is derived from the address when the link carries only one",
         %{conn: conn} do
      html = conn |> get(~p"/teams?email=sam.roe@acme.com") |> html_response(200)

      assert html =~ "Sam Roe"
      assert html =~ ~r/<tr class="[^"]*\byou-row\b/
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

    test "a drawn cursor rests on the reader's own address", %{conn: conn} do
      html =
        conn
        |> get(~p"/teams?name=Jane%20Doe&email=jane.doe@acme.com")
        |> html_response(200)

      # One pointer, in the cell holding their address — the same cell the
      # formula bar is showing.
      assert html =~ ~r/jane\.doe@acme\.com<span class="sheet-cursor"/
      assert length(String.split(html, ~s|class="sheet-cursor"|)) == 2
    end

    test "and on the third row when the link carried nothing", %{conn: conn} do
      html = conn |> get(~p"/teams") |> html_response(200)

      third = CsuiteFinderWeb.SampleSheet.rows() |> Enum.at(1)
      assert html =~ ~r/#{Regex.escape(third.email)}<span class="sheet-cursor"/
    end

    test "it cannot be mistaken for the real one", %{conn: conn} do
      # It never moves with the mouse and never takes a click, so a reader who
      # tries to use it is not left wondering why nothing happened.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ ~s|aria-hidden="true"|
      assert html =~ "pointer-events: none"
      assert html =~ "prefers-reduced-motion"
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
        assert html =~ ~s|href="/account"|, "#{path} is missing the account link"

        # The account page's anchor moves between its signed-in and signed-out
        # halves, because an id inside a hidden section is an id the browser
        # will not scroll to. Either form counts as somewhere to land.
        assert html =~ ~s|id="pricing"| or html =~ "data-pricing-anchor",
               "#{path} has nothing for #pricing to land on"
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

    test "the account page moves its anchor to whichever half is showing", %{conn: conn} do
      # Signed out, #pricing sat inside the hidden signed-in section, so the nav
      # link did nothing at all — the bug that made the site look broken.
      html = conn |> get(~p"/account") |> html_response(200)

      assert html =~ "data-pricing-anchor"
      assert html =~ "el.closest(\"section[hidden]\")"
      # Two candidates, one for each half. Counted as attributes on elements,
      # so the selector in the script below does not inflate it.
      anchors = Regex.scan(~r/<[^>]*\sdata-pricing-anchor/, html)
      assert length(anchors) == 2
    end

    test "the admin page has a way back to the site", %{conn: conn} do
      # It carries no nav on purpose, which left no links at all on it.
      previous = Application.get_env(:csuite_finder, :admin_token)
      Application.put_env(:csuite_finder, :admin_token, "nav-test-token")
      on_exit(fn -> Application.put_env(:csuite_finder, :admin_token, previous) end)

      html =
        conn
        |> put_req_header("x-admin-token", "nav-test-token")
        |> get(~p"/admin")
        |> html_response(200)

      assert html =~ ~s|<a href="/">Home</a>|
      assert html =~ ~s|href="/account"|
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

      # A real key is the prefix followed by 43 characters of url-safe base64.
      # So the thing to refuse is any secret material after the prefix, not the
      # prefix itself: the paste-in line shows `csf_live_...` on purpose, so a
      # reader can recognise the shape of the thing they are meant to swap in.
      # Refusing the bare prefix would forbid that and catch no secret.
      refute html =~ ~r/csf_live_[A-Za-z0-9_-]/
      assert html =~ "csf_live_..."
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

      # There is no free tier, and the file must not imply one.
      refute body =~ "of free credit"
      assert body =~ "$29.99"
    end

    test "documents the discovery route, so an agent knows where to start", %{conn: conn} do
      # An agent holding only a company domain needs to be told this exists,
      # or it will try to guess names to feed /email/find.
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "/csuitefinder/company/people"
      assert body =~ "department=executive"
      assert body =~ "This is the discovery route"
    end

    test "offers ten commands, and says they are not routes", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      commands = Regex.scan(~r/^### (\/[a-z]+)/m, body) |> Enum.map(&List.last/1)

      assert length(commands) == 10, "expected ten commands, got #{inspect(commands)}"

      # Order is deliberate: the one that shows what this does comes before the
      # one that explains it.
      assert ["/demo", "/find" | _] = commands

      # Dropped as a command, because every other command already ends in the
      # deliverability check. The guidance it carried has to survive that.
      refute "/verify" in commands
      assert body =~ "`accept_all` means the server takes everything"

      # Without this an agent will try to GET /find and get a 404 it cannot
      # recover from.
      assert body =~ "They are not routes"
    end

    test "/demo is capped at twenty rows and reports them honestly", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)
      [demo | _] = String.split(body, "### /find", parts: 2)
      [_, demo] = String.split(demo, "### /demo", parts: 2)
      # This is prose, so it wraps. Assert on the words, not the line breaks.
      demo = String.replace(demo, ~r/\s+/, " ")

      # Twenty rows from one company, so the cap is what bounds the spend — not
      # a budget the agent has to watch as it goes.
      assert demo =~ "limit=20"
      assert demo =~ "Twenty is the cap, not a target"

      # A short answer is the honest one; an agent told only "twenty" will widen
      # the search until it has twenty of something.
      assert demo =~ "Fewer than twenty is a real answer"

      # A row count read as a headcount is the mistake the last receipt made.
      assert demo =~ "as **rows**, not people"
      assert demo =~ "`accept_all` is not a pass"
    end

    test "no command edits what the caller gave it", %{conn: conn} do
      # An agent told to "clean a list" and left to interpret it will happily
      # rewrite the file in place. A row it deletes is a row nobody gets back,
      # and the verdict it deleted on can be wrong.
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "Never modify the list you were given"
      assert body =~ "leave the input exactly as it was"
      assert body =~ "Mark the dead rows; do not delete them."

      # And it says why, because a rule without a reason is one an agent talks
      # itself out of.
      assert body =~ "is not the same as `undeliverable`"
    end

    test "every command names the endpoints it runs", %{conn: conn} do
      # A command nobody can execute is a decoration. Each block has to point at
      # something real in the reference below it.
      body = conn |> get(~p"/llms.txt") |> response(200)
      [_intro, commands] = String.split(body, "## Commands", parts: 2)
      [commands, _rest] = String.split(commands, "## Endpoints", parts: 2)

      for block <- String.split(commands, "\n### ") |> Enum.drop(1) do
        assert block =~ ~r{`/[a-z/]+}, "a command block names no endpoint: #{block}"
      end
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
      assert html =~ "trial"
    end

    test "offers a path for people without an assistant", %{conn: conn} do
      html = conn |> get(~p"/start") |> html_response(200)

      # The page is built around pasting a line into an assistant. Someone who
      # has none still needs a way in, so it has to point at both the reference
      # and the browser path — this is the assertion that stops the page
      # becoming AI-only by degrees.
      assert html =~ ~s|href="/developers"|
      assert html =~ ~s|href="/account"|
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
      assert body["trial_usd"] == 29.99
      assert body["trial_credit_expires"] == true
      refute Map.has_key?(body, "free_trial_usd")
      # No token vocabulary left anywhere in the published terms.
      refute Jason.encode!(body) =~ "token"
    end
  end

  describe "the AI integration pitch" do
    # It is the second selling point, after what the product finds. That is a
    # claim about position, so these assert on position rather than presence:
    # a section that quietly slides below the endpoint tables is no longer the
    # second thing the page says, and nothing else would catch that.

    test "leads the home and developer pages, ahead of any other section",
         %{conn: conn} do
      for path <- ["/", "/developers"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ "Nothing to integrate. Your AI already knows how.",
               "#{path} does not carry the AI pitch"

        # First section on the page, so only the headline outranks it.
        [{first, _}] =
          Regex.scan(~r/<h2 class="section-label"[^>]*>([^<]+)</, html, capture: :all_but_first)
          |> Enum.take(1)
          |> Enum.map(&{List.first(&1), nil})

        assert first =~ "Nothing to integrate",
               "#{path} leads with #{inspect(first)} instead of the AI pitch"
      end
    end

    test "sits below the headline, which is still the first claim", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert :binary.match(html, "Reach the decision-maker") <
               :binary.match(html, "Nothing to integrate")
    end

    test "stays off the seats page, so nothing crowds the sample sheet",
         %{conn: conn} do
      # Deliberate, not an oversight. /teams sells by showing the sheet, and the
      # pitch sat between the headline and it. The seat plan reaches the same
      # story through llms.txt in the footer.
      html = conn |> get(~p"/teams") |> html_response(200)

      refute html =~ "Nothing to integrate"
      assert html =~ "sheet-tab"
    end

    test "keeps the developer wording, which is the audience that sees it",
         %{conn: conn} do
      dev = conn |> get(~p"/developers") |> html_response(200)

      assert dev =~ "it knows the whole service"
      assert dev =~ "csf_live_..."
      assert dev =~ "Then run /demo"
      assert dev =~ "No SDK, in any language"
      refute dev =~ "You never see an API"
    end

    test "the pasteable line names this service, not the request's Host", %{conn: conn} do
      # It is copied into someone else's agent, so a forged Host header must not
      # be able to point that agent at another server.
      html =
        %{conn | host: "evil.example.com"}
        |> get(~p"/")
        |> html_response(200)

      assert html =~ "https://csuitefinder.test/llms.txt"
      refute html =~ "evil.example.com"
    end
  end

  describe "the sheet scrolls" do
    test "the reader's own row is pinned, not just present", %{conn: conn} do
      # The row exists to be found. A sheet that scrolls it out of sight is
      # worse than one that does not scroll, so the sticky offsets are part of
      # the behaviour rather than decoration.
      html = conn |> get(~p"/teams?email=jane.doe@acme.com") |> html_response(200)

      assert html =~ ~r/<tr class="[^"]*\byou-row\b/
      assert html =~ "tr.you-row > td { position: sticky"
      assert html =~ "tr.colheads > td { position: sticky"
      assert html =~ "tr.titles > td { position: sticky"
    end

    test "and the grid survives being pinned", %{conn: conn} do
      # border-collapse: collapse merges each pair of adjacent borders into one
      # line owned by neither cell, and a sticky cell then scrolls away from its
      # own grid lines. This is the rule that keeps the header boxed.
      html = conn |> get(~p"/teams") |> html_response(200)

      # Scoped to the sheet. Every other table on the site still collapses, and
      # should — none of them pin anything.
      assert html =~ ".sheet table { border-collapse: separate"
      refute html =~ ".sheet table { border-collapse: collapse"
    end
  end

  describe "the endpoints table" do
    test "runs in the same order as the per-endpoint cost list", %{conn: conn} do
      # Two lists of the same endpoints on one page. If they disagree, a reader
      # comparing them is doing the reconciling, so the order is asserted rather
      # than left to whoever adds the next row.
      html = conn |> get(~p"/developers") |> html_response(200)

      # The price list: one <code>family.endpoint</code> per row.
      [_, prices_on] = String.split(html, "Per-endpoint cost", parts: 2)

      priced =
        Regex.scan(~r|<td><code>([a-z.]+)</code></td>|, prices_on, capture: :all_but_first)
        |> Enum.map(&List.first/1)

      # The endpoints table: one <code>/csuitefinder/path</code> per row, which
      # is the same key with slashes.
      [_, table_on] = String.split(html, ~s|<div class="table-scroll endpoints">|, parts: 2)
      [table_on, _] = String.split(table_on, "</table>", parts: 2)

      documented =
        Regex.scan(~r|<code>/csuitefinder/([a-z/]+)</code>|, table_on, capture: :all_but_first)
        |> Enum.map(fn [path] -> String.replace(path, "/", ".") end)

      assert documented != []
      assert priced != []

      # Every documented endpoint keeps its position from the price list. The
      # price list is the longer of the two — it carries an endpoint the table
      # has no row for — so the table is checked against that order rather than
      # for equality.
      assert documented == Enum.filter(priced, &(&1 in documented)),
             "table order #{inspect(documented)} does not follow price order #{inspect(priced)}"
    end

    test "leads with email.find and ends the email family with linkedin", %{conn: conn} do
      html = conn |> get(~p"/developers") |> html_response(200)
      [_, table_on] = String.split(html, ~s|<div class="table-scroll endpoints">|, parts: 2)

      rows =
        Regex.scan(~r|<code>/csuitefinder/([a-z/]+)</code>|, table_on, capture: :all_but_first)
        |> Enum.map(fn [path] -> String.replace(path, "/", ".") end)

      assert hd(rows) == "email.find"

      email_rows = Enum.filter(rows, &String.starts_with?(&1, "email."))
      assert List.last(email_rows) == "email.linkedin"
    end

    test "does not name a verdict we retired", %{conn: conn} do
      html = conn |> get(~p"/developers") |> html_response(200)

      assert html =~ "accept_all or unknown"
      refute html =~ "risky or unknown"
    end
  end

  describe "the sample conversation" do
    test "runs above the sheet on every page that shows one", %{conn: conn} do
      # The chat and the sheet are a pair: the file the assistant hands back is
      # the sheet underneath it. Showing the sheet without the conversation
      # leaves a table with no story, and the order is the story.
      for path <- ["/", "/teams", "/developers", "/start", "/checkout?plan=seat"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s|class="chat-app"|, "#{path} has no conversation"
        assert html =~ ~s|class="sheet-wrap"|, "#{path} has no sheet"
        assert html =~ ~s|class="composer"|, "#{path} lost the composer"

        assert :binary.match(html, ~s|class="chat-app"|) <
                 :binary.match(html, ~s|class="sheet-wrap"|),
               "#{path} puts the sheet before the conversation"
      end
    end

    test "comes from one partial, so the line cannot differ between pages",
         %{conn: conn} do
      lines =
        for path <- ["/", "/teams", "/developers", "/start"] do
          html = conn |> get(path) |> html_response(200)
          [_, rest] = String.split(html, ~s|class="chat-app"|, parts: 2)
          [bubble, _] = String.split(rest, "</div>", parts: 2)
          String.replace(bubble, ~r/\s+/, " ")
        end

      assert length(Enum.uniq(lines)) == 1,
             "the conversation differs between pages, so it is not one partial"
    end

    test "and its styles ship with the shared sheet, not one page's block",
         %{conn: conn} do
      # The CSS moved out of start.css when the chat stopped being /start's.
      html = conn |> get(~p"/teams") |> html_response(200)

      assert html =~ ".composer-send"
      assert html =~ "@keyframes dot-dim"
    end
  end

  describe "progress while a command runs" do
    test "llms.txt asks for a report every ten deliverable", %{conn: conn} do
      # A run that prints nothing for four minutes is indistinguishable from one
      # that has hung, and the person watching it cannot tell whether to wait or
      # to stop paying for it.
      body = conn |> get(~p"/llms.txt") |> response(200)
      [_, commands] = String.split(body, "## Commands", parts: 2)

      assert commands =~ "Report every ten"
      assert commands =~ "found and `deliverable`"
    end

    test "and counts only the confirmed ones", %{conn: conn} do
      # A tally that includes the undeliverable ones tells the reader they have
      # more addresses than they can actually send to, which is the number that
      # matters to them.
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "Count only the confirmed ones"
      assert body =~ "Found 10 deliverable"
    end
  end

  describe "parallelism" do
    test "llms.txt tells agents to run companies side by side", %{conn: conn} do
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "Run companies in parallel"
      assert body =~ "/email/deliverable"
    end

    test "and never to fan out finds within one company", %{conn: conn} do
      # PatternStore.get_or_fetch/2 is cache-or-buy with no in-flight
      # deduplication, so N concurrent finds at one domain all miss together and
      # buy the same address format N times. Serially the first one buys it and
      # the rest are free. This is the instruction that stands between an eager
      # agent and a bill twenty times bigger than it needed to be.
      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "Never fire several"
      assert body =~ "at the same domain at once"
      assert body =~ "buy the same format twenty times"
    end
  end
end
