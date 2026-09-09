defmodule CsuiteFinderWeb.EmailController do
  @moduledoc """
  The four email endpoints.

  Every action follows the same shape: pull params, run the lookup, meter it,
  answer. Metering happens after the lookup because what we bill depends on
  whether we actually found anything.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.{Billing, Finder, PatternStore, People, Verifier}

  action_fallback CsuiteFinderWeb.FallbackController

  @doc "POST/GET /csuitefinder/email/find"
  def find(conn, params) do
    with {:ok, full_name} <- require_param(params, "full_name"),
         {:ok, domain} <- require_param(params, "domain"),
         {:ok, result} <-
           Finder.find(full_name, domain,
             known_email: params["email"],
             refresh: truthy(params["refresh"])
           ) do
      meter(conn, result, %{full_name: full_name, domain: domain})
      json(conn, result)
    end
  end

  @doc "POST/GET /csuitefinder/email/deliverable"
  def deliverable(conn, params) do
    with {:ok, email} <- require_param(params, "email"),
         {:ok, row, lookup} <- Verifier.verify(email, refresh: truthy(params["refresh"])) do
      result = Verifier.present(row, lookup)
      # A verdict of "undeliverable" is a successful answer — the caller learned
      # something actionable, and it is billed as a result.
      meter(conn, Map.put(result, :found, row.status != "unknown"), %{email: email})
      json(conn, result)
    end
  end

  @doc "POST/GET /csuitefinder/email/enrich"
  def enrich(conn, params) do
    with {:ok, email} <- require_param(params, "email"),
         {:ok, row, lookup} <- People.enrich(email, refresh: truthy(params["refresh"])) do
      result = People.present(row, lookup)
      # An inferred guess is not a result we bill for.
      meter(conn, Map.put(result, :found, row.found and row.source == "provider"), %{
        email: email
      })

      json(conn, result)
    end
  end

  @doc "POST/GET /csuitefinder/email/pattern"
  def pattern(conn, params) do
    with {:ok, email} <- require_param(params, "email"),
         {:ok, result, lookup} <-
           PatternStore.for_email(email, refresh: truthy(params["refresh"])) do
      meter(conn, Map.put(result, :cached, lookup.cached), %{email: email})
      json(conn, result)
    end
  end

  # ------------------------------------------------------------------ helpers

  defp require_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, :missing_params, [key]}, else: {:ok, trimmed}

      _ ->
        {:error, :missing_params, [key]}
    end
  end

  defp truthy(value), do: value in [true, "true", "1", 1]

  defp meter(conn, result, request) do
    Billing.settle(%{
      account: conn.assigns[:account],
      api_key: conn.assigns[:api_key],
      endpoint: conn.assigns[:endpoint_name],
      found: Map.get(result, :found, false),
      cached: Map.get(result, :cached, false),
      provider_cost_micro: get_in(result, [:cost, :provider_micro]) || 0,
      request: request
    })
  end
end
