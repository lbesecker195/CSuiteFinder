defmodule CsuiteFinder.Prospects do
  @moduledoc """
  Finding the people at a company — the `/company/people` endpoint.

  This is the discovery half of the product: give it a domain and it returns
  named people with addresses, titles and departments, optionally filtered to a
  department (`executive` is the C-suite).

  ## Why rows, not result sets

  The cache stores one row per *person*, not one row per query. A search for
  engineering at a domain and a later search for its executives share those
  rows, so a narrow query is usually answered out of what a broad one already
  paid for. The upstream is billed per page of ten regardless of how many of
  those ten you wanted, which makes fetching wide and slicing narrow the
  cheaper shape by a distance.
  """

  import Ecto.Query

  alias CsuiteFinder.Cache.{CompanyPerson, CompanyProfile}
  alias CsuiteFinder.{Budgets, Cache, CostModel, Lookup, Repo}
  alias CsuiteFinder.Treg.Client

  @capability "companies.people.list"
  @endpoint "tomba.companies.emails.list"

  # A page of people stays usable for a month: staff move, but not so fast that
  # re-buying the same roster weekly is worth it.
  @ttl_seconds 30 * 86_400

  # The provider bills per page of ten, so asking for fewer than ten costs the
  # same as asking for ten. We always fetch a full page and keep the remainder.
  @page_size 10
  @max_limit 50

  @departments ~w(executive engineering sales finance hr it marketing legal
                  support operations communication)

  @doc """
  People at `domain`.

  Options:
    * `:department` — one of #{Enum.join(@departments, ", ")}
    * `:limit` — how many to return (1..#{@max_limit}, default #{@page_size})
    * `:kind` — "personal" for named humans, "generic" for role mailboxes
    * `:refresh` — force a fresh sweep
  """
  @spec at_domain(String.t(), keyword()) ::
          {:ok, [CompanyPerson.t()], Lookup.meta()} | {:error, atom()}
  def at_domain(domain, opts \\ []) do
    with {:ok, domain} <- Cache.normalize_domain(domain),
         {:ok, department} <- validate_department(opts[:department]) do
      limit = clamp_limit(opts[:limit])
      refresh? = Keyword.get(opts, :refresh, false)

      if not refresh? and covered?(domain, limit) do
        {:ok, query(domain, department, opts[:kind], limit), Lookup.hit()}
      else
        fetch(domain, department, opts[:kind], limit)
      end
    end
  end

  @doc "The departments the provider recognises."
  @spec departments() :: [String.t()]
  def departments, do: @departments

  @doc "Largest page we will sell in one call."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  defp validate_department(nil), do: {:ok, nil}

  defp validate_department(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in @departments, do: {:ok, normalized}, else: {:error, :invalid_department}
  end

  defp validate_department(_), do: {:error, :invalid_department}

  defp clamp_limit(nil), do: @page_size

  defp clamp_limit(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> min(n, @max_limit)
      _ -> @page_size
    end
  end

  defp query(domain, department, kind, limit) do
    CompanyPerson
    |> where([p], p.domain == ^domain)
    |> filter_department(department)
    |> filter_kind(kind)
    |> order_by([p], desc: p.confidence, asc: p.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_department(q, nil), do: q
  defp filter_department(q, department), do: where(q, [p], p.department == ^department)
  defp filter_kind(q, nil), do: q
  defp filter_kind(q, kind), do: where(q, [p], p.kind == ^kind)

  # Whether a request can be answered from what we hold.
  #
  # The breadth test is on rows held for the DOMAIN, not on rows matching the
  # filter. A department filter legitimately matches only a handful, and asking
  # "do we have `limit` engineers?" would re-sweep on every narrow query
  # forever, paying again for a page we already own. What matters is whether the
  # sweep behind those rows was wide enough and recent enough.
  defp covered?(domain, limit) do
    case Repo.one(
           from c in CompanyProfile,
             where: c.domain == ^domain,
             select: {c.people_fetched_at, c.people_total}
         ) do
      {%DateTime{} = at, total} ->
        fresh? = DateTime.diff(DateTime.utc_now(), at, :second) < @ttl_seconds
        held = Repo.one(from p in CompanyPerson, where: p.domain == ^domain, select: count(p.id))

        # Enough for what was asked, or everything the provider says exists.
        fresh? and (held >= limit or (is_integer(total) and held >= total))

      _ ->
        false
    end
  end

  defp fetch(domain, department, kind, limit) do
    # Always buy whole pages: a page of ten costs the same as a page of one, so
    # asking for less than we are charged for would be throwing rows away.
    pages = ceil(limit / @page_size)
    fetch_limit = min(pages * @page_size, @max_limit)

    query_params =
      [domain: domain, limit: fetch_limit]
      |> maybe_put(:department, department)
      |> maybe_put(:type, kind)

    started = System.monotonic_time(:millisecond)

    case Client.call(@endpoint,
           method: :get,
           query: query_params,
           max_cost: Budgets.usd(:company_people)
         ) do
      {:ok, body, meta} ->
        record(true, meta, started)
        store(domain, body, meta, fetch_limit)
        {:ok, query(domain, department, kind, limit), Lookup.miss(meta.cost_micro)}

      {:miss, meta} ->
        record(false, meta, started)
        stamp_sweep(domain, 0)
        {:ok, [], Lookup.miss(meta.cost_micro)}

      {:error, _reason, meta} ->
        record(false, meta, started)
        # Serve whatever we already hold rather than nothing; an upstream having
        # a bad minute should not erase rows we already bought.
        {:ok, query(domain, department, kind, limit), Lookup.miss(meta.cost_micro)}
    end
  end

  defp record(hit?, meta, started) do
    CostModel.record_attempt(@capability, @endpoint, hit?,
      cost_micro: meta.cost_micro,
      latency_ms: System.monotonic_time(:millisecond) - started
    )
  end

  defp store(domain, body, meta, requested) do
    data = Map.get(body, "data", %{})
    emails = Map.get(data, "emails", [])
    reported_total = get_in(body, ["meta", "total"])

    Enum.each(emails, fn person ->
      attrs = normalize(domain, person, meta)

      CsuiteFinder.Phones.observe(attrs.phone, %{
        email: attrs.email,
        domain: domain,
        full_name: attrs.full_name,
        position: attrs.position,
        source: "company_sweep",
        provider: meta.served_by
      })

      if attrs.email do
        %CompanyPerson{}
        |> CompanyPerson.changeset(attrs)
        |> Repo.insert!(
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:domain, :email]
        )
      end
    end)

    # A sweep that came back short has given us everything it is going to for
    # this domain, whatever the provider's headline total claims. Recording what
    # we can actually get — rather than what it says exists — is what stops the
    # next request re-buying the same short page forever.
    held = Repo.one(from p in CompanyPerson, where: p.domain == ^domain, select: count(p.id))
    total = if length(emails) < requested, do: held, else: reported_total

    stamp_sweep(domain, total)
  end

  defp normalize(domain, person, meta) do
    first = text(person["first_name"])
    last = text(person["last_name"])

    %{
      domain: domain,
      email: text(person["email"]),
      first_name: first,
      last_name: last,
      full_name: [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> presence(),
      position: text(person["position"]),
      department: text(person["department"]),
      seniority: text(person["seniority"]),
      linkedin_url: text(person["linkedin"]),
      twitter: text(person["twitter"]),
      phone: text(person["phone_number"]),
      kind: text(person["type"]),
      confidence: number(person["score"]),
      provider: meta.served_by || "tomba",
      raw: person
    }
  end

  # Providers are not consistent about scalars: this one returns phone_number as
  # an object on some rows and a string on others. Coerce what can be text and
  # drop what cannot, rather than letting one odd row fail the whole insert and
  # lose the page we just paid for.
  defp text(value) when is_binary(value), do: presence(String.trim(value))
  defp text(value) when is_number(value), do: to_string(value)
  defp text(_), do: nil

  defp stamp_sweep(domain, total) do
    now = DateTime.utc_now()

    from(c in CompanyProfile, where: c.domain == ^domain)
    |> Repo.update_all(set: [people_fetched_at: now, people_total: total, updated_at: now])
    |> case do
      {0, _} ->
        # No company row yet — create a stub so the sweep timestamp has a home.
        %CompanyProfile{}
        |> CompanyProfile.changeset(%{
          domain: domain,
          found: false,
          source: "people_sweep",
          people_fetched_at: now,
          people_total: total,
          expires_at: Cache.expires_at(:company)
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: :domain)

      other ->
        other
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value
  defp number(n) when is_number(n), do: n / 1
  defp number(_), do: nil
  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)

  @doc """
  Attach a phone number to each person, looked up individually.

  The sweep does not return numbers — its `phone_number` field is a boolean
  saying one exists, and `phone_data` comes back empty — so a real number costs
  a lookup per person. Run concurrently because they are independent and each
  costs a second or two; treg imposes no concurrency limit of its own.
  """
  @spec with_phones([CompanyPerson.t()], String.t()) :: {[map()], non_neg_integer()}
  def with_phones(people, domain) do
    results =
      people
      |> Task.async_stream(
        fn person ->
          case CsuiteFinder.Phones.find(%{
                 full_name: person.full_name,
                 domain: domain,
                 email: person.email
               }) do
            {:ok, %{found: true} = phone, lookup} -> {person, phone, lookup.spent_micro}
            _ -> {person, nil, 0}
          end
        end,
        max_concurrency: 8,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, triple} -> triple
        {:exit, _} -> nil
      end)
      |> Enum.reject(&is_nil/1)

    spent = results |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    rows =
      Enum.map(results, fn {person, phone, _} ->
        person
        |> present()
        |> Map.put(:phone, phone && (phone.e164 || phone.phone))
        |> Map.put(:phone_line_type, phone && phone.line_type)
      end)

    {rows, spent}
  end

  @doc "Present a person for the API."
  @spec present(CompanyPerson.t()) :: map()
  def present(%CompanyPerson{} = p) do
    %{
      email: p.email,
      full_name: p.full_name,
      first_name: p.first_name,
      last_name: p.last_name,
      position: p.position,
      department: p.department,
      seniority: p.seniority,
      linkedin_url: p.linkedin_url,
      twitter: p.twitter,
      kind: p.kind,
      confidence: p.confidence
    }
  end
end
