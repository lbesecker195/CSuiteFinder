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

        {:ok, infer_or_miss(domain, meta.cost_micro), CsuiteFinder.Lookup.miss(meta.cost_micro)}

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
        infer_or_miss(domain, meta.cost_micro)

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

  # Nobody sells a pattern for this domain. One pattern resolves every employee
  # at a company for free afterwards, so before writing the miss it is worth a
  # ten-token question — clearly marked, held for a shorter time than a bought
  # pattern, and only ever reached after the provider has already failed.
  defp infer_or_miss(domain, spent_micro) do
    case CsuiteFinder.Inference.email_pattern(domain) do
      {:ok, pattern, cost_micro} ->
        upsert(%{
          domain: domain,
          pattern: pattern,
          # Deliberately low. It is a plausible pattern, not an observed one,
          # and everything downstream that weighs confidence should treat it
          # that way.
          confidence: 0.5,
          candidates: %{},
          source: "inferred",
          found: true,
          provider_cost_micro: spent_micro + cost_micro,
          expires_at: Cache.expires_at(:pattern_inferred)
        })

      :unknown ->
        store_missing(domain, "thecompaniesapi")
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

  @doc """
  Every pattern worth trying for this domain, best first.

  "Best" means what we have *seen work*, then what the provider says is common.
  A pattern that has verified deliverable here outranks one with a higher
  published usage share, because the published share is the whole company and
  the observation is this company's actual mail server answering.

  Capped, because each one we try costs a verification and the tail is guesses.
  """
  @spec candidates(String.t(), pos_integer()) :: [String.t()]
  def candidates(domain, limit \\ 3) do
    case get_cached(domain) do
      %EmailPattern{found: true} = row ->
        observed = observed_counts(row)

        ranked =
          row.candidates
          |> Map.get("ranked", [])
          |> Enum.map(&{&1["pattern"], &1["usage"] || 0.0})

        # Anything ever seen deliverable here, then the provider's ranking,
        # then the stored headline pattern — de-duplicated, order preserved.
        ([row.pattern] ++ deliverable_first(observed) ++ Enum.map(ranked, &elem(&1, 0)))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort_by(&score(&1, observed), :desc)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  # A pattern with a confirmed delivery is worth more than one with none; one
  # with confirmed *failures* here is worth less than nothing and sinks.
  defp score(pattern, observed) do
    counts = Map.get(observed, pattern) || %{}
    Map.get(counts, "deliverable", 0) * 10 - Map.get(counts, "undeliverable", 0) * 20
  end

  defp deliverable_first(observed) do
    observed
    |> Enum.filter(fn {_p, counts} -> (counts["deliverable"] || 0) > 0 end)
    |> Enum.sort_by(fn {_p, counts} -> counts["deliverable"] end, :desc)
    |> Enum.map(&elem(&1, 0))
  end

  defp observed_counts(%EmailPattern{candidates: candidates}) do
    case Map.get(candidates || %{}, "observed") do
      %{} = observed -> observed
      _ -> %{}
    end
  end

  @doc """
  Record what the mailbox said about an address built from `pattern`.

  This is how a domain's patterns get ranked by evidence rather than by a
  provider's national average. The counts are also what `/email/pattern`
  reports as a ratio, so a caller can see which format actually lands.
  """
  @spec record_outcome(String.t(), String.t(), String.t()) :: :ok
  def record_outcome(domain, pattern, status)
      when status in ["deliverable", "undeliverable"] do
    case Repo.get_by(EmailPattern, domain: domain) do
      nil ->
        :ok

      row ->
        counts =
          row
          |> observed_counts()
          |> Map.update(pattern, %{status => 1}, fn existing ->
            Map.update(existing, status, 1, &(&1 + 1))
          end)

        row
        |> EmailPattern.changeset(%{
          candidates: Map.put(row.candidates || %{}, "observed", counts)
        })
        |> Repo.update()

        :ok
    end
  end

  def record_outcome(_domain, _pattern, _status), do: :ok

  @doc """
  Remember that a domain accepts every address.

  On a catch-all domain a verification cannot tell two candidate patterns
  apart — every one of them comes back accepting. Trying more is money spent to
  learn nothing, so the fact is recorded once and the attempt is never repeated.
  """
  @spec mark_catch_all(String.t()) :: :ok
  def mark_catch_all(domain) do
    case Repo.get_by(EmailPattern, domain: domain) do
      nil ->
        :ok

      row ->
        row
        |> EmailPattern.changeset(%{
          candidates: Map.put(row.candidates || %{}, "catch_all", true)
        })
        |> Repo.update()

        :ok
    end
  end

  @doc """
  Has this exact format been seen to deliver on this domain?

  The question `Finder` asks before spending a check: a format with a delivery
  behind it does not need another one.
  """
  @spec proven?(String.t(), String.t()) :: boolean()
  def proven?(domain, pattern) do
    case get_cached(domain) do
      %EmailPattern{} = row ->
        counts = row |> observed_counts() |> Map.get(pattern) || %{}
        Map.get(counts, "deliverable", 0) > 0

      _ ->
        false
    end
  end

  @doc "Does this domain accept every address, making verification useless here?"
  @spec catch_all?(String.t()) :: boolean()
  def catch_all?(domain) do
    case get_cached(domain) do
      %EmailPattern{candidates: %{"catch_all" => true}} -> true
      _ -> false
    end
  end

  @doc """
  The observed delivery ratio per pattern for a domain, for `/email/pattern`.

  Empty until something has actually been checked here — a ratio invented from
  a provider's usage share would look like evidence and not be any.
  """
  @spec ratios(String.t()) :: [map()]
  def ratios(domain) do
    case get_cached(domain) do
      %EmailPattern{} = row ->
        row
        |> observed_counts()
        |> Enum.map(fn {pattern, counts} ->
          delivered = counts["deliverable"] || 0
          failed = counts["undeliverable"] || 0
          checked = delivered + failed

          %{
            pattern: pattern,
            checked: checked,
            deliverable: delivered,
            undeliverable: failed,
            share: if(checked > 0, do: Float.round(delivered / checked, 3), else: nil)
          }
        end)
        |> Enum.sort_by(& &1.deliverable, :desc)

      _ ->
        []
    end
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
      # What the mailboxes actually said, per format, on this domain. Empty
      # until something has been checked here — a ratio invented from a
      # provider's usage share would look like evidence and not be any.
      delivery: ratios(row.domain),
      accepts_all: Map.get(row.candidates || %{}, "catch_all", false),
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
