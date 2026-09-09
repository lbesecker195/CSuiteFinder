defmodule CsuiteFinderWeb.SampleSheet do
  @moduledoc """
  The sample spreadsheet on the sales page.

  Real output. Every row here was produced by calling this service's own API on
  2026-09-09 — ten chief executives of Fortune 500 fintech companies, resolved
  from nothing but a name and a company domain, then each address checked
  against the live mailbox.

  Two deliberate choices about what is shown:

    * **Addresses are masked.** The first two letters of each name-part survive
      along with every separator, so a reader can see that Visa builds
      `flast`, Mastercard builds `first_last` and Amex builds `first.last` —
      which is the thing worth demonstrating. What they cannot do is write to
      anyone. These are real people; a public page is not the place to hand out
      their inbox, and no marketing point is worth doing that.

    * **The verification column shows what actually came back**, including the
      two addresses that did not verify and the six domains that accept all
      mail. A sheet of ten green ticks would be a nicer picture and a worse
      claim, and the amber and red rows are the deliverability check doing its
      job in public.

  The phone column is empty because no provider we route to holds a direct
  number for any of these ten. That is true of the C-suite at companies this
  size generally; numbers do resolve further down the org chart. It is shown
  rather than hidden for the same reason as the red rows.
  """

  @generated_on ~D[2026-09-09]

  @rows [
    %{
      name: "Ryan McInerney",
      company: "Visa",
      email: "rm••••••••@visa.com",
      phone: nil,
      status: :accept_all
    },
    %{
      name: "Michael Miebach",
      company: "Mastercard",
      email: "mi•••••_mi•••••@mastercard.com",
      phone: nil,
      status: :verified
    },
    %{
      name: "Alex Chriss",
      company: "PayPal",
      email: "ac•••••@paypal.com",
      phone: nil,
      status: :accept_all
    },
    %{
      name: "Stephen Squeri",
      company: "American Express",
      email: "st•••••.sq••••@americanexpress.com",
      phone: nil,
      status: :undeliverable
    },
    %{
      name: "Stephanie Ferris",
      company: "FIS",
      email: "st•••••••.fe••••@fisglobal.com",
      phone: nil,
      status: :accept_all
    },
    %{
      name: "Cameron Bready",
      company: "Global Payments",
      email: "ca•••••.br••••@globalpayments.com",
      phone: nil,
      status: :accept_all
    },
    %{
      name: "Richard Fairbank",
      company: "Capital One",
      email: "ri•••••.fa••••••@capitalone.com",
      phone: nil,
      status: :accept_all
    },
    %{
      name: "Sasan Goodarzi",
      company: "Intuit",
      email: "sa•••_go••••••@intuit.com",
      phone: nil,
      status: :verified
    },
    %{
      name: "Michael Rhodes",
      company: "Fiserv",
      email: "mi•••••.rh••••@fiserv.com",
      phone: nil,
      status: :accept_all
    },
    %{
      name: "Michael Shepherd",
      company: "Discover",
      email: "mi•••••••••••••@discover.com",
      phone: nil,
      status: :undeliverable
    }
  ]

  @labels %{verified: "Verified", accept_all: "Accept-all", undeliverable: "Undeliverable"}

  @doc "The rows, in sheet order."
  @spec rows() :: [map()]
  def rows, do: @rows

  @doc "When these lookups were run."
  @spec generated_on() :: Date.t()
  def generated_on, do: @generated_on

  @doc "The word shown in the Verified column."
  @spec label(atom()) :: String.t()
  def label(status), do: Map.get(@labels, status, "Unknown")

  @doc "A CSS modifier for the status cell."
  @spec status_class(atom()) :: String.t()
  def status_class(:verified), do: "ok"
  def status_class(:accept_all), do: "warn"
  def status_class(:undeliverable), do: "bad"
  def status_class(_), do: ""

  @doc "The tick, dash or cross that goes with a status."
  @spec mark(atom()) :: String.t()
  def mark(:verified), do: "✓"
  def mark(:accept_all), do: "~"
  def mark(:undeliverable), do: "✗"
  def mark(_), do: ""
end
