defmodule CsuiteFinder.PeopleSearch do
  @moduledoc """
  Finding people by role rather than by name — the `/people/search` endpoint.

  Everything else in this API resolves someone you can already name, or sweeps
  one company you already know. This is the other question: *who holds this job,
  anywhere?* — every VP of Engineering at a fintech, every Head of Procurement
  in Germany. It is the query a prospecting tool exists to answer, and until now
  we could not answer it.

  ## Why it is cheap

  The providers behind this capability are ordered cheapest first and the first
  two are **free**; between them they cover the inputs people actually have
  (a title, a company domain, or both). A search that offers those fields is
  usually answered without spending anything, which is why this can be priced
  like an address rather than like a seat.

  ## An address here is a listing, not a verified contact

  Rows sometimes carry an email. It is a directory entry, not a checked mailbox,
  and it is returned marked as such — `verified: false` on every row, always.
  Sending to one unverified is how a sending reputation gets burned, so the
  response says plainly which endpoint checks it. That warning is not decoration:
  it is the difference between this being useful and it being a bounce generator.
  """

  import Ecto.Query

  alias CsuiteFinder.Cache.PeopleSearch, as: SearchRow
  alias CsuiteFinder.{Budgets, CostModel, Lookup, Repo}
  alias CsuiteFinder.Treg.Client

  @capability "people.search"
  @endpoint "treg.people.search"

  # People move, but not weekly, and a stale row is a name and a title rather
  # than a promise. A fortnight keeps lists usable without re-buying them.
  @ttl_seconds 14 * 86_400

  @default_limit 10
  @max_limit 50

  @filters ~w(title company_domain country q full_name)a

  @doc """
  Search for people.

  Filters: `:title`, `:company_domain`, `:country`, `:q`, `:full_name`, plus
  `:limit` (1..#{@max_limit}). At least one is required.
  """
  @spec search(keyword() | map()) ::
          {:ok, [map()], Lookup.meta()} | {:error, :missing_params, [String.t()]}
  def search(opts) do
    opts = Map.new(opts)
    filters = normalize_filters(opts)
    limit = clamp_limit(opts[:limit])

    if filters == %{} do
      {:error, :missing_params, Enum.map(@filters, &"#{&1} (any one)")}
    else
      fingerprint = fingerprint(filters, limit)

      case cached(fingerprint) do
        %SearchRow{results: results} -> {:ok, results, Lookup.hit()}
        nil -> fetch(fingerprint, filters, limit)
      end
    end
  end

  @doc "The filters this endpoint accepts, for documentation."
  @spec filters() :: [atom()]
  def filters, do: @filters

  @doc "The largest page we will sell in one call."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  What a caller must do before writing to any address in these rows.

  Stated in the response rather than the docs, because the docs are not what is
  open when someone pipes this into a mail merge.
  """
  @spec advice() :: String.t()
  def advice do
    "Addresses here are directory listings, not checked mailboxes. " <>
      "Run /csuitefinder/email/deliverable on any address before you send to it."
  end

  # -------------------------------------------------------------- normalising

  defp normalize_filters(opts) do
    Enum.reduce(@filters, %{}, fn key, acc ->
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

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_limit)

  defp clamp_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> clamp_limit(n)
      :error -> @default_limit
    end
  end

  defp clamp_limit(_), do: @default_limit

  defp fingerprint(filters, limit) do
    payload =
      filters
      |> Enum.map(fn {k, v} -> {to_string(k), String.downcase(v)} end)
      |> Enum.sort()
      |> Kernel.++([{"limit", to_string(limit)}])
      |> Enum.map_join("|", fn {k, v} -> "#{k}=#{v}" end)

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # ------------------------------------------------------------------- lookup

  defp cached(fingerprint) do
    SearchRow
    |> where([s], s.fingerprint == ^fingerprint)
    |> Repo.one()
    |> case do
      %SearchRow{expires_at: at} = row when not is_nil(at) ->
        if DateTime.compare(at, DateTime.utc_now()) == :gt, do: row, else: nil

      _ ->
        nil
    end
  end

  defp fetch(fingerprint, filters, limit) do
    body = filters |> Map.put(:limit, limit) |> with_query()

    result =
      Client.call(@endpoint,
        method: :post,
        body: body,
        max_cost: Budgets.usd(:people_search),
        prefer: CostModel.preferred(@capability)
      )

    case result do
      {:ok, payload, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)

        people =
          payload
          |> extract_rows()
          |> Enum.map(&normalize_row/1)
          |> Enum.reject(&is_nil/1)
          |> dedupe()
          |> Enum.take(limit)

        store(fingerprint, filters, limit, people, meta)
        {:ok, people, Lookup.miss(meta.cost_micro)}

      {:miss, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        store(fingerprint, filters, limit, [], meta)
        {:ok, [], Lookup.miss(meta.cost_micro)}

      {:error, _reason, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        # An outage is not evidence that nobody matches, so it is not cached.
        {:ok, [], Lookup.miss(meta.cost_micro)}
    end
  end

  # The free providers here match on a description. A caller sending only a
  # title would sail past them into a paid one, so the filters are restated as
  # one — the same trick, and the same reason, as in CompanySearch.
  defp with_query(body) do
    case Map.get(body, :q) do
      existing when is_binary(existing) and existing != "" ->
        body

      _ ->
        described =
          [
            body[:title],
            body[:company_domain] && "at #{body[:company_domain]}",
            body[:country] && "in #{body[:country]}",
            body[:full_name]
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        if described == "", do: body, else: Map.put(body, :q, described)
    end
  end

  # Eighteen providers, eighteen spellings.
  defp extract_rows(payload) do
    cond do
      is_list(payload) ->
        payload

      is_map(payload) ->
        Enum.find_value(["people", "results", "data", "contacts", "items"], [], fn key ->
          case Map.get(payload, key) do
            rows when is_list(rows) -> rows
            _ -> nil
          end
        end)

      true ->
        []
    end
  end

  defp normalize_row(row) when is_map(row) do
    name = pick(row, ~w(full_name name fullName)) || join_name(row)

    if is_nil(name) do
      nil
    else
      %{
        "full_name" => name,
        "first_name" => pick(row, ~w(first_name firstName given_name)),
        "last_name" => pick(row, ~w(last_name lastName family_name surname)),
        "title" => pick(row, ~w(title position job_title headline role)),
        "company" => pick(row, ~w(company company_name organization employer)),
        "company_domain" =>
          domain_of(pick(row, ~w(company_domain domain website organization_domain))),
        "linkedin_url" => pick(row, ~w(linkedin_url linkedinUrl linkedin profile_url)),
        "location" => pick(row, ~w(location city country region)),
        "email" => pick(row, ~w(email work_email emailAddress)),
        # Never true. A directory row is a listing; only /email/deliverable
        # turns it into something you can send to, and a field that sometimes
        # said true would be read as "sometimes safe".
        "verified" => false
      }
    end
  end

  defp normalize_row(_), do: nil

  defp join_name(row) do
    first = pick(row, ~w(first_name firstName given_name))
    last = pick(row, ~w(last_name lastName family_name surname))

    case {first, last} do
      {nil, nil} -> nil
      {f, nil} -> f
      {nil, l} -> l
      {f, l} -> f <> " " <> l
    end
  end

  # Two providers describing the same person is one row. An email is the
  # strongest key; a profile URL next; otherwise the name and the employer,
  # which is where two real people can genuinely collide — so that case keeps
  # both rather than silently dropping one.
  defp dedupe(people) do
    {kept, _seen} =
      Enum.reduce(people, {[], MapSet.new()}, fn person, {kept, seen} ->
        key = person["email"] || person["linkedin_url"]

        cond do
          is_nil(key) -> {[person | kept], seen}
          MapSet.member?(seen, key) -> {kept, seen}
          true -> {[person | kept], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(kept)
  end

  defp pick(row, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(row, key) do
        value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
        _ -> nil
      end
    end)
  end

  defp domain_of(nil), do: nil

  defp domain_of(value) do
    value
    |> String.trim()
    |> String.replace(~r"^https?://", "")
    |> String.replace(~r"^www\.", "")
    |> String.split(~r"[/?#]", parts: 2)
    |> hd()
    |> String.downcase()
    |> case do
      "" -> nil
      domain -> if String.contains?(domain, "."), do: domain, else: nil
    end
  end

  defp store(fingerprint, filters, limit, people, meta) do
    %SearchRow{}
    |> SearchRow.changeset(%{
      fingerprint: fingerprint,
      filters:
        filters
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("limit", limit),
      results: people,
      total: length(people),
      found: people != [],
      provider: meta.served_by,
      provider_cost_micro: meta.cost_micro,
      expires_at: DateTime.add(DateTime.utc_now(), @ttl_seconds, :second),
      last_found_at: if(people != [], do: DateTime.utc_now())
    })
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :fingerprint
    )
  end
end
