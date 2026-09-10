defmodule CsuiteFinderWeb.CompanyController do
  @moduledoc """
  Companies: the one behind an address, and the ones matching a description.

  `/company/info` and `/company/find` are cached per domain rather than per
  address, so looking up a second person at the same company is free.
  `/company/search` is the other direction — companies you do not know about
  yet, by industry, headcount band or technology.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.{Billing, Companies, CompanySearch}
  alias CsuiteFinderWeb.Plugs.Timing

  action_fallback CsuiteFinderWeb.FallbackController

  @doc """
  POST/GET /csuitefinder/company/search — companies by industry, size or tech.

  The top of the funnel: an account list rather than a person. Billed per
  company returned, so `limit` is the spend dial and is clamped to what the
  caller can actually pay for before any upstream is touched.
  """
  def search(conn, params) do
    limit = affordable_limit(conn, params["limit"])

    with {:ok, companies, lookup} <-
           CompanySearch.search(%{
             industry: params["industry"],
             technology: params["technology"] || params["tech"],
             size: params["size"],
             country: params["country"],
             q: params["q"] || params["description"],
             name: params["name"],
             domain: params["domain"],
             limit: limit
           }) do
      rendered =
        Enum.map(companies, fn company ->
          CsuiteFinderWeb.PublicView.render(:company_row, CompanySearch.present(company))
        end)

      Billing.settle(%{
        account: conn.assigns[:account],
        api_key: conn.assigns[:api_key],
        endpoint: conn.assigns[:endpoint_name],
        found: rendered != [],
        units: length(rendered),
        cached: lookup.cached,
        provider_cost_micro: lookup.spent_micro,
        duration_ms: Timing.elapsed_ms(conn),
        request: %{
          industry: params["industry"],
          technology: params["technology"] || params["tech"],
          size: params["size"],
          limit: limit
        }
      })

      json(conn, %{
        count: length(rendered),
        filters: %{
          industry: params["industry"],
          technology: params["technology"] || params["tech"],
          size: params["size"],
          country: params["country"]
        },
        companies: rendered,
        # Every domain here is the input the rest of the API takes. Saying so
        # in the response is what turns a list into a workflow.
        next: %{
          people: "/csuitefinder/company/people?domain=<domain>",
          profile: "/csuitefinder/company/info?domain=<domain>"
        }
      })
    end
  end

  # You cannot ask for more rows than you can pay for. Clamped before the
  # upstream call, because after it the money is already ours to lose.
  defp affordable_limit(conn, requested) do
    asked =
      case Integer.parse(to_string(requested || "")) do
        {n, _} when n > 0 -> min(n, CompanySearch.max_limit())
        _ -> 10
      end

    case conn.assigns[:account] do
      nil ->
        asked

      account ->
        per_row = max(Pricing.charge_for(conn.assigns[:endpoint_name]), 1)
        max(min(asked, div(Billing.available_micro(account), per_row)), 1)
    end
  end

  @doc """
  POST/GET /csuitefinder/company/find

  Which company is behind this address. Shares `info/2`'s lookup and cache and
  returns only the identity fields — so this is free even on a cold domain that
  `info` would have paid to enrich, because the enrichment is the same one.
  """
  def find(conn, params) do
    with {:ok, value} <- present(params["email"] || params["domain"]),
         {:ok, row, lookup} <-
           Companies.info(value, refresh: params["refresh"] in ["true", "1"]) do
      meter(conn, row, lookup, value)

      json(
        conn,
        CsuiteFinderWeb.PublicView.render(
          :company_find,
          Companies.present_identity(row, lookup, params["email"])
        )
      )
    end
  end

  @doc "POST/GET /csuitefinder/company/info"
  def info(conn, params) do
    input = params["email"] || params["domain"]

    with {:ok, value} <- present(input),
         {:ok, row, lookup} <-
           Companies.info(value, refresh: params["refresh"] in ["true", "1"]) do
      meter(conn, row, lookup, value)
      json(conn, CsuiteFinderWeb.PublicView.render(:company_info, Companies.present(row, lookup)))
    end
  end

  defp meter(conn, row, lookup, value) do
    Billing.settle(%{
      account: conn.assigns[:account],
      api_key: conn.assigns[:api_key],
      endpoint: conn.assigns[:endpoint_name],
      found: row.found,
      cached: lookup.cached,
      duration_ms: CsuiteFinderWeb.Plugs.Timing.elapsed_ms(conn),
      provider_cost_micro: lookup.spent_micro,
      request: %{input: value}
    })
  end

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:error, :missing_params, ["email"]}, else: {:ok, trimmed}
  end

  defp present(_), do: {:error, :missing_params, ["email (or domain)"]}
end
