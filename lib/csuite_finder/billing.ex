defmodule CsuiteFinder.Billing do
  @moduledoc """
  Metering: check funds before we spend, record what happened after.

  The balance is checked *before* the upstream call, because a provider charge
  we cannot bill on to anyone is a straight loss. It is debited after, and only
  for answers we actually produced.

  ## Two pools

  An account holds credit it **bought** (`balance_micro`, permanent) and credit
  it was **given** (`granted_micro`, expiring — a seat's monthly allowance or
  the free trial). Spending draws down the granted pool first. That order is not
  arbitrary: granted credit is the credit with a deadline, so spending it first
  is the only order that never destroys value the customer paid for.

  An expired grant is not deleted, only ignored — every read of it goes through
  the same `NOW()` comparison, so a row left behind by a lapsed subscription
  cannot be spent by anything.
  """

  import Ecto.Query

  alias CsuiteFinder.Accounts.{Account, ApiKey}
  alias CsuiteFinder.Billing.{Pricing, UsageEvent}
  alias CsuiteFinder.Repo

  # A grant with no expiry is open-ended; one with an expiry counts only until
  # it passes. Written once and reused so no code path can disagree about what
  # an account can actually spend.
  @live_grant "CASE WHEN granted_expires_at IS NULL OR granted_expires_at > NOW() THEN granted_micro ELSE 0 END"

  @doc """
  Granted credit this account can still spend, in micro-USD.

  Zero once the grant has lapsed, whatever the column says.
  """
  @spec live_grant_micro(Account.t()) :: non_neg_integer()
  def live_grant_micro(%Account{granted_micro: micro, granted_expires_at: expires_at}) do
    cond do
      micro <= 0 -> 0
      is_nil(expires_at) -> micro
      DateTime.compare(expires_at, DateTime.utc_now()) == :gt -> micro
      true -> 0
    end
  end

  @doc "Everything this account can spend right now: bought plus unexpired grant."
  @spec available_micro(Account.t()) :: non_neg_integer()
  def available_micro(%Account{balance_micro: balance} = account) do
    balance + live_grant_micro(account)
  end

  @doc """
  The account's money, split the way a customer would want it explained.
  """
  @spec balances(Account.t()) :: map()
  def balances(%Account{} = account) do
    granted = live_grant_micro(account)

    %{
      available_usd: Pricing.usd(account.balance_micro + granted),
      purchased_usd: Pricing.usd(account.balance_micro),
      granted_usd: Pricing.usd(granted),
      granted_expires_at: (granted > 0 && account.granted_expires_at) || nil
    }
  end

  @doc """
  May this account call the endpoint?

  Two rules, because most endpoints are included rather than free:

    * A **metered** endpoint (`/email/find`) needs enough tokens to pay for it.
    * An **included** endpoint costs nothing but still needs a positive balance.
      Otherwise an account that had spent down to zero — or never bought
      anything — would keep unlimited access to five of the six endpoints, and
      the enrichment calls behind them cost us real money per request. A balance
      is what makes someone a customer; the token price is a separate question.

  Returns `:ok`, or `{:error, :insufficient_credit, details}` where `details`
  says which of the two rules was not met.
  """
  @spec ensure_funds(Account.t() | nil, String.t()) ::
          :ok | {:error, :insufficient_credit, map()}
  def ensure_funds(nil, _endpoint), do: :ok

  def ensure_funds(%Account{} = account, endpoint) do
    price = Pricing.charge_for(endpoint)
    available = available_micro(account)

    cond do
      available <= 0 ->
        {:error, :insufficient_credit, refusal(account, available, price, :no_balance)}

      available < price ->
        {:error, :insufficient_credit, refusal(account, available, price, :cannot_afford)}

      true ->
        :ok
    end
  end

  defp refusal(account, available, price, reason) do
    %{
      balance_usd: Pricing.usd(available),
      purchased_usd: Pricing.usd(account.balance_micro),
      granted_usd: Pricing.usd(live_grant_micro(account)),
      required_usd: Pricing.usd(price),
      metered: price > 0,
      reason: to_string(reason),
      minimum_purchase_usd: Pricing.min_bundle_usd()
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
        # `false` is not a foreign key: an anonymous or internal settle has no
        # key, and that has to reach the changeset as nil.
        api_key_id: if(match?(%ApiKey{}, api_key), do: api_key.id),
        endpoint: endpoint,
        cache_hit: Map.get(params, :cached, false),
        outcome: if(found?, do: "found", else: "not_found"),
        provider_cost_micro: Map.get(params, :provider_cost_micro, 0),
        charged_micro: charged,
        duration_ms: Map.get(params, :duration_ms),
        request: Map.get(params, :request, %{})
      })
      |> Repo.insert!()

    # Agent-side analytics. Recorded rather than sent: the throttle batches these
    # into one ping every ten seconds, which is what their documentation asks
    # for and what a four-hundred-row sweep makes necessary.
    CsuiteFinder.Ssa.Throttle.record(endpoint, found?, Map.get(params, :cached, false), units)

    {:ok, event}
  end

  # One statement, so two concurrent requests on the same key cannot both see
  # enough credit and overdraw between them. The grant is drawn down first and
  # the remainder comes out of the purchased balance; Postgres evaluates the
  # right-hand sides against the pre-update row, so both terms see the same
  # starting numbers.
  defp debit(%Account{id: id}, micro) do
    %{num_rows: rows} =
      Repo.query!(
        """
        UPDATE accounts
           SET granted_micro = granted_micro - LEAST(#{@live_grant}, $2::bigint),
               balance_micro = balance_micro - ($2::bigint - LEAST(#{@live_grant}, $2::bigint))
         WHERE id = $1
           AND balance_micro + #{@live_grant} >= $2::bigint
        """,
        [id, micro]
      )

    if rows == 1, do: micro, else: 0
  end

  @doc "Credit an account with credit it bought. Permanent, in micro-USD."
  @spec credit(Account.t(), integer()) :: {:ok, Account.t()}
  def credit(%Account{id: id}, micro) when micro > 0 do
    {1, [account]} =
      from(a in Account, where: a.id == ^id, select: a)
      |> Repo.update_all(inc: [balance_micro: micro])

    {:ok, account}
  end

  @doc """
  Give an account expiring credit — a seat's month, or the free trial.

  The grant **replaces** whatever grant came before it rather than adding to it.
  That is what "does not roll over" means: a seat buys a month of capacity, not
  a savings account, and month thirteen looks exactly like month one. Purchased
  credit is untouched, so a customer who tops up on top of a seat keeps every
  dollar they paid for.
  """
  @spec grant(Account.t(), integer(), DateTime.t() | nil) :: {:ok, Account.t()}
  def grant(%Account{id: id}, micro, expires_at) when micro >= 0 do
    {1, [account]} =
      from(a in Account, where: a.id == ^id, select: a)
      |> Repo.update_all(set: [granted_micro: micro, granted_expires_at: expires_at])

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
          charged_micro: sum(e.charged_micro)
        }
      )
      |> Repo.all()

    charged = rows |> Enum.map(&(&1.charged_micro || 0)) |> Enum.sum()

    %{
      since: since,
      by_endpoint: rows,
      totals: %{
        calls: Enum.sum(Enum.map(rows, & &1.calls)),
        provider_cost_usd:
          rows |> Enum.map(&(&1.provider_cost_micro || 0)) |> Enum.sum() |> to_usd(),
        charged_usd: to_usd(charged)
      }
    }
  end

  defp to_usd(micro), do: Float.round(micro / 1_000_000, 6)
end
