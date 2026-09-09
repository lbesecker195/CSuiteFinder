defmodule CsuiteFinder.PatternStore do
  @moduledoc """
  Cached email patterns, one row per domain.

  This is the cheap path that makes the whole product work: a pattern costs
  $0.0019 once and then resolves every future employee of that company for
  nothing. A raw email find costs at least $0.005 and is charged per person.
  """

  import Ecto.Query

  alias CsuiteFinder.{Budgets, Cache, CostModel, Patterns, Repo}
  alias CsuiteFinder.Cache.EmailPattern
  alias CsuiteFinder.Cache.Writer
  alias CsuiteFinder.Treg.Client

  @capability "companies.email_pattern"
  @endpoint "thecompaniesapi.companies.email_pattern"

  @doc """
  The pattern for a domain, from cache when we have one and from the provider
  when we do not.

  Returns `{:ok, row, spent_micro}` — `row.found` says whether a pattern exists.
  A negative answer is cached too, so a domain nobody can pattern is only paid
  for once a fortnight rather than on every request.
  """
  @spec get_or_fetch(String.t(), keyword()) ::
          {:ok, EmailPattern.t(), CsuiteFinder.Lookup.meta()}
  def get_or_fetch(domain, opts \\ []) do
    case get_cached(domain) do
      %EmailPattern{} = row ->
        {:ok, row, CsuiteFinder.Lookup.hit()}

      nil ->
        if Keyword.get(opts, :fetch, true) do
          fetch_and_store(domain)
        else
          {:ok, %EmailPattern{domain: domain, found: false, source: "cache_miss"},
           CsuiteFinder.Lookup.hit()}
        end
    end
  end

  @doc "A fresh cached row for this domain, or nil."
  @spec get_cached(String.t()) :: EmailPattern.t() | nil
  def get_cached(domain) do
    EmailPattern
    |> where([p], p.domain == ^domain)
    |> Repo.one()
    |> case do
      row -> if Cache.fresh?(row), do: row, else: nil
    end
  end

  defp fetch_and_store(domain) do
    result =
      Client.call(@endpoint,
        method: :get,
        query: [domain: domain],
        max_cost: Budgets.usd(:email_pattern)
      )

    case result do
      {:ok, body, meta} ->
        CostModel.record_attempt(@capability, @endpoint, true,
          cost_micro: meta.cost_micro,
          latency_ms: meta.latency_ms
        )

        {:ok, store_from_provider(domain, body, meta), CsuiteFinder.Lookup.miss(meta.cost_micro)}

      {:miss, meta} ->
        CostModel.record_attempt(@capability, @endpoint, false,
          cost_micro: meta.cost_micro,
          latency_ms: meta.latency_ms
        )

        {:ok, store_missing(domain, "thecompaniesapi"), CsuiteFinder.Lookup.miss(meta.cost_micro)}

      {:error, _reason, meta} ->
        CostModel.record_attempt(@capability, @endpoint, false,
          cost_micro: meta.cost_micro,
          latency_ms: meta.latency_ms
        )

        # An upstream failure is not evidence the domain has no pattern, so it is
        # deliberately not cached as a negative.
        {:ok, %EmailPattern{domain: domain, found: false, source: "error"},
         CsuiteFinder.Lookup.miss(meta.cost_micro)}
    end
  end

  defp store_from_provider(domain, body, meta) do
    raw_patterns = extract_patterns(body)

    ranked =
      raw_patterns
      |> Enum.map(fn %{"pattern" => p} = entry ->
        {Patterns.from_provider(p), Map.get(entry, "usagePercentage", 0.0) / 1}
      end)
      |> Enum.filter(fn {converted, _} -> match?({:ok, _}, converted) end)
      |> Enum.map(fn {{:ok, canonical}, usage} -> %{pattern: canonical, usage: usage} end)
      |> Enum.sort_by(& &1.usage, :desc)

    case ranked do
      [] ->
        store_missing(domain, "thecompaniesapi")

      [top | _] = all ->
        upsert(%{
          domain: domain,
          pattern: top.pattern,
          confidence: top.usage / 100,
          candidates: %{
            "ranked" => Enum.map(all, &%{"pattern" => &1.pattern, "usage" => &1.usage})
          },
          source: "thecompaniesapi",
          found: true,
          provider_cost_micro: meta.cost_micro,
          raw: normalize_raw(body),
          expires_at: Cache.expires_at(:pattern_found)
        })
    end
  end

  defp store_missing(domain, source) do
    upsert(%{
      domain: domain,
      pattern: nil,
      confidence: nil,
      candidates: %{},
      source: source,
      found: false,
      expires_at: Cache.expires_at(:pattern_missing)
    })
  end

  @doc """
  Teach the cache a pattern we observed rather than bought.

  When a paid find resolves `pcollison@stripe.com` for Patrick Collison, the
  pattern is sitting right there in the answer. Recording it means the next
  employee of that company resolves for free — but it never overwrites a
  provider-sourced pattern, which is backed by the whole company's addresses
  rather than this single one.
  """
  @spec learn(String.t(), String.t(), String.t()) :: :ok
  def learn(domain, email, full_name) do
    with {:ok, pattern} <- Patterns.derive(email, full_name),
         nil <- provider_backed(domain) do
      upsert(%{
        domain: domain,
        pattern: pattern,
        # One observation is weak evidence next to a provider's whole-company
        # sample, and the confidence says so.
        confidence: 0.5,
        candidates: %{"observed_from" => email},
        source: "observed",
        found: true,
        expires_at: Cache.expires_at(:pattern_found)
      })
    end

    :ok
  end

  defp provider_backed(domain) do
    EmailPattern
    |> where([p], p.domain == ^domain and p.found == true and p.source == "thecompaniesapi")
    |> Repo.one()
  end

  defp upsert(attrs) do
    Writer.put(EmailPattern, [:domain], attrs)
  end

  @doc """
  The pattern behind a single address — what `/email/pattern` answers.

  Two routes to it. The published company format is the good one and costs
  $0.0019. If the provider has no format for this domain, we fall back to
  identifying the person behind the address and working the pattern backwards
  out of their own name — still inside the $0.01 ceiling, and it turns an
  otherwise empty answer into a usable one.
  """
  @spec for_email(String.t(), keyword()) ::
          {:ok, map(), CsuiteFinder.Lookup.meta()} | {:error, atom()}
  def for_email(email, opts \\ []) do
    with {:ok, email, domain} <- CsuiteFinder.Cache.normalize_email(email) do
      {:ok, row, lookup} = get_or_fetch(domain, opts)

      if row.found do
        {:ok, present(row, email, lookup), lookup}
      else
        derive_from_person(email, domain, row, lookup)
      end
    end
  end

  defp derive_from_person(email, domain, row, lookup) do
    case CsuiteFinder.People.enrich(email) do
      {:ok, %{full_name: full_name, source: "provider"}, enrich_lookup}
      when is_binary(full_name) ->
        lookup = CsuiteFinder.Lookup.add(lookup, enrich_lookup.spent_micro)

        case Patterns.derive(email, full_name) do
          {:ok, pattern} ->
            learned =
              upsert(%{
                domain: domain,
                pattern: pattern,
                confidence: 0.5,
                candidates: %{"observed_from" => email},
                source: "observed",
                found: true,
                provider_cost_micro: lookup.spent_micro,
                expires_at: Cache.expires_at(:pattern_found)
              })

            {:ok, present(learned, email, lookup), lookup}

          {:error, :no_match} ->
            {:ok, present(row, email, lookup), lookup}
        end

      {:ok, _row, enrich_lookup} ->
        lookup = CsuiteFinder.Lookup.add(lookup, enrich_lookup.spent_micro)
        {:ok, present(row, email, lookup), lookup}

      _ ->
        {:ok, present(row, email, lookup), lookup}
    end
  end

  @doc "Present a pattern row as an API payload."
  @spec present(EmailPattern.t(), String.t() | nil, CsuiteFinder.Lookup.meta()) :: map()
  def present(%EmailPattern{} = row, email \\ nil, lookup \\ %{cached: true, spent_micro: 0}) do
    %{
      domain: row.domain,
      found: row.found,
      pattern: row.pattern,
      pattern_provider_notation: to_provider_notation(row.pattern),
      example: example_for(row.pattern, row.domain),
      confidence: row.confidence,
      alternatives: Map.get(row.candidates || %{}, "ranked", []),
      source: row.source,
      queried_email: email,
      cached: lookup.cached,
      stale: Cache.stale?(row),
      last_verified_at: row.last_found_at,
      cost: CsuiteFinder.Lookup.cost_block(lookup)
    }
  end

  defp example_for(nil, _domain), do: nil

  defp example_for(pattern, domain) do
    case Patterns.build(pattern, "Jane Doe", domain) do
      {:ok, email} -> email
      _ -> nil
    end
  end

  # Round-trip back to `[F].[L]` notation, for callers who already speak it.
  defp to_provider_notation(nil), do: nil

  defp to_provider_notation(pattern) do
    pattern
    |> String.replace("{first}", "[F]")
    |> String.replace("{last}", "[L]")
    |> String.replace("{middle}", "[M]")
    |> String.replace("{f}", "[F1]")
    |> String.replace("{l}", "[L1]")
    |> String.replace("{m}", "[M1]")
    |> then(
      &Regex.replace(~r/\{(first|last|middle):(\d+)\}/, &1, fn _f, name, n ->
        "[" <> String.upcase(String.first(name)) <> n <> "]"
      end)
    )
  end

  defp extract_patterns(%{"patterns" => patterns}) when is_list(patterns), do: patterns

  defp extract_patterns(%{"output" => %{"patterns" => patterns}}) when is_list(patterns),
    do: patterns

  defp extract_patterns(%{"raw" => %{"patterns" => patterns}}) when is_list(patterns),
    do: patterns

  defp extract_patterns(_), do: []

  defp normalize_raw(body) when is_map(body), do: body
  defp normalize_raw(other), do: %{"body" => inspect(other)}
end
