defmodule CsuiteFinder.Billing.Plans do
  @moduledoc """
  The seat plan — the other half of the business.

  Two ways to buy the same data, aimed at people who want different things:

    * **Credit** (developers): pay per answer, $0.0025 an address and $0.025 a
      number, and think about cost. Suits a script that runs a thousand lookups
      and wants the bill to reflect that.

    * **A seat** (sales, founders): $999 a month per person, lookups included,
      and never think about cost again. Suits someone who wants to work rather
      than watch a meter.

  The seat carries a fair-use ceiling rather than being literally unlimited. A
  person cannot research more than a few hundred prospects a month; a script
  behind one seat could run a million lookups and turn a $999 subscription into
  a $2,500 loss. The ceiling sits far above any human's use and well below that
  — stated plainly, because an "unlimited" plan with a secret limit is worse
  than a stated one.
  """

  alias CsuiteFinder.Billing.Pricing

  @seat_usd_per_month 999

  # Lookups a seat includes each month. Roughly twenty a working day sustained,
  # which no salesperson reaches — it is there to bound automated use, not to
  # ration real work.
  @fair_use_lookups 5_000

  @doc "Price of one seat, per month, in USD."
  @spec seat_usd() :: pos_integer()
  def seat_usd, do: @seat_usd_per_month

  @doc "Price of one seat, per month, in micro-USD."
  @spec seat_micro() :: pos_integer()
  def seat_micro, do: Pricing.micro(@seat_usd_per_month)

  @doc "Lookups included per seat per month."
  @spec fair_use_lookups() :: pos_integer()
  def fair_use_lookups, do: @fair_use_lookups

  @doc """
  What a seat's fair use costs us at list price, in micro-USD.

  Worth keeping visible internally: a seat is sold on the app around the data,
  not on the data, and the two numbers are nowhere near each other. If a
  customer only wants the feed, credit is cheaper for them and we should say so
  — a seat sold to someone who wanted an API churns in a month.
  """
  @spec seat_allowance_micro() :: pos_integer()
  def seat_allowance_micro, do: @fair_use_lookups * Pricing.charge_for("phone.find")

  @doc """
  What a seat includes, for the pricing page.

  Everything here is derived from the same constants the billing uses, so the
  page cannot advertise an allowance the code does not honour.
  """
  @spec seat() :: map()
  def seat do
    %{
      usd_per_month: @seat_usd_per_month,
      fair_use_lookups: @fair_use_lookups,
      includes: [
        "Every lookup: work emails, phone numbers, deliverability, enrichment and company data",
        "Fair use of #{delimit(@fair_use_lookups)} lookups a month — far more than a person researches",
        "The browser app, no API key or terminal required",
        "Your team's own lookups, kept and searchable",
        "Email support"
      ]
    }
  end

  @doc "How the two ways of buying compare, for the pricing page."
  @spec comparison() :: [map()]
  def comparison do
    [
      %{
        question: "How you pay",
        seat: "$#{@seat_usd_per_month} a month, per person",
        credit:
          "Per answer: $#{fmt(Pricing.price_usd("email.find"))} an email, $#{fmt(Pricing.price_usd("phone.find"))} a phone"
      },
      %{
        question: "How you use it",
        seat: "In the browser — search, save, export",
        credit: "Over the API, from your own code"
      },
      %{
        question: "Best for",
        seat: "Sales teams and founders doing outreach",
        credit: "Engineers building lookups into a product"
      },
      %{
        question: "What happens at volume",
        seat: "Included, up to fair use",
        credit: "You pay for exactly what you use, with no floor"
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
