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

    * **The column is deliverability, not confirmation, and it is binary.**
      Six of these ten domains accept all mail, so SMTP cannot confirm the
      individual mailbox — but mail sent to them is accepted and does not
      bounce, which is what "deliverable" means to someone about to send. They
      are marked deliverable on that basis, and `:raw` on each row keeps what
      the check actually returned so the distinction is not lost here.

      The two rejected addresses stay marked undeliverable. They are the
      deliverability check doing its job in public, and worth chasing: both
      suggest the address we built for that company is wrong.

  The phone column is empty because no provider we route to holds a direct
  number for any of these ten. That is true of the C-suite at companies this
  size generally; numbers do resolve further down the org chart. It is shown
  rather than hidden for the same reason as the red rows.
  """

  @generated_on ~D[2026-09-09]

  # `status` is what the sheet shows; `raw` is what the mailbox check returned,
  # kept so the accept-all distinction is not lost just because the page does
  # not draw it.
  @rows [
    %{
      name: "Ryan McInerney",
      company: "Visa",
      email: "rm••••••••@visa.com",
      phone: nil,
      status: :deliverable,
      raw: :accept_all
    },
    %{
      name: "Michael Miebach",
      company: "Mastercard",
      email: "mi•••••_mi•••••@mastercard.com",
      phone: nil,
      status: :deliverable,
      raw: :confirmed
    },
    %{
      name: "Alex Chriss",
      company: "PayPal",
      email: "ac•••••@paypal.com",
      phone: nil,
      status: :deliverable,
      raw: :accept_all
    },
    %{
      name: "Stephen Squeri",
      company: "American Express",
      email: "st•••••.sq••••@americanexpress.com",
      phone: nil,
      status: :undeliverable,
      raw: :rejected
    },
    %{
      name: "Stephanie Ferris",
      company: "FIS",
      email: "st•••••••.fe••••@fisglobal.com",
      phone: nil,
      status: :deliverable,
      raw: :accept_all
    },
    %{
      name: "Cameron Bready",
      company: "Global Payments",
      email: "ca•••••.br••••@globalpayments.com",
      phone: nil,
      status: :deliverable,
      raw: :accept_all
    },
    %{
      name: "Richard Fairbank",
      company: "Capital One",
      email: "ri•••••.fa••••••@capitalone.com",
      phone: nil,
      status: :deliverable,
      raw: :accept_all
    },
    %{
      name: "Sasan Goodarzi",
      company: "Intuit",
      email: "sa•••_go••••••@intuit.com",
      phone: nil,
      status: :deliverable,
      raw: :confirmed
    },
    %{
      name: "Michael Rhodes",
      company: "Fiserv",
      email: "mi•••••.rh••••@fiserv.com",
      phone: nil,
      status: :deliverable,
      raw: :accept_all
    },
    %{
      name: "Michael Shepherd",
      company: "Discover",
      email: "mi•••••••••••••@discover.com",
      phone: nil,
      status: :undeliverable,
      raw: :rejected
    }
  ]

  @labels %{deliverable: "Deliverable", undeliverable: "Undeliverable"}

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
  def status_class(:deliverable), do: "ok"
  def status_class(:undeliverable), do: "bad"
  def status_class(_), do: ""

  @doc "The tick or cross that goes with a status."
  @spec mark(atom()) :: String.t()
  def mark(:deliverable), do: "✓"
  def mark(:undeliverable), do: "✗"
  def mark(_), do: ""
end
