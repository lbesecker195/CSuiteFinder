defmodule CsuiteFinder.Phones do
  @moduledoc """
  Phone numbers: finding them, validating them, and reading them backwards.

  ## The reverse index

  No provider in the catalog turns a phone number back into a person — I looked.
  But a number we found *for* someone is a number we can attribute later, so
  every phone that passes through this service is stored against whoever it
  belongs to. `owner/1` then answers "whose number is this" from our own rows,
  for nothing, and gets better the more the service is used.

  That is why enrichment and company sweeps write here too: a phone arriving as
  a field on some other lookup is still a phone worth keeping.

  ## Budget

  A find is capped at $0.04. The cheap provider ($0.0048) wants a name and a
  domain; the one that accepts a bare email costs $0.0445 and is over the
  ceiling. So an email-only request resolves the name first — from our own
  enrichment cache when we have it — and asks by name. Same answer, a tenth of
  the price.
  """

  import Ecto.Query

  alias CsuiteFinder.Cache.{Phone, Writer}
  alias CsuiteFinder.{Budgets, Cache, CostModel, Lookup, Names, People, Repo}
  alias CsuiteFinder.Treg.Client

  @find_capability "people.phone.find"
  @find_endpoint "treg.people.phone.find"
  @verify_capability "people.phone.verify"
  @verify_endpoint "tomba.people.phone.verify"

  @doc """
  Normalise a number to digits with an optional leading `+`.

  The same number is written a dozen ways; the cache key cannot be.
  """
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, :invalid_phone}
  def normalize(value) when is_binary(value) do
    trimmed = String.trim(value)
    plus? = String.starts_with?(trimmed, "+")
    digits = String.replace(trimmed, ~r/\D/, "")

    cond do
      String.length(digits) < 7 -> {:error, :invalid_phone}
      String.length(digits) > 15 -> {:error, :invalid_phone}
      plus? -> {:ok, "+" <> digits}
      true -> {:ok, digits}
    end
  end

  def normalize(_), do: {:error, :invalid_phone}

  @doc """
  Find someone's phone number.

  Accepts `full_name` + `domain` (cheapest), an `email`, or a `linkedin_url`.
  """
  @spec find(map(), keyword()) :: {:ok, Phone.t(), Lookup.meta()} | {:error, atom()}
  def find(identity, opts \\ []) do
    with {:ok, identity} <- resolve_identity(identity) do
      case cached_for(identity) do
        %Phone{} = row ->
          if Keyword.get(opts, :refresh, false),
            do: fetch(identity),
            else: {:ok, row, Lookup.hit()}

        nil ->
          fetch(identity)
      end
    end
  end

  @doc """
  Whose number is this, from what we already hold. Never costs anything.
  """
  @spec owner(String.t()) :: {:ok, Phone.t()} | {:error, :invalid_phone | :unknown}
  def owner(value) do
    with {:ok, phone} <- normalize(value) do
      digits = String.replace(phone, ~r/\D/, "")

      # The same number is stored as 7075485509 by one provider and +17075485509
      # by another, so an exact match misses half the time. Comparing the last
      # ten digits — the national number — spans the country-code difference.
      # Only for numbers long enough that the tail is actually distinguishing.
      query =
        if String.length(digits) >= 10 do
          from p in Phone,
            where:
              p.phone == ^phone or p.e164 == ^phone or
                fragment(
                  "right(regexp_replace(?, '[^0-9]', '', 'g'), 10) = right(?, 10)",
                  p.phone,
                  ^digits
                )
        else
          from p in Phone, where: p.phone == ^phone or p.e164 == ^phone
        end

      case Repo.one(from p in query, limit: 1) do
        %Phone{} = row -> {:ok, row}
        nil -> {:error, :unknown}
      end
    end
  end

  @doc """
  The email address behind a number, from what we hold.

  Lets a phone stand in for an email on the person and company routes. There is
  nothing to buy here — no provider reverses a number — so an unknown number is
  simply unknown.
  """
  @spec email_for(String.t()) :: {:ok, String.t()} | {:error, :invalid_phone | :unknown}
  def email_for(value) do
    case owner(value) do
      {:ok, %Phone{email: email}} when is_binary(email) -> {:ok, email}
      {:ok, _} -> {:error, :unknown}
      error -> error
    end
  end

  @doc """
  Validate and format a number: is it real, what kind of line, which carrier.
  """
  @spec validate(String.t(), keyword()) ::
          {:ok, Phone.t(), Lookup.meta()} | {:error, atom()}
  def validate(value, opts \\ []) do
    with {:ok, phone} <- normalize(value) do
      existing = Repo.one(from p in Phone, where: p.phone == ^phone)

      if not Keyword.get(opts, :refresh, false) and validated_recently?(existing) do
        {:ok, existing, Lookup.hit()}
      else
        fetch_validation(phone, opts[:country_code], existing)
      end
    end
  end

  @doc """
  Record a phone seen on some other lookup — an enrichment, a company sweep.

  Never overwrites a richer row with a barer one: a number we validated keeps
  its carrier and line type when it later turns up as a bare field elsewhere.
  """
  @spec observe(String.t() | nil, map()) :: :ok
  def observe(nil, _attrs), do: :ok

  def observe(value, attrs) do
    case normalize(value) do
      {:ok, phone} ->
        Writer.put(
          Phone,
          [:phone],
          Map.merge(attrs, %{phone: phone, found: true, source: attrs[:source] || "observed"})
        )

        :ok

      {:error, _} ->
        :ok
    end
  end

  # ------------------------------------------------------------------ finding

  defp resolve_identity(%{"phone" => _} = _identity), do: {:error, :invalid_identity}

  defp resolve_identity(identity) do
    domain = identity["domain"] || identity[:domain]
    full_name = identity["full_name"] || identity[:full_name]
    email = identity["email"] || identity[:email]
    linkedin = identity["linkedin_url"] || identity[:linkedin_url]

    cond do
      is_binary(full_name) and is_binary(domain) ->
        with {:ok, domain} <- Cache.normalize_domain(domain) do
          {:ok, %{full_name: String.trim(full_name), domain: domain, email: email}}
        end

      is_binary(email) ->
        from_email(email)

      is_binary(linkedin) ->
        {:ok, %{linkedin_url: linkedin}}

      true ->
        {:error, :missing_identity}
    end
  end

  # An email alone routes to a $0.0445 provider, over our ceiling. Resolving the
  # name first — free when the enrichment is already cached — puts the request
  # on the $0.0048 path instead.
  defp from_email(email) do
    with {:ok, email, domain} <- Cache.normalize_email(email) do
      case People.enrich(email) do
        {:ok, %{full_name: full_name}, _} when is_binary(full_name) ->
          {:ok, %{full_name: full_name, domain: domain, email: email}}

        _ ->
          {:error, :name_unknown}
      end
    end
  end

  defp cached_for(%{email: email}) when is_binary(email) do
    Repo.one(from p in Phone, where: p.email == ^email and p.found, limit: 1)
  end

  defp cached_for(%{full_name: full_name, domain: domain}) do
    key = Names.name_key(full_name)

    Repo.one(
      from p in Phone,
        where: p.domain == ^domain and p.found and fragment("lower(?)", p.full_name) == ^key,
        limit: 1
    )
  end

  defp cached_for(_), do: nil

  defp fetch(identity) do
    body =
      identity
      |> Map.take([:full_name, :domain, :linkedin_url])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    started = System.monotonic_time(:millisecond)

    case Client.call(@find_endpoint,
           method: :post,
           body: body,
           max_cost: Budgets.usd(:phone_find),
           prefer: CostModel.preferred(@find_capability)
         ) do
      {:ok, payload, meta} ->
        CostModel.record_waterfall(@find_capability, meta.tried, latency_ms: elapsed(started))
        {:ok, store_find(identity, payload, meta), Lookup.miss(meta.cost_micro)}

      {result, meta} when result in [:miss] ->
        CostModel.record_waterfall(@find_capability, meta.tried, latency_ms: elapsed(started))
        {:ok, not_found(identity, meta), Lookup.miss(meta.cost_micro)}

      {:error, _reason, meta} ->
        CostModel.record_waterfall(@find_capability, meta.tried, latency_ms: elapsed(started))
        {:ok, not_found(identity, meta), Lookup.miss(meta.cost_micro)}
    end
  end

  defp store_find(identity, payload, meta) do
    output = Map.get(payload, "output", %{}) || %{}
    number = output["phone"]

    case number && normalize(number) do
      {:ok, phone} ->
        names = split_name(identity[:full_name])
        existing = Repo.one(from p in Phone, where: p.phone == ^phone)

        fresh =
          %{
            phone: phone,
            email: identity[:email],
            domain: identity[:domain],
            full_name: identity[:full_name],
            first_name: names.first,
            last_name: names.last,
            line_type: output["line_type"],
            found: true,
            source: "provider",
            provider: meta.served_by,
            provider_cost_micro: meta.cost_micro,
            raw: payload,
            expires_at: Cache.expires_at(:enrichment_provider)
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        # The row is written whole, so anything this call does not know must be
        # carried across or it is erased: the carrier a validation established,
        # and the email address an earlier find attributed. Dropping nils above
        # is what lets the merge below win where this call knows nothing.
        attrs =
          attribution(existing)
          |> Map.merge(validation_of(existing))
          |> Map.merge(fresh)

        Writer.put(Phone, [:phone], attrs)

      _ ->
        not_found(identity, meta)
    end
  end

  defp not_found(identity, meta) do
    %Phone{
      phone: nil,
      email: identity[:email],
      domain: identity[:domain],
      full_name: identity[:full_name],
      found: false,
      source: "provider",
      provider: meta.served_by
    }
  end

  # ---------------------------------------------------------------- validating

  defp validated_recently?(%Phone{validated_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at, :second) < 90 * 86_400

  defp validated_recently?(_), do: false

  defp fetch_validation(phone, country_code, existing) do
    query = [phone: phone] |> maybe_put(:country_code, country_code)
    started = System.monotonic_time(:millisecond)

    case Client.call(@verify_endpoint,
           method: :get,
           query: query,
           max_cost: Budgets.usd(:phone_verify)
         ) do
      {:ok, payload, meta} ->
        CostModel.record_attempt(@verify_capability, @verify_endpoint, true,
          cost_micro: meta.cost_micro,
          latency_ms: elapsed(started)
        )

        {:ok, store_validation(phone, existing, payload, meta), Lookup.miss(meta.cost_micro)}

      {_other, meta} ->
        CostModel.record_attempt(@verify_capability, @verify_endpoint, false,
          cost_micro: meta.cost_micro,
          latency_ms: elapsed(started)
        )

        {:ok, existing || %Phone{phone: phone, found: false, source: "provider"},
         Lookup.miss(meta.cost_micro)}

      {:error, _reason, meta} ->
        CostModel.record_attempt(@verify_capability, @verify_endpoint, false,
          cost_micro: meta.cost_micro,
          latency_ms: elapsed(started)
        )

        {:ok, existing || %Phone{phone: phone, found: false, source: "provider"},
         Lookup.miss(meta.cost_micro)}
    end
  end

  defp store_validation(phone, existing, payload, meta) do
    d = Map.get(payload, "data", %{}) || %{}
    region = Map.get(d, "region", %{}) || %{}

    attrs = %{
      phone: phone,
      e164: d["e164_format"],
      valid: d["valid"],
      local_format: d["local_format"],
      intl_format: d["intl_format"],
      rfc3966_format: d["rfc3966_format"],
      country_code: d["country_code"],
      line_type: d["line_type"],
      carrier: d["carrier"],
      region: region["name"],
      region_code: region["code"],
      timezones: List.wrap(d["timezones"]),
      validated_at: DateTime.utc_now(),
      found: true,
      provider: meta.served_by,
      provider_cost_micro: meta.cost_micro,
      raw: payload,
      expires_at: Cache.expires_at(:enrichment_provider)
    }

    # Carry the attribution forward. The row is written whole, so a validation —
    # which knows the carrier but not the person — would otherwise null out
    # whose number it is, and the reverse lookup that attribution exists for
    # would answer "found, owner unknown".
    Writer.put(Phone, [:phone], Map.merge(attribution(existing), attrs))
  end

  defp attribution(%Phone{} = existing) do
    existing
    |> Map.take([:email, :domain, :full_name, :first_name, :last_name, :position, :source])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Map.put_new(:source, "validated")
  end

  defp attribution(_), do: %{source: "validated"}

  # The fields a validation establishes, carried across a later find.
  defp validation_of(%Phone{} = existing) do
    existing
    |> Map.take([
      :e164,
      :valid,
      :local_format,
      :intl_format,
      :rfc3966_format,
      :country_code,
      :carrier,
      :region,
      :region_code,
      :validated_at
    ])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp validation_of(_), do: %{}

  defp split_name(nil), do: %{first: nil, last: nil}

  defp split_name(full_name) do
    case Names.split(full_name) do
      {:ok, parts} -> %{first: titlecase(parts.first), last: titlecase(parts.last)}
      _ -> %{first: nil, last: nil}
    end
  end

  defp titlecase(nil), do: nil
  defp titlecase(v), do: String.capitalize(v)
  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
  defp maybe_put(list, _k, nil), do: list
  defp maybe_put(list, k, v), do: Keyword.put(list, k, v)

  @doc "Present a phone row for the API."
  @spec present(Phone.t(), Lookup.meta()) :: map()
  def present(%Phone{} = p, lookup) do
    %{
      phone: p.e164 || p.phone,
      found: p.found,
      line_type: p.line_type,
      carrier: p.carrier,
      country_code: p.country_code,
      region: p.region,
      valid: p.valid,
      formats:
        if p.e164 || p.local_format do
          %{
            e164: p.e164,
            local: p.local_format,
            international: p.intl_format,
            rfc3966: p.rfc3966_format
          }
        end,
      belongs_to:
        if p.full_name || p.email do
          %{full_name: p.full_name, email: p.email, domain: p.domain, position: p.position}
        end,
      cached: lookup.cached
    }
  end
end
