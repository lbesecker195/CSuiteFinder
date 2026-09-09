defmodule CsuiteFinder.CostModel do
  @moduledoc """
  Which provider to reach for first, and what a lookup is expected to cost.

  ## The problem with a raw success rate

  Providers are tried in a waterfall, so they do not see the same queries. The
  first provider gets every question, easy ones included. The fourth provider
  only ever sees the questions three others already failed — a systematically
  harder slice. Scoring them on unweighted hit rate therefore punishes the late
  providers for the position we put them in, and would keep them there forever.

  So each attempt is recorded with `prior_failures`: how many providers had
  already missed on that same query. A hit is weighted `1 + prior_failures`,
  which says a hit after three misses is worth four times as much evidence as a
  hit on a question anyone could have answered. Misses are weighted the same
  way, so the weighting corrects for difficulty without inventing hits.

  ## The score

      hit_rate  = (weighted_hits + A) / (weighted_attempts + A + B)
      cost/hit  = cost_micro_total / max(hits, 1)
      score     = cost_per_hit / hit_rate        # expected micro-USD per success

  `A`/`B` are a Beta(1,1) prior, so a provider that has been tried twice is not
  ranked above one with a thousand calls behind it on the strength of a lucky
  streak. Ordering ascending by `score` is the right waterfall order when
  providers bill only on a hit: it puts the cheapest expected cost per resolved
  email first, rather than the cheapest sticker price.
  """

  import Ecto.Query

  alias CsuiteFinder.Budgets
  alias CsuiteFinder.Cache.{ProviderAttempt, ProviderStat}
  alias CsuiteFinder.Repo

  # Beta(1,1) — uniform prior over hit rate.
  @prior_alpha 1.0
  @prior_beta 1.0

  # What we assume about a provider we have never called, so it still gets
  # ranked rather than being sorted to the bottom or the top by accident.
  @cold_start_hit_rate 0.5

  @doc """
  Record every provider treg tried on our behalf.

  treg reports the whole waterfall in `_treg.tried`, so one API response tells us
  how each provider did on the same question — including the ones that missed,
  which is the data an unweighted counter would never see.
  """
  @spec record_waterfall(String.t(), [map()], keyword()) :: :ok
  def record_waterfall(capability, tried, opts \\ [])

  def record_waterfall(capability, tried, opts) when is_list(tried) do
    latency = Keyword.get(opts, :latency_ms)

    tried
    |> Enum.with_index()
    |> Enum.each(fn {attempt, index} ->
      hit? = Map.get(attempt, "outcome") == "hit"

      record_attempt(
        capability,
        Map.get(attempt, "endpoint_id") || Map.get(attempt, "provider") || "unknown",
        hit?,
        prior_failures: index,
        cost_micro: Map.get(attempt, "charged_micro", 0),
        latency_ms: latency
      )
    end)

    :ok
  end

  def record_waterfall(_capability, _tried, _opts), do: :ok

  @doc """
  Record a single provider attempt, updating the append-only log and the rolling
  aggregate in one transaction so the two can never drift.
  """
  @spec record_attempt(String.t(), String.t(), boolean(), keyword()) :: :ok
  def record_attempt(capability, provider, hit?, opts \\ []) do
    prior_failures = Keyword.get(opts, :prior_failures, 0)
    cost_micro = Keyword.get(opts, :cost_micro, 0)
    latency_ms = Keyword.get(opts, :latency_ms)
    weight = 1.0 + prior_failures
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      Repo.insert!(%ProviderAttempt{
        capability: capability,
        provider: provider,
        hit: hit?,
        prior_failures: prior_failures,
        cost_micro: cost_micro,
        latency_ms: latency_ms,
        inserted_at: now
      })

      Repo.query!(
        """
        INSERT INTO provider_stats
          (capability, provider, attempts, hits, weighted_attempts, weighted_hits,
           cost_micro_total, latency_ms_total, last_ok_at, inserted_at, updated_at)
        VALUES ($1, $2, 1, $3, $4, $5, $6, $7, $8, $9, $9)
        ON CONFLICT (capability, provider) DO UPDATE SET
          attempts          = provider_stats.attempts + 1,
          hits              = provider_stats.hits + EXCLUDED.hits,
          weighted_attempts = provider_stats.weighted_attempts + EXCLUDED.weighted_attempts,
          weighted_hits     = provider_stats.weighted_hits + EXCLUDED.weighted_hits,
          cost_micro_total  = provider_stats.cost_micro_total + EXCLUDED.cost_micro_total,
          latency_ms_total  = provider_stats.latency_ms_total + EXCLUDED.latency_ms_total,
          last_ok_at        = COALESCE(EXCLUDED.last_ok_at, provider_stats.last_ok_at),
          updated_at        = EXCLUDED.updated_at
        """,
        [
          capability,
          provider,
          if(hit?, do: 1, else: 0),
          weight,
          if(hit?, do: weight, else: 0.0),
          cost_micro,
          latency_ms || 0,
          if(hit?, do: now, else: nil),
          now
        ]
      )
    end)

    :ok
  end

  @doc """
  Providers for a capability, best expected cost per success first.
  """
  @spec ranked(String.t()) :: [map()]
  def ranked(capability) do
    stats =
      ProviderStat
      |> where([s], s.capability == ^capability)
      |> Repo.all()

    fallback = fallback_cost_per_hit(stats, capability)

    stats
    |> Enum.map(&score(&1, fallback))
    |> Enum.sort_by(& &1.expected_cost_micro_per_success)
  end

  # What to assume a hit costs from a provider that has never produced one.
  #
  # This matters more than it looks. Per-success providers bill nothing on a
  # miss, so a provider that has missed twenty times has spent $0 — and dividing
  # that zero by any hit rate ranks it as free and puts it first, ahead of every
  # provider that actually works. Pricing its hypothetical hit at what a hit
  # costs elsewhere in this capability keeps the arithmetic honest: a provider
  # that never hits then scores its assumed cost over a near-zero hit rate,
  # which is a very large number, which is last. Exactly where it belongs.
  defp fallback_cost_per_hit(stats, capability) do
    total_cost = stats |> Enum.map(& &1.cost_micro_total) |> Enum.sum()
    total_hits = stats |> Enum.map(& &1.hits) |> Enum.sum()

    if total_hits > 0 do
      total_cost / total_hits
    else
      # Nothing in this capability has ever hit; assume the budget ceiling, so
      # providers order by hit rate alone until we know better.
      default_cost_micro(capability)
    end
  end

  defp default_cost_micro(capability) do
    case capability do
      "people.email.find" -> Budgets.micro(:email_find)
      "people.email.verify" -> Budgets.micro(:email_verify)
      "people.enrich" -> Budgets.micro(:person_enrich)
      "companies.email_pattern" -> Budgets.micro(:email_pattern)
      "companies.enrich" -> Budgets.micro(:company_enrich)
      _ -> 10_000
    end
    |> Kernel./(1)
  end

  @doc """
  Turn one aggregate row into its score.

  `fallback_cost` prices a hit for a provider that has not produced one yet.
  """
  @spec score(ProviderStat.t() | map(), float()) :: map()
  def score(stat, fallback_cost \\ 10_000.0)

  def score(%ProviderStat{} = stat, fallback_cost) do
    hit_rate =
      (stat.weighted_hits + @prior_alpha) /
        (stat.weighted_attempts + @prior_alpha + @prior_beta)

    cost_per_hit =
      if stat.hits > 0 do
        stat.cost_micro_total / stat.hits
      else
        # Never resolved anything: assume a hit would cost what hits cost here,
        # plus whatever its misses have already burned.
        fallback_cost + stat.cost_micro_total
      end

    %{
      provider: stat.provider,
      capability: stat.capability,
      attempts: stat.attempts,
      hits: stat.hits,
      raw_hit_rate: if(stat.attempts > 0, do: stat.hits / stat.attempts, else: nil),
      weighted_hit_rate: Float.round(hit_rate, 4),
      cost_micro_per_hit: Float.round(cost_per_hit, 2),
      cost_is_estimated: stat.hits == 0,
      expected_cost_micro_per_success: Float.round(cost_per_hit / hit_rate, 2),
      avg_latency_ms:
        if(stat.attempts > 0, do: div(stat.latency_ms_total, stat.attempts), else: nil),
      last_ok_at: stat.last_ok_at
    }
  end

  @doc """
  The provider we would send first for a capability, as a value for treg's
  `X-Treg-Route-Prefer` header. `nil` until we have evidence worth acting on —
  treg's own cheapest-first order is a good default, and we only override it
  once our numbers disagree with it.
  """
  @spec preferred(String.t(), non_neg_integer()) :: String.t() | nil
  def preferred(capability, min_attempts \\ 20) do
    case ranked(capability) do
      [%{provider: provider, attempts: attempts} | _] when attempts >= min_attempts ->
        provider |> String.split(".") |> hd()

      _ ->
        nil
    end
  end

  @doc """
  What we expect the next lookup of this capability to cost, in micro-USD, given
  the waterfall we would run. Each provider is reached only if every cheaper one
  missed, so its cost is discounted by that probability.
  """
  @spec expected_cost_micro(String.t()) :: float()
  def expected_cost_micro(capability) do
    capability
    |> ranked()
    |> Enum.reduce({0.0, 1.0}, fn provider, {total, reach_prob} ->
      rate = provider.weighted_hit_rate
      {total + reach_prob * rate * provider.cost_micro_per_hit, reach_prob * (1 - rate)}
    end)
    |> elem(0)
    |> Float.round(2)
  end

  @doc """
  Full report for the ops endpoint: per-provider scores and the blended estimate.
  """
  @spec report() :: map()
  def report do
    capabilities =
      ProviderStat
      |> select([s], s.capability)
      |> distinct(true)
      |> Repo.all()

    Map.new(capabilities, fn capability ->
      {capability,
       %{
         providers: ranked(capability),
         expected_cost_micro_per_lookup: expected_cost_micro(capability),
         cold_start_hit_rate: @cold_start_hit_rate
       }}
    end)
  end
end
