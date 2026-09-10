defmodule CsuiteFinderWeb.PeopleController do
  @moduledoc """
  `/people/search` — who holds this job, anywhere.

  The counterpart to `/company/people`: that one sweeps a company you already
  know, this one searches across companies for a role. Billed per person
  returned, so `limit` is the spend dial and is clamped to what the caller can
  pay for before any upstream is touched.
  """

  use CsuiteFinderWeb, :controller

  alias CsuiteFinder.Billing.Pricing
  alias CsuiteFinder.{Billing, PeopleSearch}
  alias CsuiteFinderWeb.Plugs.Timing

  action_fallback CsuiteFinderWeb.FallbackController

  @doc "POST/GET /csuitefinder/people/search"
  def search(conn, params) do
    limit = affordable_limit(conn, params["limit"])

    with {:ok, people, lookup} <-
           PeopleSearch.search(%{
             title: params["title"],
             company_domain: params["company_domain"] || params["domain"],
             country: params["country"],
             q: params["q"] || params["description"],
             full_name: params["full_name"],
             limit: limit
           }) do
      rendered =
        Enum.map(people, fn person ->
          CsuiteFinderWeb.PublicView.render(:person_search_row, atomize(person))
        end)

      Billing.settle(%{
        account: conn.assigns[:account],
        api_key: conn.assigns[:api_key],
        endpoint: conn.assigns[:endpoint_name],
        found: rendered != [],
        units: length(rendered),
        cached: lookup.cached,
        provider_cost_micro: lookup.spent_micro,
        duration_ms: Timing.elapsed_ms(conn),
        request: %{title: params["title"], domain: params["domain"], limit: limit}
      })

      json(conn, %{
        count: length(rendered),
        filters: %{
          title: params["title"],
          company_domain: params["company_domain"] || params["domain"],
          country: params["country"]
        },
        people: rendered,
        # Said in the response, not only the docs: the docs are not what is open
        # when someone pipes this into a mail merge.
        advice: PeopleSearch.advice(),
        next: %{
          verify: "/csuitefinder/email/deliverable?email=<email>",
          find: "/csuitefinder/email/find?full_name=<name>&domain=<domain>"
        }
      })
    end
  end

  # The cache stores rows as jsonb, so they come back string-keyed while the
  # public projection works in atoms. Converting by walking the whitelist rather
  # than the row means no atom is ever created from provider data, and a field a
  # provider invents cannot reach the response even by accident.
  defp atomize(person) do
    CsuiteFinderWeb.PublicView.fields(:person_search_row)
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(person, Atom.to_string(key)) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp affordable_limit(conn, requested) do
    asked =
      case Integer.parse(to_string(requested || "")) do
        {n, _} when n > 0 -> min(n, PeopleSearch.max_limit())
        _ -> 10
      end

    case conn.assigns[:account] do
      nil ->
        asked

      account ->
        per_row = max(Pricing.charge_for(conn.assigns[:endpoint_name]), 1)
        max(min(asked, div(Billing.available_micro(account), per_row)), 1)
    end
  end
end
