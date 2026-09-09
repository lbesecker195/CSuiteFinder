defmodule CsuiteFinderWeb.BillingController do
  @moduledoc """
  Account balance, PayPal top-ups, and the capture webhook.
  """

  use CsuiteFinderWeb, :controller

  require Logger

  alias CsuiteFinder.Billing
  alias CsuiteFinder.Billing.{PayPal, Pricing}

  action_fallback CsuiteFinderWeb.FallbackController

  @doc "GET /csuitefinder/billing/balance"
  def balance(conn, _params) do
    case conn.assigns[:account] do
      nil ->
        json(conn, %{authenticated: false, terms: Pricing.terms()})

      account ->
        json(conn, %{
          account_id: account.id,
          email: account.email,
          token_balance: account.token_balance,
          token_balance_usd: Pricing.usd_for_tokens(account.token_balance),
          on_free_trial: not is_nil(account.trial_granted_at) and account.token_balance > 0,
          status: account.status,
          prices_in_tokens: Pricing.list(),
          terms: Pricing.terms()
        })
    end
  end

  @doc "GET /csuitefinder/billing/usage"
  def usage(conn, params) do
    case conn.assigns[:account] do
      nil ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

      account ->
        days = params |> Map.get("days", "30") |> to_int(30)
        json(conn, Billing.usage_summary(account, days))
    end
  end

  @doc "POST /csuitefinder/billing/topup — buy a token bundle."
  def topup(conn, params) do
    with {:ok, account} <- authed(conn),
         {:ok, amount} <- amount(params["amount_usd"]),
         {:ok, payment, response} <-
           PayPal.create_order(account, amount,
             return_url: params["return_url"] || "",
             cancel_url: params["cancel_url"] || ""
           ) do
      json(conn, %{
        payment_id: payment.id,
        paypal_order_id: payment.paypal_order_id,
        amount_usd: amount,
        tokens: payment.tokens,
        status: payment.status,
        # The link the customer opens to approve the payment.
        approve_url: approve_link(response)
      })
    else
      {:error, :below_minimum, details} ->
        conn
        |> put_status(:bad_request)
        |> json(
          Map.merge(details, %{
            error: "below_minimum_bundle",
            message: "Token bundles start at $#{Pricing.min_bundle_usd()}."
          })
        )

      {:error, :invalid_amount} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_amount", message: "`amount_usd` must be a positive number."})

      {:error, :paypal_not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "paypal_not_configured",
          message: "Set PAYPAL_CLIENT_ID and PAYPAL_CLIENT_SECRET."
        })

      other ->
        other
    end
  end

  @doc "POST /csuitefinder/billing/capture"
  def capture(conn, %{"paypal_order_id" => order_id}) do
    case PayPal.capture_order(order_id) do
      {:ok, payment} ->
        json(conn, %{
          paypal_order_id: payment.paypal_order_id,
          status: payment.status,
          tokens_credited: payment.tokens,
          credited_usd: Float.round(payment.amount_micro / 1_000_000, 2)
        })

      {:error, :unknown_order} ->
        conn |> put_status(:not_found) |> json(%{error: "unknown_order"})

      {:error, reason} ->
        # PayPal's error body carries its debug_id, its internal vocabulary and
        # its documentation links. Log it, do not hand it to the caller.
        Logger.warning("paypal capture failed: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{
          error: "capture_failed",
          message:
            "The payment could not be captured. If you have not approved it yet, " <>
              "open the approve_url from the top-up response first. Nothing was charged."
        })
    end
  end

  def capture(conn, _params),
    do: conn |> put_status(:bad_request) |> json(%{error: "missing paypal_order_id"})

  @doc """
  POST /csuitefinder/billing/webhook

  Unauthenticated by design — PayPal calls it — so the signature is verified
  with PayPal before anything is credited, and an unverified event is dropped.
  """
  def webhook(conn, params) do
    headers = Map.new(conn.req_headers)

    case PayPal.verify_webhook(headers, params) do
      :ok ->
        handle_event(params)
        json(conn, %{received: true})

      {:error, :invalid_signature} ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid_signature"})

      {:error, reason} ->
        Logger.warning("paypal webhook verification unavailable: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "verification_unavailable"})
    end
  end

  # An approval webhook is the reliable capture trigger: the customer's browser
  # may never come back to the return URL, but PayPal will retry this.
  defp handle_event(%{"event_type" => type, "resource" => resource})
       when type in ["CHECKOUT.ORDER.APPROVED", "PAYMENT.CAPTURE.COMPLETED"] do
    case order_id_from(resource) do
      nil -> :ok
      order_id -> PayPal.capture_order(order_id)
    end
  end

  defp handle_event(_), do: :ok

  defp order_id_from(%{"id" => id, "intent" => _}), do: id
  defp order_id_from(%{"supplementary_data" => %{"related_ids" => %{"order_id" => id}}}), do: id
  defp order_id_from(%{"id" => id}), do: id
  defp order_id_from(_), do: nil

  defp authed(conn) do
    case conn.assigns[:account] do
      nil -> {:error, :unauthorized}
      account -> {:ok, account}
    end
  end

  defp amount(value) when is_number(value) and value > 0, do: {:ok, value / 1}

  defp amount(value) when is_binary(value) do
    case Float.parse(value) do
      {amount, _} when amount > 0 -> {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp amount(_), do: {:error, :invalid_amount}

  defp approve_link(%{"links" => links}) when is_list(links) do
    Enum.find_value(links, fn
      %{"rel" => "approve", "href" => href} -> href
      %{"rel" => "payer-action", "href" => href} -> href
      _ -> nil
    end)
  end

  defp approve_link(_), do: nil

  defp to_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end
end
