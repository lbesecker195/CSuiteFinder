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
  alias CsuiteFinder.Billing.{Payment, Pricing}
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

  defp config, do: Application.get_env(:csuite_finder, __MODULE__, [])
  defp base_url, do: config()[:base_url] || "https://api-m.sandbox.paypal.com"

  @doc "Is PayPal wired up in this environment?"
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(config()[:client_id]) and not is_nil(config()[:client_secret])
end
