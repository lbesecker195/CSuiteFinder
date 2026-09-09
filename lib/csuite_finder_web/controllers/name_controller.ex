defmodule CsuiteFinderWeb.NameController do
  @moduledoc """
  `/name/who` — who is behind this address.

  Same lookup and same cache as `/email/enrich`; this endpoint answers the
  narrower question and returns only the identity fields, so a caller who wants
  a name does not have to wade through an employment record to find it.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.{Billing, People}

  action_fallback CsuiteFinderWeb.FallbackController

  @doc "POST/GET /csuitefinder/name/who"
  def who(conn, params) do
    with {:ok, email} <- require_email(params),
         {:ok, row, lookup} <- People.enrich(email, refresh: params["refresh"] in ["true", "1"]) do
      result = %{
        email: row.email,
        found: row.found,
        full_name: row.full_name,
        first_name: row.first_name,
        last_name: row.last_name,
        position: row.position,
        company_name: row.company_name,
        linkedin_url: row.linkedin_url,
        confidence: row.confidence
      }

      Billing.settle(%{
        account: conn.assigns[:account],
        api_key: conn.assigns[:api_key],
        endpoint: conn.assigns[:endpoint_name],
        found: row.found and row.source == "provider",
        cached: lookup.cached,
        duration_ms: CsuiteFinderWeb.Plugs.Timing.elapsed_ms(conn),
        provider_cost_micro: lookup.spent_micro,
        request: %{email: email}
      })

      json(conn, CsuiteFinderWeb.PublicView.render(:who, result))
    end
  end

  defp require_email(params) do
    case Map.get(params, "email") do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, :missing_params, ["email"]}, else: {:ok, trimmed}

      _ ->
        {:error, :missing_params, ["email"]}
    end
  end
end
