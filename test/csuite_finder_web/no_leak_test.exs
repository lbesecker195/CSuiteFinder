defmodule CsuiteFinderWeb.NoLeakTest do
  @moduledoc """
  The public API must not disclose how it is built.

  Two separate guarantees, tested separately because they fail differently:

    * No response carries an internal field (who served it, what it cost,
      whether the cache answered, how the address was derived).
    * No response carries the *name* of an upstream we buy from, anywhere in
      its body — including nested inside data we do pass through.

  The second check is a substring sweep over the whole encoded response rather
  than a key check, because a vendor name can arrive inside a value we did not
  write: a provider id echoed in a description, a URL, an error string.
  """

  use CsuiteFinderWeb.ConnCase, async: true

  alias CsuiteFinder.{Fixtures, TregStub}
  alias CsuiteFinderWeb.PublicView

  # Fields that describe our plumbing rather than the customer's answer.
  @forbidden_keys ~w(source pattern_source provider cached stale cost warning
                     provider_cost_micro charged_tokens raw _treg served_by
                     tried refresh_failures)

  # Vendor names that must never reach a customer.
  @forbidden_terms ~w(treg thecompaniesapi trykitt tomba hunter findymail
                      leadmagic apollo contactout millionverifier icypeas
                      companyenrich leadsforge aviato pdl lusha fiber-ai)

  setup %{conn: conn} do
    {_account, key} = Fixtures.account_with_key(tokens: 400)

    TregStub.stub(fn
      "thecompaniesapi.companies.email_pattern", _ ->
        {200, %{"patterns" => [%{"pattern" => "[F].[L]", "usagePercentage" => 95.0}]}, 1_900}

      "treg.people.email.verify", _ ->
        {200,
         TregStub.routed(%{"valid" => true, "status" => "valid"},
           served_by: "trykitt.people.email.verify"
         ), 1_500}

      "treg.people.enrich", _ ->
        {200,
         TregStub.routed(%{"full_name" => "Jane Doe", "title" => "CTO"},
           served_by: "hunter.people.enrich"
         ), 4_900}

      "treg.companies.enrich", _ ->
        {200,
         TregStub.routed(%{"name" => "Acme Inc", "industry" => "software"},
           served_by: "thecompaniesapi.companies.enrich"
         ), 1_900}

      _other, _params ->
        {404, %{}, 0}
    end)

    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> key)}
  end

  defp assert_clean(body, view) do
    for key <- @forbidden_keys do
      refute Map.has_key?(body, key), "response leaked internal field #{inspect(key)}"
    end

    allowed = Enum.map(PublicView.fields(view), &Atom.to_string/1)

    for key <- Map.keys(body) do
      assert key in allowed, "response carried #{inspect(key)}, which is not in the #{view} view"
    end

    encoded = String.downcase(Jason.encode!(body))

    for term <- @forbidden_terms do
      refute String.contains?(encoded, term), "response mentioned upstream #{inspect(term)}"
    end
  end

  describe "no endpoint discloses its plumbing" do
    test "email/find", %{conn: conn} do
      body =
        conn
        |> get(~p"/csuitefinder/email/find?full_name=Jane%20Doe&domain=acme.com")
        |> json_response(200)

      assert body["email"] == "jane.doe@acme.com"
      assert_clean(body, :email_find)
    end

    test "email/deliverable", %{conn: conn} do
      body =
        conn
        |> get(~p"/csuitefinder/email/deliverable?email=jane@acme.com")
        |> json_response(200)

      assert body["deliverable"]
      assert_clean(body, :deliverable)
    end

    test "email/enrich", %{conn: conn} do
      body =
        conn |> get(~p"/csuitefinder/email/enrich?email=jane@acme.com") |> json_response(200)

      assert body["full_name"] == "Jane Doe"
      assert_clean(body, :enrich)
    end

    test "email/enrich when the answer is inferred", %{conn: conn} do
      TregStub.stub(fn "treg.people.enrich", _ -> {200, %{"output" => nil}, 0} end)

      body =
        conn
        |> get(~p"/csuitefinder/email/enrich?email=sam.poe@acme.com")
        |> json_response(200)

      assert body["full_name"] == "Sam Poe"
      assert_clean(body, :enrich)
    end

    test "email/pattern keeps the pattern but not its source", %{conn: conn} do
      body =
        conn
        |> get(~p"/csuitefinder/email/pattern?email=x@acme.com")
        |> json_response(200)

      # The pattern is the whole product of this endpoint.
      assert body["pattern"] == "{first}.{last}"
      assert_clean(body, :pattern)
    end

    test "name/who", %{conn: conn} do
      body = conn |> get(~p"/csuitefinder/name/who?email=jane@acme.com") |> json_response(200)

      assert body["full_name"] == "Jane Doe"
      assert_clean(body, :who)
    end

    test "company/find", %{conn: conn} do
      body =
        conn |> get(~p"/csuitefinder/company/find?email=jane@acme.com") |> json_response(200)

      assert body["name"] == "Acme Inc"
      assert_clean(body, :company_find)
    end

    test "company/info", %{conn: conn} do
      body =
        conn |> get(~p"/csuitefinder/company/info?email=jane@acme.com") |> json_response(200)

      assert body["name"] == "Acme Inc"
      assert_clean(body, :company_info)
    end
  end

  describe "the rest of the public surface" do
    test "health does not name a supplier", %{conn: conn} do
      body = conn |> get(~p"/csuitefinder/health") |> json_response(200)
      encoded = String.downcase(Jason.encode!(body))

      for term <- @forbidden_terms do
        refute String.contains?(encoded, term)
      end

      assert Map.has_key?(body, "lookups_configured")
    end

    test "a failed lookup does not echo the upstream's response", %{conn: conn} do
      # Every upstream fails, with a body that names a vendor and its quota.
      TregStub.stub(fn _endpoint, _params ->
        {500, %{"error" => "tomba quota exceeded for account 44"}, 0}
      end)

      body =
        conn
        |> get(~p"/csuitefinder/email/find?full_name=Jane%20Doe&domain=acme.com")
        |> json_response(200)

      encoded = String.downcase(Jason.encode!(body))
      refute String.contains?(encoded, "tomba")
      refute String.contains?(encoded, "quota")
    end

    test "the landing page does not describe the plumbing", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200) |> String.downcase()

      for term <- @forbidden_terms do
        refute String.contains?(html, term), "landing page mentioned #{inspect(term)}"
      end

      refute html =~ ~s("source")
      refute html =~ ~s("cached")
      refute html =~ ~s("stale")
    end

    test "/ops is operator-only, not reachable with a customer key", %{conn: conn} do
      # It ranks every upstream by name and price, so a customer key must not
      # open it. Refused either as unauthorised or as disabled — both are
      # closed; what matters is that it is never 200 and never leaks.
      for path <- [~p"/csuitefinder/ops/costs", ~p"/csuitefinder/ops/cache"] do
        response = get(conn, path)
        assert response.status in [401, 503], "#{path} answered #{response.status}"

        body = String.downcase(response.resp_body)

        for term <- @forbidden_terms do
          refute String.contains?(body, term)
        end
      end
    end

    test "a failed capture does not echo PayPal's error body", %{conn: conn} do
      # PayPal returns a debug_id, its own error vocabulary and doc links.
      # None of that is the customer's business.
      body =
        conn
        |> post(~p"/csuitefinder/billing/capture", %{paypal_order_id: "UNKNOWN"})
        |> json_response(404)

      refute Map.has_key?(body, "detail")
    end

    test "pricing publishes terms without naming a supplier", %{conn: conn} do
      body = conn |> get(~p"/csuitefinder/pricing") |> json_response(200)
      encoded = String.downcase(Jason.encode!(body))

      for term <- @forbidden_terms do
        refute String.contains?(encoded, term)
      end
    end
  end
end
