defmodule CsuiteFinder.Metrics do
  @moduledoc """
  Aggregates for the admin dashboard.

  The number that decides whether this business works is the **cache hit rate**
  on `email.find`. A find sells for one token ($0.0025); a find that misses the
  cache and falls through to a paid provider can cost up to $0.02. So a fresh
  find loses money and a cached one is nearly pure margin, and the blend is what
  makes the P&L. Everything here is arranged to make that visible rather than
  buried in a total.

  Every figure comes from `usage_events`, which is written once per billable
  request, so the dashboard and the invoice are reading the same rows.
  """

  import Ecto.Query

  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing.{Payment, Pricing, UsageEvent}

  alias CsuiteFinder.Cache.{
    CompanyProfile,
    Email,
    EmailPattern,
    EmailVerification,
    PersonEnrichment
  }

  alias CsuiteFinder.{CostModel, Repo}

  @cache_tables [
    {"email_patterns", EmailPattern},
    {"emails", Email},
    {"email_verifications", EmailVerification},
    {"person_enrichments", PersonEnrichment},
    {"company_profiles", CompanyProfile}
  ]

  @doc "Everything the dashboard renders, for a window of `days`."
  @spec dashboard(pos_integer()) :: map()
  def dashboard(days \\ 30) do
    since = since(days)

    %{
      days: days,
      generated_at: DateTime.utc_now(),
      headline: headline(since),
      find_economics: find_economics(since),
      daily: daily(days),
      by_endpoint: by_endpoint(since),
      latency: latency(since),
      cache: cache_stats(),
      accounts: accounts_stats(since),
      payments: payments_stats(),
      providers: CostModel.report()
    }
  end

  defp since(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  # ------------------------------------------------------------------ headline

  @doc "Top-line counters for the window."
  @spec headline(DateTime.t()) :: map()
  def headline(since) do
    row =
      from(e in UsageEvent,
        where: e.inserted_at >= ^since,
        select: %{
          requests: count(e.id),
          cache_hits: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", e.cache_hit)),
          found: sum(fragment("CASE WHEN ? = 'found' THEN 1 ELSE 0 END", e.outcome)),
          provider_cost_micro: sum(e.provider_cost_micro),
          tokens: sum(e.charged_tokens),
          avg_ms: avg(e.duration_ms),
          p95_ms: fragment("percentile_disc(0.95) WITHIN GROUP (ORDER BY ?)", e.duration_ms)
        }
      )
      |> Repo.one()
      |> zero_nils()

    revenue_micro = row.tokens * Pricing.micro_per_token()

    Map.merge(row, %{
      cache_hit_rate: ratio(row.cache_hits, row.requests),
      found_rate: ratio(row.found, row.requests),
      provider_cost_usd: usd(row.provider_cost_micro),
      revenue_usd: usd(revenue_micro),
      margin_usd: usd(revenue_micro - row.provider_cost_micro),
      margin_pct: ratio(revenue_micro - row.provider_cost_micro, revenue_micro),
      avg_ms: row.avg_ms,
      p95_ms: row.p95_ms
    })
  end

  @doc """
  The unit economics of a find, which is the only metered endpoint.

  Split by whether the cache answered, because the two have opposite signs and
  an average of them hides that.
  """
  @spec find_economics(DateTime.t()) :: map()
  def find_economics(since) do
    rows =
      from(e in UsageEvent,
        where: e.inserted_at >= ^since and e.endpoint == "email.find",
        group_by: e.cache_hit,
        select: %{
          cache_hit: e.cache_hit,
          calls: count(e.id),
          provider_cost_micro: sum(e.provider_cost_micro),
          tokens: sum(e.charged_tokens)
        }
      )
      |> Repo.all()
      |> Enum.map(&zero_nils/1)

    cached = Enum.find(rows, %{calls: 0, provider_cost_micro: 0, tokens: 0}, & &1.cache_hit)
    fresh = Enum.find(rows, %{calls: 0, provider_cost_micro: 0, tokens: 0}, &(not &1.cache_hit))

    total_calls = cached.calls + fresh.calls
    total_cost = cached.provider_cost_micro + fresh.provider_cost_micro
    total_tokens = cached.tokens + fresh.tokens
    revenue_micro = total_tokens * Pricing.micro_per_token()

    %{
      price_micro: Pricing.charge_for("email.find") * Pricing.micro_per_token(),
      calls: total_calls,
      cached: segment(cached),
      fresh: segment(fresh),
      cache_hit_rate: ratio(cached.calls, total_calls),
      avg_cost_micro: per_call(total_cost, total_calls),
      margin_per_find_micro: per_call(revenue_micro - total_cost, total_calls),
      # Above this share of cached finds, the blend is profitable. Below it, each
      # additional find loses money — the single most useful number on the page.
      breakeven_cache_rate: breakeven_cache_rate(fresh)
    }
  end

  defp segment(row) do
    %{
      calls: row.calls,
      provider_cost_usd: usd(row.provider_cost_micro),
      avg_cost_micro: per_call(row.provider_cost_micro, row.calls),
      margin_micro:
        per_call(
          row.tokens * Pricing.micro_per_token() - row.provider_cost_micro,
          row.calls
        )
    }
  end

  # A cached find costs us nothing and earns the token price. A fresh one earns
  # the same and costs whatever the providers charged. Solving for the mix that
  # nets to zero gives the hit rate we must hold.
  defp breakeven_cache_rate(%{calls: 0}), do: nil

  defp breakeven_cache_rate(fresh) do
    price = Pricing.charge_for("email.find") * Pricing.micro_per_token()
    avg_fresh_cost = fresh.provider_cost_micro / fresh.calls

    cond do
      avg_fresh_cost <= price -> 0.0
      price == 0 -> nil
      true -> Float.round((avg_fresh_cost - price) / avg_fresh_cost, 4)
    end
  end

  # ---------------------------------------------------------------- timeseries

  @doc "Requests, cost and revenue per day, oldest first, with empty days filled."
  @spec daily(pos_integer()) :: [map()]
  def daily(days) do
    since = since(days)

    rows =
      from(e in UsageEvent,
        where: e.inserted_at >= ^since,
        group_by: fragment("date_trunc('day', ?)", e.inserted_at),
        order_by: fragment("date_trunc('day', ?)", e.inserted_at),
        select: %{
          day: fragment("date_trunc('day', ?)::date", e.inserted_at),
          requests: count(e.id),
          cache_hits: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", e.cache_hit)),
          provider_cost_micro: sum(e.provider_cost_micro),
          tokens: sum(e.charged_tokens)
        }
      )
      |> Repo.all()
      |> Map.new(&{&1.day, zero_nils(&1)})

    today = Date.utc_today()

    # A gap in the chart should read as a quiet day, not as missing data.
    for offset <- (days - 1)..0//-1 do
      day = Date.add(today, -offset)

      Map.get(rows, day, %{
        day: day,
        requests: 0,
        cache_hits: 0,
        provider_cost_micro: 0,
        tokens: 0
      })
    end
  end

  # ------------------------------------------------------------------ breakdown

  @doc "Per-endpoint traffic, cost and revenue."
  @spec by_endpoint(DateTime.t()) :: [map()]
  def by_endpoint(since) do
    from(e in UsageEvent,
      where: e.inserted_at >= ^since,
      group_by: e.endpoint,
      order_by: [desc: count(e.id)],
      select: %{
        endpoint: e.endpoint,
        calls: count(e.id),
        cache_hits: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", e.cache_hit)),
        found: sum(fragment("CASE WHEN ? = 'found' THEN 1 ELSE 0 END", e.outcome)),
        provider_cost_micro: sum(e.provider_cost_micro),
        tokens: sum(e.charged_tokens),
        avg_ms: avg(e.duration_ms),
        p95_ms: fragment("percentile_disc(0.95) WITHIN GROUP (ORDER BY ?)", e.duration_ms),
        avg_cached_ms: fragment("avg(?) FILTER (WHERE ? = true)", e.duration_ms, e.cache_hit),
        avg_fresh_ms: fragment("avg(?) FILTER (WHERE ? = false)", e.duration_ms, e.cache_hit)
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      row = zero_nils(row)

      Map.merge(row, %{
        cache_hit_rate: ratio(row.cache_hits, row.calls),
        found_rate: ratio(row.found, row.calls),
        provider_cost_usd: usd(row.provider_cost_micro),
        revenue_usd: usd(row.tokens * Pricing.micro_per_token()),
        metered: Pricing.metered?(row.endpoint)
      })
    end)
  end

  @doc """
  What callers waited, split by whether the cache answered.

  Averaging the two together mostly measures the hit rate rather than our own
  speed, which is why they are reported apart.
  """
  @spec latency(DateTime.t()) :: map()
  def latency(since) do
    rows =
      from(e in UsageEvent,
        where: e.inserted_at >= ^since and not is_nil(e.duration_ms),
        group_by: e.cache_hit,
        select: %{cache_hit: e.cache_hit, calls: count(e.id), avg_ms: avg(e.duration_ms)}
      )
      |> Repo.all()
      |> Enum.map(&zero_nils/1)

    cached = Enum.find(rows, %{calls: 0, avg_ms: nil}, & &1.cache_hit)
    fresh = Enum.find(rows, %{calls: 0, avg_ms: nil}, &(not &1.cache_hit))

    %{
      cached_ms: cached.avg_ms,
      cached_calls: cached.calls,
      fresh_ms: fresh.avg_ms,
      fresh_calls: fresh.calls
    }
  end

  @doc "Row counts and staleness per cache table."
  @spec cache_stats() :: map()
  def cache_stats do
    tables =
      Enum.map(@cache_tables, fn {name, schema} ->
        %{
          table: name,
          rows: Repo.aggregate(schema, :count, :id),
          stale: Repo.aggregate(from(r in schema, where: r.refresh_failures > 0), :count, :id)
        }
      end)

    %{
      tables: tables,
      total_rows: tables |> Enum.map(& &1.rows) |> Enum.sum(),
      total_stale: tables |> Enum.map(& &1.stale) |> Enum.sum(),
      # Patterns are the asset: each one resolves a whole company for free.
      patterns_held: Repo.aggregate(from(p in EmailPattern, where: p.found), :count, :id)
    }
  end

  @doc "Customers, and the tokens they are still owed."
  @spec accounts_stats(DateTime.t()) :: map()
  def accounts_stats(since) do
    total = Repo.aggregate(Account, :count, :id)
    outstanding = to_int(Repo.aggregate(Account, :sum, :token_balance))

    active =
      from(e in UsageEvent,
        where: e.inserted_at >= ^since and not is_nil(e.account_id),
        select: count(e.account_id, :distinct)
      )
      |> Repo.one()
      |> to_int()

    on_trial =
      from(a in Account,
        where: not is_nil(a.trial_granted_at) and a.token_balance > 0,
        where:
          a.id not in subquery(
            from(p in Payment, where: p.status == "credited", select: p.account_id)
          )
      )
      |> Repo.aggregate(:count, :id)

    %{
      total: total,
      active: active,
      on_trial: on_trial,
      paying: total - on_trial,
      tokens_outstanding: outstanding,
      # Tokens sold but not yet spent — a liability, not revenue.
      deferred_revenue_usd: Pricing.usd_for_tokens(outstanding)
    }
  end

  @doc "Captured PayPal bundles."
  @spec payments_stats() :: map()
  def payments_stats do
    row =
      from(p in Payment,
        where: p.status == "credited",
        select: %{
          count: count(p.id),
          amount_micro: sum(p.amount_micro),
          tokens: sum(p.tokens)
        }
      )
      |> Repo.one()
      |> zero_nils()

    Map.put(row, :amount_usd, usd(row.amount_micro))
  end

  # -------------------------------------------------------------------- helpers

  # Postgres returns SUM() over a bigint column as `numeric`, which arrives as a
  # `Decimal` rather than an integer — and a Decimal in an arithmetic expression
  # raises. Everything counted here is whole units (requests, tokens, micro-USD),
  # so results are normalised to integers on the way out of every query.
  # Latency stays nil when there is nothing to average: zeroing it would render
  # as "0 ms", which reads as instant rather than as unmeasured.
  @nilable ~w(avg_ms p95_ms avg_cached_ms avg_fresh_ms)a

  defp zero_nils(map) do
    Map.new(map, fn
      {:day, value} -> {:day, value}
      {key, value} when key in @nilable -> {key, round_ms(value)}
      {key, value} -> {key, to_int(value)}
    end)
  end

  defp round_ms(nil), do: nil
  defp round_ms(%Decimal{} = d), do: d |> Decimal.to_float() |> round()
  defp round_ms(value) when is_number(value), do: round(value)
  defp round_ms(_), do: nil

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: round(value)
  # Non-numeric values (the `cache_hit` boolean a group-by carries) pass through.
  defp to_int(value), do: value

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: Float.round(numerator / denominator, 4)

  defp per_call(_total, 0), do: 0.0
  defp per_call(total, calls), do: Float.round(total / calls, 2)

  defp usd(micro), do: Float.round(micro / 1_000_000, 6)
end
