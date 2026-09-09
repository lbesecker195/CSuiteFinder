defmodule CsuiteFinderWeb.CompanyController do
  @moduledoc """
  `/company/info` — the company behind an address.

  Cached per domain rather than per address, so looking up a second person at the
  same company is free.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.{Billing, Companies}

  action_fallback CsuiteFinderWeb.FallbackController

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
