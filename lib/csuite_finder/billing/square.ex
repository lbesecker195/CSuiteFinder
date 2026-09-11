defmodule CsuiteFinder.Billing.Square do
  @moduledoc """
  Square, through hosted Payment Links.

  Same shape as the Stripe gateway beside it: we never see a card, Square hosts
  the page and collects the buyer's email, and a webhook tells us what happened.
  The differences from Stripe are Square's, not ours, and there are three worth
  knowing because they change what the calling code can assume.

    * **Every write needs an idempotency key.** Square requires one on creation
      calls, which is a better default than Stripe's — a retried request cannot
      double-charge.

    * **Everything is scoped to a location.** A Square account can have several,
      and an order created against the wrong one lands in the wrong ledger, so
      `location_id` is required rather than inferred.

    * **The webhook signature covers the URL as well as the body.** Square signs
      `notification_url <> body`, so the URL configured in the dashboard has to
      match ours character for character — a trailing slash is enough to reject
      every event.

  Subscriptions are the real gap and are handled in `seat_link/2`: see the note
  there before wiring a seat button to this.
  """

  require Logger

  alias CsuiteFinder.Accounts
  alias CsuiteFinder.Accounts.Account
  alias CsuiteFinder.Billing.{Payment, Pricing}
  alias CsuiteFinder.Repo

  # Pinned. Square dates its API and changes behaviour between versions, so a
  # deployment that silently followed "latest" would change what it does without
  # anything in this repository changing.
  @version "2025-01-23"

  # ---------------------------------------------------------------- checkout

  @doc """
  A hosted payment page for a one-off charge — the trial, or a top-up.

  `quick_pay` builds the line from an amount rather than a catalogue object, so
  the price a customer is charged comes from `Pricing` and cannot drift from
  what the site quotes.
  """
  @spec create_payment_link(Account.t() | nil, number(), String.t(), keyword()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def create_payment_link(account, amount_usd, kind, opts \\ []) do
    cond do
      not configured?() ->
        {:error, :square_not_configured}

      is_nil(location_id()) ->
        {:error, :square_location_not_configured}

      true ->
        body = %{
          idempotency_key: idempotency_key(),
          quick_pay: %{
            name: describe(kind),
            price_money: %{amount: round(amount_usd * 100), currency: "USD"},
            location_id: location_id()
          },
          checkout_options: %{
            redirect_url: Keyword.get(opts, :return_url),
            ask_for_shipping_address: false
          },
          pre_populated_data: %{buyer_email: buyer_email(account, opts)},
          # Carried through the order and handed back on the webhook. It is how
          # a payment finds its account without trusting anything the buyer
          # typed on Square's page.
          payment_note: reference(account, kind)
        }

        case post("/v2/online-checkout/payment-links", prune(body)) do
          {:error, :square_rejected_email} ->
            # Square validates the address and refuses some that look fine to
            # us — example.com among them. A prefill is a convenience, so
            # losing it is not worth losing the sale: drop it and go again, and
            # the buyer types their own address on Square's page.
            Logger.info("square: prefill address refused, retrying without it")

            body
            |> Map.delete(:pre_populated_data)
            |> prune()
            |> then(&post("/v2/online-checkout/payment-links", &1))

          other ->
            other
        end
    end
  end

  @doc """
  The link a seat button points at.

  **Square cannot start a card-on-file subscription from a hosted link.** Its
  Subscriptions API needs a customer and a stored card before a plan can be
  attached, which a one-page checkout does not produce — so unlike Stripe, "click
  the price, get billed monthly" is not one step here.

  Until that flow exists, this returns the configured link and nothing clever:
  set `SQUARE_SEAT_LINK` to a subscription plan's own checkout URL created in
  the Square dashboard. Returning an error rather than inventing a one-off
  charge is deliberate — taking $999 once from somebody who believes they are
  subscribing is the worst failure available here.
  """
  @spec seat_link(:month | :year) :: {:ok, String.t()} | {:error, :square_seat_link_missing}
  def seat_link(interval \\ :month) do
    case config()[seat_key(interval)] do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :square_seat_link_missing}
    end
  end

  defp seat_key(:year), do: :seat_annual_link
  defp seat_key(_), do: :seat_link

  defp post(path, body) do
    case request(path, body) do
      {:ok, %{status: status, body: %{"payment_link" => %{"url" => url} = link}}}
      when status in 200..299 ->
        {:ok, url, link}

      {:ok, %{body: %{"errors" => [%{"code" => "INVALID_EMAIL_ADDRESS"} | _]}}} ->
        {:error, :square_rejected_email}

      {:ok, %{body: %{"errors" => [%{"detail" => detail} | _]}}} ->
        Logger.warning("square refused: #{detail}")
        {:error, :square_refused}

      other ->
        Logger.warning("square call failed: #{inspect(other)}")
        {:error, :square_unavailable}
    end
  end

  defp request(path, body) do
    Req.post(
      url: base_url() <> path,
      json: body,
      headers: [
        {"authorization", "Bearer " <> access_token()},
        {"square-version", @version}
      ],
      receive_timeout: 30_000
    )
  end

  defp describe("seat_trial"),
    do: "CSuiteFinder trial — #{Pricing.trial_months()} month of credit"

  defp describe(_), do: "CSuiteFinder credit"

  defp reference(%Account{id: id}, kind), do: "account_#{id}|#{kind}"
  defp reference(_, kind), do: "account_new|#{kind}"

  defp buyer_email(%Account{email: email}, _opts), do: email
  defp buyer_email(_, opts), do: Keyword.get(opts, :email)

  # Square rejects nulls where Stripe ignores them, so empty fields come out
  # before the request rather than being sent and argued about.
  defp prune(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {k, prune(v)} end)
    |> Enum.reject(fn {_k, v} -> v in [nil, "", %{}] end)
    |> Map.new()
  end

  defp prune(other), do: other

  defp idempotency_key, do: Ecto.UUID.generate()

  # ---------------------------------------------------------------- webhooks

  @doc """
  Check a webhook really came from Square.

  Square signs `notification_url <> body` and base64-encodes it — the URL is
  part of the signed material, which Stripe's scheme does not do. So the URL
  configured in Square's dashboard has to match what is passed here exactly; a
  trailing slash or http-for-https rejects every event, and the failure looks
  identical to a forged request.

  Takes the raw bytes: re-encoding a parsed body reorders keys and the hash
  stops matching. See `CsuiteFinderWeb.CacheBodyReader`.
  """
  @spec verify_webhook(binary(), String.t() | nil, String.t()) :: :ok | {:error, atom()}
  def verify_webhook(raw_body, signature, notification_url)

  def verify_webhook(_raw, nil, _url), do: {:error, :missing_signature}

  def verify_webhook(raw_body, signature, notification_url)
      when is_binary(raw_body) and is_binary(signature) do
    case signature_key() do
      key when is_binary(key) and key != "" ->
        expected =
          :hmac
          |> :crypto.mac(:sha256, key, notification_url <> raw_body)
          |> Base.encode64()

        if Plug.Crypto.secure_compare(signature, expected) do
          :ok
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :not_configured}
    end
  end

  # ----------------------------------------------------------------- payments

  @doc """
  Record a completed payment and credit the account, once.

  Keyed on Square's payment id, so a webhook Square retries — and it does —
  credits a single time.
  """
  @spec record_payment(map()) :: {:ok, Payment.t()} | {:error, term()}
  def record_payment(%{"id" => payment_id} = payment) do
    with {:ok, account_id} <- account_for(payment),
         nil <- Repo.get_by(Payment, provider: "square", provider_ref: payment_id) do
      amount_micro = (get_in(payment, ["amount_money", "amount"]) || 0) * 10_000

      %Payment{}
      |> Payment.changeset(%{
        provider: "square",
        account_id: account_id,
        provider_ref: payment_id,
        provider_txn_id: payment["order_id"],
        amount_micro: amount_micro,
        credit_micro: amount_micro,
        kind: kind_from(payment),
        status: "created",
        raw: payment
      })
      |> Repo.insert()
    else
      %Payment{} = already -> {:ok, already}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_payment(_), do: {:error, :malformed_payment}

  @doc "Credit a recorded payment. Idempotent on `credited_at`."
  @spec credit_payment(Payment.t()) :: {:ok, Payment.t()} | {:error, term()}
  def credit_payment(%Payment{credited_at: nil} = payment) do
    credit_micro = Pricing.credit_for_purchase(payment.amount_micro / 1_000_000)

    Repo.transaction(fn ->
      account = Repo.get!(Account, payment.account_id)
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

  defp apply_credit(account, "seat_trial", credit_micro) do
    {:ok, _} = CsuiteFinder.Billing.grant(account, credit_micro, Pricing.trial_expires_at())

    account
    |> Account.changeset(%{trial_granted_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp apply_credit(account, _kind, credit_micro) do
    {:ok, _} = CsuiteFinder.Billing.credit(account, credit_micro)
  end

  @doc """
  The account a payment belongs to, opening one from the buyer's address if it
  has none.

  Same rule as the Stripe gateway: pay first, register second. The note we set
  on the order is checked before the email, because an account we already knew
  about is a fact and the address on a receipt is a claim.
  """
  @spec account_for(map()) :: {:ok, integer()} | {:error, term()}
  def account_for(payment) do
    case account_id_from(payment) do
      {:ok, id} -> {:ok, id}
      {:error, :no_account} -> payment |> buyer_email_from() |> find_or_create()
    end
  end

  @doc "The account id we stamped on the order, if it is one we already had."
  @spec account_id_from(map()) :: {:ok, integer()} | {:error, :no_account}
  def account_id_from(payment) do
    with note when is_binary(note) <- payment["note"],
         ["account_" <> id, _kind] <- String.split(note, "|", parts: 2),
         {parsed, _} <- Integer.parse(id) do
      {:ok, parsed}
    else
      _ -> {:error, :no_account}
    end
  end

  defp kind_from(payment) do
    case payment["note"] do
      note when is_binary(note) ->
        case String.split(note, "|", parts: 2) do
          [_, kind] when kind != "" -> kind
          _ -> "topup"
        end

      _ ->
        "topup"
    end
  end

  defp buyer_email_from(payment) do
    get_in(payment, ["buyer_email_address"]) ||
      get_in(payment, ["shipping_address", "email"])
  end

  defp find_or_create(nil), do: {:error, :no_account}

  defp find_or_create(email) do
    case Accounts.get_account_by_email(email) do
      %{id: id} ->
        {:ok, id}

      nil ->
        case Accounts.register(%{email: email, audience: "sales"}) do
          {:ok, %{account: account}} ->
            Logger.info("square: opened an account for #{email} from a completed payment")
            {:ok, account.id}

          {:error, reason} ->
            Logger.error("square: could not open an account for #{email}: #{inspect(reason)}")
            {:error, :account_creation_failed}
        end
    end
  end

  # ------------------------------------------------------------------- config

  defp config, do: Application.get_env(:csuite_finder, __MODULE__, [])

  @doc false
  def access_token, do: config()[:access_token]

  @doc false
  def signature_key, do: config()[:signature_key]

  @doc """
  The webhook URL Square was told about.

  Part of the signed material, so this has to be the exact string configured in
  Square's dashboard rather than something rebuilt from the request — a request
  arriving via a proxy can report a different host, and the signature would then
  fail for a genuine event.
  """
  @spec notification_url() :: String.t()
  def notification_url, do: config()[:notification_url] || ""

  @doc "The Square location every order is created against."
  @spec location_id() :: String.t() | nil
  def location_id, do: config()[:location_id]

  @doc "Sandbox or production, decided by configuration rather than guessed."
  @spec base_url() :: String.t()
  def base_url do
    config()[:base_url] ||
      if mode() == "production",
        do: "https://connect.squareup.com",
        else: "https://connect.squareupsandbox.com"
  end

  @doc "Is Square wired up in this environment?"
  @spec configured?() :: boolean()
  def configured?, do: is_binary(access_token()) and access_token() != ""

  @doc "Are webhooks verifiable in this environment?"
  @spec webhooks_configured?() :: boolean()
  def webhooks_configured?, do: is_binary(signature_key()) and signature_key() != ""

  @doc """
  "production" or "sandbox", set explicitly.

  Not inferred from the token, which was the first attempt and was wrong:
  Square's sandbox tokens begin `EAAA` exactly as production ones do — the
  sandbox token for this account does — so guessing pointed a sandbox token at
  the live API.

  **Sandbox is the default.** A missing setting should fail towards the
  environment where nothing real happens; the opposite default risks charging a
  real card because a variable was forgotten.
  """
  @spec mode() :: String.t()
  def mode do
    case config()[:env] do
      "production" -> "production"
      :production -> "production"
      _ -> "sandbox"
    end
  end
end
