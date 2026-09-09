defmodule CsuiteFinder.Billing.Pricing do
  @moduledoc """
  What we charge, in dollars.

  Prices are held as micro-USD integers — a millionth of a dollar — because
  money in floats accumulates error, and a rate of $0.0025 has no exact binary
  representation. Every figure a customer sees is derived from these integers.

  Two rules decide most of an invoice:

    * **A miss is free.** If we cannot resolve the thing, nothing is charged.
      Customers buy answers, not attempts.
    * **A cached answer costs the same as a fresh one.** The answer is identical
      to the caller, and the margin on repeat questions is what pays for the
      lookups that cost us $0.02 and find nothing.
  """

  @micro 1_000_000

  # Charged per answer, in micro-USD.
  @prices %{
    # An address resolved from a name.
    "email.find" => 2_500,
    # A phone number costs ten times an address: the data is scarcer, the
    # providers charge more for it, and it cannot be derived from a pattern the
    # way an address can.
    "phone.find" => 25_000,
    # Per person returned. The phone-bearing route buys a lookup for each one.
    "company.people" => 25_000,
    "email.company.people" => 2_500,
    # Included with any balance.
    "email.deliverable" => 0,
    "email.enrich" => 0,
    "email.pattern" => 0,
    "email.name" => 0,
    # Phone-input routes are answered from numbers we already hold: nothing to
    # buy, so nothing to charge beyond requiring a balance.
    "phone.name" => 0,
    "phone.enrich" => 0,
    "phone.company" => 0,
    "company.info" => 0,
    "company.find" => 0,
    "phone.valid" => 0
  }

  # The smallest purchase we sell, in USD.
  @min_bundle_usd 1_000

  # The amounts we offer. A dollar paid is a dollar of credit — no volume tier,
  # no bonus, nothing to reconcile later.
  @bundles [1_000, 2_000, 3_000]

  # Credit granted to a new account, with no card and no commitment.
  @trial_micro 1_000_000

  @doc "Charge for an endpoint, in micro-USD."
  @spec charge_for(String.t()) :: non_neg_integer()
  def charge_for(endpoint), do: Map.get(@prices, endpoint, 0)

  @doc "Charge for an endpoint, in USD."
  @spec price_usd(String.t()) :: float()
  def price_usd(endpoint), do: usd(charge_for(endpoint))

  @doc "Convert micro-USD to USD."
  @spec usd(integer()) :: float()
  def usd(micro), do: Float.round(micro / @micro, 6)

  @doc "Convert USD to micro-USD."
  @spec micro(number()) :: integer()
  def micro(amount), do: round(amount * @micro)

  @doc "The free trial grant, in micro-USD."
  @spec trial_micro() :: pos_integer()
  def trial_micro, do: @trial_micro

  @doc "The free trial grant, in USD."
  @spec trial_usd() :: float()
  def trial_usd, do: usd(@trial_micro)

  @doc "Smallest purchase, in USD."
  @spec min_bundle_usd() :: pos_integer()
  def min_bundle_usd, do: @min_bundle_usd

  @doc """
  What `usd` credits, in micro-USD.

  A dollar buys a dollar of credit at every size. Kept as its own function
  because the capture path must call something that cannot silently disagree
  with what the purchase page quoted.
  """
  @spec credit_for_purchase(number()) :: non_neg_integer()
  def credit_for_purchase(usd_paid), do: micro(usd_paid)

  @doc "The amounts offered for sale, smallest first."
  @spec bundles() :: [map()]
  def bundles do
    for usd <- @bundles do
      %{
        usd: usd,
        credit_usd: usd,
        # What it buys, in the units customers actually care about.
        emails: trunc(micro(usd) / max(charge_for("email.find"), 1)),
        phones: trunc(micro(usd) / max(charge_for("phone.find"), 1))
      }
    end
  end

  @doc """
  Validate a purchase against the minimum.

  Enforced server-side: the amount arrives from the client and the minimum is a
  commercial term, not a suggestion.
  """
  @spec validate_bundle(number()) :: {:ok, non_neg_integer()} | {:error, :below_minimum, map()}
  def validate_bundle(usd_paid) when is_number(usd_paid) do
    if usd_paid >= @min_bundle_usd do
      {:ok, credit_for_purchase(usd_paid)}
    else
      {:error, :below_minimum, %{minimum_usd: @min_bundle_usd, requested_usd: usd_paid}}
    end
  end

  @doc "The price list, in micro-USD."
  @spec list() :: map()
  def list, do: @prices

  @doc "The price list, in dollars."
  @spec list_usd() :: map()
  def list_usd, do: Map.new(@prices, fn {endpoint, m} -> {endpoint, usd(m)} end)

  @doc "Endpoints billed per result rather than per call."
  @spec per_result?(String.t()) :: boolean()
  def per_result?(endpoint), do: endpoint in ~w(company.people email.company.people)

  @doc "Does this endpoint cost anything, or is it included with a balance?"
  @spec metered?(String.t()) :: boolean()
  def metered?(endpoint), do: charge_for(endpoint) > 0

  @doc "Should this outcome be billed? Only answers are."
  @spec billable?(String.t(), boolean()) :: boolean()
  def billable?(_endpoint, found?), do: found?

  @doc "Everything a caller needs to understand what they are buying."
  @spec terms() :: map()
  def terms do
    %{
      currency: "USD",
      prices_usd: list_usd(),
      minimum_purchase_usd: @min_bundle_usd,
      free_trial_usd: trial_usd(),
      purchase_amounts_usd: @bundles,
      billing_rules: [
        "Charged per answer: $#{:erlang.float_to_binary(usd(@prices["email.find"]), [:compact, decimals: 4])} an email address, $#{:erlang.float_to_binary(usd(@prices["phone.find"]), [:compact, decimals: 4])} a phone number.",
        "Everything else is included, but still needs a positive balance.",
        "A lookup that finds nothing is free.",
        "A cached answer costs the same as a fresh one.",
        "Inferred (unverified) enrichment results are never billed."
      ]
    }
  end
end
