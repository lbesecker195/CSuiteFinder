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
    Repo,
    Verifier
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
        case buildable(domain, parts) do
          [] ->
            # The company's format needs a name part this person does not have
            # (a `{last}` pattern against a mononym) — fall through and buy it.
            find_via_provider(full_name, parts, name_key, domain, lookup)

          candidates ->
            confirm(candidates, full_name, parts, name_key, domain, pattern_row, lookup)
        end

      _ ->
        find_via_provider(full_name, parts, name_key, domain, lookup)
    end
  end

  # Every pattern this domain might use, turned into an address for this person.
  # Patterns needing a name part they do not have are dropped rather than
  # producing a half-built address.
  defp buildable(domain, parts) do
    domain
    |> PatternStore.candidates()
    |> Enum.flat_map(fn pattern ->
      case Patterns.apply_pattern(pattern, parts) do
        {:ok, local} -> [{pattern, local <> "@" <> domain}]
        {:error, :missing_part} -> []
      end
    end)
    |> Enum.uniq_by(&elem(&1, 1))
  end

  # Build the address, then ask the mailbox whether it exists.
  #
  # A pattern is a statement about a company, not about a person, and companies
  # keep exceptions — the founder on `first@`, the person who married and kept
  # both surnames. Returning a constructed address unchecked is how a customer
  # ends up bouncing mail we told them was fine.
  #
  # It is not checked every time. A check costs money, so it is spent only where
  # it can change the answer: when the domain offers more than one plausible
  # format, or when the one we hold has never actually been seen to deliver
  # here. Once a format has proved itself on a domain, later people at that
  # company resolve on it without another check — the same amortisation that
  # makes buying the pattern worth it in the first place.
  defp confirm(candidates, full_name, parts, name_key, domain, pattern_row, lookup) do
    [{top_pattern, top_email} | _] = candidates

    if worth_checking?(candidates, domain, top_pattern) do
      case walk(candidates, domain, lookup) do
        {:deliverable, pattern, email, lookup} ->
          {:ok,
           accept(email, pattern, full_name, parts, name_key, domain, pattern_row, lookup,
             verification: "deliverable"
           )}

        {:undecidable, lookup} ->
          # A catch-all domain accepts everything, so no check can separate the
          # candidates. Take the best-ranked one and say it is unconfirmed.
          {:ok,
           accept(top_email, top_pattern, full_name, parts, name_key, domain, pattern_row, lookup,
             verification: "accept_all"
           )}

        {:exhausted, lookup} ->
          # Every format we know for this company was rejected for this person.
          # Our guesses are disproved, so buy the answer rather than return one.
          find_via_provider(full_name, parts, name_key, domain, lookup)
      end
    else
      {:ok,
       accept(top_email, top_pattern, full_name, parts, name_key, domain, pattern_row, lookup, [])}
    end
  end

  # Two reasons not to spend: the domain accepts everything, so no check can
  # discriminate; or the best format has already been seen to deliver here, so
  # the question is settled. Candidates are ranked proven-first, which is what
  # makes the second test worth doing on the top one alone.
  defp worth_checking?(_candidates, domain, top_pattern) do
    not (PatternStore.catch_all?(domain) or PatternStore.proven?(domain, top_pattern))
  end

  defp walk(candidates, domain, lookup), do: walk(candidates, domain, lookup, :exhausted)

  defp walk([], _domain, lookup, outcome), do: {outcome, lookup}

  defp walk([{pattern, email} | rest], domain, lookup, outcome) do
    case Verifier.verify(email) do
      {:ok, row, verify_lookup} ->
        lookup =
          if verify_lookup.cached, do: lookup, else: Lookup.add(lookup, verify_lookup.spent_micro)

        cond do
          row.catch_all == true ->
            PatternStore.mark_catch_all(domain)
            {:undecidable, lookup}

          row.status == "deliverable" ->
            PatternStore.record_outcome(domain, pattern, "deliverable")
            {:deliverable, pattern, email, lookup}

          row.status == "undeliverable" ->
            PatternStore.record_outcome(domain, pattern, "undeliverable")
            walk(rest, domain, lookup, outcome)

          true ->
            # "unknown" is not evidence either way — a verifier that could not
            # tell us must not be read as a rejection. Try the next format, but
            # remember that the run is now inconclusive rather than exhaustive,
            # so an all-unknown sweep returns the best guess instead of paying
            # to replace addresses nobody disproved.
            walk(rest, domain, lookup, :undecidable)
        end

      {:error, _reason} ->
        # A verifier outage must not turn a resolvable address into a miss.
        {:undecidable, lookup}
    end
  end

  defp accept(email, pattern, full_name, parts, name_key, domain, pattern_row, lookup, opts) do
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
        verification_status: Keyword.get(opts, :verification),
        provider_cost_micro: lookup.spent_micro,
        expires_at: Cache.expires_at(:email_found)
      })

    present(row, lookup, pattern_source: pattern_row.source)
  end

  @doc """
  Find the work email behind a LinkedIn profile URL.

  A different shape of the same job, and a dearer one. The cheap path — buy a
  company's format once, then resolve everyone there for nothing — needs a
  domain, and a profile URL does not carry one. So this always reaches a
  provider, which is why it is priced separately rather than folded into
  `find/3`.

  The answer is stored in the ordinary address cache, keyed by name and domain
  like everything else, with the profile URL as a second index into it. A
  company whose format we learn this way makes the *next* person there free on
  the cheap path.
  """
  @spec find_by_linkedin(String.t(), keyword()) :: {:ok, result()} | {:error, atom()}
  def find_by_linkedin(url, opts \\ []) do
    with {:ok, url} <- normalize_linkedin(url) do
      case cached_by_linkedin(url, opts) do
        %Email{} = row -> {:ok, present(row, Lookup.hit(), from_cache: true)}
        nil -> resolve_linkedin(url)
      end
    end
  end

  # Canonical enough that the same profile written three ways is one purchase:
  # scheme and www dropped, query and trailing slash dropped, lower-cased.
  defp normalize_linkedin(url) when is_binary(url) do
    trimmed =
      url
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r"^https?://", "")
      |> String.replace(~r"^([a-z]{2,3}\.)?www\.", "")
      |> String.split(~r"[?#]", parts: 2)
      |> hd()
      |> String.trim_trailing("/")

    if Regex.match?(~r"^([a-z]{2,3}\.)?linkedin\.com/(in|pub)/[^/]+$", trimmed) do
      {:ok, "https://www." <> String.replace(trimmed, ~r"^[a-z]{2,3}\.", "")}
    else
      {:error, :invalid_linkedin_url}
    end
  end

  defp normalize_linkedin(_), do: {:error, :invalid_linkedin_url}

  defp cached_by_linkedin(url, opts) do
    if Keyword.get(opts, :refresh, false) do
      nil
    else
      row =
        Email
        |> where([e], e.linkedin_url == ^url)
        |> order_by([e], desc: e.found)
        |> limit(1)
        |> Repo.one()

      if Cache.fresh?(row), do: row, else: nil
    end
  end

  defp resolve_linkedin(url) do
    result =
      Client.call(@endpoint,
        method: :post,
        body: %{linkedin_url: url},
        max_cost: Budgets.usd(:email_find_linkedin),
        prefer: CostModel.preferred(@capability)
      )

    case result do
      {:ok, payload, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        lookup = Lookup.miss(meta.cost_micro)

        case extract_email(payload) do
          nil -> {:ok, present(store_linkedin_missing(url, lookup, meta), lookup)}
          email -> {:ok, present(store_linkedin_found(url, email, payload, lookup, meta), lookup)}
        end

      {:miss, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        lookup = Lookup.miss(meta.cost_micro)
        {:ok, present(store_linkedin_missing(url, lookup, meta), lookup)}

      {:error, _reason, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        # A provider outage is not evidence the profile has no address, so it is
        # not cached as a miss.
        {:error, :provider_unavailable}
    end
  end

  defp store_linkedin_found(url, email, payload, lookup, meta) do
    [_, domain] = String.split(email, "@", parts: 2)
    full_name = payload_name(payload)

    # The format this address reveals is worth more than the address: it makes
    # everyone else at that company resolvable for nothing.
    if full_name, do: PatternStore.learn(domain, email, full_name)

    store(%{
      name_key: (full_name && Names.name_key(full_name)) || "linkedin:" <> url,
      domain: domain,
      full_name: full_name || email,
      email: email,
      linkedin_url: url,
      found: true,
      source: "provider",
      confidence: confidence_of(payload),
      verification_status: verification_of(payload),
      provider: meta.served_by,
      provider_cost_micro: lookup.spent_micro,
      raw: payload,
      expires_at: Cache.expires_at(:email_found)
    })
  end

  # A profile that resolved to nothing still gets a row, so the same URL is not
  # bought twice. It is keyed on the URL rather than a person, because a miss
  # is exactly the case where we never learned who they are.
  defp store_linkedin_missing(url, lookup, meta) do
    store(%{
      name_key: "linkedin:" <> url,
      domain: "linkedin.com",
      full_name: url,
      linkedin_url: url,
      found: false,
      source: "provider",
      provider: meta.served_by,
      provider_cost_micro: lookup.spent_micro,
      expires_at: Cache.expires_at(:email_missing)
    })
  end

  defp payload_name(payload) when is_map(payload) do
    Enum.find_value(["full_name", "name", "fullName"], fn key ->
      case get_in(payload, ["output", key]) || Map.get(payload, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp payload_name(_), do: nil

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

        case choose_email(extract_emails(payload), domain, lookup) do
          {nil, lookup} ->
            {:ok, store_missing(name_key, domain, full_name, parts, lookup, meta)}

          {email, lookup} ->
            # The answer carries the company's format for free — bank it. And if
            # the provider says it checked the mailbox, that is an observed
            # delivery for this format: the next colleague can be built from it
            # without buying a check of their own. A provider's unverified best
            # guess earns no such credit — it is a guess like ours.
            PatternStore.learn(domain, email, full_name)

            if verification_of(payload) == "verified" do
              case Patterns.derive(email, full_name) do
                {:ok, derived} -> PatternStore.record_outcome(domain, derived, "deliverable")
                _ -> :ok
              end
            end

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
      linkedin_url: row.linkedin_url,
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

  # Providers sometimes return more than one address for a person — the headline
  # answer plus alternatives. All of them, best-guess first.
  defp extract_emails(payload) do
    output = (is_map(payload) && Map.get(payload, "output")) || %{}

    alternatives =
      [
        Map.get(output, "emails"),
        Map.get(output, "alternatives"),
        is_map(payload) && Map.get(payload, "emails")
      ]
      |> Enum.filter(&is_list/1)
      |> List.flatten()
      |> Enum.map(fn
        value when is_binary(value) -> value
        %{"email" => value} when is_binary(value) -> value
        _ -> nil
      end)

    [extract_email(payload) | alternatives]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  # One address is the answer. Several is a question, and the mailbox settles
  # it — the same check the pattern path uses, hitting the same cache. The
  # loser is never stored: only the address that answered is cached for this
  # person, so a later call cannot hand back one we already disproved.
  defp choose_email([], _domain, lookup), do: {nil, lookup}
  defp choose_email([only], _domain, lookup), do: {only, lookup}

  defp choose_email(emails, domain, lookup) do
    if PatternStore.catch_all?(domain) do
      # Every candidate would come back accepting; the provider's own ordering
      # is better evidence than a check that cannot discriminate.
      {hd(emails), lookup}
    else
      Enum.reduce_while(emails, {hd(emails), lookup}, fn email, {_best, acc} ->
        case Verifier.verify(email) do
          {:ok, %{status: "deliverable"}, verify_lookup} ->
            {:halt, {email, add_unless_cached(acc, verify_lookup)}}

          {:ok, %{catch_all: true}, verify_lookup} ->
            {:halt, {hd(emails), add_unless_cached(acc, verify_lookup)}}

          {:ok, _row, verify_lookup} ->
            {:cont, {hd(emails), add_unless_cached(acc, verify_lookup)}}

          {:error, _reason} ->
            {:halt, {hd(emails), acc}}
        end
      end)
    end
  end

  defp add_unless_cached(lookup, %{cached: true}), do: lookup
  defp add_unless_cached(lookup, verify_lookup), do: Lookup.add(lookup, verify_lookup.spent_micro)

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
