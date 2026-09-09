defmodule CsuiteFinder.People do
  @moduledoc """
  Person data behind an email address — the `/email/enrich` and `/name/who`
  endpoints.

  ## On the inferred fallback

  When no provider can identify an address, we still answer, by reading the name
  out of the address itself: `john.smith@acme.com` is almost certainly John
  Smith, and if we hold that company's pattern we can invert it and be sure of
  the split rather than guessing at it.

  That answer is *always* labelled `source: "inferred"` with a low confidence and
  an explicit warning, and it is cached in its own right so it can be told apart
  from provider data later. Returning a guess dressed as a verified record would
  poison the cache for every later caller and put bounces in someone's sending
  reputation, so the guess is offered — clearly marked — rather than disguised.
  """

  import Ecto.Query

  alias CsuiteFinder.{Budgets, Cache, CostModel, PatternStore, Patterns, Repo}
  alias CsuiteFinder.Cache.PersonEnrichment
  alias CsuiteFinder.Cache.Writer
  alias CsuiteFinder.Treg.Client

  @capability "people.enrich"
  @endpoint "treg.people.enrich"

  @generic_mailboxes ~w(info hello contact support sales admin help team office
                        billing careers jobs press marketing legal noreply
                        no-reply donotreply postmaster abuse security webmaster
                        enquiries hi ask service accounts hr recruiting)

  @doc """
  Enrich a person from their email address.

  Falls back to labelled local inference when no provider has the person.
  """
  @spec enrich(String.t(), keyword()) ::
          {:ok, PersonEnrichment.t(), CsuiteFinder.Lookup.meta()} | {:error, atom()}
  def enrich(email, opts \\ []) do
    with {:ok, email, domain} <- Cache.normalize_email(email) do
      case cached(email, opts) do
        %PersonEnrichment{} = row -> {:ok, row, CsuiteFinder.Lookup.hit()}
        nil -> fetch(email, domain)
      end
    end
  end

  @doc """
  Just the name behind an address. Same data path as `enrich/2` — the endpoints
  differ in what they present, not in what they cost.
  """
  @spec name_for(String.t()) ::
          {:ok, PersonEnrichment.t(), CsuiteFinder.Lookup.meta()} | {:error, atom()}
  def name_for(email), do: enrich(email)

  defp cached(email, opts) do
    if Keyword.get(opts, :refresh, false) do
      nil
    else
      row = Repo.one(from p in PersonEnrichment, where: p.email == ^email)
      if Cache.fresh?(row), do: row, else: nil
    end
  end

  defp fetch(email, domain) do
    result =
      Client.call(@endpoint,
        method: :post,
        body: %{email: email},
        max_cost: Budgets.usd(:person_enrich),
        prefer: CostModel.preferred(@capability)
      )

    case result do
      {:ok, payload, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)

        case normalize_output(payload) do
          %{full_name: nil} ->
            {:ok, infer(email, domain, meta.cost_micro),
             CsuiteFinder.Lookup.miss(meta.cost_micro)}

          attrs ->
            {:ok, store_provider(email, domain, attrs, payload, meta),
             CsuiteFinder.Lookup.miss(meta.cost_micro)}
        end

      {:miss, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        {:ok, infer(email, domain, meta.cost_micro), CsuiteFinder.Lookup.miss(meta.cost_micro)}

      {:error, _reason, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        {:ok, infer(email, domain, meta.cost_micro), CsuiteFinder.Lookup.miss(meta.cost_micro)}
    end
  end

  defp store_provider(email, domain, attrs, payload, meta) do
    # Every number this service sees is worth keeping: no provider does reverse
    # phone lookup, so our own rows are the only way one is ever attributable.
    CsuiteFinder.Phones.observe(attrs[:phone], %{
      email: email,
      domain: domain,
      full_name: attrs[:full_name],
      position: attrs[:position],
      source: "enrichment",
      provider: meta.served_by
    })

    attrs
    |> Map.merge(%{
      email: email,
      domain: domain,
      found: true,
      source: "provider",
      confidence: "high",
      provider: meta.served_by,
      provider_cost_micro: meta.cost_micro,
      raw: payload,
      expires_at: Cache.expires_at(:enrichment_provider)
    })
    |> upsert()
  end

  # ---------------------------------------------------------------- inference

  @doc """
  Derive what we can from the address alone. Never presented as provider data.
  """
  @spec infer(String.t(), String.t(), integer()) :: PersonEnrichment.t()
  def infer(email, domain, spent_micro \\ 0) do
    [local | _] = String.split(email, "@")
    parts = infer_name_parts(local, domain)

    parts
    |> Map.merge(%{
      email: email,
      domain: domain,
      company_name: company_guess(domain),
      found: parts.full_name != nil or parts.last_name != nil,
      source: "inferred",
      provider: nil,
      provider_cost_micro: spent_micro,
      expires_at: Cache.expires_at(:enrichment_inferred)
    })
    |> upsert()
  end

  defp infer_name_parts(local, domain) do
    cond do
      # A shared mailbox belongs to no one; inventing a person for it is the one
      # guess that is always wrong.
      local in @generic_mailboxes ->
        %{full_name: nil, first_name: nil, last_name: nil, confidence: "none"}

      true ->
        case pattern_inversion(local, domain) do
          {:ok, parts} -> parts
          :error -> heuristic_split(local)
        end
    end
  end

  # If we already hold this company's pattern, the split is knowable rather than
  # guessable. Only a cached pattern is used — inference must not quietly turn
  # into a second paid lookup.
  defp pattern_inversion(local, domain) do
    with %{found: true, pattern: pattern} when is_binary(pattern) <-
           PatternStore.get_cached(domain),
         {:ok, names} <- Patterns.invert(local, pattern) do
      from_inverted(names)
    else
      _ -> :error
    end
  end

  # What the inversion yields depends on the company's format. `{first}.{last}`
  # gives both names; `{f}{last}` gives a surname and a single initial, which is
  # a real answer about the surname and no answer at all about the first name.
  # Reporting the initial as a first name ("Mbenioff") would be worse than
  # admitting we only know the surname.
  defp from_inverted(names) do
    first = names[:first]
    last = names[:last]

    cond do
      is_binary(first) and is_binary(last) ->
        {:ok,
         %{
           full_name: titlecase(first) <> " " <> titlecase(last),
           first_name: titlecase(first),
           last_name: titlecase(last),
           confidence: "medium"
         }}

      is_binary(last) ->
        {:ok,
         %{
           full_name: nil,
           first_name: nil,
           last_name: titlecase(last),
           confidence: "low"
         }}

      is_binary(first) ->
        {:ok,
         %{
           full_name: titlecase(first),
           first_name: titlecase(first),
           last_name: nil,
           confidence: "low"
         }}

      true ->
        :error
    end
  end

  defp heuristic_split(local) do
    cleaned = String.replace(local, ~r/\d+$/, "")

    case String.split(cleaned, ~r/[._\-]/, trim: true) do
      [first, last] when byte_size(first) > 1 and byte_size(last) > 1 ->
        %{
          full_name: titlecase(first) <> " " <> titlecase(last),
          first_name: titlecase(first),
          last_name: titlecase(last),
          confidence: "low"
        }

      [first, middle, last] when byte_size(first) > 1 and byte_size(last) > 1 ->
        %{
          full_name: titlecase(first) <> " " <> titlecase(middle) <> " " <> titlecase(last),
          first_name: titlecase(first),
          last_name: titlecase(last),
          confidence: "low"
        }

      [single] when byte_size(single) > 2 ->
        # `patrick@` — a first name, and no way to know the surname.
        %{
          full_name: titlecase(single),
          first_name: titlecase(single),
          last_name: nil,
          confidence: "low"
        }

      _ ->
        %{full_name: nil, first_name: nil, last_name: nil, confidence: "none"}
    end
  end

  defp titlecase(nil), do: nil

  defp titlecase(value) do
    value
    |> String.split(~r/[\s'\-]/, include_captures: true, trim: true)
    |> Enum.map_join(fn
      part when part in ["-", "'", " "] -> part
      part -> String.capitalize(part)
    end)
  end

  defp company_guess(domain) do
    domain |> String.split(".") |> hd() |> titlecase()
  end

  # ------------------------------------------------------------------ storage

  # `known?` is deliberately tied to the provider, not to `found`. An inferred
  # guess can have `found: true` and still must never overwrite a real record —
  # if a provider identified this address once and today's refresh missed, the
  # provider's answer is the one worth keeping.
  defp upsert(attrs) do
    Writer.put(PersonEnrichment, [:email], attrs, known?: attrs[:source] == "provider")
  end

  defp normalize_output(%{"output" => output}) when is_map(output) do
    %{
      full_name: get(output, ["full_name", "fullName", "name"]),
      first_name: get(output, ["first_name", "firstName", "givenName"]),
      last_name: get(output, ["last_name", "lastName", "familyName"]),
      position: get(output, ["title", "position", "job_title"]),
      seniority: get(output, ["seniority"]),
      department: get(output, ["department", "role"]),
      company_name: get(output, ["company", "company_name", "organization"]),
      linkedin_url: get(output, ["linkedin_url", "linkedin"]),
      twitter: get(output, ["twitter", "twitter_handle"]),
      location: get(output, ["location"]),
      phone: get(output, ["phone", "phone_number"])
    }
  end

  defp normalize_output(_), do: %{full_name: nil}

  defp get(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  @doc "Present an enrichment row as an API payload."
  @spec present(PersonEnrichment.t(), CsuiteFinder.Lookup.meta()) :: map()
  def present(%PersonEnrichment{} = row, lookup) do
    base = %{
      email: row.email,
      found: row.found,
      full_name: row.full_name,
      first_name: row.first_name,
      last_name: row.last_name,
      position: row.position,
      seniority: row.seniority,
      department: row.department,
      company_name: row.company_name,
      linkedin_url: row.linkedin_url,
      twitter: row.twitter,
      location: row.location,
      phone: row.phone,
      source: row.source,
      confidence: row.confidence,
      provider: row.provider,
      cached: lookup.cached,
      stale: CsuiteFinder.Cache.stale?(row),
      last_verified_at: row.last_found_at,
      cost: CsuiteFinder.Lookup.cost_block(lookup)
    }

    if row.source == "inferred" do
      Map.put(
        base,
        :warning,
        "No provider could identify this address. These fields were derived from " <>
          "the address itself and are not verified — treat them as a guess."
      )
    else
      base
    end
  end
end
