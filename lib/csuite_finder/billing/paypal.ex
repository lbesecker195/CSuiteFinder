defmodule CsuiteFinder.Billing.PayPal do
  @moduledoc """
  PayPal Orders v2 — creating a top-up, capturing it, and verifying webhooks.

  Two things this module refuses to do by design. It never trusts an amount sent
  by the browser: the capture is credited from what PayPal says was captured, not
  from what the client claimed. And crediting is keyed on the order id with a
  unique constraint, so a webhook PayPal retries (which it will) cannot credit an
  account twice.
  """

  require Logger

  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing
  alias CsuiteFinder.Billing.{Payment, PayPalPlan, Plans, Pricing}
  alias CsuiteFinder.Repo

  @doc """
  Create a PayPal order for a token bundle.

  The bundle minimum is checked here, before PayPal is involved, so an
  under-minimum request never becomes a real order someone can approve.
  """
  @spec create_order(Account.t(), float(), keyword()) ::
          {:ok, Payment.t(), map()} | {:error, term()} | {:error, :below_minimum, map()}
  def create_order(%Account{} = account, amount_usd, opts \\ []) when amount_usd > 0 do
    with {:ok, credit_micro} <- Pricing.validate_bundle(amount_usd) do
      do_create_order(account, amount_usd, credit_micro, opts)
    end
  end

  defp do_create_order(%Account{} = account, amount_usd, credit_micro, opts) do
    body = %{
      intent: "CAPTURE",
      purchase_units: [
        %{
          reference_id: "topup_account_#{account.id}",
          description: "CSuiteFinder — $#{Pricing.usd(credit_micro)} of API credit",
          amount: %{
            currency_code: "USD",
            value: :erlang.float_to_binary(amount_usd / 1, decimals: 2)
          }
        }
      ],
      application_context: %{
        brand_name: "CSuiteFinder",
        user_action: "PAY_NOW",
        return_url: Keyword.get(opts, :return_url, ""),
        cancel_url: Keyword.get(opts, :cancel_url, "")
      }
    }

    with {:ok, token} <- access_token(),
         {:ok, %{status: status, body: response}} when status in 200..299 <-
           post("/v2/checkout/orders", body, token) do
      {:ok, payment} =
        %Payment{}
        |> Payment.changeset(%{
          account_id: account.id,
          paypal_order_id: response["id"],
          amount_micro: round(amount_usd * 1_000_000),
          credit_micro: credit_micro,
          status: "created",
          raw: response
        })
        |> Repo.insert()

      {:ok, payment, response}
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("paypal create_order failed #{status}: #{inspect(body)}")
        {:error, {:paypal, status, body}}

      error ->
        error
    end
  end

  @doc """
  Capture an approved order and credit the account.

  Idempotent: an order already credited returns the existing payment untouched.
  """
  @spec capture_order(String.t()) :: {:ok, Payment.t()} | {:error, term()}
  def capture_order(order_id) do
    case Repo.get_by(Payment, paypal_order_id: order_id) do
      nil ->
        {:error, :unknown_order}

      %Payment{status: "credited"} = payment ->
        {:ok, payment}

      %Payment{} = payment ->
        do_capture(payment)
    end
  end

  defp do_capture(%Payment{} = payment) do
    with {:ok, token} <- access_token(),
         {:ok, %{status: status, body: response}} when status in 200..299 <-
           post("/v2/checkout/orders/#{payment.paypal_order_id}/capture", %{}, token) do
      case captured_amount(response) do
        {:ok, capture_id, amount_micro} ->
          credit_once(payment, capture_id, amount_micro, response)

        :error ->
          mark(payment, "failed", response)
          {:error, :capture_not_completed}
      end
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("paypal capture failed #{status}: #{inspect(body)}")
        mark(payment, "failed", body)
        {:error, {:paypal, status, body}}

      error ->
        error
    end
  end

  # The credit and the status change are one transaction, so a crash between
  # them cannot leave an account credited for an order still marked capturable.
  defp credit_once(payment, capture_id, amount_micro, response) do
    # Credit is derived from what PayPal actually captured, never from what the
    # client asked for — a tampered amount buys exactly what it paid for. Run
    # through the bundles so a larger purchase gets the bonus it was quoted
    # rather than only its face value.
    credit_micro = Pricing.credit_for_purchase(amount_micro / 1_000_000)

    Repo.transaction(fn ->
      account = Repo.get!(Account, payment.account_id)
      {:ok, _account} = Billing.credit(account, credit_micro)

      payment
      |> Payment.changeset(%{
        status: "credited",
        paypal_capture_id: capture_id,
        amount_micro: amount_micro,
        credit_micro: credit_micro,
        credited_at: DateTime.utc_now(),
        raw: response
      })
      |> Repo.update!()
    end)
  end

  defp captured_amount(%{"status" => "COMPLETED"} = response) do
    with [unit | _] <- get_in(response, ["purchase_units"]),
         [capture | _] <- get_in(unit, ["payments", "captures"]),
         %{"amount" => %{"value" => value}, "id" => id} <- capture,
         {amount, _} <- Float.parse(value) do
      {:ok, id, round(amount * 1_000_000)}
    else
      _ -> :error
    end
  end

  defp captured_amount(_), do: :error

  defp mark(payment, status, raw) do
    payment |> Payment.changeset(%{status: status, raw: wrap(raw)}) |> Repo.update()
  end

  defp wrap(raw) when is_map(raw), do: raw
  defp wrap(raw), do: %{"body" => inspect(raw)}

  @doc """
  Ask PayPal whether a webhook really came from PayPal.

  Verification is delegated to PayPal's own endpoint rather than reimplemented,
  and a webhook that does not verify is dropped — an unverified "payment
  completed" is exactly the message an attacker would forge.
  """
  @spec verify_webhook(map(), map()) :: :ok | {:error, :invalid_signature | term()}
  def verify_webhook(headers, event) do
    payload = %{
      auth_algo: headers["paypal-auth-algo"],
      cert_url: headers["paypal-cert-url"],
      transmission_id: headers["paypal-transmission-id"],
      transmission_sig: headers["paypal-transmission-sig"],
      transmission_time: headers["paypal-transmission-time"],
      webhook_id: config()[:webhook_id],
      webhook_event: event
    }

    with {:ok, token} <- access_token(),
         {:ok, %{status: 200, body: %{"verification_status" => "SUCCESS"}}} <-
           post("/v1/notifications/verify-webhook-signature", payload, token) do
      :ok
    else
      {:ok, %{body: body}} ->
        Logger.warning("paypal webhook verification rejected: #{inspect(body)}")
        {:error, :invalid_signature}

      error ->
        error
    end
  end

  # ------------------------------------------------------ seat subscriptions

  @doc """
  Create a monthly seat subscription for `account`, `seats` seats.

  Returns PayPal's subscription resource; the caller stores it and sends the
  customer to the approval link. Nothing is charged until they approve.
  """
  @spec create_seat_subscription(Account.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_seat_subscription(%Account{} = account, seats, opts \\ []) do
    with {:ok, plan} <- ensure_seat_plan(),
         {:ok, token} <- access_token(),
         {:ok, %{status: status, body: response}} when status in 200..299 <-
           post(
             "/v1/billing/subscriptions",
             %{
               plan_id: plan.paypal_plan_id,
               quantity: to_string(seats),
               subscriber: %{email_address: account.email},
               custom_id: "account_#{account.id}",
               application_context: %{
                 brand_name: "CSuiteFinder",
                 user_action: "SUBSCRIBE_NOW",
                 shipping_preference: "NO_SHIPPING",
                 return_url: Keyword.get(opts, :return_url, ""),
                 cancel_url: Keyword.get(opts, :cancel_url, "")
               }
             },
             token
           ) do
      {:ok, response}
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("paypal create_subscription failed #{status}: #{inspect(body)}")
        {:error, {:paypal, status, body}}

      error ->
        error
    end
  end

  @doc "A subscription's current state at PayPal."
  @spec get_subscription(String.t()) :: {:ok, map()} | {:error, term()}
  def get_subscription(id) do
    with {:ok, token} <- access_token(),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           get("/v1/billing/subscriptions/#{id}", token) do
      {:ok, body}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:paypal, status, body}}
      error -> error
    end
  end

  @doc "Stop a subscription renewing. The period already paid for is not refunded."
  @spec cancel_subscription(String.t(), String.t()) :: :ok | {:error, term()}
  def cancel_subscription(id, reason) do
    with {:ok, token} <- access_token(),
         {:ok, %{status: status}} when status in 200..299 <-
           post("/v1/billing/subscriptions/#{id}/cancel", %{reason: reason}, token) do
      :ok
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("paypal cancel_subscription failed #{status}: #{inspect(body)}")
        {:error, {:paypal, status, body}}

      error ->
        error
    end
  end

  @doc """
  The PayPal billing plan for a seat, creating it the first time it is needed.

  PayPal models a subscription price as a product plus a plan, both created once
  and referenced by id afterwards. The row is keyed on the price, so raising the
  seat price creates a new plan rather than silently billing the old amount —
  and existing subscribers stay on the plan they agreed to, which is how PayPal
  works and also how it ought to work.
  """
  @spec ensure_seat_plan() :: {:ok, PayPalPlan.t()} | {:error, term()}
  def ensure_seat_plan do
    key = "seat-#{Plans.seat_usd()}-month"

    case Repo.get_by(PayPalPlan, key: key) do
      %PayPalPlan{} = plan -> {:ok, plan}
      nil -> create_seat_plan(key)
    end
  end

  defp create_seat_plan(key) do
    with {:ok, token} <- access_token(),
         {:ok, product_id} <- ensure_product(token),
         {:ok, %{status: status, body: plan}} when status in 200..299 <-
           post(
             "/v1/billing/plans",
             %{
               product_id: product_id,
               name: "CSuiteFinder seat",
               description:
                 "One seat: $#{Plans.seat_usd()} of lookup credit each month. Unused credit does not roll over.",
               billing_cycles: [
                 %{
                   frequency: %{interval_unit: "MONTH", interval_count: 1},
                   tenure_type: "REGULAR",
                   sequence: 1,
                   # 0 = forever, until cancelled.
                   total_cycles: 0,
                   pricing_scheme: %{
                     fixed_price: %{
                       currency_code: "USD",
                       value: :erlang.float_to_binary(Plans.seat_usd() / 1, decimals: 2)
                     }
                   }
                 }
               ],
               payment_preferences: %{
                 auto_bill_outstanding: true,
                 setup_fee_failure_action: "CANCEL",
                 payment_failure_threshold: 2
               },
               # Seats are billed per unit, so the plan price multiplies by
               # `quantity` on the subscription.
               quantity_supported: true
             },
             token
           ) do
      %PayPalPlan{}
      |> PayPalPlan.changeset(%{
        key: key,
        paypal_product_id: product_id,
        paypal_plan_id: plan["id"],
        amount_micro: Plans.seat_micro(),
        raw: plan
      })
      |> Repo.insert()
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("paypal create_plan failed #{status}: #{inspect(body)}")
        {:error, {:paypal, status, body}}

      error ->
        error
    end
  end

  defp ensure_product(token) do
    case post(
           "/v1/catalogs/products",
           %{
             name: "CSuiteFinder",
             description: "Work email and phone lookups",
             type: "SERVICE",
             category: "SOFTWARE"
           },
           token
         ) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 -> {:ok, id}
      {:ok, %{status: status, body: body}} -> {:error, {:paypal, status, body}}
      error -> error
    end
  end

  @doc "The link a customer opens to approve an order or a subscription."
  @spec approve_link(map()) :: String.t() | nil
  def approve_link(%{"links" => links}) when is_list(links) do
    Enum.find_value(links, fn
      %{"rel" => "approve", "href" => href} -> href
      %{"rel" => "payer-action", "href" => href} -> href
      _ -> nil
    end)
  end

  def approve_link(_), do: nil

  # ------------------------------------------------------------------- client

  defp access_token do
    client_id = config()[:client_id]
    secret = config()[:client_secret]

    if is_nil(client_id) or is_nil(secret) do
      {:error, :paypal_not_configured}
    else
      auth = Base.encode64("#{client_id}:#{secret}")

      case Req.post(
             url: base_url() <> "/v1/oauth2/token",
             headers: [
               {"authorization", "Basic " <> auth},
               {"content-type", "application/x-www-form-urlencoded"}
             ],
             body: "grant_type=client_credentials",
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
        {:ok, %{status: status, body: body}} -> {:error, {:paypal_auth, status, body}}
        {:error, reason} -> {:error, {:transport, reason}}
      end
    end
  end

  defp post(path, body, token) do
    Req.post(
      url: base_url() <> path,
      json: body,
      headers: [{"authorization", "Bearer " <> token}],
      receive_timeout: 30_000
    )
  end

  defp get(path, token) do
    Req.get(
      url: base_url() <> path,
      headers: [{"authorization", "Bearer " <> token}],
      receive_timeout: 30_000
    )
  end

  defp config, do: Application.get_env(:csuite_finder, __MODULE__, [])
  defp base_url, do: config()[:base_url] || "https://api-m.sandbox.paypal.com"

  @doc "Is PayPal wired up in this environment?"
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(config()[:client_id]) and not is_nil(config()[:client_secret])
end
