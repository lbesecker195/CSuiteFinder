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
  alias CsuiteFinder.Billing.{PayPal, Plans, Subscription}
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
  """
  @spec start(Account.t(), pos_integer(), keyword()) ::
          {:ok, Subscription.t(), String.t()} | {:error, term()}
  def start(%Account{} = account, seats, opts \\ []) do
    with {:ok, seats} <- validate_seats(seats),
         {:ok, response} <- PayPal.create_seat_subscription(account, seats, opts),
         {:ok, subscription} <- store_new(account, seats, response) do
      {:ok, subscription, PayPal.approve_link(response)}
    end
  end

  defp validate_seats(seats) when is_integer(seats) and seats > 0 and seats <= @max_seats,
    do: {:ok, seats}

  defp validate_seats(_), do: {:error, :invalid_seats}

  defp store_new(account, seats, %{"id" => id} = response) do
    %Subscription{}
    |> Subscription.changeset(%{
      account_id: account.id,
      paypal_subscription_id: id,
      paypal_plan_id: response["plan_id"],
      seats: seats,
      status: status_of(response["status"] || "pending"),
      grant_micro_per_period: Plans.seat_grant_micro() * seats,
      raw: response
    })
    |> Repo.insert()
  end

  defp store_new(_account, _seats, _response), do: {:error, :paypal_no_subscription_id}

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
  def record_payment(paypal_subscription_id, payment_id, period_end \\ nil) do
    case get(paypal_subscription_id) do
      nil ->
        {:error, :unknown_subscription}

      %Subscription{last_payment_id: same} when is_binary(payment_id) and same == payment_id ->
        {:error, :already_granted}

      subscription ->
        grant_period(subscription, payment_id, period_end)
    end
  end

  defp grant_period(%Subscription{} = subscription, payment_id, period_end) do
    expires_at = period_end || Plans.seat_grant_expires_at()
    account = Repo.get!(Account, subscription.account_id)
    micro = subscription.grant_micro_per_period

    Repo.transaction(fn ->
      {:ok, _account} = Billing.grant(account, micro, expires_at)

      subscription
      |> Subscription.changeset(%{
        status: "active",
        last_payment_id: payment_id,
        current_period_end: expires_at
      })
      |> Repo.update!()
    end)
  end

  @doc """
  Mirror a status change from PayPal — activated, suspended, cancelled, expired.

  Ending a subscription does not claw the current month back. The customer paid
  for it; it simply stops being renewed, and the grant lapses on its own date.
  """
  @spec set_status(String.t(), String.t(), map()) ::
          {:ok, Subscription.t()} | {:error, :unknown_subscription}
  def set_status(paypal_subscription_id, status, raw \\ %{}) do
    case get(paypal_subscription_id) do
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
        with :ok <- PayPal.cancel_subscription(subscription.paypal_subscription_id, reason) do
          subscription
          |> Subscription.changeset(%{status: "cancelled"})
          |> Repo.update()
        end
    end
  end

  @doc "Ask PayPal for a subscription's current state and store what it says."
  @spec refresh(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def refresh(%Subscription{} = subscription) do
    with {:ok, remote} <- PayPal.get_subscription(subscription.paypal_subscription_id) do
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

  defp get(id), do: Repo.get_by(Subscription, paypal_subscription_id: id)

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
