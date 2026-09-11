defmodule CsuiteFinder.Billing.Subscriptions do
  @moduledoc """
  Seat subscriptions: start one, keep it in step with PayPal, grant its credit.

  The rule that shapes this module is that **a month's credit does not roll
  over**. Each payment calls `CsuiteFinder.Billing.grant/3`, which *replaces*
  the account's granted balance and re-dates its expiry. So the state a customer
  ends up in depends only on their most recent payment, never on the order or
  the number of times PayPal delivered a webhook — which matters, because PayPal
  retries.

  What a subscription never touches is credit the account bought outright. That
  sits in a different column and outlives every subscription.
  """

  import Ecto.Query

  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing
  alias CsuiteFinder.Billing.{PayPal, Plans, Stripe, Subscription}
  alias CsuiteFinder.Repo

  @max_seats 500

  @doc "The account's subscription, if it has one. Newest wins."
  @spec for_account(Account.t()) :: Subscription.t() | nil
  def for_account(%Account{id: id}) do
    Repo.one(
      from s in Subscription,
        where: s.account_id == ^id,
        order_by: [desc: s.id],
        limit: 1
    )
  end

  @doc """
  Start a seat subscription: create it at PayPal and store it as `pending`.

  Nothing is granted here. The customer still has to approve the payment, and a
  subscription that grants credit before money moves is a subscription people
  will start and never approve.

  Returns the row and the URL the customer opens to approve it.

  `:interval` is `:month` (the default) or `:year`. It is stored rather than
  inferred later, because it decides who hands out the monthly credit: a monthly
  seat is granted by each payment, an annual one by
  `refresh_annual_seats/1`. Guess it wrong in either direction and the customer
  is either short eleven months of credit or given twelve at once.
  """
  @spec start(Account.t(), pos_integer(), keyword()) ::
          {:ok, Subscription.t(), String.t()} | {:error, term()}
  def start(%Account{} = account, seats, opts \\ []) do
    with {:ok, seats} <- validate_seats(seats),
         {:ok, interval} <- validate_interval(Keyword.get(opts, :interval, :month)) do
      if Stripe.configured?() do
        start_stripe(account, seats, interval, opts)
      else
        start_paypal(account, seats, interval, opts)
      end
    end
  end

  # Stripe does not create the subscription until the customer has paid, so
  # there is no subscription id to store yet. The row is keyed on the Checkout
  # Session instead and re-keyed when the webhook hands us the real one. Storing
  # it now rather than on the webhook is deliberate: an approval that arrives
  # for a session we never recorded is indistinguishable from a forged one.
  defp start_stripe(account, seats, interval, opts) do
    with {:ok, url, session} <-
           Stripe.create_seat_session(account, seats, String.to_existing_atom(interval), opts),
         {:ok, subscription} <-
           store_new(account, seats, interval, %{"id" => session["id"]}, "stripe") do
      {:ok, subscription, url}
    end
  end

  defp start_paypal(account, seats, interval, opts) do
    with {:ok, response} <- PayPal.create_seat_subscription(account, seats, opts),
         {:ok, subscription} <- store_new(account, seats, interval, response, "paypal") do
      {:ok, subscription, PayPal.approve_link(response)}
    end
  end

  @doc """
  A seat was bought by someone with no account, and has now been paid for.

  Nothing was stored when they were sent to Checkout, because there was nobody
  to store it against. Stripe has since collected an address and confirmed the
  money moved, so this is the first moment the row can exist — and the first
  moment it should, since a row created any earlier would be a subscription
  nobody had paid for.
  """
  @spec open_from_session(integer(), String.t(), map()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def open_from_session(account_id, subscription_id, session) do
    seats = int_or(get_in(session, ["metadata", "seats"]), 1)
    interval = get_in(session, ["metadata", "interval"]) || "month"

    %Subscription{}
    |> Subscription.changeset(%{
      account_id: account_id,
      provider: "stripe",
      provider_ref: subscription_id,
      interval: interval,
      seats: seats,
      status: "active",
      grant_micro_per_period: Plans.seat_grant_micro() * seats,
      raw: session
    })
    |> Repo.insert()
  end

  defp int_or(value, fallback) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> n
      _ -> fallback
    end
  end

  @doc """
  A Checkout Session was paid: attach the real subscription id and grant.

  Until this point the row is keyed on the session, which is the only id that
  existed when the customer was sent to pay.
  """
  @spec attach_stripe_subscription(String.t(), String.t(), map()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def attach_stripe_subscription(session_id, subscription_id, session \\ %{}) do
    case get(session_id) do
      nil ->
        {:error, :unknown_subscription}

      subscription ->
        interval = get_in(session, ["metadata", "interval"]) || subscription.interval

        subscription
        |> Subscription.changeset(%{
          provider_ref: subscription_id,
          interval: interval,
          status: "active",
          raw: session
        })
        |> Repo.update()
    end
  end

  defp validate_interval(interval) when interval in [:month, :year],
    do: {:ok, to_string(interval)}

  defp validate_interval(interval) when interval in ["month", "year"], do: {:ok, interval}
  defp validate_interval(_), do: {:error, :invalid_interval}

  defp validate_seats(seats) when is_integer(seats) and seats > 0 and seats <= @max_seats,
    do: {:ok, seats}

  defp validate_seats(_), do: {:error, :invalid_seats}

  defp store_new(account, seats, interval, %{"id" => id} = response, provider) do
    %Subscription{}
    |> Subscription.changeset(%{
      account_id: account.id,
      provider: provider,
      interval: interval,
      provider_ref: id,
      provider_plan_id: response["plan_id"],
      seats: seats,
      status: status_of(response["status"] || "pending"),
      grant_micro_per_period: Plans.seat_grant_micro() * seats,
      raw: response
    })
    |> Repo.insert()
  end

  defp store_new(_account, _seats, _interval, _response, _provider),
    do: {:error, :no_subscription_id}

  @doc "The maximum seats one subscription may carry."
  @spec max_seats() :: pos_integer()
  def max_seats, do: @max_seats

  @doc """
  A payment came in for a subscription: grant its month of credit.

  `payment_id` is PayPal's id for that payment. A repeat of one we have already
  granted is ignored, so a retried webhook does not re-date the expiry of a
  month the customer is halfway through.
  """
  @spec record_payment(String.t(), String.t() | nil, DateTime.t() | nil) ::
          {:ok, Subscription.t()} | {:error, :unknown_subscription | :already_granted}
  def record_payment(provider_ref, payment_id, period_end \\ nil) do
    case get(provider_ref) do
      nil ->
        {:error, :unknown_subscription}

      %Subscription{last_payment_id: same} when is_binary(payment_id) and same == payment_id ->
        {:error, :already_granted}

      subscription ->
        grant_period(subscription, payment_id, period_end)
    end
  end

  defp grant_period(%Subscription{} = subscription, payment_id, period_end) do
    paid_through = period_end || default_period_end(subscription)
    account = Repo.get!(Account, subscription.account_id)
    micro = subscription.grant_micro_per_period

    # An annual payment buys a year of service but only a month of credit at a
    # time — the other eleven arrive from refresh_annual_seats/1. Granting the
    # whole year here would hand over $999 that has to last twelve months, which
    # is the opposite of what the customer bought.
    month = Date.beginning_of_month(Date.utc_today())

    {grant_until, refreshed_for} =
      if annual?(subscription) do
        {month
         |> Date.shift(month: 1)
         |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")
         |> earlier_of(paid_through), month}
      else
        {paid_through, nil}
      end

    Repo.transaction(fn ->
      {:ok, _account} = Billing.grant(account, micro, grant_until)

      subscription
      |> Subscription.changeset(%{
        status: "active",
        last_payment_id: payment_id,
        current_period_end: paid_through,
        # Claimed here as well as in the refresher, so the month a payment
        # already granted cannot be granted a second time an hour later.
        refreshed_for: refreshed_for
      })
      |> Repo.update!()
    end)
  end

  defp annual?(%Subscription{interval: "year"}), do: true
  defp annual?(_), do: false

  defp default_period_end(%Subscription{interval: "year"}),
    do: DateTime.shift(DateTime.utc_now(), year: 1)

  defp default_period_end(_), do: Plans.seat_grant_expires_at()

  # ------------------------------------------------------- the monthly refresh

  @doc """
  Top every live annual seat back up for the current month.

  A monthly seat needs none of this: it is invoiced monthly, and the grant rides
  on the payment. An annual seat is invoiced once and owes twelve monthly
  grants, so after the first one there is no payment left to hang them on.
  Without this, someone who paid $9,990 would be credited once and have nothing
  to spend for eleven months.

  Returns the number of seats topped up.
  """
  @spec refresh_annual_seats(Date.t()) :: non_neg_integer()
  def refresh_annual_seats(today \\ Date.utc_today()) do
    month = Date.beginning_of_month(today)
    now = DateTime.utc_now()

    from(s in Subscription,
      where:
        s.interval == "year" and s.status == "active" and
          (is_nil(s.refreshed_for) or s.refreshed_for < ^month) and
          not is_nil(s.current_period_end) and s.current_period_end > ^now
    )
    |> Repo.all()
    |> Enum.count(&refresh_one(&1, month))
  end

  # Claim the month before granting it, in one conditional UPDATE.
  #
  # Two things make this necessary. The refresher runs on a timer, so a restart
  # can call it twice in a minute; and the app can run on more than one node,
  # where every node's timer fires. The UPDATE is the lock: whoever moves
  # `refreshed_for` forward is the one who grants, and everybody else sees zero
  # rows and does nothing. Granting first and marking afterwards would hand out
  # a second $999 every time this raced.
  defp refresh_one(%Subscription{} = subscription, month) do
    {count, _} =
      from(s in Subscription,
        where:
          s.id == ^subscription.id and
            (is_nil(s.refreshed_for) or s.refreshed_for < ^month)
      )
      |> Repo.update_all(set: [refreshed_for: month, updated_at: DateTime.utc_now()])

    count == 1 and grant_month(subscription, month)
  end

  defp grant_month(%Subscription{} = subscription, month) do
    account = Repo.get!(Account, subscription.account_id)

    # One month of credit, and never past the period already paid for: a seat
    # that lapses in a fortnight must not hand out a month that outlives it.
    expires_at =
      month
      |> Date.shift(month: 1)
      |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")
      |> earlier_of(subscription.current_period_end)

    {:ok, _account} = Billing.grant(account, subscription.grant_micro_per_period, expires_at)
    true
  end

  defp earlier_of(a, nil), do: a

  defp earlier_of(a, b) do
    if DateTime.compare(a, b) == :lt, do: a, else: b
  end

  @doc """
  Mirror a status change from PayPal — activated, suspended, cancelled, expired.

  Ending a subscription does not claw the current month back. The customer paid
  for it; it simply stops being renewed, and the grant lapses on its own date.
  """
  @spec set_status(String.t(), String.t(), map()) ::
          {:ok, Subscription.t()} | {:error, :unknown_subscription}
  def set_status(provider_ref, status, raw \\ %{}) do
    case get(provider_ref) do
      nil ->
        {:error, :unknown_subscription}

      subscription ->
        subscription
        |> Subscription.changeset(%{status: status_of(status), raw: raw})
        |> Repo.update()
    end
  end

  @doc """
  Cancel at PayPal, and mirror it here.

  The seat runs to the end of the period already paid for — `current_period_end`
  is left alone and the granted credit expires on its own.
  """
  @spec cancel(Account.t(), String.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def cancel(%Account{} = account, reason \\ "Cancelled by the account holder") do
    case for_account(account) do
      nil ->
        {:error, :no_subscription}

      %Subscription{status: status} when status in ~w(cancelled expired) ->
        {:error, :not_active}

      subscription ->
        with :ok <- PayPal.cancel_subscription(subscription.provider_ref, reason) do
          subscription
          |> Subscription.changeset(%{status: "cancelled"})
          |> Repo.update()
        end
    end
  end

  @doc "Ask PayPal for a subscription's current state and store what it says."
  @spec refresh(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def refresh(%Subscription{} = subscription) do
    with {:ok, remote} <- PayPal.get_subscription(subscription.provider_ref) do
      subscription
      |> Subscription.changeset(%{
        status: status_of(remote["status"]),
        current_period_end: next_billing(remote) || subscription.current_period_end,
        raw: remote
      })
      |> Repo.update()
    end
  end

  @doc "The next billing time PayPal reports, if it reports one."
  @spec next_billing(map()) :: DateTime.t() | nil
  def next_billing(%{"billing_info" => %{"next_billing_time" => time}}) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  def next_billing(_), do: nil

  defp get(id), do: Repo.get_by(Subscription, provider_ref: id)

  # PayPal shouts its statuses; the column stores them lower-case. Anything we
  # do not recognise is recorded as pending rather than crashing a webhook.
  defp status_of(status) when is_binary(status) do
    normalised = String.downcase(status)

    if normalised in ~w(pending approval_pending approved active suspended cancelled expired),
      do: normalised,
      else: "pending"
  end

  defp status_of(_), do: "pending"
end
