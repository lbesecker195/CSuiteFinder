defmodule CsuiteFinderWeb.BillingController do
  @moduledoc """
  Account balance, PayPal top-ups, and the capture webhook.
  """

  use CsuiteFinderWeb, :controller

  require Logger

  alias CsuiteFinder.{Accounts, Audience, Billing}
  alias CsuiteFinder.Billing.{PayPal, Plans, Pricing, Stripe, Subscription, Subscriptions}

  action_fallback CsuiteFinderWeb.FallbackController

  @doc "GET /csuitefinder/billing/balance"
  def balance(conn, _params) do
    case conn.assigns[:account] do
      nil ->
        json(conn, %{authenticated: false, terms: Pricing.terms()})

      account ->
        balances = Billing.balances(account)

        json(conn, %{
          account_id: account.id,
          email: account.email,
          # Everything the page renders hangs off this: which prices, which
          # purchase path, which nav. See CsuiteFinder.Audience.
          audience: account.audience,
          # `balance_usd` stays the headline number — everything spendable —
          # because that is the field callers already read. The split is
          # alongside it, so a customer can see which dollars have a deadline.
          balance_usd: balances.available_usd,
          purchased_usd: balances.purchased_usd,
          granted_usd: balances.granted_usd,
          granted_expires_at: balances.granted_expires_at,
          # Once, per account, whether it was granted or bought.
          trial_taken: not is_nil(account.trial_granted_at),
          # Whether a password exists, never anything about it. Checkout creates
          # accounts without one — asking before someone has decided to buy is
          # a field that costs signups and protects nothing — so the account
          # page has to know when to ask for one afterwards.
          has_password: not is_nil(account.password_hash),
          status: account.status,
          # A per-answer price list is the developer's offer and the
          # salesperson's distraction — $0.0025 read next to $999 makes the seat
          # look absurd, and the seat is what they are here to buy.
          prices_usd: if(Audience.developer?(account.audience), do: Pricing.list_usd()),
          terms: Pricing.terms(account.audience)
        })
    end
  end

  @doc """
  POST /csuitefinder/billing/audience — move between the two halves.

  Someone who signed up on the wrong side of the site should be able to say so
  without opening a support ticket, and the whole UI keys off this one field.
  """
  def audience(conn, params) do
    with {:ok, account} <- authed(conn),
         {:ok, account} <- Accounts.set_audience(account, params["audience"]) do
      json(conn, %{audience: account.audience, terms: Pricing.terms(account.audience)})
    end
  end

  @doc "GET /csuitefinder/billing/usage"
  def usage(conn, params) do
    case conn.assigns[:account] do
      nil ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

      account ->
        days = params |> Map.get("days", "30") |> to_int(30)

        json(conn, usage_for(Billing.usage_summary(account, days), account.audience))
    end
  end

  # A per-endpoint charge divided by the number of answers *is* the unit price,
  # so the breakdown goes to developers only. A seat holder still gets what they
  # actually want from this: how much they have done, and what it has used.
  defp usage_for(summary, audience) do
    if Audience.developer?(audience) do
      summary
    else
      %{
        since: summary.since,
        totals: %{
          calls: summary.totals.calls,
          credit_used_usd: summary.totals.charged_usd
        },
        by_endpoint:
          Enum.map(summary.by_endpoint, fn row ->
            %{endpoint: row.endpoint, calls: row.calls, found: row.found}
          end)
      }
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
        provider_ref: payment.provider_ref,
        amount_usd: amount,
        credit_usd: Pricing.usd(payment.credit_micro),
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
            error: "below_minimum_purchase",
            message: "Purchases start at $#{Pricing.min_bundle_usd()}."
          })
        )

      {:error, :invalid_amount} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_amount", message: "`amount_usd` must be a positive number."})

      {:error, reason}
      when reason in [
             :paypal_not_configured,
             :stripe_not_configured,
             :stripe_price_not_configured
           ] ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "payments_not_configured",
          message: "Payments are not switched on in this environment."
        })

      other ->
        other
    end
  end

  @doc """
  POST /csuitefinder/billing/trial — buy one trial of the seat.

  A fixed price, once per account. Every trial is paid: a card up
  front is what separates someone evaluating a seat from a drive-by signup.
  """
  def trial(conn, params) do
    with {:ok, account} <- authed(conn),
         {:ok, payment, approve_url} <- start_trial(account, params) do
      json(conn, %{
        provider_ref: payment.provider_ref,
        amount_usd: Pricing.trial_usd(),
        credit_usd: Pricing.usd(payment.credit_micro),
        expires_in_months: Pricing.trial_months(),
        approve_url: approve_url,
        notice:
          "One trial per account. The credit expires after " <>
            "#{Pricing.trial_months()} month, the same way a seat's does."
      })
    else
      {:error, :trial_already_taken} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "trial_already_taken",
          message: "This account has already had its trial. A seat is the next step."
        })

      {:error, reason}
      when reason in [
             :paypal_not_configured,
             :stripe_not_configured,
             :stripe_price_not_configured
           ] ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "payments_not_configured"})

      other ->
        other
    end
  end

  # Stripe when it is configured, PayPal otherwise. The two return the same
  # shape so nothing above this line has to know which took the money.
  defp start_trial(account, params) do
    urls = [
      return_url: params["return_url"] || "",
      cancel_url: params["cancel_url"] || ""
    ]

    if Stripe.configured?() do
      # One trial per account, checked here rather than at Stripe: a second
      # Checkout Session would be a real payment page for a product we will not
      # grant twice.
      if not is_nil(account.trial_granted_at) do
        {:error, :trial_already_taken}
      else
        with {:ok, url, session} <-
               Stripe.create_payment_session(account, Pricing.trial_usd(), "seat_trial", urls),
             {:ok, payment} <- Stripe.record_payment(session) do
          {:ok, payment, url}
        end
      end
    else
      with {:ok, payment, response} <- PayPal.create_trial_order(account, urls) do
        {:ok, payment, PayPal.approve_link(response)}
      end
    end
  end

  @doc "POST /csuitefinder/billing/capture"
  def capture(conn, %{"provider_ref" => order_id}) do
    case PayPal.capture_order(order_id) do
      {:ok, payment} ->
        json(conn, %{
          provider_ref: payment.provider_ref,
          status: payment.status,
          kind: payment.kind,
          credited_usd: Pricing.usd(payment.credit_micro),
          paid_usd: Float.round(payment.amount_micro / 1_000_000, 2),
          # Said at the moment of payment, not only on the page that sold it.
          # Someone who has just handed over money is the person most owed a
          # plain statement of what they got.
          expires_in_months: if(payment.kind == "seat_trial", do: Pricing.trial_months())
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
    do: conn |> put_status(:bad_request) |> json(%{error: "missing provider_ref"})

  # ------------------------------------------------------ seat subscriptions

  @doc "GET /csuitefinder/billing/subscription — the account's seat plan, if any."
  def subscription(conn, _params) do
    with {:ok, account} <- authed(conn) do
      json(conn, %{
        seat: seat_terms(),
        subscription: subscription_view(Subscriptions.for_account(account))
      })
    end
  end

  @doc "POST /csuitefinder/billing/subscribe — start a monthly seat subscription."
  def subscribe(conn, params) do
    with {:ok, account} <- authed(conn),
         {:ok, seats} <- seats(params["seats"]),
         {:ok, subscription, approve_url} <-
           Subscriptions.start(account, seats,
             return_url: params["return_url"] || "",
             cancel_url: params["cancel_url"] || ""
           ) do
      json(conn, %{
        subscription: subscription_view(subscription),
        approve_url: approve_url,
        # Said here as well as on the page, because this is the response an
        # integrator reads when they wire the flow up themselves.
        notice:
          "Nothing is charged until the payer approves. Each payment grants " <>
            "$#{Plans.seat_usd()} of credit per seat, which expires at the end of the month."
      })
    else
      {:error, :invalid_seats} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_seats",
          message: "`seats` must be a whole number from 1 to #{Subscriptions.max_seats()}."
        })

      {:error, reason}
      when reason in [
             :paypal_not_configured,
             :stripe_not_configured,
             :stripe_price_not_configured
           ] ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "payments_not_configured",
          message: "Payments are not switched on in this environment."
        })

      {:error, {:paypal, _status, _body} = reason} ->
        Logger.warning("paypal subscribe failed: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{
          error: "subscribe_failed",
          message: "The subscription could not be created. Nothing was charged."
        })

      other ->
        other
    end
  end

  @doc "POST /csuitefinder/billing/subscription/cancel"
  def unsubscribe(conn, _params) do
    with {:ok, account} <- authed(conn),
         {:ok, subscription} <- Subscriptions.cancel(account) do
      json(conn, %{
        subscription: subscription_view(subscription),
        notice:
          "Cancelled. The month you have already paid for runs to its end; " <>
            "credit you bought outright is not affected."
      })
    else
      {:error, reason} when reason in [:no_subscription, :not_active] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "no_active_subscription"})

      other ->
        other
    end
  end

  defp seat_terms do
    seat = Plans.seat()

    %{
      usd_per_month: seat.usd_per_month,
      credit_usd_per_month: seat.credit_usd,
      rolls_over: false,
      max_seats: Subscriptions.max_seats()
    }
  end

  defp subscription_view(nil), do: nil

  defp subscription_view(%Subscription{} = s) do
    %{
      id: s.provider_ref,
      status: s.status,
      seats: s.seats,
      credit_usd_per_month: Pricing.usd(s.grant_micro_per_period),
      current_period_end: s.current_period_end
    }
  end

  defp seats(nil), do: {:ok, 1}
  defp seats(n) when is_integer(n), do: {:ok, n}

  defp seats(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_seats}
    end
  end

  defp seats(_), do: {:error, :invalid_seats}

  @doc """
  POST /csuitefinder/billing/webhook

  Unauthenticated by design — PayPal calls it — so the signature is verified
  with PayPal before anything is credited, and an unverified event is dropped.
  """
  def webhook(conn, params) do
    if Stripe.configured?() do
      stripe_webhook(conn, params)
    else
      paypal_webhook(conn, params)
    end
  end

  # Verified against the raw bytes, never the parsed map — re-encoding params
  # reorders keys and the hash stops matching. The body survives the parser via
  # CsuiteFinderWeb.CacheBodyReader.
  defp stripe_webhook(conn, params) do
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case Stripe.verify_webhook(conn.assigns[:raw_body] || "", signature) do
      :ok ->
        handle_stripe(params)
        json(conn, %{received: true})

      {:error, :not_configured} ->
        # Accepting unverified events would mean anyone who found this URL could
        # grant themselves a seat, so an unset secret closes the endpoint.
        Logger.error("stripe webhook received but STRIPE_WEBHOOK_SECRET is unset")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "verification_unavailable"})

      {:error, reason} ->
        Logger.warning("stripe webhook rejected: #{inspect(reason)}")
        conn |> put_status(:unauthorized) |> json(%{error: "invalid_signature"})
    end
  end

  # A completed session is the one event that must never be missed: the customer
  # has paid by the time it arrives.
  defp handle_stripe(%{"type" => "checkout.session.completed", "data" => %{"object" => session}}) do
    case session["mode"] do
      "subscription" ->
        grant_seat(session)

      _ ->
        credit_stripe_payment(session)
    end

    :ok
  end

  # A renewal. The subscription id is the customer's, the invoice id is what
  # makes the grant idempotent across Stripe's retries.
  defp handle_stripe(%{"type" => "invoice.paid", "data" => %{"object" => invoice}}) do
    case invoice["subscription"] do
      id when is_binary(id) -> Subscriptions.record_payment(id, invoice["id"], nil)
      _ -> :ok
    end

    :ok
  end

  defp handle_stripe(%{"type" => type, "data" => %{"object" => object}})
       when type in ["customer.subscription.deleted", "customer.subscription.updated"] do
    Subscriptions.set_status(object["id"], object["status"] || "cancelled", object)
    :ok
  end

  defp handle_stripe(_event), do: :ok

  # Two ways a seat arrives. From /checkout there is already a pending row, keyed
  # on the session because the subscription did not exist yet; it is re-keyed
  # here. From a $999 CTA there is no row and no account at all — Stripe
  # collected the address, so both are created now, which is the first moment
  # anything has been paid for.
  defp grant_seat(session) do
    with id when is_binary(id) <- session["subscription"] do
      case Subscriptions.attach_stripe_subscription(session["id"], id, session) do
        {:ok, _} ->
          Subscriptions.record_payment(id, session["id"], nil)

        {:error, :unknown_subscription} ->
          with {:ok, account_id} <- Stripe.account_for(session),
               {:ok, _} <- Subscriptions.open_from_session(account_id, id, session) do
            Subscriptions.record_payment(id, session["id"], nil)
          end
      end
    end
  end

  defp credit_stripe_payment(session) do
    case Stripe.record_payment(session) do
      {:ok, payment} -> Stripe.credit_payment(payment)
      other -> other
    end
  end

  defp paypal_webhook(conn, params) do
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

  # Each payment on a subscription grants that month's credit. This is the event
  # that means money actually moved, which is why the grant hangs off it rather
  # than off activation.
  defp handle_event(%{"event_type" => "PAYMENT.SALE.COMPLETED", "resource" => resource}) do
    case resource["billing_agreement_id"] do
      id when is_binary(id) -> Subscriptions.record_payment(id, resource["id"])
      _ -> :ok
    end
  end

  # A subscription with no trial period is charged on activation, and PayPal
  # does not always send the sale event for that first charge before this one.
  # Granting here too is safe: a grant replaces rather than accumulates, so the
  # customer ends up with exactly one month either way.
  defp handle_event(%{"event_type" => "BILLING.SUBSCRIPTION.ACTIVATED", "resource" => resource}) do
    case resource["id"] do
      id when is_binary(id) ->
        Subscriptions.record_payment(id, resource["id"], Subscriptions.next_billing(resource))

      _ ->
        :ok
    end
  end

  defp handle_event(%{"event_type" => "BILLING.SUBSCRIPTION." <> change, "resource" => resource})
       when change in ~w(CANCELLED SUSPENDED EXPIRED) do
    case resource["id"] do
      id when is_binary(id) -> Subscriptions.set_status(id, change, resource)
      _ -> :ok
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
