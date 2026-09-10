defmodule CsuiteFinderWeb.OpsController do
  @moduledoc """
  Operational visibility: what the cost model currently believes, and how well
  the cache is paying for itself.
  """

  use CsuiteFinderWeb, :controller

  import Ecto.Query

  alias CsuiteFinder.Cache.{
    CompanyProfile,
    Email,
    EmailPattern,
    EmailVerification,
    PersonEnrichment
  }

  alias CsuiteFinder.{Budgets, CostModel, Repo}
  alias CsuiteFinder.Billing.{Pricing, UsageEvent}

  @doc "GET /csuitefinder/ops/costs"
  def costs(conn, _params) do
    json(conn, %{
      capabilities: CostModel.report(),
      budgets_usd: Budgets.all(),
      pricing: Pricing.terms(),
      explanation:
        "Providers are ordered by cost_micro_per_hit ascending — what we paid " <>
          "divided by the answers we got. A miss on a per-success provider is " <>
          "free, so a cheap one that often misses still costs nothing to ask; " <>
          "and a per-call provider's wasted misses are already inside its cost " <>
          "per hit, so no second correction is applied. " <>
          "expected_cost_micro_per_success divides that by the hit rate again " <>
          "and is reported for reference only — it is not what routes. " <>
          "Hits are weighted by (1 + prior_failures) so a provider tried late, " <>
          "on questions others already failed, is not penalised for the harder " <>
          "queries it sees."
    })
  end

  @doc "GET /csuitefinder/ops/cache"
  def cache(conn, _params) do
    json(conn, %{
      rows: %{
        email_patterns: count(EmailPattern),
        emails: count(Email),
        email_verifications: count(EmailVerification),
        person_enrichments: count(PersonEnrichment),
        company_profiles: count(CompanyProfile)
      },
      hit_rate: hit_rate(),
      spend: spend()
    })
  end

  defp count(schema), do: Repo.aggregate(schema, :count, :id)

  defp hit_rate do
    total = count(UsageEvent)

    hits =
      UsageEvent |> where([e], e.cache_hit == true) |> Repo.aggregate(:count, :id)

    %{
      requests: total,
      cache_hits: hits,
      ratio: if(total > 0, do: Float.round(hits / total, 4), else: 0.0)
    }
  end

  defp spend do
    provider = Repo.aggregate(UsageEvent, :sum, :provider_cost_micro) || 0
    charged_micro = Repo.aggregate(UsageEvent, :sum, :charged_micro) || 0

    %{
      provider_cost_usd: Float.round(provider / 1_000_000, 6),
      charged_usd: Float.round(charged_micro / 1_000_000, 6),
      margin_usd: Float.round((charged_micro - provider) / 1_000_000, 6)
    }
  end
end
