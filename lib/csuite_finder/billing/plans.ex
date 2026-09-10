defmodule CsuiteFinder.Billing.Plans do
  @moduledoc """
  The seat plan — the other half of the business.

  Two ways to buy the same data, aimed at people who want different things:

    * **Credit** (developers): buy a balance, spend it per answer, $0.0025 an
      address and $0.025 a number. Bought credit never expires.

    * **A seat** (sales, founders): $999 a month per person, which puts $999 of
      credit in the account every month. Suits someone who wants the app and a
      predictable invoice rather than a meter to watch.

  A seat's dollar is the same dollar credit buys — the price of a lookup does
  not change with how you paid for it. What differs is the lifetime: **a seat's
  monthly credit does not roll over.** Each renewal replaces the allowance
  rather than stacking on it, so an unused month is spent capacity, not banked
  capacity. That is what makes the subscription a subscription; if it
  accumulated, a customer could pay for a year, use nothing, and then run
  $12,000 of lookups in a week against one month's revenue.

  Anything bought outright sits in a separate pool and is untouched by that —
  see `CsuiteFinder.Billing` for how the two are spent.
  """

  alias CsuiteFinder.Billing.Pricing

  @seat_usd_per_month 999

  @doc "Price of one seat, per month, in USD."
  @spec seat_usd() :: pos_integer()
  def seat_usd, do: @seat_usd_per_month

  @doc "Price of one seat, per month, in micro-USD."
  @spec seat_micro() :: pos_integer()
  def seat_micro, do: Pricing.micro(@seat_usd_per_month)

  @doc """
  Credit a seat grants each month, in micro-USD.

  Equal to the price. A seat is not a discount and not a markup — it is the
  same credit on a subscription, with an app around it.
  """
  @spec seat_grant_micro() :: pos_integer()
  def seat_grant_micro, do: seat_micro()

  @doc """
  When a seat's grant, made now, lapses.

  One month, matching the billing period: the next payment replaces it, and a
  cancelled subscription stops granting rather than needing to be clawed back.
  """
  @spec seat_grant_expires_at(DateTime.t()) :: DateTime.t()
  def seat_grant_expires_at(from \\ DateTime.utc_now()) do
    DateTime.shift(from, month: 1)
  end

  @doc "What one seat's monthly credit buys, in lookups, at list price."
  @spec seat_lookups() :: map()
  def seat_lookups do
    %{
      emails: div(seat_grant_micro(), Pricing.charge_for("email.find")),
      phones: div(seat_grant_micro(), Pricing.charge_for("phone.find"))
    }
  end

  @doc """
  What a seat includes, for the pricing page.

  Derived from the same constants the billing uses, so the page cannot
  advertise an allowance the code does not honour.
  """
  @spec seat() :: map()
  def seat do
    lookups = seat_lookups()

    %{
      usd_per_month: @seat_usd_per_month,
      credit_usd: @seat_usd_per_month,
      lookups: lookups,
      includes: [
        "$#{delimit(@seat_usd_per_month)} of credit every month — around #{delimit(lookups.emails)} work email addresses",
        "Every lookup: work emails, deliverability, enrichment and company data",
        "Works with ChatGPT, Claude or any AI assistant — your team asks in plain English",
        "Everything you look up is kept, so asking again answers instantly",
        "Email support"
      ],
      # Said plainly rather than in a footnote. A customer who discovers this at
      # renewal feels cheated; one who is told up front is buying a month of
      # capacity and knows it.
      caveats: [
        "Unused credit does not roll over — each month starts at $#{delimit(@seat_usd_per_month)}.",
        "Trying it first costs $#{Pricing.trial_usd()}, once, and that credit expires with the month too.",
        "Credit you buy outright never expires, and a seat does not touch it.",
        "Cancel any time; the month you have paid for runs to its end."
      ]
    }
  end

  @doc "How the two ways of buying compare, for the pricing page."
  @spec comparison() :: [map()]
  def comparison do
    [
      %{
        question: "How you pay",
        seat: "$#{delimit(@seat_usd_per_month)} a month, per person",
        credit: "Up front, from $#{delimit(Pricing.min_bundle_usd())}"
      },
      %{
        question: "What that buys",
        seat: "$#{delimit(@seat_usd_per_month)} of credit each month",
        credit: "A dollar of credit per dollar paid"
      },
      %{
        question: "When it expires",
        seat: "At the end of the month — it does not roll over",
        credit: "Never"
      },
      %{
        question: "What a lookup costs",
        seat: "The same: $#{fmt(Pricing.price_usd("email.find"))} a work email address",
        credit: "$#{fmt(Pricing.price_usd("email.find"))} a work email address"
      },
      %{
        question: "How you use it",
        seat: "In the browser — search, save, export",
        credit: "Over the API, from your own code"
      },
      %{
        question: "Best for",
        seat: "Sales teams and founders doing outreach every month",
        credit: "Engineers building lookups into a product"
      }
    ]
  end

  defp fmt(usd), do: :erlang.float_to_binary(usd, [:compact, decimals: 4])

  defp delimit(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
