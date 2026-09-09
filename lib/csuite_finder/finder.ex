defmodule CsuiteFinder.Finder do
  @moduledoc """
  Resolving a name + company domain to a work email.

  The order of attack is deliberate, cheapest first:

    1. **Cache.** Somebody may already have asked. Free.
    2. **Pattern.** One `$0.0019` lookup gives the company's address format, and
       that format then resolves every future employee of that company for
       nothing. This is the path that makes the unit economics work.
    3. **A known colleague's address**, when the caller supplies one — we work
       the pattern backwards out of it instead of buying it.
    4. **A raw find**, capped at $0.02, only when there is no pattern to apply.

  Every paid answer teaches the pattern cache on the way out, so the expensive
  path makes the cheap path better for the next caller.
  """

  import Ecto.Query

  alias CsuiteFinder.{
    Budgets,
    Cache,
    CostModel,
    Lookup,
    Names,
    PatternStore,
    Patterns,
    People,
    Repo
  }

  alias CsuiteFinder.Cache.Email
  alias CsuiteFinder.Cache.Writer
  alias CsuiteFinder.Treg.Client

  @capability "people.email.find"
  @endpoint "treg.people.email.find"

  @type result :: %{
          required(:found) => boolean(),
          required(:source) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Find `full_name`'s email at `domain`.

  Options:
    * `:known_email` — a colleague's address at the same company, used to derive
      the pattern rather than pay for one.
    * `:refresh` — bypass the cached answer for this person.
  """
  @spec find(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, atom()}
  def find(full_name, domain, opts \\ []) do
    with {:ok, domain} <- Cache.normalize_domain(domain),
         {:ok, parts} <- Names.split(full_name) do
      name_key = Names.name_key(full_name)

      case cached(name_key, domain, opts) do
        %Email{} = row ->
          {:ok, present(row, Lookup.hit(), from_cache: true)}

        nil ->
          resolve(full_name, parts, name_key, domain, opts)
      end
    else
      {:error, :invalid_domain} -> {:error, :invalid_domain}
      {:error, :unparseable} -> {:error, :invalid_name}
    end
  end

  defp cached(name_key, domain, opts) do
    if Keyword.get(opts, :refresh, false) do
      nil
    else
      row = cached_row(name_key, domain)
      if Cache.fresh?(row), do: row, else: nil
    end
  end

  defp resolve(full_name, parts, name_key, domain, opts) do
    # A caller-supplied colleague address is the cheapest pattern there is.
    lookup =
      case Keyword.get(opts, :known_email) do
        nil -> Lookup.hit()
        known -> learn_from_known_email(known, domain, Lookup.hit())
      end

    {:ok, pattern_row, pattern_lookup} = PatternStore.get_or_fetch(domain)

    lookup =
      if pattern_lookup.cached,
        do: lookup,
        else: Lookup.add(lookup, pattern_lookup.spent_micro)

    case pattern_row do
      %{found: true, pattern: pattern} when is_binary(pattern) ->
        case Patterns.apply_pattern(pattern, parts) do
          {:ok, local} ->
            email = local <> "@" <> domain

            row =
              store(%{
                name_key: name_key,
                domain: domain,
                full_name: full_name,
                first_name: parts.first,
                last_name: parts.last,
                email: email,
                found: true,
                source: "pattern",
                pattern_used: pattern,
                confidence: pattern_row.confidence,
                provider_cost_micro: lookup.spent_micro,
                expires_at: Cache.expires_at(:email_found)
              })

            {:ok, present(row, lookup, pattern_source: pattern_row.source)}

          {:error, :missing_part} ->
            # The company's format needs a name part this person does not have
            # (a `{last}` pattern against a mononym) — fall through and buy it.
            find_via_provider(full_name, parts, name_key, domain, lookup)
        end

      _ ->
        find_via_provider(full_name, parts, name_key, domain, lookup)
    end
  end

  defp find_via_provider(full_name, parts, name_key, domain, lookup) do
    body =
      %{full_name: full_name, domain: domain}
      |> maybe_put(:first_name, parts.first)
      |> maybe_put(:last_name, parts.last)

    result =
      Client.call(@endpoint,
        method: :post,
        body: body,
        max_cost: Budgets.usd(:email_find),
        prefer: CostModel.preferred(@capability)
      )

    case result do
      {:ok, payload, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        lookup = Lookup.add(lookup, meta.cost_micro)

        case extract_email(payload) do
          nil ->
            {:ok, store_missing(name_key, domain, full_name, parts, lookup, meta)}

          email ->
            # The answer carries the company's format for free — bank it.
            PatternStore.learn(domain, email, full_name)

            row =
              store(%{
                name_key: name_key,
                domain: domain,
                full_name: full_name,
                first_name: parts.first,
                last_name: parts.last,
                email: email,
                found: true,
                source: "provider",
                pattern_used: derive_or_nil(email, full_name),
                confidence: confidence_of(payload),
                verification_status: verification_of(payload),
                provider: meta.served_by,
                provider_cost_micro: lookup.spent_micro,
                raw: payload,
                expires_at: Cache.expires_at(:email_found)
              })

            {:ok, present(row, lookup)}
        end

      {:miss, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)

        {:ok,
         store_missing(
           name_key,
           domain,
           full_name,
           parts,
           Lookup.add(lookup, meta.cost_micro),
           meta
         )}

      {:error, _reason, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)

        {:ok,
         %{
           found: false,
           email: nil,
           full_name: full_name,
           domain: domain,
           source: "error",
           cached: false,
           cost: Lookup.cost_block(Lookup.add(lookup, meta.cost_micro))
         }}
    end
  end

  # A colleague's address tells us the company format, if we can find out whose
  # address it is. Our own caches answer that for free most of the time.
  defp learn_from_known_email(known, domain, lookup) do
    with {:ok, email, email_domain} <- Cache.normalize_email(known),
         true <- email_domain == domain,
         {:ok, enrichment, enrich_lookup} <- People.name_for(email) do
      if enrichment.full_name do
        PatternStore.learn(domain, email, enrichment.full_name)
      end

      if enrich_lookup.cached,
        do: lookup,
        else: Lookup.add(lookup, enrich_lookup.spent_micro)
    else
      _ -> lookup
    end
  end

  defp store_missing(name_key, domain, full_name, parts, lookup, meta) do
    row =
      store(%{
        name_key: name_key,
        domain: domain,
        full_name: full_name,
        first_name: parts.first,
        last_name: parts.last,
        found: false,
        source: "provider",
        provider: meta.served_by,
        provider_cost_micro: lookup.spent_micro,
        expires_at: Cache.expires_at(:email_missing)
      })

    present(row, lookup)
  end

  defp store(attrs) do
    Writer.put(Email, [:name_key, :domain], attrs)
  end

  defp present(row, lookup, opts \\ [])

  defp present(%Email{} = row, lookup, opts) do
    %{
      found: row.found,
      email: row.email,
      full_name: row.full_name,
      domain: row.domain,
      pattern: row.pattern_used,
      pattern_source: Keyword.get(opts, :pattern_source),
      confidence: row.confidence,
      # `source` says how the address was derived; `cached` says whether this
      # request spent anything. A pattern-built address off a cached pattern is
      # `source: "pattern"` and `cached: true` — both are true, and a caller
      # needs the first to judge the answer and the second to reconcile spend.
      source: if(Keyword.get(opts, :from_cache, false), do: "cache", else: row.source),
      verification_status: row.verification_status,
      provider: row.provider,
      cached: lookup.cached,
      stale: Cache.stale?(row),
      last_verified_at: row.last_found_at,
      cost: Lookup.cost_block(lookup)
    }
  end

  defp derive_or_nil(email, full_name) do
    case Patterns.derive(email, full_name) do
      {:ok, pattern} -> pattern
      _ -> nil
    end
  end

  defp extract_email(%{"output" => %{"email" => email}}) when is_binary(email), do: email
  defp extract_email(%{"email" => email}) when is_binary(email), do: email
  defp extract_email(_), do: nil

  defp confidence_of(%{"output" => %{"score" => score}}) when is_number(score), do: score / 100
  defp confidence_of(%{"output" => %{"confidence" => c}}) when is_number(c), do: c / 100
  defp confidence_of(_), do: nil

  defp verification_of(%{"output" => %{"verified" => true}}), do: "verified"
  defp verification_of(%{"raw" => %{"validity" => v}}) when is_binary(v), do: v
  defp verification_of(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Look up a cached row without spending anything."
  @spec cached_row(String.t(), String.t()) :: Email.t() | nil
  def cached_row(name_key, domain) do
    Email
    |> where([e], e.name_key == ^name_key and e.domain == ^domain)
    |> Repo.one()
  end
end
