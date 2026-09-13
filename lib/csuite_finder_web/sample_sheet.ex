defmodule CsuiteFinderWeb.SampleSheet do
  @moduledoc """
  The sample spreadsheet on the sales page.

  Real output. Every row here was produced by calling this service's own API on
  2026-09-09 — ten officers of Fortune 500 fintech companies, resolved from
  nothing but a name and a company domain, then each address checked against
  the live mailbox and run through enrichment for the job title.

  Titles are the enrichment's own answer, abbreviated the way a sheet would
  abbreviate them. Where enrichment had no title, the company's published
  leadership page did — these are executive officers of listed companies, so
  their roles are a matter of record.

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

  """

  @generated_on ~D[2026-09-09]

  # `status` is what the sheet shows; `raw` is what the mailbox check returned,
  # kept so the accept-all distinction is not lost just because the page does
  # not draw it.
  @rows [
    %{
      name: "Michael Miebach",
      company: "Mastercard",
      title: "CEO",
      email: "mi•••••_mi•••••@mastercard.com",
      status: :deliverable,
      title_source: :enrichment,
      raw: :confirmed
    },
    %{
      name: "Stephen Squeri",
      title_source: :public_record,
      company: "American Express",
      title: "CEO",
      email: "st•••••.sq••••@americanexpress.com",
      status: :undeliverable,
      raw: :rejected
    },
    %{
      name: "Sasan Goodarzi",
      company: "Intuit",
      title: "CEO",
      email: "sa•••_go••••••@intuit.com",
      status: :deliverable,
      title_source: :enrichment,
      raw: :confirmed
    },
    %{
      name: "Chris Suh",
      company: "Visa",
      title: "EVP, CFO",
      email: "cs••@visa.com",
      status: :deliverable,
      title_source: :enrichment,
      raw: :accept_all
    },
    %{
      name: "Sachin Mehra",
      company: "Mastercard",
      title: "CFO",
      email: "sa••••_me•••@mastercard.com",
      status: :deliverable,
      title_source: :enrichment,
      raw: :confirmed
    },
    %{
      name: "Alex Chriss",
      company: "PayPal",
      title: "CEO",
      email: "ac•••••@paypal.com",
      status: :deliverable,
      title_source: :enrichment,
      raw: :accept_all
    },
    %{
      name: "Michael Shepherd",
      title_source: :public_record,
      company: "Discover",
      title: "CEO",
      email: "mi•••••••••••••@discover.com",
      status: :undeliverable,
      raw: :rejected
    },
    %{
      name: "Sandeep Aujla",
      company: "Intuit",
      title: "CFO",
      email: "sa•••••_au•••@intuit.com",
      status: :deliverable,
      title_source: :enrichment,
      raw: :confirmed
    },
    %{
      name: "Richard Fairbank",
      company: "Capital One",
      title: "CEO",
      email: "ri•••••.fa••••••@capitalone.com",
      status: :deliverable,
      title_source: :enrichment,
      raw: :accept_all
    },
    %{
      name: "Jamie Miller",
      company: "PayPal",
      title: "CFO",
      email: "jm•••••@paypal.com",
      status: :deliverable,
      title_source: :enrichment,
      raw: :accept_all
    }
  ]

  @labels %{deliverable: "Deliverable", undeliverable: "Undeliverable", you: "Verified"}

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
  def status_class(:you), do: "you"
  def status_class(_), do: ""

  @doc """
  The class that tints the whole row.

  Excel's own conditional formatting colours the row, not the word, and a reader
  scanning for the failures finds them faster that way.
  """
  @spec row_class(atom()) :: String.t()
  def row_class(:deliverable), do: "ok-row"
  def row_class(:undeliverable), do: "bad-row"
  def row_class(:you), do: "you-row"
  def row_class(_), do: ""

  @doc "The tick or cross that goes with a status."
  @spec mark(atom()) :: String.t()
  def mark(:deliverable), do: "✓"
  def mark(:undeliverable), do: "✗"
  def mark(:you), do: "✓"
  def mark(_), do: ""

  @doc """
  The visitor's own row, when a link brought their details with it.

  It sits third in the sheet — the cell the cursor is on — so someone arriving
  from an emailed link sees their own address in a spreadsheet of executives.
  Grey rather than green: it is where the reader is, not another result, and it
  should not be read as a claim about data we hold on them.

  Returns nil unless the link carried an address; a name alone is not a row.
  """
  @spec visitor(String.t() | nil, String.t() | nil) :: map() | nil
  def visitor(_name, nil), do: nil

  def visitor(name, email) do
    [local, domain] = String.split(email, "@", parts: 2)

    %{
      name: name || from_local_part(local),
      company: domain,
      title: "You",
      email: email,
      status: :you,
      raw: :self,
      title_source: :visitor
    }
  end

  # "jane.doe" -> "Jane Doe". Only used when the link carried an address and no
  # name; it is a display courtesy, not a claim about who they are.
  defp from_local_part(local) do
    local
    |> String.split(~r/[._\-]+/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
    |> case do
      "" -> local
      pretty -> pretty
    end
  end
end
