defmodule CsuiteFinder.Billing do
  @moduledoc """
  Metering: check funds before we spend, record what happened after.

  The balance is checked *before* the upstream call, because a provider charge
  we cannot bill on to anyone is a straight loss. It is debited after, and only
  for answers we actually produced.
  """

  import Ecto.Query

  alias CsuiteFinder.Accounts.{Account, ApiKey}
  alias CsuiteFinder.Billing.{Pricing, UsageEvent}
  alias CsuiteFinder.Repo

  @doc """
  May this account call the endpoint?

  Two rules, because most endpoints are included rather than free:

    * A **metered** endpoint (`/email/find`) needs enough tokens to pay for it.
    * An **included** endpoint costs nothing but still needs a positive balance.
      Otherwise an account that had spent down to zero — or never bought
      anything — would keep unlimited access to five of the six endpoints, and
      the enrichment calls behind them cost us real money per request. A balance
      is what makes someone a customer; the token price is a separate question.

  Returns `:ok`, or `{:error, :insufficient_tokens, details}` where `details`
  says which of the two rules was not met.
  """
  @spec ensure_funds(Account.t() | nil, String.t()) ::
          :ok | {:error, :insufficient_tokens, map()}
  def ensure_funds(nil, _endpoint), do: :ok

  def ensure_funds(%Account{} = account, endpoint) do
    price = Pricing.charge_for(endpoint)

    cond do
      account.token_balance <= 0 ->
        {:error, :insufficient_tokens, refusal(account, price, :no_balance)}

      account.token_balance < price ->
        {:error, :insufficient_tokens, refusal(account, price, :cannot_afford)}

      true ->
        :ok
    end
  end

  defp refusal(account, price, reason) do
    %{
      token_balance: account.token_balance,
      tokens_required: max(price, 1),
      metered: price > 0,
      reason: to_string(reason),
      minimum_bundle_usd: Pricing.min_bundle_usd()
    }
  end

  @doc """
  Record a completed lookup and debit the account for it.

  The debit is a conditional UPDATE rather than a read-modify-write, so two
  concurrent requests on the same key cannot both pass a balance check and
  overdraw the account.
  """
  @spec settle(map()) :: {:ok, UsageEvent.t()}
  def settle(%{endpoint: endpoint, found: found?} = params) do
    account = Map.get(params, :account)
    api_key = Map.get(params, :api_key)
    # `units` is how many billable things the answer contained — rows, for a
    # per-result endpoint. Everything else bills one unit per call.
    units = Map.get(params, :units, 1)

    charge =
      if Pricing.billable?(endpoint, found?),
        do: Pricing.charge_for(endpoint) * units,
        else: 0

    charged =
      case account do
        %Account{} = acct when charge > 0 -> debit(acct, charge)
        _ -> 0
      end

    event =
      %UsageEvent{}
      |> UsageEvent.changeset(%{
        account_id: account && account.id,
        api_key_id: match?(%ApiKey{}, api_key) && api_key.id,
        endpoint: endpoint,
        cache_hit: Map.get(params, :cached, false),
        outcome: if(found?, do: "found", else: "not_found"),
        provider_cost_micro: Map.get(params, :provider_cost_micro, 0),
        charged_tokens: charged,
        duration_ms: Map.get(params, :duration_ms),
        request: Map.get(params, :request, %{})
      })
      |> Repo.insert!()

    {:ok, event}
  end

  defp debit(%Account{id: id}, tokens) do
    {count, _} =
      from(a in Account, where: a.id == ^id and a.token_balance >= ^tokens)
      |> Repo.update_all(inc: [token_balance: -tokens])

    if count == 1, do: tokens, else: 0
  end

  @doc "Credit an account with tokens (a captured PayPal bundle, or the trial)."
  @spec credit(Account.t(), integer()) :: {:ok, Account.t()}
  def credit(%Account{id: id}, tokens) when tokens > 0 do
    {1, [account]} =
      from(a in Account, where: a.id == ^id, select: a)
      |> Repo.update_all(inc: [token_balance: tokens])

    {:ok, account}
  end

  @doc "Usage summary for an account over the last `days` days."
  @spec usage_summary(Account.t(), pos_integer()) :: map()
  def usage_summary(%Account{id: id}, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    rows =
      from(e in UsageEvent,
        where: e.account_id == ^id and e.inserted_at >= ^since,
        group_by: e.endpoint,
        select: %{
          endpoint: e.endpoint,
          calls: count(e.id),
          cache_hits: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", e.cache_hit)),
          found: sum(fragment("CASE WHEN ? = 'found' THEN 1 ELSE 0 END", e.outcome)),
          provider_cost_micro: sum(e.provider_cost_micro),
          charged_tokens: sum(e.charged_tokens)
        }
      )
      |> Repo.all()

    tokens_spent = rows |> Enum.map(&(&1.charged_tokens || 0)) |> Enum.sum()

    %{
      since: since,
      by_endpoint: rows,
      totals: %{
        calls: Enum.sum(Enum.map(rows, & &1.calls)),
        provider_cost_usd:
          rows |> Enum.map(&(&1.provider_cost_micro || 0)) |> Enum.sum() |> to_usd(),
        tokens_spent: tokens_spent,
        tokens_spent_usd: Pricing.usd_for_tokens(tokens_spent)
      }
    }
  end

  defp to_usd(micro), do: Float.round(micro / 1_000_000, 6)
end
