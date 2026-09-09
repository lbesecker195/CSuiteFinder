defmodule CsuiteFinder.Companies do
  @moduledoc """
  Company data behind an email address — the `/company/info` endpoint.

  Keyed on the domain rather than the address, so every employee of a company
  shares one cached row: the second person you look up at Stripe costs nothing.
  """

  import Ecto.Query

  alias CsuiteFinder.{Budgets, Cache, CostModel, Repo}
  alias CsuiteFinder.Cache.CompanyProfile
  alias CsuiteFinder.Cache.Writer
  alias CsuiteFinder.Treg.Client

  @capability "companies.enrich"
  @endpoint "treg.companies.enrich"

  @free_providers ~w(gmail.com googlemail.com yahoo.com hotmail.com outlook.com
                     live.com aol.com icloud.com me.com mac.com proton.me
                     protonmail.com gmx.com mail.com yandex.com zoho.com
                     fastmail.com hey.com msn.com)

  @doc "Company info from an email address (or a bare domain)."
  @spec info(String.t(), keyword()) ::
          {:ok, CompanyProfile.t(), CsuiteFinder.Lookup.meta()} | {:error, atom()}
  def info(email_or_domain, opts \\ []) do
    with {:ok, domain} <- resolve_domain(email_or_domain) do
      cond do
        domain in @free_providers ->
          # A consumer mailbox has no company behind it; buying an enrichment for
          # gmail.com would return Google and mislead the caller.
          {:ok, personal_domain_row(domain), CsuiteFinder.Lookup.hit()}

        true ->
          case cached(domain, opts) do
            %CompanyProfile{} = row -> {:ok, row, CsuiteFinder.Lookup.hit()}
            nil -> fetch(domain)
          end
      end
    end
  end

  defp resolve_domain(input) when is_binary(input) do
    if String.contains?(input, "@") do
      case Cache.normalize_email(input) do
        {:ok, _email, domain} -> {:ok, domain}
        error -> error
      end
    else
      Cache.normalize_domain(input)
    end
  end

  defp resolve_domain(_), do: {:error, :invalid_email}

  defp cached(domain, opts) do
    if Keyword.get(opts, :refresh, false) do
      nil
    else
      row = Repo.one(from c in CompanyProfile, where: c.domain == ^domain)
      if Cache.fresh?(row), do: row, else: nil
    end
  end

  defp fetch(domain) do
    result =
      Client.call(@endpoint,
        method: :post,
        body: %{domain: domain},
        max_cost: Budgets.usd(:company_enrich),
        prefer: CostModel.preferred(@capability)
      )

    case result do
      {:ok, payload, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        {:ok, store(domain, payload, meta), CsuiteFinder.Lookup.miss(meta.cost_micro)}

      {:miss, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        {:ok, store_missing(domain, meta), CsuiteFinder.Lookup.miss(meta.cost_micro)}

      {:error, _reason, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        {:ok, store_missing(domain, meta), CsuiteFinder.Lookup.miss(meta.cost_micro)}
    end
  end

  defp store(domain, payload, meta) do
    output = Map.get(payload, "output", %{})

    upsert(%{
      domain: domain,
      name: get(output, ["name", "company_name", "legal_name"]),
      legal_name: get(output, ["legal_name", "legalName"]),
      description: get(output, ["description", "summary", "about"]),
      industry: get(output, ["industry", "sector", "category"]),
      employee_count: int(output["employee_count"] || output["employees"]),
      employee_range: get(output, ["employee_range", "size", "employees_range"]),
      founded_year: int(output["founded_year"] || output["founded"]),
      revenue_range: get(output, ["revenue_range", "revenue"]),
      country: get(output, ["country", "country_name"]),
      city: get(output, ["city", "locality"]),
      website: get(output, ["website", "url", "domain"]),
      linkedin_url: get(output, ["linkedin_url", "linkedin"]),
      logo_url: get(output, ["logo", "logo_url"]),
      tech_stack: list(output["tech_stack"] || output["technologies"]),
      found: map_size(output) > 0,
      source: "provider",
      provider: meta.served_by,
      provider_cost_micro: meta.cost_micro,
      raw: payload,
      expires_at: Cache.expires_at(:company)
    })
  end

  defp store_missing(domain, meta) do
    upsert(%{
      domain: domain,
      name: domain |> String.split(".") |> hd() |> String.capitalize(),
      website: "https://" <> domain,
      found: false,
      source: "inferred",
      provider: meta.served_by,
      provider_cost_micro: meta.cost_micro,
      expires_at: Cache.expires_at(:company)
    })
  end

  defp personal_domain_row(domain) do
    %CompanyProfile{
      domain: domain,
      name: nil,
      found: false,
      source: "free_email_provider",
      tech_stack: []
    }
  end

  defp upsert(attrs) do
    Writer.put(CompanyProfile, [:domain], attrs)
  end

  defp get(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp list(_), do: []

  @doc """
  Present just the company's identity — who this is, not everything about them.

  Same lookup and same cached row as `present/2`; this answers the narrower
  question so a caller who wants to know which company an address belongs to
  does not have to read past a paragraph of marketing copy to find the name.
  """
  @spec present_identity(CompanyProfile.t(), CsuiteFinder.Lookup.meta(), String.t() | nil) ::
          map()
  def present_identity(%CompanyProfile{} = row, lookup, email \\ nil) do
    base = %{
      queried_email: email,
      domain: row.domain,
      found: row.found,
      name: row.name,
      legal_name: row.legal_name,
      website: row.website,
      linkedin_url: row.linkedin_url,
      logo_url: row.logo_url,
      source: row.source,
      provider: row.provider,
      cached: lookup.cached,
      stale: CsuiteFinder.Cache.stale?(row),
      last_verified_at: row.last_found_at,
      cost: CsuiteFinder.Lookup.cost_block(lookup)
    }

    if row.source == "free_email_provider" do
      Map.put(base, :note, "This is a consumer email provider, not a company domain.")
    else
      base
    end
  end

  @doc "Present a company row as an API payload."
  @spec present(CompanyProfile.t(), CsuiteFinder.Lookup.meta()) :: map()
  def present(%CompanyProfile{} = row, lookup) do
    base = %{
      domain: row.domain,
      found: row.found,
      name: row.name,
      legal_name: row.legal_name,
      description: row.description,
      industry: row.industry,
      employee_count: row.employee_count,
      employee_range: row.employee_range,
      founded_year: row.founded_year,
      revenue_range: row.revenue_range,
      country: row.country,
      city: row.city,
      website: row.website,
      linkedin_url: row.linkedin_url,
      logo_url: row.logo_url,
      tech_stack: row.tech_stack || [],
      source: row.source,
      provider: row.provider,
      cached: lookup.cached,
      stale: CsuiteFinder.Cache.stale?(row),
      last_verified_at: row.last_found_at,
      cost: CsuiteFinder.Lookup.cost_block(lookup)
    }

    if row.source == "free_email_provider" do
      Map.put(base, :note, "This is a consumer email provider, not a company domain.")
    else
      base
    end
  end
end
