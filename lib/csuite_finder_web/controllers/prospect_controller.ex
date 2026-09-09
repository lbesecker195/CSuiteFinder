defmodule CsuiteFinderWeb.ProspectController do
  @moduledoc """
  `/company/people` — who works at a company.

  The one endpoint that discovers rather than resolves: give it a domain and it
  returns named people with addresses and titles, `department=executive` for the
  C-suite.

  Billed per person returned, so `limit` is the spend dial. It is clamped to the
  caller's balance before the upstream is touched, which is what stops a
  50-row request from an account holding 5 tokens either overdrawing or handing
  back 50 rows for 5 tokens.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.{Billing, Prospects}
  alias CsuiteFinderWeb.Plugs.Timing

  action_fallback CsuiteFinderWeb.FallbackController

  @doc """
  POST/GET /csuitefinder/email/company/people — emails only, 1 token per person.

  What the domain sweep actually returns. Cheaper because nothing else is bought.
  """
  def emails(conn, params), do: run(conn, params, phones: false)

  @doc """
  POST/GET /csuitefinder/company/people — emails and phone numbers, 5 tokens each.

  The sweep does not carry numbers; its `phone_number` field is a boolean saying
  one exists and `phone_data` comes back empty. So each person here costs a
  phone lookup of their own, which is why this is priced like /phone/find rather
  than like the email-only route above.
  """
  def people(conn, params), do: run(conn, params, phones: true)

  defp run(conn, params, opts) do
    with {:ok, domain} <- require_domain(params),
         limit = affordable_limit(conn, params["limit"]),
         {:ok, people, lookup} <-
           Prospects.at_domain(domain,
             department: params["department"],
             kind: params["type"],
             limit: limit,
             refresh: params["refresh"] in ["true", "1"]
           ) do
      {rendered, phone_spend} =
        if opts[:phones] do
          {rows, spent} = Prospects.with_phones(people, domain)
          {Enum.map(rows, &CsuiteFinderWeb.PublicView.render(:person_with_phone, &1)), spent}
        else
          {Enum.map(people, fn person ->
             CsuiteFinderWeb.PublicView.render(:person, Prospects.present(person))
           end), 0}
        end

      Billing.settle(%{
        account: conn.assigns[:account],
        api_key: conn.assigns[:api_key],
        endpoint: conn.assigns[:endpoint_name],
        found: rendered != [],
        units: length(rendered),
        cached: lookup.cached,
        provider_cost_micro: lookup.spent_micro + phone_spend,
        duration_ms: Timing.elapsed_ms(conn),
        request: %{domain: domain, department: params["department"], limit: limit}
      })

      json(conn, %{
        domain: domain,
        department: params["department"],
        count: length(rendered),
        people: rendered
      })
    end
  end

  # You cannot ask for more rows than you can pay for. Clamping here — before
  # the upstream call — is cheaper than discovering the shortfall at settle
  # time, when the money has already been spent on our side.
  defp affordable_limit(conn, requested) do
    asked =
      case Integer.parse(to_string(requested || "")) do
        {n, _} when n > 0 -> min(n, Prospects.max_limit())
        _ -> 10
      end

    case conn.assigns[:account] do
      nil ->
        asked

      account ->
        # Divide by the per-row price, not the balance: a row costs 5 tokens on
        # the phone-included route and 1 on the email-only one, so a balance of
        # 20 buys four of the former and twenty of the latter.
        per_row = max(Pricing.charge_for(conn.assigns[:endpoint_name]), 1)
        max(min(asked, div(CsuiteFinder.Billing.available_micro(account), per_row)), 1)
    end
  end

  defp require_domain(params) do
    case params["domain"] || params["email"] do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, :missing_params, ["domain"]}, else: {:ok, trimmed}

      _ ->
        {:error, :missing_params, ["domain"]}
    end
  end
end
