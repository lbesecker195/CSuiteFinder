defmodule CsuiteFinder.Billing.Pricing do
  @moduledoc """
  Tokens are the unit of account. One token is $0.0025.

  Customers buy tokens in bundles of $1,000 or more and spend them per answer.
  Pricing the product in tokens rather than dollars means the per-endpoint rate
  can be tuned without repricing anything a customer already holds.

  Two rules decide most of an invoice:

    * **A miss is free.** If we cannot resolve the address, no tokens are taken.
      Customers are buying answers, not attempts.
    * **A cache hit costs the same as a fresh lookup.** The answer is identical
      to the caller, and the margin on repeat questions is exactly what pays for
      the lookups where we spend $0.02 and find nothing.
  """

  # Micro-USD per token: $0.0025.
  @micro_per_token 2_500

  # The smallest bundle we sell, in USD.
  @min_bundle_usd 1_000

  # Tokens granted to a new account, with no card and no commitment: $1.00.
  @trial_tokens 400

  # Only the find consumes tokens. Everything else is included, because the find
  # is the reason anyone is here — the follow-up questions (is it deliverable,
  # whose is it, what does the company look like) are what make a found address
  # worth having, and metering them would only push callers to ask fewer of them.
  #
  # They are included, not ungated: see `Billing.ensure_funds/2`. An account must
  # hold tokens to reach the API at all, so "free" means free to a customer, not
  # free to the internet.
  @prices %{
    "email.find" => 1,
    "email.deliverable" => 0,
    "email.enrich" => 0,
    "email.pattern" => 0,
    "name.who" => 0,
    "company.info" => 0,
    "company.find" => 0
  }

  @doc "Token price in micro-USD."
  @spec micro_per_token() :: pos_integer()
  def micro_per_token, do: @micro_per_token

  @doc "Token price in USD."
  @spec token_price_usd() :: float()
  def token_price_usd, do: @micro_per_token / 1_000_000

  @doc "Smallest purchasable bundle, in USD."
  @spec min_bundle_usd() :: pos_integer()
  def min_bundle_usd, do: @min_bundle_usd

  @doc "Free-trial grant, in tokens."
  @spec trial_tokens() :: pos_integer()
  def trial_tokens, do: @trial_tokens

  @doc "Cost of an endpoint, in tokens."
  @spec charge_for(String.t()) :: non_neg_integer()
  def charge_for(endpoint), do: Map.get(@prices, endpoint, 0)

  @doc "How many tokens `usd` buys."
  @spec tokens_for_usd(number()) :: non_neg_integer()
  def tokens_for_usd(usd), do: trunc(usd * 1_000_000 / @micro_per_token)

  @doc "What `tokens` are worth, in USD."
  @spec usd_for_tokens(integer()) :: float()
  def usd_for_tokens(tokens), do: Float.round(tokens * @micro_per_token / 1_000_000, 6)

  @doc """
  Validate a purchase amount against the bundle minimum.

  Enforced server-side rather than only in the UI, because the amount arrives
  from the client and the minimum is a commercial term, not a suggestion.
  """
  @spec validate_bundle(number()) ::
          {:ok, integer()} | {:error, :below_minimum, map()}
  def validate_bundle(usd) when is_number(usd) do
    if usd >= @min_bundle_usd do
      {:ok, tokens_for_usd(usd)}
    else
      {:error, :below_minimum,
       %{minimum_usd: @min_bundle_usd, requested_usd: usd, tokens_per_usd: tokens_for_usd(1)}}
    end
  end

  @doc "The price list, in tokens, for the pricing endpoint."
  @spec list() :: map()
  def list, do: @prices

  @doc "The price list expressed in dollars, for humans."
  @spec list_usd() :: map()
  def list_usd,
    do: Map.new(@prices, fn {endpoint, tokens} -> {endpoint, usd_for_tokens(tokens)} end)

  @doc "Everything a caller needs to understand what they are buying."
  @spec terms() :: map()
  def terms do
    %{
      token_price_usd: token_price_usd(),
      minimum_bundle_usd: @min_bundle_usd,
      tokens_per_minimum_bundle: tokens_for_usd(@min_bundle_usd),
      free_trial_tokens: @trial_tokens,
      free_trial_usd: usd_for_tokens(@trial_tokens),
      prices_in_tokens: @prices,
      prices_in_usd: list_usd(),
      billing_rules: [
        "Only /email/find costs a token. Every other endpoint is included.",
        "Included endpoints still need a positive token balance to call.",
        "Only answers are billed — a find that resolves nothing is free.",
        "A cached answer costs the same as a fresh one.",
        "Inferred (unverified) enrichment results are never billed."
      ]
    }
  end

  @doc """
  Does this endpoint consume tokens, or is it included with a balance?
  """
  @spec metered?(String.t()) :: boolean()
  def metered?(endpoint), do: charge_for(endpoint) > 0

  @doc "Should this outcome be billed? Only answers are."
  @spec billable?(String.t(), boolean()) :: boolean()
  def billable?(_endpoint, found?), do: found?
end
