defmodule CsuiteFinder.Verifier do
  @moduledoc """
  Deliverability checks — the `/email/deliverable` endpoint.

  Capped at $0.002, which reaches the three cheapest verifiers treg routes to.
  A verdict is cached with a TTL that depends on the verdict: a dead mailbox
  stays dead far longer than a catch-all one stays catch-all.
  """

  import Ecto.Query

  alias CsuiteFinder.{Budgets, Cache, CostModel, Repo}
  alias CsuiteFinder.Cache.EmailVerification
  alias CsuiteFinder.Cache.Writer
  alias CsuiteFinder.Treg.Client

  @capability "people.email.verify"
  @endpoint "treg.people.email.verify"

  @doc "Check whether an address is deliverable."
  @spec verify(String.t(), keyword()) ::
          {:ok, EmailVerification.t(), CsuiteFinder.Lookup.meta()} | {:error, atom()}
  def verify(email, opts \\ []) do
    with {:ok, email, domain} <- Cache.normalize_email(email) do
      case cached(email, opts) do
        %EmailVerification{} = row -> {:ok, row, CsuiteFinder.Lookup.hit()}
        nil -> fetch(email, domain)
      end
    end
  end

  defp cached(email, opts) do
    if Keyword.get(opts, :refresh, false) do
      nil
    else
      row = Repo.one(from v in EmailVerification, where: v.email == ^email)
      if Cache.fresh?(row), do: row, else: nil
    end
  end

  defp fetch(email, domain) do
    result =
      Client.call(@endpoint,
        method: :post,
        body: %{email: email},
        max_cost: Budgets.usd(:email_verify),
        prefer: CostModel.preferred(@capability)
      )

    case result do
      {:ok, payload, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        row = store(email, domain, payload, meta)

        # The caller paid for this answer; it costs nothing to learn from it.
        # See CsuiteFinder.Finder.record_verification/3.
        CsuiteFinder.Finder.record_verification(email, row.status, row.catch_all)

        {:ok, row, CsuiteFinder.Lookup.miss(meta.cost_micro)}

      {:miss, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        {:ok, store_unknown(email, domain, meta), CsuiteFinder.Lookup.miss(meta.cost_micro)}

      {:error, _reason, meta} ->
        CostModel.record_waterfall(@capability, meta.tried, latency_ms: meta.latency_ms)
        {:ok, store_unknown(email, domain, meta), CsuiteFinder.Lookup.miss(meta.cost_micro)}
    end
  end

  defp store(email, domain, payload, meta) do
    output = Map.get(payload, "output", %{})
    raw = Map.get(payload, "raw", %{})
    status = classify(output, raw)

    upsert(%{
      email: email,
      domain: domain,
      status: status,
      sub_status: str(output["status"] || raw["validity"] || raw["result"]),
      score: num(output["score"] || raw["score"]),
      catch_all: bool(output["catch_all"] || raw["catchAll"] || raw["catch_all"]),
      disposable: bool(output["disposable"] || raw["disposable"]),
      role_account: bool(output["role"] || raw["roleAccount"] || raw["role_account"]),
      free_provider: bool(output["free"] || raw["free"]),
      mx_found: mx_found(output, raw),
      smtp_check: bool(output["smtp"] || raw["validSMTP"]),
      provider: meta.served_by,
      provider_cost_micro: meta.cost_micro,
      raw: payload,
      expires_at: Cache.expires_at(ttl_class(status))
    })
  end

  defp store_unknown(email, domain, meta) do
    upsert(%{
      email: email,
      domain: domain,
      status: "unknown",
      provider: meta.served_by,
      provider_cost_micro: meta.cost_micro,
      expires_at: Cache.expires_at(:verify_accept_all)
    })
  end

  # Providers disagree on vocabulary, so everything is folded onto four verdicts
  # a caller can act on: send, do not send, be careful, we could not tell.
  defp classify(output, raw) do
    signal =
      [output["status"], output["result"], raw["validity"], raw["result"], raw["status"]]
      |> Enum.find(&is_binary/1)
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    valid = output["valid"]

    cond do
      signal in ["valid", "deliverable", "ok", "safe"] -> "deliverable"
      signal in ["invalid", "undeliverable", "bad", "not_valid"] -> "undeliverable"
      signal in ["catch_all", "catch-all", "accept_all", "accept-all"] -> "accept_all"
      # Some providers call this "risky". We do not pass that word on. A
      # catch-all domain is most large companies, so about half of corporate
      # addresses land here — and a verdict that reads as a warning on half the
      # list tells the customer their emails are dangerous when what actually
      # happened is that the domain would not answer a question about one
      # mailbox. The fact is the same; the word was doing harm.
      is_binary(signal) and String.contains?(signal, "risky") -> "accept_all"
      is_binary(signal) and String.contains?(signal, "unknown") -> "unknown"
      valid == true -> "deliverable"
      valid == false and is_nil(signal) -> "undeliverable"
      true -> "unknown"
    end
  end

  @doc """
  The verdict in plain words, for whatever renders it.

  `accept_all` is the one that matters here. It is not a warning about the
  address — it is the domain declining to answer a question about a single
  mailbox, which is how most large companies are configured. Saying that
  plainly is the difference between a customer reading half their list as
  dangerous and reading it as normal.
  """
  @spec explain(String.t() | nil) :: String.t()
  def explain("deliverable"),
    do: "Confirmed against the live mailbox. Safe to send."

  def explain("undeliverable"),
    do: "The mailbox does not exist. Do not send — this one would bounce."

  def explain("accept_all"),
    do:
      "This company accepts mail for every address at its domain, so no single " <>
        "mailbox can be confirmed from outside. Normal for large companies, and " <>
        "not a sign the address is wrong."

  def explain("unknown"),
    do:
      "The mailbox could not be checked just now — the domain did not answer. " <>
        "Not a failed check, and nothing was charged for it."

  def explain(_), do: "Not checked yet."

  defp ttl_class("deliverable"), do: :verify_deliverable
  defp ttl_class("undeliverable"), do: :verify_undeliverable
  defp ttl_class(_), do: :verify_accept_all

  defp mx_found(output, raw) do
    cond do
      is_boolean(output["mx"]) -> output["mx"]
      is_binary(raw["mxDomain"]) -> true
      is_boolean(raw["mxFound"]) -> raw["mxFound"]
      true -> nil
    end
  end

  defp str(value) when is_binary(value), do: value
  defp str(_), do: nil
  defp num(value) when is_number(value), do: value / 1
  defp num(_), do: nil
  defp bool(value) when is_boolean(value), do: value
  defp bool(_), do: nil

  # Verifications carry a verdict rather than a `found` flag: anything but
  # "unknown" is a real answer worth keeping.
  defp upsert(attrs) do
    Writer.put(EmailVerification, [:email], attrs, known?: attrs[:status] not in [nil, "unknown"])
  end

  @doc "Present a verification row as an API payload."
  @spec present(EmailVerification.t(), CsuiteFinder.Lookup.meta()) :: map()
  def present(%EmailVerification{} = row, lookup) do
    %{
      email: row.email,
      deliverable: row.status == "deliverable",
      status: row.status,
      # Said in words, because a bare status gets rendered by somebody else's
      # UI and "accept_all" is one search-and-replace away from "Risky" on a
      # customer's screen.
      explanation: explain(row.status),
      sub_status: row.sub_status,
      score: row.score,
      catch_all: row.catch_all,
      disposable: row.disposable,
      role_account: row.role_account,
      free_provider: row.free_provider,
      mx_found: row.mx_found,
      smtp_check: row.smtp_check,
      provider: row.provider,
      cached: lookup.cached,
      stale: CsuiteFinder.Cache.stale?(row),
      last_verified_at: row.last_found_at,
      checked_at: row.updated_at,
      cost: CsuiteFinder.Lookup.cost_block(lookup)
    }
  end
end
