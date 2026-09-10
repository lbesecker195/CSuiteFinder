defmodule CsuiteFinder.MetricsTest do
  use CsuiteFinder.DataCase, async: true

  alias CsuiteFinder.Billing.{Pricing, UsageEvent}
  alias CsuiteFinder.{Fixtures, Metrics, Repo}

  defp event(attrs) do
    %UsageEvent{}
    |> UsageEvent.changeset(
      Map.merge(
        %{
          endpoint: "email.find",
          outcome: "found",
          cache_hit: false,
          provider_cost_micro: 0,
          charged_micro: 2_500,
          duration_ms: 100
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp since, do: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

  describe "headline/1" do
    test "counts requests, hits and money" do
      event(%{cache_hit: true, provider_cost_micro: 0})
      event(%{cache_hit: false, provider_cost_micro: 1_900})
      event(%{outcome: "not_found", charged_micro: 0, provider_cost_micro: 5_000})

      h = Metrics.headline(since())

      assert h.requests == 3
      assert h.cache_hits == 1
      assert h.found == 2
      assert h.provider_cost_micro == 6_900
      assert h.charged_micro == 5_000
      assert h.revenue_usd == 0.005
      assert h.margin_usd == -0.0019
      assert h.cache_hit_rate == Float.round(1 / 3, 4)
    end

    test "is all zeros, not a crash, on an empty window" do
      h = Metrics.headline(since())

      assert h.requests == 0
      assert h.cache_hit_rate == 0.0
      assert h.margin_usd == 0.0
    end
  end

  describe "find_economics/1" do
    test "separates cached finds from fresh ones" do
      event(%{cache_hit: true, provider_cost_micro: 0})
      event(%{cache_hit: true, provider_cost_micro: 0})
      event(%{cache_hit: false, provider_cost_micro: 20_000})

      # Other endpoints must not contaminate find economics.
      event(%{endpoint: "company.info", charged_micro: 0, provider_cost_micro: 1_900})

      e = Metrics.find_economics(since())

      assert e.calls == 3
      assert e.cached.calls == 2
      assert e.fresh.calls == 1
      assert e.cache_hit_rate == Float.round(2 / 3, 4)

      # A cached find earns the whole token price; a fresh one at $0.02 loses.
      assert e.cached.margin_micro == 2_500.0
      assert e.fresh.margin_micro == -17_500.0
      assert e.margin_per_find_micro == Float.round((2_500 * 3 - 20_000) / 3, 2)
    end

    test "break-even is the cache rate that nets the blend to zero" do
      # Fresh finds cost $0.01 against a $0.0025 price.
      event(%{cache_hit: false, provider_cost_micro: 10_000})

      e = Metrics.find_economics(since())

      # (10000 - 2500) / 10000 — hold 75% cached or lose money.
      assert e.breakeven_cache_rate == 0.75
    end

    test "break-even is zero when a fresh find already pays for itself" do
      event(%{cache_hit: false, provider_cost_micro: 1_900})

      assert Metrics.find_economics(since()).breakeven_cache_rate == 0.0
    end

    test "break-even is nil with no fresh finds to measure" do
      event(%{cache_hit: true, provider_cost_micro: 0})

      assert Metrics.find_economics(since()).breakeven_cache_rate == nil
    end
  end

  describe "daily/1" do
    test "returns one entry per day, oldest first, gaps filled with zeros" do
      event(%{})

      series = Metrics.daily(7)

      assert length(series) == 7
      assert List.last(series).day == Date.utc_today()
      assert List.last(series).requests == 1
      # A quiet day is a zero, not a missing point.
      assert Enum.all?(series, &is_integer(&1.requests))
      assert hd(series).requests == 0
    end
  end

  describe "latency" do
    test "reports what callers waited, split by cache" do
      event(%{cache_hit: true, duration_ms: 10})
      event(%{cache_hit: true, duration_ms: 20})
      event(%{cache_hit: false, duration_ms: 800})

      l = Metrics.latency(since())

      # Averaging these together would mostly measure the hit rate, not our speed.
      assert l.cached_ms == 15
      assert l.cached_calls == 2
      assert l.fresh_ms == 800
      assert l.fresh_calls == 1
    end

    test "headline carries an average and a p95" do
      for ms <- [10, 20, 30, 40, 2_000], do: event(%{duration_ms: ms})

      h = Metrics.headline(since())

      assert h.avg_ms == 420
      assert h.p95_ms == 2_000
    end

    test "unmeasured latency stays nil rather than reading as instant" do
      # A 0 here would render as "0 ms" and look like the fastest endpoint we have.
      event(%{duration_ms: nil})

      assert Metrics.headline(since()).avg_ms == nil
      assert Metrics.latency(since()).cached_ms == nil
    end

    test "per-endpoint rows carry the cached/fresh split" do
      event(%{endpoint: "email.find", cache_hit: true, duration_ms: 12})
      event(%{endpoint: "email.find", cache_hit: false, duration_ms: 900})

      row = Metrics.by_endpoint(since()) |> Enum.find(&(&1.endpoint == "email.find"))

      assert row.avg_cached_ms == 12
      assert row.avg_fresh_ms == 900
      assert row.avg_ms == 456
    end
  end

  describe "by_endpoint/1" do
    test "flags which endpoints are metered" do
      event(%{endpoint: "email.find", charged_tokens: 1})
      event(%{endpoint: "company.find", charged_micro: 0, provider_cost_micro: 1_900})

      rows = Metrics.by_endpoint(since())

      find = Enum.find(rows, &(&1.endpoint == "email.find"))
      company = Enum.find(rows, &(&1.endpoint == "company.find"))

      assert find.metered
      refute company.metered
      assert company.provider_cost_usd == 0.0019
      assert company.revenue_usd == 0.0
    end
  end

  describe "accounts_stats/1" do
    test "counts unspent tokens as deferred revenue, not revenue" do
      {_account, _key} = Fixtures.account_with_key(usd: 1.0)

      stats = Metrics.accounts_stats(since())

      assert stats.total == 1
      assert stats.deferred_revenue_usd == 1.0
    end

    test "survives a bigint sum coming back as a Decimal" do
      # Regression: SUM() over a bigint column arrives as Decimal, and a Decimal
      # in an arithmetic expression raises rather than coercing.
      Fixtures.account_with_key(usd: 1_000.0)

      assert Metrics.accounts_stats(since()).deferred_revenue_usd == 1_000.0
    end
  end

  describe "dashboard/1" do
    test "assembles every panel without blowing up on an empty database" do
      data = Metrics.dashboard(30)

      assert data.days == 30
      assert data.headline.requests == 0
      assert length(data.daily) == 30
      assert data.by_endpoint == []
      assert data.cache.total_rows == 0
      assert data.payments.count == 0
      assert is_map(data.providers)
    end

    test "the headline price is what answers actually sold for, blended" do
      # There are several billable routes at different prices now, so one
      # endpoint's list price is not something the margin below can be measured
      # against. With no traffic there is nothing to average, and it is zero.
      assert Metrics.find_economics(since()).price_micro == 0
    end

    test "and it counts every billable route, not just /email/find" do
      # The panel used to look frozen for anyone whose traffic was company or
      # people rows, because it silently excluded them.
      {account, key} = CsuiteFinder.Fixtures.account_with_key(usd: 5.0)

      {:ok, _} =
        CsuiteFinder.Billing.settle(%{
          account: account,
          api_key: key_row(key),
          endpoint: "company.people",
          found: true,
          units: 2,
          provider_cost_micro: 3_000
        })

      economics = Metrics.find_economics(since())

      assert economics.calls == 1
      assert economics.price_micro == Pricing.charge_for("company.people") * 2
    end

    defp key_row(plaintext) do
      {:ok, _account, key} = CsuiteFinder.Accounts.authenticate(plaintext)
      key
    end
  end

  describe "corpus/1 growth" do
    defp email_row(address, inserted_at) do
      %CsuiteFinder.Cache.Email{}
      |> CsuiteFinder.Cache.Email.changeset(%{
        name_key: "k-" <> address,
        domain: "acme.com",
        full_name: "A Person",
        email: address,
        found: true,
        source: "test"
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(inserted_at: inserted_at)
      |> Repo.update!()
    end

    defp swept_row(address, inserted_at) do
      %CsuiteFinder.Cache.CompanyPerson{}
      |> CsuiteFinder.Cache.CompanyPerson.changeset(%{
        domain: "acme.com",
        email: address,
        full_name: "A Person",
        source: "test"
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(inserted_at: inserted_at)
      |> Repo.update!()
    end

    defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 86_400, :second)

    test "counts only addresses we did not already hold" do
      # Held before the window, and swept again inside it. The second sighting
      # is not a new address, and this is the case the EXCEPT exists for.
      email_row("old@acme.com", days_ago(60))
      swept_row("old@acme.com", days_ago(2))

      # Genuinely new inside the window.
      email_row("new@acme.com", days_ago(3))

      corpus = Metrics.corpus(days_ago(30))

      assert corpus.total == 2
      assert corpus.new_in_window == 1
    end

    test "an address found by two routes inside the window counts once" do
      email_row("both@acme.com", days_ago(5))
      swept_row("both@acme.com", days_ago(4))

      assert Metrics.corpus(days_ago(30)).new_in_window == 1
    end

    test "without a window there is no growth figure to report" do
      email_row("x@acme.com", days_ago(1))

      assert Metrics.corpus().new_in_window == nil
    end
  end
end
