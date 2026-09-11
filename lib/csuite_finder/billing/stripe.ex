defmodule CsuiteFinder.Billing.Stripe do
  @moduledoc """
  Stripe, through hosted Checkout.

  We never see a card. Every purchase is a Checkout Session — Stripe hosts the
  page, collects the card and the email, and tells us what happened over a
  webhook. That keeps card data out of this application entirely, and it is why
  there is no publishable key here: nothing is rendered client-side.

  Three kinds of purchase, two Stripe modes:

    * a **seat** is `mode: subscription` against a price created in the
      dashboard, monthly or annual;
    * the **trial** and a **top-up** are `mode: payment` with the amount built
      inline, so the price a customer is charged comes from `Pricing` and cannot
      drift from what the site quotes.

  `client_reference_id` carries our account id through Stripe and back on the
  webhook. It is how a payment finds its account without trusting anything the
  customer typed.
  """

  require Logger

  alias CsuiteFinder.Accounts
  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing.{Payment, Pricing}
  alias CsuiteFinder.Repo

  @api "https://api.stripe.com/v1"
  # Stripe's own tolerance for replayed webhooks.
  @tolerance_seconds 300

  # ----------------------------------------------------------------- checkout

  @doc """
  A Checkout Session for one seat subscription.

  `seats` becomes the line quantity, so three seats is one subscription at three
  times the price rather than three subscriptions to reconcile.
  """
  @spec create_seat_session(Account.t() | nil, pos_integer(), :month | :year, keyword()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def create_seat_session(account, seats, interval \\ :month, opts \\ []) do
    # Checked before the price, and before anything is sent: without a key this
    # would otherwise reach api.stripe.com with `Basic bmlsOg==` and wait out a
    # 30-second timeout to be told what we already knew.
    cond do
      not configured?() ->
        {:error, :stripe_not_configured}

      is_nil(price_id(interval)) ->
        {:error, :stripe_price_not_configured}

      true ->
        price = price_id(interval)

        [
          {"mode", "subscription"},
          {"line_items[0][price]", price},
          {"line_items[0][quantity]", to_string(seats)},
          {"subscription_data[metadata][interval]", to_string(interval)},
          {"subscription_data[metadata][seats]", to_string(seats)},
          {"metadata[interval]", to_string(interval)},
          {"metadata[seats]", to_string(seats)}
        ]
        |> common(account, opts)
        |> session()
    end
  end

  @doc """
  A Checkout Session for a one-off charge — the trial, or a top-up.

  The amount is built inline rather than referring to a dashboard price: these
  numbers come from `Pricing`, and a price object would be a second place to
  change them.
  """
  @spec create_payment_session(Account.t(), number(), String.t(), keyword()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def create_payment_session(%Account{} = account, amount_usd, kind, opts \\ []) do
    if not configured?() do
      {:error, :stripe_not_configured}
    else
      build_payment_session(account, amount_usd, kind, opts)
    end
  end

  defp build_payment_session(account, amount_usd, kind, opts) do
    [
      {"mode", "payment"},
      {"line_items[0][price_data][currency]", "usd"},
      {"line_items[0][price_data][unit_amount]", to_string(round(amount_usd * 100))},
      {"line_items[0][price_data][product_data][name]", describe(kind)},
      {"line_items[0][quantity]", "1"},
      {"payment_intent_data[metadata][account_id]", to_string(account.id)},
      {"payment_intent_data[metadata][kind]", kind},
      {"metadata[kind]", kind}
    ]
    |> common(account, opts)
    |> session()
  end

  # `account` may be nil. That is the whole point of buying before registering:
  # there is nobody to reference yet, Checkout collects the address, and the
  # account is opened from it when the payment completes. Anything we already
  # know is still sent, so someone arriving from a campaign link does not retype
  # an address we were given in the URL.
  defp common(fields, account, opts) do
    identity =
      case account do
        %Account{} = a ->
          [
            {"client_reference_id", "account_#{a.id}"},
            {"customer_email", a.email},
            {"metadata[account_id]", to_string(a.id)}
          ]

        _ ->
          [{"customer_email", Keyword.get(opts, :email)}]
      end

    (fields ++
       identity ++
       [
         {"success_url", Keyword.get(opts, :return_url, "")},
         {"cancel_url", Keyword.get(opts, :cancel_url, "")}
       ])
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
  end

  defp session(fields) do
    case post("/checkout/sessions", fields) do
      {:ok, %{status: status, body: %{"url" => url} = body}} when status in 200..299 ->
        {:ok, url, body}

      {:ok, %{body: %{"error" => %{"message" => message}}}} ->
        Logger.warning("stripe checkout refused: #{message}")
        {:error, :stripe_refused}

      other ->
        Logger.warning("stripe checkout failed: #{inspect(other)}")
        {:error, :stripe_unavailable}
    end
  end

  defp describe("seat_trial"),
    do: "CSuiteFinder trial — #{Pricing.trial_months()} month of credit"

  defp describe(_), do: "CSuiteFinder credit"

  # ------------------------------------------------------------- subscriptions

  @doc "Cancel a subscription at Stripe. The period already paid for runs on."
  @spec cancel_subscription(String.t()) :: {:ok, map()} | {:error, term()}
  def cancel_subscription(id) do
    case post("/subscriptions/#{id}", [{"cancel_at_period_end", "true"}]) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      other -> {:error, other}
    end
  end

  @doc """
  What was actually billed: how many seats, and how often.

  Read from the subscription's own line item rather than from metadata we
  attached. A Payment Link lets the buyer change the quantity on Stripe's page,
  and its metadata is set when the link is made, not when it is used — so
  metadata can say one seat while the customer bought five. The line item is
  what the card was charged for, and it is what the credit has to match.

  Falls back to one monthly seat, which under-grants rather than over-grants if
  Stripe cannot be reached: too little credit is a support message, too much is
  money given away.
  """
  @spec subscription_terms(String.t()) :: {:month | :year, pos_integer()}
  def subscription_terms(subscription_id) do
    with {:ok, subscription} <- get_subscription(subscription_id),
         [item | _] <- get_in(subscription, ["items", "data"]) do
      interval =
        case get_in(item, ["price", "recurring", "interval"]) do
          "year" -> :year
          _ -> :month
        end

      seats =
        case item["quantity"] do
          n when is_integer(n) and n > 0 -> n
          _ -> 1
        end

      {interval, seats}
    else
      other ->
        Logger.warning(
          "stripe: could not read subscription #{subscription_id}: #{inspect(other)}"
        )

        {:month, 1}
    end
  end

  @doc "Read a subscription back from Stripe."
  @spec get_subscription(String.t()) :: {:ok, map()} | {:error, term()}
  def get_subscription(id) do
    case Req.get(url: @api <> "/subscriptions/#{id}", auth: {:basic, secret_key() <> ":"}) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      other -> {:error, other}
    end
  end

  # ---------------------------------------------------------------- webhooks

  @doc """
  Check a webhook really came from Stripe.

  The signature is over the **raw** request body, so this takes the bytes rather
  than the parsed map: re-encoding a decoded body reorders keys and the hash
  stops matching. See `CsuiteFinderWeb.CacheBodyReader` for how the raw body
  survives the parser.

  The timestamp is checked as well as the hash. A signature stays valid forever
  otherwise, so a captured request could be replayed back at us for as long as
  the endpoint exists.
  """
  @spec verify_webhook(binary(), String.t() | nil) :: :ok | {:error, atom()}
  def verify_webhook(raw_body, signature_header)

  def verify_webhook(_raw, nil), do: {:error, :missing_signature}

  def verify_webhook(raw_body, header) when is_binary(raw_body) and is_binary(header) do
    with secret when is_binary(secret) <- webhook_secret(),
         {:ok, timestamp, signatures} <- parse_signature(header),
         :ok <- check_age(timestamp) do
      expected =
        :hmac
        |> :crypto.mac(:sha256, secret, "#{timestamp}.#{raw_body}")
        |> Base.encode16(case: :lower)

      # Constant time, and against every v1 signature present: Stripe sends more
      # than one while a signing secret is being rolled.
      if Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)) do
        :ok
      else
        {:error, :invalid_signature}
      end
    else
      nil -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_signature(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    timestamp =
      Enum.find_value(parts, fn
        ["t", v] -> v
        _ -> nil
      end)

    signatures = for ["v1", v] <- parts, do: v

    if timestamp && signatures != [] do
      {:ok, timestamp, signatures}
    else
      {:error, :malformed_signature}
    end
  end

  defp check_age(timestamp) do
    with {seconds, _} <- Integer.parse(timestamp),
         age when age <= @tolerance_seconds <- abs(System.system_time(:second) - seconds) do
      :ok
    else
      _ -> {:error, :timestamp_out_of_tolerance}
    end
  end

  # ------------------------------------------------------------------ payments

  @doc """
  Record a completed one-off Checkout Session and credit the account.

  Keyed on the session id, which is unique per purchase, so a webhook Stripe
  retries — and it does retry — credits once.
  """
  @spec record_payment(map()) :: {:ok, Payment.t()} | {:error, term()}
  def record_payment(%{"id" => session_id} = session) do
    with {:ok, account_id} <- account_for(session),
         nil <- Repo.get_by(Payment, provider: "stripe", provider_ref: session_id) do
      amount_micro = (session["amount_total"] || 0) * 10_000
      kind = get_in(session, ["metadata", "kind"]) || "topup"

      %Payment{}
      |> Payment.changeset(%{
        provider: "stripe",
        account_id: account_id,
        provider_ref: session_id,
        provider_txn_id: session["payment_intent"],
        amount_micro: amount_micro,
        credit_micro: amount_micro,
        kind: kind,
        status: "created",
        raw: session
      })
      |> Repo.insert()
    else
      %Payment{} = already -> {:ok, already}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_payment(_), do: {:error, :malformed_session}

  @doc """
  Credit a paid session, once.

  Idempotent on `credited_at`: Stripe retries a webhook until it gets a 2xx, and
  a second delivery of the same session must not buy a second lot of credit. The
  amount comes from what Stripe says was collected, never from anything the
  caller sent — a tampered request buys exactly what it paid for.
  """
  @spec credit_payment(Payment.t()) :: {:ok, Payment.t()} | {:error, term()}
  def credit_payment(%Payment{credited_at: nil} = payment) do
    credit_micro = Pricing.credit_for_purchase(payment.amount_micro / 1_000_000)

    Repo.transaction(fn ->
      account = Repo.get!(CsuiteFinder.Accounts.Account, payment.account_id)
      apply_credit(account, payment.kind, credit_micro)

      payment
      |> Payment.changeset(%{
        status: "credited",
        credit_micro: credit_micro,
        credited_at: DateTime.utc_now()
      })
      |> Repo.update!()
    end)
  end

  def credit_payment(%Payment{} = already), do: {:ok, already}

  # A top-up is credit bought outright and never expires. A trial is a month of
  # the seat, so it lands in the expiring pool and stamps the account as having
  # taken its one trial.
  defp apply_credit(account, "seat_trial", credit_micro) do
    {:ok, _} = CsuiteFinder.Billing.grant(account, credit_micro, Pricing.trial_expires_at())

    account
    |> CsuiteFinder.Accounts.Account.changeset(%{trial_granted_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp apply_credit(account, _kind, credit_micro) do
    {:ok, _} = CsuiteFinder.Billing.credit(account, credit_micro)
  end

  @doc """
  The account this payment belongs to, creating one if the buyer had none.

  Checkout collects an email address itself, which is what makes a purchase
  possible with no account and no form in front of it: someone can click a price
  and pay, and the account is built afterwards from the address they gave
  Stripe. That address is the one the receipt went to, so it is also the one
  they will expect to sign in with.

  An account we already know is matched by id first and by address second —
  paying twice must not produce two accounts for one person.
  """
  @spec account_for(map()) :: {:ok, integer()} | {:error, term()}
  def account_for(session) do
    case account_id_from(session) do
      {:ok, id} ->
        {:ok, id}

      {:error, :no_account} ->
        session
        |> buyer_email()
        |> find_or_create_account()
    end
  end

  defp buyer_email(session) do
    get_in(session, ["customer_details", "email"]) || session["customer_email"]
  end

  defp find_or_create_account(nil), do: {:error, :no_account}

  defp find_or_create_account(email) do
    case Accounts.get_account_by_email(email) do
      %{id: id} ->
        {:ok, id}

      nil ->
        # Opened as a sales account: only a seat or a trial can reach this path,
        # and both are the sales product. No password — one is asked for on the
        # account page once there is something worth signing in to protect.
        case Accounts.register(%{email: email, audience: "sales"}) do
          {:ok, %{account: account}} ->
            Logger.info("stripe: opened an account for #{email} from a completed purchase")
            {:ok, account.id}

          {:error, reason} ->
            Logger.error("stripe: could not open an account for #{email}: #{inspect(reason)}")
            {:error, :account_creation_failed}
        end
    end
  end

  @doc "The account id Stripe carried for us, from whichever field holds it."
  @spec account_id_from(map()) :: {:ok, integer()} | {:error, :no_account}
  def account_id_from(session) do
    raw =
      get_in(session, ["metadata", "account_id"]) ||
        case session["client_reference_id"] do
          "account_" <> id -> id
          _ -> nil
        end

    case raw && Integer.parse(to_string(raw)) do
      {id, _} -> {:ok, id}
      _ -> {:error, :no_account}
    end
  end

  # ------------------------------------------------------------------- config

  defp post(path, fields) do
    Req.post(
      url: @api <> path,
      form: fields,
      auth: {:basic, secret_key() <> ":"},
      receive_timeout: 30_000
    )
  end

  defp config, do: Application.get_env(:csuite_finder, __MODULE__, [])

  @doc false
  def secret_key, do: config()[:secret_key]

  @doc false
  def webhook_secret, do: config()[:webhook_secret]

  @doc "The price id for a seat at this interval, or nil if it is not configured."
  @spec price_id(:month | :year) :: String.t() | nil
  def price_id(:year), do: config()[:seat_annual_price_id]
  def price_id(_), do: config()[:seat_price_id]

  @doc "Is Stripe wired up in this environment?"
  @spec configured?() :: boolean()
  def configured?, do: is_binary(secret_key()) and secret_key() != ""

  @doc "Are webhooks verifiable in this environment?"
  @spec webhooks_configured?() :: boolean()
  def webhooks_configured?, do: is_binary(webhook_secret()) and webhook_secret() != ""

  @doc "\"live\" or \"test\", read from the key itself."
  @spec mode() :: String.t()
  def mode do
    case secret_key() do
      "sk_live_" <> _ -> "live"
      "rk_live_" <> _ -> "live"
      _ -> "test"
    end
  end
end
