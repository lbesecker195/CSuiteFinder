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

      cond do
        not Cache.fresh?(row) -> nil
        worth_another_try?(row) -> nil
        true -> row
      end
    end
  end

  @doc """
  Should a repeat request for this person be re-resolved rather than answered
  from the cache?

  Only when what we hold is an address the mailbox has rejected AND there is a
  method left we have not spent — another of the company's formats, or the paid
  lookup. A caller asking again is the demand signal: the address they were
  given does not work, and handing back the same dead address a second time
  helps nobody.

  When everything has been tried this returns false, so a caller hammering an
  unresolvable person is answered from the cache rather than re-billed on every
  request.
  """
  @spec worth_another_try?(Email.t() | nil) :: boolean()
  def worth_another_try?(%Email{verification_status: "undeliverable"} = row) do
    not row.provider_tried or untried_patterns?(row)
  end

  def worth_another_try?(_row), do: false

  defp untried_patterns?(%Email{} = row) do
    case Names.split(row.full_name || "") do
      {:ok, parts} ->
        row.domain
        |> buildable(parts, row.rejected || [])
        |> Enum.any?()

      _ ->
        false
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
        case buildable(domain, parts, rejected_for(name_key, domain)) do
          [] ->
            # The company's format needs a name part this person does not have
            # (a `{last}` pattern against a mononym) — fall through and buy it.
            find_via_provider(full_name, parts, name_key, domain, lookup)

          [{pattern, email} | _] ->
            # Built and returned, not checked. Verifying every address we
            # generate would cost more than the address sells for — the
            # customer's own /email/deliverable call is what teaches us whether
            # a format lands, and it teaches us for free.
            {:ok,
             accept(email, pattern, full_name, parts, name_key, domain, pattern_row, lookup, [])}
        end

      _ ->
        find_via_provider(full_name, parts, name_key, domain, lookup)
    end
  end

  # Every pattern this domain might use, turned into an address for this person.
  # Patterns needing a name part they do not have are dropped rather than
  # producing a half-built address.
  defp buildable(domain, parts, rejected) do
    domain
    |> PatternStore.candidates()
    |> Enum.flat_map(fn pattern ->
      case Patterns.apply_pattern(pattern, parts) do
        # Lower-cased here, because that is how it is stored — and comparing a
        # freshly built "Jane.Doe@acme.com" against a stored "jane.doe@acme.com"
        # silently rebuilds an address we have already been told is dead.
        {:ok, local} -> [{pattern, String.downcase(local <> "@" <> domain)}]
        {:error, :missing_part} -> []
      end
    end)
    |> Enum.uniq_by(&elem(&1, 1))
    # An address this person has already been proved not to have is not a
    # candidate, however common the format is at their company.
    |> Enum.reject(fn {_pattern, email} -> email in rejected end)
  end

  defp rejected_for(name_key, domain) do
    case cached_row(name_key, domain) do
      %Email{rejected: rejected} when is_list(rejected) -> rejected
      _ -> []
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
        # Formats ruled out for this person on the way to the one that worked,
        # so a later attempt never rebuilds them.
        rejected: Enum.uniq(rejected_for(name_key, domain) ++ Keyword.get(opts, :rejected, [])),
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

  defp find_via_provider(full_name, parts, name_key, domain, lookup, ruled_out \\ []) do
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
            {:ok,
             store_missing(
               name_key,
               domain,
               full_name,
               parts,
               lookup,
               meta,
               Enum.uniq(rejected_for(name_key, domain) ++ ruled_out)
             )}

          {email, lookup} ->
            known_dead = Enum.uniq(rejected_for(name_key, domain) ++ ruled_out)

            if email in known_dead do
              # The provider handed back the very address the customer already
              # proved dead. That is the dead end we started from, not an
              # answer, so it is reported as a miss rather than sold again.
              {:ok, store_missing(name_key, domain, full_name, parts, lookup, meta, known_dead)}
            else
              provider_answer(
                email,
                known_dead,
                full_name,
                parts,
                name_key,
                domain,
                payload,
                meta,
                lookup
              )
            end
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

  # An address the provider found, banked along with what it teaches us about
  # the company's format.
  defp provider_answer(
         email,
         known_dead,
         full_name,
         parts,
         name_key,
         domain,
         payload,
         meta,
         lookup
       ) do
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
        rejected: known_dead,
        provider_tried: true,
        found: true,
        source: "provider",
        pattern_used: email && derive_or_nil(email, full_name),
        confidence: confidence_of(payload),
        provider: meta.served_by,
        provider_cost_micro: lookup.spent_micro,
        raw: payload,
        expires_at: Cache.expires_at(:email_found)
      })

    {:ok, present(row, lookup)}
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

  defp store_missing(name_key, domain, full_name, parts, lookup, meta, ruled_out \\ []) do
    row =
      store(%{
        name_key: name_key,
        domain: domain,
        full_name: full_name,
        first_name: parts.first,
        last_name: parts.last,
        found: false,
        source: "provider",
        rejected: ruled_out,
        # The paid lookup has been spent on this person, whatever it returned.
        provider_tried: true,
        # A disproof is not an empty refresh. The durable cache keeps the last
        # known value when a lookup comes back with nothing, which is right when
        # the provider simply failed — and wrong here, where the customer has
        # told us the address we were keeping is dead. Force the write so the
        # dead address stops being served.
        overwrite: ruled_out != [],
        provider: meta.served_by,
        provider_cost_micro: lookup.spent_micro,
        expires_at: Cache.expires_at(:email_missing)
      })

    present(row, lookup)
  end

  defp store(attrs) do
    {overwrite, attrs} = Map.pop(attrs, :overwrite, false)

    # `known?: true` tells the durable writer this is a definitive answer rather
    # than a refresh that came back empty, so it replaces the stored row instead
    # of preserving what was there.
    Writer.put(Email, [:name_key, :domain], attrs, known?: overwrite or attrs[:found] == true)
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

  # Several addresses for one person: the provider's own ordering is its best
  # guess and we take it. Checking them ourselves would cost more than the
  # answer sells for; a customer who verifies the one we returned tells us for
  # free whether it was right, and the next attempt for that person uses it.
  defp choose_email([], _domain, lookup), do: {nil, lookup}
  defp choose_email([best | _rest], _domain, lookup), do: {best, lookup}

  defp confidence_of(%{"output" => %{"score" => score}}) when is_number(score), do: score / 100
  defp confidence_of(%{"output" => %{"confidence" => c}}) when is_number(c), do: c / 100
  defp confidence_of(_), do: nil

  defp verification_of(%{"output" => %{"verified" => true}}), do: "verified"
  defp verification_of(%{"raw" => %{"validity" => v}}) when is_binary(v), do: v
  defp verification_of(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Take note of a deliverability check the customer paid for.

  This is the only place a mailbox result ever enters the finder, and it is
  deliberately the *customer's* check rather than one of ours. Verifying every
  address we generate would cost more than the address sells for; a customer
  checking one before they send it is going to happen anyway, and it tells us
  the same thing for nothing.

  What it teaches:

    * **This person.** The cached row records what the mailbox said. An address
      that was rejected makes the next request for that person re-resolve by
      another route instead of handing back the same dead address.
    * **This company.** The format behind the address gets a mark for or
      against it, which is what ranks the candidates for everyone else there —
      by what has been seen to land rather than by a provider's average.
    * **This domain.** A server that accepts everything is recorded as such,
      because no verification there means anything.

  Called by `CsuiteFinder.Verifier` after a check is stored. Never fails a
  verification: this is bookkeeping on the side of an answer the caller has
  already been given.
  """
  @spec record_verification(String.t(), String.t() | nil, boolean() | nil) :: :ok
  def record_verification(email, status, catch_all \\ false)

  def record_verification(email, status, catch_all) when is_binary(email) do
    if catch_all == true, do: mark_domain_catch_all(email)

    case verdict(status, catch_all) do
      nil ->
        :ok

      verdict ->
        Email
        |> where([e], e.email == ^email)
        |> Repo.all()
        |> Enum.each(&apply_verdict(&1, email, verdict, status, catch_all))
    end

    :ok
  end

  def record_verification(_email, _status, _catch_all), do: :ok

  # "unknown" is not a verdict. Recording it would mark a row as checked when
  # nothing was learned, and stop the next check from being worth making.
  defp verdict(_status, true), do: "accept_all"
  defp verdict(status, _) when status in ["deliverable", "undeliverable"], do: status
  defp verdict(_status, _), do: nil

  defp apply_verdict(%Email{} = row, email, verdict, status, catch_all) do
    row
    |> Email.changeset(%{
      verification_status: verdict,
      # Only an outright rejection rules an address out. A catch-all "accepted"
      # is not evidence the mailbox exists, but it is not evidence against it
      # either, so it must not send the next request off hunting.
      rejected:
        if(status == "undeliverable",
          do: Enum.uniq([email | row.rejected || []]),
          else: row.rejected || []
        )
    })
    |> Repo.update()

    learn_pattern_outcome(row, email, status, catch_all)
  end

  # A catch-all server accepts every address, so its verdict says nothing about
  # the format. Recording it would poison the ranking with a result that is
  # equally true of every candidate.
  defp learn_pattern_outcome(_row, _email, _status, true), do: :ok

  defp learn_pattern_outcome(%Email{full_name: full_name, domain: domain}, email, status, _)
       when is_binary(full_name) and is_binary(domain) and
              status in ["deliverable", "undeliverable"] do
    case Patterns.derive(email, full_name) do
      {:ok, pattern} -> PatternStore.record_outcome(domain, pattern, status)
      _ -> :ok
    end
  end

  defp learn_pattern_outcome(_row, _email, _status, _catch_all), do: :ok

  defp mark_domain_catch_all(email) do
    case String.split(email, "@", parts: 2) do
      [_local, domain] -> PatternStore.mark_catch_all(domain)
      _ -> :ok
    end
  end

  @doc "Look up a cached row without spending anything."
  @spec cached_row(String.t(), String.t()) :: Email.t() | nil
  def cached_row(name_key, domain) do
    Email
    |> where([e], e.name_key == ^name_key and e.domain == ^domain)
    |> Repo.one()
  end
end
