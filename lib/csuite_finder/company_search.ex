defmodule CsuiteFinder.CompanySearch do
  @moduledoc """
  Finding companies rather than people — the `/company/search` endpoint.

  This is the top of the funnel: an account list. Give it an industry, a
  technology, a headcount band or a plain description and it returns companies
  with their domains, and every one of those domains is the input the rest of
  the API already takes — `/company/people` for the room, `/email/find` for a
  named person in it.

  ## Two caches, not one

  A search remembers only *which* companies it returned, keyed on a fingerprint
  of the filters. The companies themselves are ordinary `company_profiles` rows,
  the same ones `/company/info` reads and writes. So a domain discovered by a
  search is enriched by any later profile lookup, and a company already known
  costs nothing to return again.

  The fingerprint is taken after normalisation, so the same question spelled two
  ways — different case, different parameter order, a stray space — is one
  purchase rather than two.

  ## Why every search carries a free-text `q`

  The providers behind this route are ordered cheapest first, and the cheapest
  are free — but they match on `q`, while an industry-only request offers them
  nothing to match on and falls through to a paid one. treg sends each provider
  only the fields it accepts, so adding a `q` built from the filters costs
  nothing and makes the free providers eligible. The filters still ride along
  for the providers that take them; this only widens who can answer.

  ## On headcount

  Providers disagree about what a size filter even is, and most of the ones this
  routes to do not take one at all. So `size` is applied twice and honestly:
  it is folded into the free-text query for the providers that read one, and it
  is applied again here against the headcount that came back. A company whose
  headcount the provider did not report is kept rather than dropped — silence is
  not evidence of size.
  """

  import Ecto.Query

  alias CsuiteFinder.Cache.{CompanyProfile, CompanySearch}
  alias CsuiteFinder.{Budgets, Cache, CostModel, Lookup, Repo}
  alias CsuiteFinder.Treg.Client

  @capability "companies.search"
  @endpoint "treg.companies.search"

  # An account list ages slowly: companies do not change industry or technology
  # stack week to week, and re-buying the same list is pure loss.
  @ttl_seconds 30 * 86_400

  @default_limit 10
  @max_limit 50

  @filters ~w(industry technology country q name domain)a

  @doc """
  Search for companies.

  Options are the filters — `:industry`, `:technology`, `:country`, `:q`,
  `:name`, `:domain`, `:size` — plus `:limit` (1..#{@max_limit}).

  At least one filter is required: an unfiltered search is a request to buy a
  random page of the internet.
  """
  @spec search(keyword() | map()) ::
          {:ok, [CompanyProfile.t()], Lookup.meta()} | {:error, :missing_params, [String.t()]}
  def search(opts) do
    opts = Map.new(opts)
    filters = normalize_filters(opts)
    size = normalize_size(opts[:size])
    limit = clamp_limit(opts[:limit])

    if filters == %{} and is_nil(size) do
      # Naming every accepted filter, because the caller's next move is to pick
      # one and a bare "missing parameters" makes them read the docs first.
      {:error, :missing_params, Enum.map(filters(), &"#{&1} (any one)")}
    else
      fingerprint = fingerprint(filters, size, limit)

      case cached(fingerprint) do
        %CompanySearch{} = row -> {:ok, load(row.domains), Lookup.hit()}
        nil -> fetch(fingerprint, filters, size, limit)
      end
    end
  end

  @doc "The filters this endpoint accepts, for documentation."
  @spec filters() :: [atom()]
  def filters, do: @filters ++ [:size]

  @doc "The largest page we will sell in one call."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  # -------------------------------------------------------------- normalising

  defp normalize_filters(opts) do
    @filters
    |> Enum.reduce(%{}, fn key, acc ->
      case clean(opts[key] || opts[to_string(key)]) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp clean(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, 200) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean(_), do: nil

  # "50-200", "200+", "1000" — anything else is ignored rather than guessed at.
  defp normalize_size(value) do
    case clean(value) do
      nil ->
        nil

      text ->
        case Regex.run(~r/^(\d+)\s*(?:[-–]\s*(\d+)|(\+))?$/, text) do
          [_, min] ->
            %{min: String.to_integer(min), max: nil, label: text}

          [_, min, max] ->
            %{min: String.to_integer(min), max: String.to_integer(max), label: text}

          [_, min, "", "+"] ->
            %{min: String.to_integer(min), max: nil, label: text}

          _ ->
            nil
        end
    end
  end

  defp clamp_limit(nil), do: @default_limit

  defp clamp_limit(value) when is_integer(value),
    do: value |> max(1) |> min(@max_limit)

  defp clamp_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> clamp_limit(n)
      :error -> @default_limit
    end
  end

  defp clamp_limit(_), do: @default_limit

  # Normalised first, so "SaaS" and " saas " are the same purchase.
  defp fingerprint(filters, size, limit) do
    payload =
      filters
      |> Enum.map(fn {k, v} -> {to_string(k), String.downcase(v)} end)
      |> Enum.sort()
      |> Kernel.++([{"size", (size && size.label) || ""}, {"limit", to_string(limit)}])
      |> Enum.map_join("|", fn {k, v} -> "#{k}=#{v}" end)

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # ------------------------------------------------------------------- lookup

  defp cached(fingerprint) do
    CompanySearch
    |> where([s], s.fingerprint == ^fingerprint)
    |> Repo.one()
    |> case do
      row -> if fresh?(row), do: row, else: nil
    end
  end

  defp fresh?(nil), do: false

  defp fresh?(%CompanySearch{expires_at: nil}), do: false

  defp fresh?(%CompanySearch{expires_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) == :gt

  defp load([]), do: []

  defp load(domains) do
    rows =
      CompanyProfile
      |> where([c], c.domain in ^domains)
      |> Repo.all()
      |> Map.new(&{&1.domain, &1})

    # Provider order is relevance order; the database's is not.
    Enum.flat_map(domains, fn domain ->
      case Map.get(rows, domain) do
        nil -> []
        row -> [row]
      end
    end)
  end

  defp fetch(fingerprint, filters, size, limit) do
    body =
      filters
      |> Map.put(:limit, limit)
      |> maybe_widen(size)
      |> with_query()

    result =
      Client.call(@endpoint,
        method: :post,
        body: body,
        max_cost: Budgets.usd(:company_search),
        prefer: CostModel.preferred(@capability)
      )

    case result do
      {:ok, payload, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)

        companies =
          payload
          |> extract_rows()
          |> Enum.map(&normalize_row/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(&within?(&1, size))
          |> Enum.uniq_by(& &1.domain)
          |> Enum.take(limit)

        rows = Enum.map(companies, &upsert_profile(&1, meta))
        store(fingerprint, filters, size, limit, rows, payload, meta)

        {:ok, rows, Lookup.miss(meta.cost_micro)}

      {:miss, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        store(fingerprint, filters, size, limit, [], nil, meta)
        {:ok, [], Lookup.miss(meta.cost_micro)}

      {:error, _reason, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        # An upstream failure is not evidence that nothing matches, so it is
        # deliberately not cached as an empty result.
        {:ok, [], Lookup.miss(meta.cost_micro)}
    end
  end

  # Most providers here have no size filter. Folding the band into the free-text
  # query is the only way the ones that read one ever see it.
  defp maybe_widen(body, nil), do: body

  defp maybe_widen(body, size) do
    hint = "#{size.label} employees"
    Map.update(body, :q, hint, fn existing -> existing <> " " <> hint end)
  end

  # The cheapest providers for this capability are free and match on `q` alone.
  # A caller who sent only `industry` would sail past them into a paid one, so
  # the filters are restated as a description. Costs nothing, changes nothing
  # for the providers that read the structured fields, and is the difference
  # between a free row and a paid one.
  defp with_query(body) do
    case Map.get(body, :q) do
      existing when is_binary(existing) and existing != "" ->
        body

      _ ->
        described =
          [
            body[:industry] && "#{body[:industry]} companies",
            body[:technology] && "using #{body[:technology]}",
            body[:country] && "in #{body[:country]}",
            body[:name]
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        if described == "", do: body, else: Map.put(body, :q, described)
    end
  end

  defp within?(_company, nil), do: true

  defp within?(%{employee_count: nil}, _size), do: true

  defp within?(%{employee_count: count}, %{min: min, max: max}) do
    count >= min and (is_nil(max) or count <= max)
  end

  # ------------------------------------------------------------ provider rows

  # Fifteen providers behind one route, and they disagree about what to call the
  # list as well as what to call its fields.
  defp extract_rows(payload) do
    cond do
      is_list(payload) ->
        payload

      is_map(payload) ->
        Enum.find_value(
          ["companies", "results", "data", "organizations", "items"],
          [],
          fn key ->
            case Map.get(payload, key) do
              rows when is_list(rows) -> rows
              _ -> nil
            end
          end
        )

      true ->
        []
    end
  end

  # Fifteen providers, fifteen spellings. Anything without a domain is dropped:
  # a company we cannot address is not an account.
  defp normalize_row(row) when is_map(row) do
    case domain_of(row) do
      nil ->
        nil

      domain ->
        %{
          domain: domain,
          name: pick(row, ~w(name company_name companyName legal_name title)),
          industry: pick(row, ~w(industry sector industries category)),
          employee_count:
            integer(pick(row, ~w(employee_count employees employeeCount headcount size))),
          employee_range: pick(row, ~w(employee_range employeeRange size_range employeesRange)),
          country: pick(row, ~w(country country_code countryCode location_country)),
          city: pick(row, ~w(city locality location_city town)),
          website: pick(row, ~w(website url website_url homepage)),
          linkedin_url: pick(row, ~w(linkedin_url linkedinUrl linkedin social_linkedin)),
          description: pick(row, ~w(description summary about tagline)),
          tech_stack: list(pick(row, ~w(technologies tech_stack techStack technology)))
        }
    end
  end

  defp normalize_row(_), do: nil

  defp domain_of(row) do
    case pick(row, ~w(domain website_domain primary_domain website url homepage)) do
      nil ->
        nil

      value ->
        value
        |> String.trim()
        |> String.replace(~r{^https?://}i, "")
        |> String.replace(~r{^www\.}i, "")
        |> String.split(~r{[/?#]}, parts: 2)
        |> hd()
        |> String.downcase()
        |> case do
          "" -> nil
          domain -> if String.contains?(domain, "."), do: domain, else: nil
        end
    end
  end

  defp pick(row, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(row, key) do
        value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
        value when is_integer(value) -> value
        value when is_list(value) -> if value == [], do: nil, else: value
        _ -> nil
      end
    end)
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp integer(_), do: nil

  defp list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp list(value) when is_binary(value), do: [value]
  defp list(_), do: []

  # ------------------------------------------------------------------ storing

  # Written into the same table /company/info uses, so a domain discovered here
  # is a company the rest of the API already knows. `found: true` and a `source`
  # of "search" keep it distinguishable from a full profile lookup, which
  # returns more fields than a search row carries.
  defp upsert_profile(company, meta) do
    attrs =
      company
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == [] end)
      |> Map.merge(%{
        found: true,
        source: "search",
        provider: meta.served_by,
        expires_at: Cache.expires_at(:company)
      })

    existing = Repo.get_by(CompanyProfile, domain: company.domain)

    # A search row is thinner than a profile. Merging over the existing row
    # rather than replacing it means discovery never erases what an enrichment
    # already paid for.
    (existing || %CompanyProfile{})
    |> CompanyProfile.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  defp store(fingerprint, filters, size, limit, rows, payload, meta) do
    domains = Enum.map(rows, & &1.domain)

    %CompanySearch{}
    |> CompanySearch.changeset(%{
      fingerprint: fingerprint,
      filters:
        filters
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.merge(%{"size" => size && size.label, "limit" => limit}),
      domains: domains,
      total: length(domains),
      found: domains != [],
      provider: meta.served_by,
      provider_cost_micro: meta.cost_micro,
      raw: raw(payload),
      expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second),
      last_found_at: if(domains != [], do: DateTime.utc_now())
    })
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :fingerprint
    )
  end

  defp raw(payload) when is_map(payload), do: payload
  defp raw(_), do: nil

  @doc "The public shape of one company in a search result."
  @spec present(CompanyProfile.t()) :: map()
  def present(%CompanyProfile{} = row) do
    %{
      domain: row.domain,
      name: row.name,
      industry: row.industry,
      employee_count: row.employee_count,
      employee_range: row.employee_range,
      country: row.country,
      city: row.city,
      website: row.website,
      linkedin_url: row.linkedin_url,
      description: row.description,
      tech_stack: row.tech_stack
    }
  end
end
